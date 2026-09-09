const std = @import("std");
const StateDirectory = @import("state_directory.zig").StateDirectory;
const file_name = "identity.bin";
const pending_name = "identity.pending";
const record_size = 68; // ASI1 + two UUIDs + SHA-256 of the first 36 bytes.

pub const Identity = struct {
    server_id: [16]u8,
    session_id: [16]u8,

    /// Called once during serialized initialization while StateDirectory is
    /// locked. Existing committed identities are immutable, never repaired or
    /// regenerated on corruption. Errors after rename may mean the identity was
    /// committed: retry by reading, not by deleting the committed file.
    pub fn loadOrCreate(state: *StateDirectory) !Identity {
        if (try readExisting(state.dir)) |existing| return existing;
        try discardPending(state.dir);
        const value = Identity{ .server_id = newUUID(), .session_id = newUUID() };
        const record = value.encode();
        const fd = try std.posix.openat(state.dir.fd, pending_name, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0o600);
        var file = std.fs.File{ .handle = fd };
        defer file.close();
        errdefer state.dir.deleteFile(pending_name) catch {};
        try validateFile(try std.posix.fstat(fd));
        try file.writeAll(&record);
        try file.sync();
        try state.dir.rename(pending_name, file_name);
        try std.posix.fsync(state.dir.fd);
        return value;
    }

    fn encode(self: Identity) [record_size]u8 {
        var bytes: [record_size]u8 = undefined;
        @memcpy(bytes[0..4], "ASI1");
        @memcpy(bytes[4..20], &self.server_id);
        @memcpy(bytes[20..36], &self.session_id);
        std.crypto.hash.sha2.Sha256.hash(bytes[0..36], bytes[36..68], .{});
        return bytes;
    }

    fn decode(bytes: []const u8) !Identity {
        if (bytes.len != record_size or !std.mem.eql(u8, bytes[0..4], "ASI1"))
            return error.InvalidServiceIdentity;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..36], &digest, .{});
        if (!std.mem.eql(u8, &digest, bytes[36..68])) return error.InvalidServiceIdentity;
        const value = Identity{ .server_id = bytes[4..20].*, .session_id = bytes[20..36].* };
        for ([_][16]u8{ value.server_id, value.session_id }) |id| {
            if (id[6] & 0xf0 != 0x40 or id[8] & 0xc0 != 0x80) return error.InvalidServiceIdentity;
        }
        if (std.mem.eql(u8, &value.server_id, &value.session_id)) return error.InvalidServiceIdentity;
        return value;
    }
};

/// Each service incarnation calls this separately; epochs are never persisted.
pub fn newUUID() [16]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return bytes;
}

pub fn uuidText(bytes: [16]u8) [36]u8 {
    const hex = "0123456789abcdef";
    var result: [36]u8 = undefined;
    var offset: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            result[offset] = '-';
            offset += 1;
        }
        result[offset] = hex[byte >> 4];
        result[offset + 1] = hex[byte & 15];
        offset += 2;
    }
    return result;
}

fn validateFile(stat: std.posix.Stat) !void {
    if (!std.posix.S.ISREG(stat.mode) or stat.uid != std.posix.geteuid() or
        stat.mode & 0o777 != 0o600 or stat.nlink != 1)
        return error.UnsafeIdentityFile;
}

