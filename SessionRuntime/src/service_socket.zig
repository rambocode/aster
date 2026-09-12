const std = @import("std");
const StateDirectory = @import("state_directory.zig").StateDirectory;
const c = @cImport({
    @cInclude("session_pty.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub const socket_name = "control.sock";

/// The service enters its locked state directory once, before starting threads.
/// PTY children always receive their own explicit cwd. Keeping bind relative
/// avoids Unix path length limits and parent-path replacement during startup.
pub const ServiceSocket = struct {
    server: std.net.Server,
    directory_fd: std.posix.fd_t,
    identity: std.posix.Stat,

    pub fn listen(state: *StateDirectory) !ServiceSocket {
        const directory = try std.posix.fstat(state.dir.fd);
        const cwd = try std.posix.fstatat(std.posix.AT.FDCWD, ".", 0);
        if (!sameFile(directory, cwd)) return error.ServiceDirectoryNotCurrent;
        try removeStale(state.dir.fd);
        var server = try (try std.net.Address.initUnix(socket_name)).listen(.{ .force_nonblocking = true });
        errdefer server.deinit();
        const identity = try std.posix.fstatat(state.dir.fd, socket_name, std.posix.AT.SYMLINK_NOFOLLOW);
        errdefer removeOwned(state.dir.fd, identity) catch {};
        if (!std.posix.S.ISSOCK(identity.mode) or identity.uid != std.posix.geteuid())
            return error.UnsafeServiceSocket;
        if (c.chmod(socket_name, 0o600) != 0) return error.SocketPermissionFailed;
        return .{ .server = server, .directory_fd = state.dir.fd, .identity = identity };
    }

    /// Returns one nonblocking same-user connection, null when no connection is
    /// queued, or PeerRejected after closing an unauthenticated connection.
    pub fn accept(self: *ServiceSocket) !?std.net.Server.Connection {
        const connection = self.server.accept() catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        errdefer connection.stream.close();
        const fd = connection.stream.handle;
        if (c.session_same_user(fd) != 1) return error.PeerRejected;
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        return connection;
    }

    /// Close the listener before releasing StateDirectory. Only this listener's
    /// inode is unlinked; a renamed/replaced path is left untouched.
    pub fn close(self: *ServiceSocket) !void {
        defer self.* = undefined;
        self.server.deinit();
        try removeOwned(self.directory_fd, self.identity);
    }
};

fn sameFile(a: std.posix.Stat, b: std.posix.Stat) bool {
    return a.dev == b.dev and a.ino == b.ino;
}

fn removeOwned(directory: std.posix.fd_t, identity: std.posix.Stat) !void {
    const current = std.posix.fstatat(directory, socket_name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (sameFile(current, identity) and std.posix.S.ISSOCK(current.mode))
        try std.posix.unlinkat(directory, socket_name, 0);
}

fn removeStale(directory: std.posix.fd_t) !void {
    const existing = std.posix.fstatat(directory, socket_name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (!std.posix.S.ISSOCK(existing.mode) or existing.uid != std.posix.geteuid() or existing.nlink != 1)
        return error.UnsafeServiceSocket;
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(fd);
    const address = try std.net.Address.initUnix(socket_name);
    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.ConnectionRefused => {
            try removeOwned(directory, existing);
            return;
        },
        // Pending/full backlogs are not evidence of a dead service.
        error.WouldBlock, error.ConnectionPending => return error.AlreadyListening,
        else => return err,
    };
    return error.AlreadyListening;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    state: StateDirectory,
    cwd: std.fs.Dir,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var cwd = try std.fs.cwd().openDir(".", .{});
        errdefer cwd.close();
        var state = try StateDirectory.acquire(tmp.dir, "session");
        errdefer state.deinit();
        try std.posix.fchdir(state.dir.fd);
        return .{ .tmp = tmp, .state = state, .cwd = cwd };
    }

    fn deinit(self: *Fixture) void {
        std.posix.fchdir(self.cwd.fd) catch @panic("test cwd restoration failed");
        self.cwd.close();
        self.state.deinit();
        self.tmp.cleanup();
    }
};

test "listener is private and accepts a nonblocking same-user connection" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var endpoint = try ServiceSocket.listen(&fixture.state);
    defer endpoint.close() catch @panic("socket cleanup failed");
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast((try std.posix.fstatat(fixture.state.dir.fd, socket_name, 0)).mode & 0o777)));
    try std.testing.expect(try endpoint.accept() == null);
    const client = try std.net.connectUnixSocket(socket_name);
    defer client.close();
    const accepted = (try endpoint.accept()).?;
    defer accepted.stream.close();
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, accepted.stream.read(&byte));
}

