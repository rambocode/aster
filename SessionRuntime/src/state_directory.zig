const std = @import("std");

/// Owns a private session directory and its exclusive lifetime lock. The caller
/// supplies an already-open parent directory; names are single path components.
/// Keep this value alive until all service resources have been closed. Never
/// unlink server.lock: replacing its inode would let two servers hold locks.
pub const StateDirectory = struct {
    dir: std.fs.Dir,
    lock_fd: std.posix.fd_t,

    pub fn acquire(parent: std.fs.Dir, name: []const u8) !StateDirectory {
        try validateName(name);
        std.posix.mkdirat(parent.fd, name, 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var dir = try openExisting(parent, name);
        errdefer dir.close();

        const fd = try std.posix.openat(dir.fd, "server.lock", .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
        }, 0o600);
        errdefer std.posix.close(fd);
        const lock = try std.posix.fstat(fd);
        if (!std.posix.S.ISREG(lock.mode) or lock.uid != std.posix.geteuid() or
            lock.mode & 0o777 != 0o600 or lock.nlink != 1)
            return error.UnsafeStateLock;
        std.posix.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => return error.AlreadyRunning,
            else => return err,
        };
        return .{ .dir = dir, .lock_fd = fd };
    }

    pub fn validateName(name: []const u8) !void {
        if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or
            std.mem.eql(u8, name, "..") or std.mem.indexOfAny(u8, name, "/\\\x00") != null)
            return error.InvalidStateName;
    }

    /// Read-only lookup: never creates the directory or acquires/creates its lock.
    pub fn openExisting(parent: std.fs.Dir, name: []const u8) !std.fs.Dir {
        try validateName(name);
        // Linux's path-only directory descriptor cannot fsync metadata commits.
        var dir = try parent.openDir(name, .{ .no_follow = true, .iterate = true });
        errdefer dir.close();
        const info = try std.posix.fstat(dir.fd);
        if (info.uid != std.posix.geteuid() or info.mode & 0o777 != 0o700)
            return error.UnsafeStateDirectory;
        return dir;
    }

    /// Releases the kernel lock and directory handle. Persistent state and the
    /// lock inode remain available for the next service instance.
    pub fn deinit(self: *StateDirectory) void {
        std.posix.close(self.lock_fd);
        self.dir.close();
        self.* = undefined;
    }
};

test "private state is exclusive and reusable without replacing its lock inode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try StateDirectory.acquire(tmp.dir, "session");
    const identity = try std.posix.fstat(first.lock_fd);
    try std.testing.expectError(error.AlreadyRunning, StateDirectory.acquire(tmp.dir, "session"));
    first.deinit();
    var second = try StateDirectory.acquire(tmp.dir, "session");
    defer second.deinit();
    const reopened = try std.posix.fstat(second.lock_fd);
    try std.testing.expectEqual(identity.ino, reopened.ino);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(reopened.mode & 0o777)));
}

test "state rejects traversal and non-private existing directories without repairing them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "", ".", "..", "../other", "a/b", "a\x00b" }) |name|
        try std.testing.expectError(error.InvalidStateName, StateDirectory.acquire(tmp.dir, name));
    try tmp.dir.makeDir("shared");
    var shared = try tmp.dir.openDir("shared", .{});
    defer shared.close();
    try std.posix.fchmod(shared.fd, 0o755);
    try std.testing.expectError(error.UnsafeStateDirectory, StateDirectory.acquire(tmp.dir, "shared"));
    try std.testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast((try std.posix.fstat(shared.fd)).mode & 0o777)));
}

test "state refuses symbolic directory and lock paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    state.deinit();
    try tmp.dir.symLink("session", "alias", .{ .is_directory = true });
    if (StateDirectory.acquire(tmp.dir, "alias")) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedSymlinkRejection;
    } else |_| {}
    var dir = try tmp.dir.openDir("session", .{});
    defer dir.close();
    try dir.deleteFile("server.lock");
    try dir.symLink("target", "server.lock", .{});
    if (StateDirectory.acquire(tmp.dir, "session")) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedSymlinkRejection;
    } else |_| {}
    try std.testing.expectError(error.FileNotFound, dir.statFile("target"));
}

test "state refuses a non-private lock without changing its permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    try std.posix.fchmod(state.lock_fd, 0o644);
    state.deinit();
    try std.testing.expectError(error.UnsafeStateLock, StateDirectory.acquire(tmp.dir, "session"));
}

test "another process cannot acquire a live service lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    const pid = try std.posix.fork();
    if (pid == 0) {
        var second = StateDirectory.acquire(tmp.dir, "session") catch |err|
            std.posix.exit(if (err == error.AlreadyRunning) 42 else 2);
        second.deinit();
        std.posix.exit(3);
    }
    const result = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.posix.W.IFEXITED(result.status));
    try std.testing.expectEqual(@as(u8, 42), std.posix.W.EXITSTATUS(result.status));
}

test "process exit releases the lock without deleting persistent state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pipe = try std.posix.pipe();
    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe[0]);
        const state = StateDirectory.acquire(tmp.dir, "session") catch std.posix.exit(2);
        _ = state; // Deliberately exit without deinit to verify kernel ownership.
        _ = std.posix.write(pipe[1], "R") catch std.posix.exit(3);
        std.posix.exit(0);
    }
    std.posix.close(pipe[1]);
    defer std.posix.close(pipe[0]);
    var ready: [1]u8 = undefined;
    const count = try std.posix.read(pipe[0], &ready);
    const result = std.posix.waitpid(pid, 0);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u8, 'R'), ready[0]);
    try std.testing.expect(std.posix.W.IFEXITED(result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(result.status));
    var recovered = try StateDirectory.acquire(tmp.dir, "session");
    defer recovered.deinit();
}

test "hard-linked lock files are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    state.deinit();
    try std.posix.linkat(tmp.dir.fd, "session/server.lock", tmp.dir.fd, "other.lock", 0);
    try std.testing.expectError(error.UnsafeStateLock, StateDirectory.acquire(tmp.dir, "session"));
}