fn readExisting(dir: std.fs.Dir) !?Identity {
    const fd = std.posix.openat(dir.fd, file_name, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var file = std.fs.File{ .handle = fd };
    defer file.close();
    const stat = try std.posix.fstat(fd);
    try validateFile(stat);
    if (stat.size != record_size) return error.InvalidServiceIdentity;
    var bytes: [record_size + 1]u8 = undefined;
    const count = try file.readAll(&bytes);
    return try Identity.decode(bytes[0..count]);
}

/// This reserved staging file is never authoritative. Recover interrupted writes
/// only when its type, owner, permissions and link count match a private file.
fn discardPending(dir: std.fs.Dir) !void {
    const stat = std.posix.fstatat(dir.fd, pending_name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try validateFile(stat);
    try dir.deleteFile(pending_name);
}

test "committed service identities survive lock release and epochs are fresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try StateDirectory.acquire(tmp.dir, "session");
    const identity = try Identity.loadOrCreate(&first);
    const file = try first.dir.statFile(file_name);
    first.deinit();
    var second = try StateDirectory.acquire(tmp.dir, "session");
    defer second.deinit();
    try std.testing.expectEqualDeep(identity, try Identity.loadOrCreate(&second));
    try std.testing.expectEqual(file.inode, (try second.dir.statFile(file_name)).inode);
    try std.testing.expect(!std.mem.eql(u8, &newUUID(), &newUUID()));
    const text = uuidText(identity.server_id);
    try std.testing.expect(text[8] == '-' and text[14] == '4' and text[23] == '-');
}

test "corrupt committed identity is rejected and remains unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    const identity = try Identity.loadOrCreate(&state);
    var damaged = identity.encode();
    damaged[12] ^= 1;
    var file = try state.dir.createFile(file_name, .{ .mode = 0o600 });
    try file.writeAll(&damaged);
    file.close();
    try std.testing.expectError(error.InvalidServiceIdentity, Identity.loadOrCreate(&state));
    const actual = try state.dir.readFileAlloc(std.testing.allocator, file_name, 100);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, &damaged, actual);
}

test "incomplete staging identity is discarded before first commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    var file = try state.dir.createFile(pending_name, .{ .mode = 0o600 });
    try file.writeAll("ASI");
    file.close();
    _ = try Identity.loadOrCreate(&state);
    try std.testing.expectError(error.FileNotFound, state.dir.statFile(pending_name));
    try std.testing.expectEqual(@as(u64, record_size), (try state.dir.statFile(file_name)).size);
}

test "unsafe staging and committed paths are never followed or repaired" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    try state.dir.symLink("outside", pending_name, .{});
    try std.testing.expectError(error.UnsafeIdentityFile, Identity.loadOrCreate(&state));
    try state.dir.deleteFile(pending_name);
    try state.dir.symLink("outside", file_name, .{});
    if (Identity.loadOrCreate(&state)) |_| return error.ExpectedRejection else |_| {}
    try std.testing.expectError(error.FileNotFound, state.dir.statFile("outside"));
}

test "identity format rejects unknown versions lengths and checksummed invalid UUIDs" {
    const identity = Identity{ .server_id = newUUID(), .session_id = newUUID() };
    var bytes = identity.encode();
    try std.testing.expectError(error.InvalidServiceIdentity, Identity.decode(bytes[0..20]));
    bytes[3] = '2';
    try std.testing.expectError(error.InvalidServiceIdentity, Identity.decode(&bytes));
    bytes = identity.encode();
    bytes[10] = 0;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..36], bytes[36..68], .{});
    try std.testing.expectError(error.InvalidServiceIdentity, Identity.decode(&bytes));
}

test "committed identity permissions and hard links are enforced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    _ = try Identity.loadOrCreate(&state);
    var file = try state.dir.openFile(file_name, .{});
    defer file.close();
    try file.chmod(0o644);
    try std.testing.expectError(error.UnsafeIdentityFile, Identity.loadOrCreate(&state));
    try file.chmod(0o600);
    try std.posix.linkat(state.dir.fd, file_name, state.dir.fd, "linked", 0);
    try std.testing.expectError(error.UnsafeIdentityFile, Identity.loadOrCreate(&state));
}

test "fresh process reads the committed identity rather than allocating a new one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    const expected = try Identity.loadOrCreate(&state);
    state.deinit();
    const pipe = try std.posix.pipe();
    const pid = try std.posix.fork();
    if (pid == 0) {
        std.posix.close(pipe[0]);
        var child_state = StateDirectory.acquire(tmp.dir, "session") catch std.posix.exit(2);
        const actual = Identity.loadOrCreate(&child_state) catch std.posix.exit(3);
        const record = actual.encode();
        _ = std.posix.write(pipe[1], &record) catch std.posix.exit(4);
        child_state.deinit();
        std.posix.exit(0);
    }
    std.posix.close(pipe[1]);
    var reader = std.fs.File{ .handle = pipe[0] };
    defer reader.close();
    var record: [record_size]u8 = undefined;
    const count = try reader.readAll(&record);
    const result = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.posix.W.IFEXITED(result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(result.status));
    try std.testing.expectEqual(@as(usize, record_size), count);
    try std.testing.expectEqualDeep(expected, try Identity.decode(&record));
}
