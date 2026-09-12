const std = @import("std");
const StateDirectory = @import("state_directory.zig").StateDirectory;
const identities = @import("service_identity.zig");
const ServiceSocket = @import("service_socket.zig").ServiceSocket;

/// Owns the startup resources of one service process. Call before creating any
/// threads; cwd belongs to this service for the lifetime of the instance. Only
/// after open succeeds may the daemon send its private ready report.
pub const ServiceInstance = struct {
    state: StateDirectory,
    identity: identities.Identity,
    epoch: [16]u8,
    socket: ServiceSocket,
    previous_cwd: std.fs.Dir,
    /// Registry parent, kept open for the instance lifetime so registry-scope
    /// requests resolve without re-walking a path the caller may have changed.
    parent: std.fs.Dir,

    pub fn open(parent: std.fs.Dir, name: []const u8) !ServiceInstance {
        var previous = try std.fs.cwd().openDir(".", .{});
        errdefer previous.close();
        var retained = try parent.openDir(".", .{ .iterate = true });
        errdefer retained.close();
        var state = try StateDirectory.acquire(parent, name);
        errdefer state.deinit();
        const identity = try identities.Identity.loadOrCreate(&state);
        const epoch = identities.newUUID();
        try std.posix.fchdir(state.dir.fd);
        const socket = ServiceSocket.listen(&state) catch |err| {
            std.posix.fchdir(previous.fd) catch return error.ServiceDirectoryRestoreFailed;
            return err;
        };
        return .{ .state = state, .identity = identity, .epoch = epoch, .socket = socket, .previous_cwd = previous, .parent = retained };
    }

    /// Closes the endpoint before releasing its lifetime lock. Persistent
    /// identity and state files remain. Cleanup errors propagate to the caller.
    pub fn close(self: *ServiceInstance) !void {
        defer self.* = undefined;
        defer self.previous_cwd.close();
        defer self.parent.close();
        defer self.state.deinit();
        const socket_result = self.socket.close();
        try std.posix.fchdir(self.previous_cwd.fd);
        try socket_result;
    }
};

test "service restart preserves identity and changes only the incarnation epoch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try ServiceInstance.open(tmp.dir, "session");
    const identity = first.identity;
    const epoch = first.epoch;
    try first.close();
    var second = try ServiceInstance.open(tmp.dir, "session");
    defer second.close() catch @panic("test service cleanup failed");
    try std.testing.expectEqualDeep(identity, second.identity);
    try std.testing.expect(!std.mem.eql(u8, &epoch, &second.epoch));
}

test "socket initialization failure restores cwd and releases startup lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    var file = try state.dir.createFile("control.sock", .{});
    file.close();
    state.deinit();
    const before = try std.posix.fstatat(std.posix.AT.FDCWD, ".", 0);
    try std.testing.expectError(error.UnsafeServiceSocket, ServiceInstance.open(tmp.dir, "session"));
    const after = try std.posix.fstatat(std.posix.AT.FDCWD, ".", 0);
    try std.testing.expectEqual(before.ino, after.ino);
    try std.testing.expectEqual(before.dev, after.dev);
    var recovered = try StateDirectory.acquire(tmp.dir, "session");
    defer recovered.deinit();
    try std.testing.expect((try recovered.dir.statFile("control.sock")).kind == .file);
}
