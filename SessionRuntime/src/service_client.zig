const std = @import("std");
const StateDirectory = @import("state_directory.zig").StateDirectory;
const identities = @import("service_identity.zig");
const Hello = @import("handshake.zig").Hello;
const Request = @import("operation_request.zig").Request;
const replies = @import("operation_response.zig");
const control = @import("service_control.zig");
const protocol = @import("protocol.zig");
const c = @cImport({
    @cInclude("session_pty.h");
});

// Decode required wire fields without the server constructor's convenience defaults.
const StatusWire = struct {
    version: []const u8,
    protocolMajor: u16,
    protocolMinor: u16,
    capabilities: []const []const u8,
};

pub const Reply = struct { bytes: []u8, is_error: bool };

/// Read-only status transaction. The returned JSON is caller-owned. Socket I/O
/// shares one monotonic deadline; peer UID, hello and response identity are all
/// validated before success. This function never starts or repairs a service.
/// It temporarily changes cwd for short Unix socket paths; use only in the
/// single-threaded CLI/bootstrap process, never from an in-process UI client.
pub fn statusAtPath(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, timeout_ms: u32) !Reply {
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    return status(allocator, parent, name, timeout_ms);
}

pub fn status(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, timeout_ms: u32) !Reply {
    return transact(allocator, parent, name, timeout_ms, .@"server.status");
}

pub fn stopAtPath(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, timeout_ms: u32) !Reply {
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    return stop(allocator, parent, name, timeout_ms);
}

/// Stops one named session through its own control socket. Never sends a signal
/// and never touches any sibling session's state.
pub fn stop(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, timeout_ms: u32) !Reply {
    return transact(allocator, parent, name, timeout_ms, .@"server.stop");
}

