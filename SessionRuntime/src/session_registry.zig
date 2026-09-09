const std = @import("std");
const StateDirectory = @import("state_directory.zig").StateDirectory;
const identities = @import("service_identity.zig");
const client = @import("service_client.zig");
const launch = @import("service_launch.zig");

pub const maximum_sessions: usize = 1024;
pub const maximum_name: usize = 128;
/// Bounded per-session probe. A stopped or wedged session must not stall the
/// whole listing, and the registry never infers liveness from the directory.
const probe_ms: u32 = 700;
const stop_ms: u32 = 5000;

pub const State = enum { running, stopped, attention };

/// How a new session's background service is started.
///
/// `in_process` forks directly and is what the standalone CLI uses. A live
/// service must not do that: forking a running server would inherit its signal
/// pipe, PTY descriptors and pool state, and would leave the new daemon as its
/// child to reap. `child_process` re-runs the installed binary's own
/// `server start` entry point instead, which forks, detaches and exits, so the
/// new session's service shares nothing with the session that asked for it.
pub const Launcher = enum { in_process, child_process };

/// One named session as `#/$defs/session` describes it. serverID/serverEpoch are
/// present only for a session whose live service actually answered.
pub const Session = struct {
    sessionID: [36]u8,
    /// The name is stored inline so a Session outlives the listing arena that
    /// produced it; registry results are passed across scopes constantly.
    name_bytes: [maximum_name]u8 = undefined,
    name_length: usize = 0,
    state: State,
    serverID: ?[36]u8 = null,
    serverEpoch: ?[36]u8 = null,

    pub fn name(self: *const Session) []const u8 {
        return self.name_bytes[0..self.name_length];
    }

    /// Builds the descriptor for an already-running local service.
    pub fn withKnown(session_id: [36]u8, server_id: [36]u8, server_epoch: [36]u8, value: []const u8) Session {
        return withName(.{ .sessionID = session_id, .state = .running, .serverID = server_id, .serverEpoch = server_epoch }, value);
    }

    fn withName(session: Session, value: []const u8) Session {
        var result = session;
        result.name_length = value.len;
        @memcpy(result.name_bytes[0..value.len], value);
        return result;
    }
};

/// Owns the names and the session array returned by `list`.
pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    sessions: []Session,
    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The named-session registry is the private state parent directory: one
/// subdirectory per session, each holding that session's own lock, identity,
/// idempotency log and layout snapshot. There is no separate index file, so a
/// crashed writer can never desynchronize the registry from reality.
///
/// A directory without a committed `identity.bin` was never a started session
/// and is deliberately ignored: the protocol requires a stable sessionID, and
/// inventing one for an empty directory would let two listings disagree.
/// Registry view over one private state parent.
///
/// `live` is the identity of the service that is currently serving the request,
/// when the caller is itself one of the registry's sessions. It answers for
/// itself from that value instead of connecting to its own control socket,
/// which it cannot do while it is busy handling this very request.
pub const Registry = struct {
    parent: std.fs.Dir,
    launcher: Launcher = .in_process,
    live: ?Session = null,

    pub fn list(self: Registry, allocator: std.mem.Allocator) !Listing {
        return listIn(allocator, self.parent, self.live);
    }

    pub fn describe(self: Registry, allocator: std.mem.Allocator, name: []const u8) !Session {
        return describeIn(allocator, self.parent, name, self.live);
    }

    pub fn create(self: Registry, allocator: std.mem.Allocator, name: []const u8) !Session {
        return createIn(allocator, self.parent, name, self.launcher);
    }

    pub fn attach(self: Registry, allocator: std.mem.Allocator, session_id: [36]u8) !Session {
        var listing = try self.list(allocator);
        defer listing.deinit();
        return locate(&listing, session_id) orelse error.SessionNotFound;
    }

    /// Stops one session through its own `server.stop` RPC. Never signals a PID
    /// and never touches another session. The layout snapshot is deliberately
    /// left on disk: stopping keeps the structure, only deleting discards it.
    pub fn stop(self: Registry, allocator: std.mem.Allocator, session_id: [36]u8) !Session {
        const found = try self.attach(allocator, session_id);
        // A service cannot drive its own stop handshake from inside a request it
        // is still answering; that is what the session-scope server.stop is for.
        if (self.isSelf(session_id)) return error.SelfSessionTarget;
        if (found.state != .running) return found;
        const reply = try client.stop(allocator, self.parent, found.name(), stop_ms);
        allocator.free(reply.bytes);
        return self.describe(allocator, found.name());
    }

    /// Deletes a stopped session's state directory. A running session is refused
    /// so a delete can never orphan live processes, and only the named session's
    /// own directory is removed.
    pub fn delete(self: Registry, allocator: std.mem.Allocator, session_id: [36]u8) !bool {
        const found = try self.attach(allocator, session_id);
        if (found.state != .stopped) return error.SessionRunning;
        var dir = try StateDirectory.openExisting(self.parent, found.name());
        {
            defer dir.close();
            // Refuse anything that is not this service's own flat state files; an
            // unexpected subdirectory means the caller aimed at the wrong path.
            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind != .file) return error.UnexpectedSessionContent;
            }
            var again = dir.iterate();
            while (try again.next()) |entry| try dir.deleteFile(entry.name);
        }
        try self.parent.deleteDir(found.name());
        return true;
    }

    fn isSelf(self: Registry, session_id: [36]u8) bool {
        const live = self.live orelse return false;
        return std.mem.eql(u8, &live.sessionID, &session_id);
    }
};

