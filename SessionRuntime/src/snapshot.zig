const std = @import("std");

pub const maximum_bytes = 32 * 1024 * 1024;
/// Owns one in-flight snapshot. Invalid ordering or integrity permanently rejects
/// the transaction; caller must start a new assembler for a new snapshot ID.
pub const Assembler = struct {
    allocator: std.mem.Allocator,
    expected: usize,
    digest: [32]u8,
    bytes: std.ArrayList(u8) = .empty,
    next_index: u32 = 0,
    failed: bool = false,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, expected: usize, digest: [32]u8) !Assembler {
        if (expected == 0 or expected > maximum_bytes) return error.InvalidSnapshotLength;
        return .{ .allocator = allocator, .expected = expected, .digest = digest };
    }
    pub fn deinit(self: *Assembler) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn append(self: *Assembler, index: u32, chunk: []const u8) !void {
        if (self.failed or self.finished) return error.InvalidSnapshotState;
        errdefer self.failed = true;
        if (index != self.next_index) return error.SnapshotSequenceGap;
        if (chunk.len == 0 or chunk.len > 256 * 1024 or chunk.len > self.expected - self.bytes.items.len)
            return error.InvalidChunkLength;
        try self.bytes.appendSlice(self.allocator, chunk);
        self.next_index += 1;
    }

    /// Returns borrowed immutable bytes only after declared size and SHA-256
    /// agree. No partial payload is exposed by this interface.
    pub fn finish(self: *Assembler) ![]const u8 {
        if (self.failed or self.finished) return error.InvalidSnapshotState;
        errdefer self.failed = true;
        if (self.bytes.items.len != self.expected) return error.IncompleteSnapshot;
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.bytes.items, &actual, .{});
        if (!std.mem.eql(u8, &actual, &self.digest)) return error.SnapshotIntegrityFailure;
        self.finished = true;
        return self.bytes.items;
    }
};

test "snapshot is available only after all ordered chunks pass integrity" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abcdef", &digest, .{});
    var assembler = try Assembler.init(std.testing.allocator, 6, digest);
    defer assembler.deinit();
    try assembler.append(0, "abc");
    try assembler.append(1, "def");
    try std.testing.expectEqualStrings("abcdef", try assembler.finish());
    try std.testing.expectError(error.InvalidSnapshotState, assembler.append(2, "x"));
}

test "missing and corrupted snapshots cannot be applied" {
    const digest = [_]u8{0} ** 32;
    var missing = try Assembler.init(std.testing.allocator, 6, digest);
    defer missing.deinit();
    try missing.append(0, "abc");
    try std.testing.expectError(error.IncompleteSnapshot, missing.finish());
    try std.testing.expectError(error.InvalidSnapshotState, missing.append(1, "def"));
    var corrupt = try Assembler.init(std.testing.allocator, 3, digest);
    defer corrupt.deinit();
    try corrupt.append(0, "abc");
    try std.testing.expectError(error.SnapshotIntegrityFailure, corrupt.finish());
}

test "out of order chunks and resource excess reject the transaction" {
    const digest = [_]u8{0} ** 32;
    try std.testing.expectError(error.InvalidSnapshotLength, Assembler.init(std.testing.allocator, maximum_bytes + 1, digest));
    var assembler = try Assembler.init(std.testing.allocator, 1, digest);
    defer assembler.deinit();
    try std.testing.expectError(error.SnapshotSequenceGap, assembler.append(1, "x"));
    try std.testing.expectError(error.InvalidSnapshotState, assembler.finish());
}