fn transact(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, timeout_ms: u32, comptime operation: @import("operation_kind.zig").Operation) !Reply {
    const info = try std.posix.fstat(parent.fd);
    if (info.uid != std.posix.geteuid() or info.mode & 0o077 != 0) return error.UnsafeStateParent;
    var deadline = try Deadline.init(timeout_ms);
    const stream = try connect(parent, name, &deadline);
    defer stream.close();
    const scratch = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(scratch);
    var bounded = std.heap.FixedBufferAllocator.init(scratch);
    const hello_bytes = try readFrame(allocator, stream, &deadline);
    defer allocator.free(hello_bytes);
    const hello = try std.json.parseFromSlice(Hello, bounded.allocator(), hello_bytes, .{ .ignore_unknown_fields = true });
    defer hello.deinit();
    try hello.value.negotiateRequired(if (operation == .@"server.stop") &.{ "server_lifecycle", "health_check" } else &.{"health_check"});
    const request_id = identities.uuidText(identities.newUUID());
    const client_id = identities.uuidText(identities.newUUID());
    const request = Request{ .type = "request", .requestID = &request_id, .clientID = &client_id, .scope = .session, .operation = operation, .target = .{ .serverID = hello.value.serverID, .serverEpoch = hello.value.serverEpoch, .sessionID = hello.value.sessionID }, .params = .{ .object = std.json.ObjectMap.init(bounded.allocator()) } };
    const encoded = try std.json.Stringify.valueAlloc(allocator, request, .{ .emit_null_optional_fields = false });
    defer allocator.free(encoded);
    var header: [5]u8 = undefined;
    header[0] = 1;
    std.mem.writeInt(u32, header[1..5], @intCast(encoded.len), .big);
    try writeAll(stream, &header, &deadline);
    try writeAll(stream, encoded, &deadline);
    const response = try readReply(allocator, stream, &deadline, request.target.?);
    errdefer allocator.free(response);
    const tag = try std.json.parseFromSlice(std.json.Value, bounded.allocator(), response, .{});
    defer tag.deinit();
    if (tag.value != .object) return error.InvalidServiceStatus;
    const message_type = tag.value.object.get("type") orelse return error.InvalidServiceStatus;
    if (message_type != .string) return error.InvalidServiceStatus;
    const is_error = std.mem.eql(u8, message_type.string, "error");
    if (is_error) {
        if (!tag.value.object.contains("error") or tag.value.object.contains("result")) return error.InvalidServiceStatus;
        const failure = try std.json.parseFromSlice(replies.Failure, bounded.allocator(), response, .{ .ignore_unknown_fields = true });
        defer failure.deinit();
        try failure.value.validate(request);
        return .{ .bytes = response, .is_error = true };
    }
    if (!std.mem.eql(u8, message_type.string, "response") or !tag.value.object.contains("result") or
        tag.value.object.contains("error")) return error.InvalidServiceStatus;
    if (operation == .@"server.stop") {
        const stopped = try std.json.parseFromSlice(replies.Response(struct { stopping: bool }), bounded.allocator(), response, .{ .ignore_unknown_fields = true });
        defer stopped.deinit();
        try stopped.value.validate(request);
        if (!stopped.value.result.stopping) return error.InvalidServiceStop;
        try waitStopped(allocator, parent, name, stream, hello.value.serverEpoch, &deadline);
        const completed = try std.json.Stringify.valueAlloc(allocator, .{
            .type = "server_stop",
            .state = "stopped",
            .target = request.target.?,
        }, .{});
        allocator.free(response);
        return .{ .bytes = completed, .is_error = false };
    }
    const parsed = try std.json.parseFromSlice(replies.Response(StatusWire), bounded.allocator(), response, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try parsed.value.validate(request);
    const result = parsed.value.result;
    if (result.version.len == 0 or result.version.len > 128 or result.protocolMajor != hello.value.protocolMajor or
        result.protocolMinor != hello.value.protocolMinor or result.capabilities.len != hello.value.capabilities.len)
        return error.InvalidServiceStatus;
    for (result.capabilities, 0..) |actual, index| {
        var present = false;
        for (hello.value.capabilities) |expected| {
            if (std.mem.eql(u8, actual, expected)) {
                present = true;
                break;
            }
        }
        if (!present) return error.InvalidServiceStatus;
        for (result.capabilities[0..index]) |earlier| {
            if (std.mem.eql(u8, actual, earlier)) return error.InvalidServiceStatus;
        }
    }
    return .{ .bytes = response, .is_error = false };
}

pub fn connect(parent: std.fs.Dir, name: []const u8, deadline: *Deadline) !std.net.Stream {
    var dir = try StateDirectory.openExisting(parent, name);
    defer dir.close();
    const stat = try std.posix.fstatat(dir.fd, "control.sock", std.posix.AT.SYMLINK_NOFOLLOW);
    if (!std.posix.S.ISSOCK(stat.mode) or stat.uid != std.posix.geteuid() or stat.mode & 0o777 != 0o600)
        return error.UnsafeServiceSocket;
    var previous = try std.fs.cwd().openDir(".", .{});
    defer previous.close();
    try std.posix.fchdir(dir.fd);
    const result = connectCurrent(deadline);
    const restored = std.posix.fchdir(previous.fd);
    if (restored) |_| {} else |err| {
        if (result) |stream| stream.close() else |_| {}
        return err;
    }
    return result;
}

fn connectCurrent(deadline: *Deadline) !std.net.Stream {
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    errdefer std.posix.close(fd);
    const address = try std.net.Address.initUnix("control.sock");
    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {
            try deadline.wait(fd, std.posix.POLL.OUT);
            try std.posix.getsockoptError(fd);
        },
        else => return err,
    };
    if (c.session_same_user(fd) != 1) return error.ServicePeerRejected;
    return .{ .handle = fd };
}

pub const Deadline = struct {
    clock: std.time.Timer,
    budget: u64,
    pub fn init(milliseconds: u32) !Deadline {
        if (milliseconds == 0 or milliseconds > 60_000) return error.InvalidClientTimeout;
        return .{ .clock = try std.time.Timer.start(), .budget = @as(u64, milliseconds) * std.time.ns_per_ms };
    }
    fn remainingMilliseconds(self: *Deadline) !u32 {
        const elapsed = self.clock.read();
        if (elapsed >= self.budget) return error.ServiceTimedOut;
        return @intCast((self.budget - elapsed + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
    }
    pub fn wait(self: *Deadline, fd: std.posix.fd_t, events: i16) !void {
        const elapsed = self.clock.read();
        if (elapsed >= self.budget) return error.ServiceTimedOut;
        const remaining = (self.budget - elapsed + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(remaining)) == 0) return error.ServiceTimedOut;
        if (fds[0].revents & events == 0) return error.ServiceDisconnected;
    }
};

pub fn writeAll(stream: std.net.Stream, bytes: []const u8, deadline: *Deadline) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try deadline.wait(stream.handle, std.posix.POLL.OUT);
        const count = std.posix.send(stream.handle, bytes[offset..], std.posix.MSG.NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (count == 0) return error.ServiceDisconnected;
        offset += count;
    }
}