fn listIn(allocator: std.mem.Allocator, parent: std.fs.Dir, live: ?Session) !Listing {
    try checkParent(parent);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const temporary = arena.allocator();
    var found: std.ArrayList(Session) = .empty;
    var iterator = parent.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        validateName(entry.name) catch continue;
        if (found.items.len >= maximum_sessions) return error.ResourceLimit;
        var name_bytes: [maximum_name]u8 = undefined;
        @memcpy(name_bytes[0..entry.name.len], entry.name);
        const session = describeIn(allocator, parent, name_bytes[0..entry.name.len], live) catch continue;
        try found.append(temporary, session);
    }
    return .{ .arena = arena, .sessions = try found.toOwnedSlice(temporary) };
}

/// Resolves the real state of one named session. Running is only reported after
/// the service answered on its own socket with a matching sessionID; directory
/// presence alone never counts as running.
fn describeIn(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, live: ?Session) !Session {
    var dir = try StateDirectory.openExisting(parent, name);
    var identity: ?identities.Identity = null;
    {
        defer dir.close();
        identity = identities.readExisting(dir) catch return error.SessionUnreadable;
    }
    const value = identity orelse return error.SessionNotStarted;
    var session = Session.withName(.{ .sessionID = identities.uuidText(value.session_id), .state = .stopped }, name);
    if (live) |current| {
        if (std.mem.eql(u8, &current.sessionID, &session.sessionID)) {
            session.state = .running;
            session.serverID = current.serverID;
            session.serverEpoch = current.serverEpoch;
            return session;
        }
    }
    const reply = client.status(allocator, parent, name, probe_ms) catch |err| switch (err) {
        // No socket, or a stale one nobody listens on: the service is gone.
        error.FileNotFound, error.ConnectionRefused, error.ServiceDisconnected => return session,
        // Anything else means a service may exist but could not be verified.
        else => {
            session.state = .attention;
            return session;
        },
    };
    defer allocator.free(reply.bytes);
    if (reply.is_error) {
        session.state = .attention;
        return session;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, reply.bytes, .{}) catch {
        session.state = .attention;
        return session;
    };
    defer parsed.deinit();
    const target = parsed.value.object.get("target") orelse {
        session.state = .attention;
        return session;
    };
    const server_id = text(target, "serverID") orelse return attention(&session);
    const server_epoch = text(target, "serverEpoch") orelse return attention(&session);
    const session_id = text(target, "sessionID") orelse return attention(&session);
    // A live service that does not present the committed sessionID is not this
    // session; report attention rather than adopting its identity.
    if (!std.mem.eql(u8, session_id, &session.sessionID)) return attention(&session);
    session.state = .running;
    session.serverID = server_id[0..36].*;
    session.serverEpoch = server_epoch[0..36].*;
    return session;
}

fn attention(session: *Session) Session {
    session.state = .attention;
    return session.*;
}

fn text(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const item = value.object.get(key) orelse return null;
    if (item != .string or item.string.len != 36) return null;
    return item.string;
}

/// Creates a named session and starts its own independent background service.
/// Each session gets its own directory, lock, socket and process, so a fault in
/// one session cannot reach another.
fn createIn(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, launcher: Launcher) !Session {
    try checkParent(parent);
    try validateName(name);
    if (existing(parent, name)) return error.SessionExists;
    var count: usize = 0;
    var iterator = parent.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .directory) count += 1;
    }
    if (count >= maximum_sessions) return error.ResourceLimit;
    switch (launcher) {
        .in_process => {
            const report = try launch.startAt(allocator, parent, name);
            allocator.free(report);
        },
        .child_process => try startDetached(allocator, parent, name),
    }
    return describeIn(allocator, parent, name, null);
}

/// Runs the installed binary's own background launcher and waits for it. That
/// process performs the fork/detach and exits, so the new daemon is re-parented
/// away and never becomes a zombie child of the caller.
fn startDetached(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent_path = try parent.realpath(".", &buffer);
    const executable = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    var child = std.process.Child.init(&.{ executable, "server", "start", parent_path, name }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) return error.StartupOutcomeUnknown;
}

fn existing(parent: std.fs.Dir, name: []const u8) bool {
    _ = std.posix.fstatat(parent.fd, name, std.posix.AT.SYMLINK_NOFOLLOW) catch return false;
    return true;
}

fn locate(listing: *Listing, session_id: [36]u8) ?Session {
    for (listing.sessions) |session| {
        if (std.mem.eql(u8, &session.sessionID, &session_id)) return session;
    }
    return null;
}

fn checkParent(parent: std.fs.Dir) !void {
    const info = try std.posix.fstat(parent.fd);
    if (info.uid != std.posix.geteuid() or info.mode & 0o077 != 0) return error.UnsafeStateParent;
}

/// Registry names are single, printable path components. `.` and `..` would
/// escape the registry, and control characters would make listings ambiguous.
pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > maximum_name) return error.InvalidSessionName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidSessionName;
    for (name) |byte| {
        if (byte == '/' or byte == '\\' or byte < 0x20 or byte == 0x7f) return error.InvalidSessionName;
    }
    StateDirectory.validateName(name) catch return error.InvalidSessionName;
}

test "session registry names reject traversal separators and control bytes" {
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b", "a\x1bb" }) |name|
        try std.testing.expectError(error.InvalidSessionName, validateName(name));
    try validateName("work");
    try validateName("a" ** 128);
    try std.testing.expectError(error.InvalidSessionName, validateName("a" ** 129));
}

test "session registry ignores directories that never committed an identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.posix.fchmod(tmp.dir.fd, 0o700);
    try std.posix.mkdirat(tmp.dir.fd, "unstarted", 0o700);
    const view = Registry{ .parent = tmp.dir };
    var listing = try view.list(std.testing.allocator);
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 0), listing.sessions.len);
}