test "live listener is never removed by a second bind attempt" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var endpoint = try ServiceSocket.listen(&fixture.state);
    defer endpoint.close() catch @panic("socket cleanup failed");
    try std.testing.expectError(error.AlreadyListening, ServiceSocket.listen(&fixture.state));
    const current = try std.posix.fstatat(fixture.state.dir.fd, socket_name, 0);
    try std.testing.expect(sameFile(current, endpoint.identity));
}

test "closed listener residue is recovered while the lifetime lock is held" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var old = try (try std.net.Address.initUnix(socket_name)).listen(.{});
    old.deinit();
    var recovered = try ServiceSocket.listen(&fixture.state);
    try recovered.close();
    try std.testing.expectError(error.FileNotFound, fixture.state.dir.statFile(socket_name));
}

test "regular files and symlinks at the socket path are preserved" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var file = try fixture.state.dir.createFile(socket_name, .{});
    file.close();
    try std.testing.expectError(error.UnsafeServiceSocket, ServiceSocket.listen(&fixture.state));
    try std.testing.expect((try fixture.state.dir.statFile(socket_name)).kind == .file);
    try fixture.state.dir.deleteFile(socket_name);
    try fixture.state.dir.symLink("missing-target", socket_name, .{});
    try std.testing.expectError(error.UnsafeServiceSocket, ServiceSocket.listen(&fixture.state));
    var path: [100]u8 = undefined;
    try std.testing.expectEqualStrings("missing-target", try fixture.state.dir.readLink(socket_name, &path));
}

test "closing a listener preserves a replacement file" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var endpoint = try ServiceSocket.listen(&fixture.state);
    try fixture.state.dir.rename(socket_name, "retired.sock");
    var replacement = try fixture.state.dir.createFile(socket_name, .{});
    replacement.close();
    try endpoint.close();
    try std.testing.expect((try fixture.state.dir.statFile(socket_name)).kind == .file);
}

test "binding requires the locked directory to be current" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try std.posix.fchdir(fixture.cwd.fd);
    try std.testing.expectError(error.ServiceDirectoryNotCurrent, ServiceSocket.listen(&fixture.state));
}

test "kernel peer credentials reject a different uid" {
    if (std.posix.geteuid() != 0) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var endpoint = try ServiceSocket.listen(&fixture.state);
    defer endpoint.close() catch @panic("socket cleanup failed");
    // Only this temporary test directory is opened to the child UID so the
    // credential check is exercised independently of filesystem permissions.
    try std.posix.fchmod(fixture.state.dir.fd, 0o755);
    if (c.chmod(socket_name, 0o666) != 0) return error.TestPermissionFailed;
    const child = try std.posix.fork();
    if (child == 0) {
        if (c.setuid(65534) != 0) std.posix.exit(2);
        const stream = std.net.connectUnixSocket(socket_name) catch std.posix.exit(3);
        stream.close();
        std.posix.exit(0);
    }
    const result = std.posix.waitpid(child, 0);
    try std.testing.expect(std.posix.W.IFEXITED(result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(result.status));
    try std.testing.expectError(error.PeerRejected, endpoint.accept());
    try std.testing.expect(try endpoint.accept() == null);
}