fn readExactly(stream: std.net.Stream, bytes: []u8, deadline: *Deadline) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try deadline.wait(stream.handle, std.posix.POLL.IN);
        const count = stream.read(bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (count == 0) return error.ServiceDisconnected;
        offset += count;
    }
}

pub fn readFrame(allocator: std.mem.Allocator, stream: std.net.Stream, deadline: *Deadline) ![]u8 {
    var header: [5]u8 = undefined;
    try readExactly(stream, &header, deadline);
    const size = std.mem.readInt(u32, header[1..5], .big);
    if (header[0] != 1 or size == 0 or size > protocol.maximum_control_bytes) return error.InvalidServiceFrame;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    try readExactly(stream, bytes, deadline);
    try control.checkDepth(bytes);
    return bytes;
}

fn waitStopped(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, stream: std.net.Stream, epoch: []const u8, deadline: *Deadline) !void {
    // A stop acknowledgement alone is not completion. Wait for this connection
    // to close, then verify lock release or a different verified incarnation.
    while (true) {
        deadline.wait(stream.handle, std.posix.POLL.IN) catch |err| {
            if (err != error.ServiceDisconnected) return err;
        };
        var scratch: [512]u8 = undefined;
        const count = stream.read(&scratch) catch |err| switch (err) {
            error.WouldBlock => continue,
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (count == 0) break;
        // 服务进入 stopping 后仍会有界排空已生成的回复与事件（设计草案 §5），这些
        // 字节完全合法。旧实现把它们当成停止失败，结果是「只要还有运行中的终端就必然
        // 报 InvalidServiceStop」——服务其实已正常停止，退出码却不可信，会诱使调用方
        // 重试或升级成信号。这里丢弃并继续等待连接关闭，上界仍由 deadline 兜底。
    }
    while (true) {
        _ = try deadline.remainingMilliseconds();
        var directory = try StateDirectory.openExisting(parent, name);
        defer directory.close();
        const fd = try std.posix.openat(directory.fd, "server.lock", .{
            .ACCMODE = .RDONLY,
            .NOFOLLOW = true,
            .CLOEXEC = true,
            .NONBLOCK = true,
        }, 0);
        const released = lockReleased(fd);
        std.posix.close(fd);
        if (try released) return;
        const current = status(allocator, parent, name, @min(300, try deadline.remainingMilliseconds())) catch |err| switch (err) {
            error.FileNotFound, error.ConnectionRefused, error.ServiceDisconnected, error.ServiceTimedOut => {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer allocator.free(current.bytes);
        if (!current.is_error) {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, current.bytes, .{});
            defer parsed.deinit();
            const actual = parsed.value.object.get("target").?.object.get("serverEpoch").?.string;
            if (!std.mem.eql(u8, actual, epoch)) return; // Never stop the replacement.
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn lockReleased(fd: std.posix.fd_t) !bool {
    const info = try std.posix.fstat(fd);
    if (!std.posix.S.ISREG(info.mode) or info.uid != std.posix.geteuid() or
        info.mode & 0o777 != 0o600 or info.nlink != 1) return error.UnsafeStateLock;
    std.posix.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return err,
    };
    return true;
}

/// One-shot request clients may receive lifecycle events before their reply.
/// Validate and consume them without treating them as the requested result.
/// The same transport deadline bounds the entire event/reply sequence.
pub fn readReply(allocator: std.mem.Allocator, stream: std.net.Stream, deadline: *Deadline, target: replies.Target) ![]u8 {
    const scratch = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(scratch);
    var bounded = std.heap.FixedBufferAllocator.init(scratch);
    var after: u64 = 0;
    var revision: ?u64 = null;
    for (0..256) |_| {
        bounded.reset();
        const bytes = try readFrame(allocator, stream, deadline);
        var retained = false;
        defer if (!retained) allocator.free(bytes);
        try control.checkDepth(bytes);
        const tag = try std.json.parseFromSlice(struct { type: []const u8 }, bounded.allocator(), bytes, .{ .ignore_unknown_fields = true });
        defer tag.deinit();
        if (!std.mem.eql(u8, tag.value.type, "event")) {
            retained = true;
            return bytes;
        }
        const event = try std.json.parseFromSlice(replies.Event(std.json.Value), bounded.allocator(), bytes, .{});
        defer event.deinit();
        try event.value.validate(event.value.event, target, after, revision);
        after = event.value.sequence;
        revision = event.value.revision;
    }
    return error.TooManyEventsBeforeReply;
}
