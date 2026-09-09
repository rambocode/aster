const std = @import("std");
const protocol = @import("protocol.zig");
pub const Frame = protocol.Frame;
pub const maximum_snapshot_bytes: usize = 32 * 1024 * 1024;
pub const maximum_delta_bytes: usize = 65536;
pub const header_bytes: usize = 5;
pub const Limits = struct {
    /// Owned source buffer, separate from the caller's socket output queue.
    snapshot_bytes: usize = maximum_snapshot_bytes,
    delta_bytes: usize = maximum_delta_bytes,
    /// Fixed total transaction lifetime. Individual writes never renew it.
    transaction_timeout_ms: u64 = 30_000,
};
pub const Cancellation = enum { idle, needs_snapshot, disconnect };
const Phase = enum { idle, begin, chunks, end };
const Transaction = enum { snapshot, delta };

/// Single-connection transactional surface producer, confined to one owner.
/// Successful begin transfers an allocation made by this allocator; failed begin
/// leaves ownership with the caller. No Session or socket is retained. A source
/// buffer may be 32 MiB; next borrows slices and never duplicates that buffer.
/// The caller enforces its socket queue cap (8 MiB) through next's wire budget.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    source: ?[]u8 = null,
    phase: Phase = .idle,
    transaction: Transaction = .snapshot,
    begin_bytes: [320]u8 = undefined,
    begin_length: usize = 0,
    offset: usize = 0,
    offered: ?usize = null,
    sequence: u64 = 0,
    completed_sequence: ?u64 = null,
    started_ms: u64 = 0,
    last_clock_ms: u64 = 0,
    exposed: bool = false,
    must_disconnect: bool = false,
    needs_snapshot: bool = true,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Stream {
        if (limits.snapshot_bytes == 0 or limits.snapshot_bytes > maximum_snapshot_bytes or
            limits.delta_bytes == 0 or limits.delta_bytes > maximum_delta_bytes or
            limits.transaction_timeout_ms == 0 or limits.transaction_timeout_ms > 60_000)
            return error.InvalidSurfaceLimits;
        return .{ .allocator = allocator, .limits = limits };
    }
    pub fn deinit(self: *Stream) void {
        if (self.source) |source| self.allocator.free(source);
        self.* = undefined;
    }
    pub fn beginSnapshot(self: *Stream, owned: []u8, sequence: u64, now_ms: u64) !void {
        try self.begin(owned, sequence, null, now_ms);
    }
    pub fn beginDelta(self: *Stream, owned: []u8, sequence: u64, base_sequence: u64, now_ms: u64) !void {
        try self.begin(owned, sequence, base_sequence, now_ms);
    }
    fn begin(self: *Stream, owned: []u8, sequence: u64, base: ?u64, now_ms: u64) !void {
        try self.clock(now_ms);
        if (self.must_disconnect) return error.SurfaceConnectionFailed;
        if (now_ms > std.math.maxInt(u64) - self.limits.transaction_timeout_ms) return error.SurfaceClockOverflow;
        if (self.phase != .idle) return error.TransactionInProgress;
        const maximum = if (base != null) self.limits.delta_bytes else self.limits.snapshot_bytes;
        if (owned.len == 0 or owned.len > maximum) return error.SurfacePayloadLimit;
        if (base) |value| {
            if (self.needs_snapshot or self.completed_sequence == null) return error.SnapshotRequired;
            if (self.completed_sequence.? != value or sequence <= value) return error.InvalidDeltaSequence;
        } else if (self.completed_sequence) |previous| {
            if (sequence < previous) return error.StaleSurfaceSequence;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(owned, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const encoded = if (base) |value|
            try std.fmt.bufPrint(&self.begin_bytes, "{{\"type\":\"delta_begin\",\"length\":{d},\"sha256\":\"{s}\",\"sequence\":{d},\"baseSequence\":{d}}}", .{ owned.len, hex, sequence, value })
        else
            try std.fmt.bufPrint(&self.begin_bytes, "{{\"type\":\"snapshot_begin\",\"length\":{d},\"sha256\":\"{s}\",\"sequence\":{d}}}", .{ owned.len, hex, sequence });
        self.begin_length = encoded.len;
        self.source = owned;
        self.sequence = sequence;
        self.started_ms = now_ms;
        self.phase = .begin;
        self.transaction = if (base == null) .snapshot else .delta;
        self.offset = 0;
        self.exposed = false;
        self.offered = null;
    }

    /// Offer exactly one frame fitting wire_budget, including the five-byte
    /// framing header. null means idle or insufficient budget; it never advances
    /// the transaction. Repeat calls return the same outstanding frame. Payload
    /// borrows this object until ackFrame, cancel, timeout or deinit. Acknowledge
    /// only after the frame has actually drained to the transport; copying into
    /// a queue is not delivery. Retain partial-write cursors externally. Do not
    /// move this object while its control-frame payload is borrowed.
    pub fn next(self: *Stream, wire_budget: usize, now_ms: u64) !?Frame {
        try self.tick(now_ms);
        if (self.offered) |length| return if (length + header_bytes <= wire_budget) self.currentFrame(length) else null;
        if (self.phase == .idle or wire_budget <= header_bytes) return null;
        const length = switch (self.phase) {
            .idle => unreachable,
            .begin => self.begin_length,
            .chunks => @min(self.source.?.len - self.offset, protocol.maximum_surface_bytes, wire_budget - header_bytes),
            .end => self.endBytes().len,
        };
        const frame = self.currentFrame(length);
        if (frame.payload.len + header_bytes > wire_budget) return null;
        self.offered = frame.payload.len;
        // Once exposed, bytes may already be partially written to the socket.
        // Cancellation must close the connection rather than splice a new begin.
        self.exposed = true;
        return frame;
    }

    fn endBytes(self: *const Stream) []const u8 {
        return if (self.transaction == .snapshot) "{\"type\":\"snapshot_end\"}" else "{\"type\":\"delta_end\"}";
    }
    fn currentFrame(self: *const Stream, length: usize) Frame {
        return switch (self.phase) {
            .idle => unreachable,
            .begin => .{ .kind = .control, .payload = self.begin_bytes[0..length] },
            .chunks => .{ .kind = .surface, .payload = self.source.?[self.offset..][0..length] },
            .end => .{ .kind = .control, .payload = self.endBytes() },
        };
    }

    /// Complete the outstanding frame after its payload was consumed. End ack
    /// releases source storage exactly once and commits the resulting sequence.
    pub fn ackFrame(self: *Stream, now_ms: u64) !void {
        try self.tick(now_ms);
        const length = self.offered orelse return error.NoOutstandingSurfaceFrame;
        switch (self.phase) {
            .idle => unreachable,
            .begin => self.phase = .chunks,
            .chunks => {
                self.offset += length;
                if (self.offset == self.source.?.len) self.phase = .end;
            },
            .end => {
                self.completed_sequence = self.sequence;
                self.needs_snapshot = false;
                self.releaseSource();
            },
        }
        self.offered = null;
    }

    /// Fixed deadline, including time waiting for queue capacity. Trickle writes
    /// cannot extend it. After an exposed frame times out, caller must disconnect.
    /// An unexposed obsolete snapshot can be discarded and recaptured safely.
    pub fn tick(self: *Stream, now_ms: u64) !void {
        try self.clock(now_ms);
        if (self.must_disconnect) return error.SurfaceConnectionFailed;
        if (self.phase != .idle and now_ms - self.started_ms >= self.limits.transaction_timeout_ms) {
            _ = self.cancel();
            return error.SurfaceConsumerTimedOut;
        }
    }
    pub fn deadlineMilliseconds(self: *const Stream) ?u64 {
        return if (self.phase == .idle) null else self.started_ms +| self.limits.transaction_timeout_ms;
    }
    pub fn ownedBytes(self: *const Stream) usize {
        return if (self.source) |bytes| bytes.len else 0;
    }
    /// Invalidates every borrowed frame. Calling twice is safe. Once begin was
    /// exposed, the only recovery is a fresh connection/Stream; no new transaction
    /// may follow an unterminated transfer on the same byte stream.
    pub fn cancel(self: *Stream) Cancellation {
        if (self.must_disconnect) return .disconnect;
        if (self.phase == .idle) return .idle;
        self.must_disconnect = self.exposed;
        self.needs_snapshot = true;
        self.releaseSource();
        return if (self.must_disconnect) .disconnect else .needs_snapshot;
    }
    fn releaseSource(self: *Stream) void {
        if (self.source) |source| self.allocator.free(source);
        self.source = null;
        self.phase = .idle;
        self.offset = 0;
        self.offered = null;
        self.exposed = false;
    }
    fn clock(self: *Stream, now_ms: u64) !void {
        if (now_ms < self.last_clock_ms) return error.NonMonotonicSurfaceClock;
        self.last_clock_ms = now_ms;
    }
};

fn complete(stream: *Stream, now_ms: u64) !void {
    while (try stream.next(protocol.maximum_surface_bytes + header_bytes, now_ms)) |_| try stream.ackFrame(now_ms);
}

test "surface stream snapshots preserve schema hash framing order and borrowed chunks" {
    const a = std.testing.allocator;
    var stream = try Stream.init(a, .{});
    defer stream.deinit();
    const bytes = try a.alloc(u8, protocol.maximum_surface_bytes + 13);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index);
    const original = bytes.ptr;
    try stream.beginSnapshot(bytes, std.math.maxInt(u64), 10);
    try std.testing.expect(try stream.next(5, 10) == null);
    const begin_frame = (try stream.next(512, 10)).?;
    try std.testing.expectEqual(.control, begin_frame.kind);
    const parsed = try std.json.parseFromSlice(struct { type: []const u8, length: usize, sha256: []const u8, sequence: u64 }, a, begin_frame.payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("snapshot_begin", parsed.value.type);
    try std.testing.expectEqual(bytes.len, parsed.value.length);
    try std.testing.expectEqual(std.math.maxInt(u64), parsed.value.sequence);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(hash, .lower), parsed.value.sha256);
    try std.testing.expectEqual(begin_frame.payload.ptr, (try stream.next(512, 11)).?.payload.ptr);
    try stream.ackFrame(11);
    const first = (try stream.next(protocol.maximum_surface_bytes + header_bytes, 12)).?;
    try std.testing.expectEqual(.surface, first.kind);
    try std.testing.expectEqual(original, first.payload.ptr);
    try std.testing.expectEqual(protocol.maximum_surface_bytes, first.payload.len);
    try stream.ackFrame(12);
    const tail = (try stream.next(10, 13)).?;
    try std.testing.expectEqual(@as(usize, 5), tail.payload.len);
    try stream.ackFrame(13);
    const last = (try stream.next(100, 14)).?;
    try std.testing.expectEqual(@as(usize, 8), last.payload.len);
    try stream.ackFrame(14);
    const end = (try stream.next(100, 15)).?;
    try std.testing.expectEqualStrings("{\"type\":\"snapshot_end\"}", end.payload);
    try stream.ackFrame(15);
    try std.testing.expectEqual(@as(usize, 0), stream.ownedBytes());
    try std.testing.expectEqual(std.math.maxInt(u64), stream.completed_sequence.?);
    try std.testing.expect(!stream.needs_snapshot);
    try std.testing.expect(try stream.next(100, 15) == null);
}

test "surface stream delta requires committed base and never interrupts a transaction" {
    const a = std.testing.allocator;
    var stream = try Stream.init(a, .{});
    defer stream.deinit();
    const initial_delta = try a.dupe(u8, "x");
    defer a.free(initial_delta);
    try std.testing.expectError(error.SnapshotRequired, stream.beginDelta(initial_delta, 1, 0, 0));
    try stream.beginSnapshot(try a.dupe(u8, "initial"), 10, 0);
    const replacement = try a.dupe(u8, "replacement");
    defer a.free(replacement);
    try std.testing.expectError(error.TransactionInProgress, stream.beginSnapshot(replacement, 11, 0));
    try complete(&stream, 0);
    try std.testing.expectError(error.InvalidDeltaSequence, stream.beginDelta(initial_delta, 12, 9, 0));
    try std.testing.expectError(error.InvalidDeltaSequence, stream.beginDelta(initial_delta, 10, 10, 0));
    try stream.beginDelta(try a.dupe(u8, "delta"), 12, 10, 1);
    const frame = (try stream.next(512, 1)).?;
    const parsed = try std.json.parseFromSlice(struct { type: []const u8, length: usize, sha256: []const u8, sequence: u64, baseSequence: u64 }, a, frame.payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("delta_begin", parsed.value.type);
    try std.testing.expectEqual(@as(u64, 10), parsed.value.baseSequence);
    try stream.ackFrame(1);
    try std.testing.expectError(error.NoOutstandingSurfaceFrame, stream.ackFrame(1));
    try complete(&stream, 1);
    try std.testing.expectEqual(@as(u64, 12), stream.completed_sequence.?);
}

test "surface stream deadline is total and trickle cannot renew it" {
    const a = std.testing.allocator;
    var stream = try Stream.init(a, .{ .transaction_timeout_ms = 100 });
    defer stream.deinit();
    try stream.beginSnapshot(try a.dupe(u8, "longer payload"), 1, 500);
    _ = (try stream.next(512, 510)).?;
    try stream.ackFrame(510);
    _ = (try stream.next(6, 580)).?;
    try stream.ackFrame(580);
    try std.testing.expectEqual(@as(?u64, 600), stream.deadlineMilliseconds());
    try std.testing.expectError(error.SurfaceConsumerTimedOut, stream.next(6, 600));
    try std.testing.expectEqual(@as(usize, 0), stream.ownedBytes());
    try std.testing.expect(stream.must_disconnect and stream.needs_snapshot);
    const retry = try a.dupe(u8, "retry");
    defer a.free(retry);
    try std.testing.expectError(error.SurfaceConnectionFailed, stream.beginSnapshot(retry, 2, 601));
    try std.testing.expectEqual(.disconnect, stream.cancel());
}

test "surface stream cancellation before exposure allows safe recapture and owns only accepted data" {
    const a = std.testing.allocator;
    var stream = try Stream.init(a, .{ .snapshot_bytes = 8, .delta_bytes = 4, .transaction_timeout_ms = 10 });
    defer stream.deinit();
    const oversized = try a.dupe(u8, "123456789");
    defer a.free(oversized);
    try std.testing.expectError(error.SurfacePayloadLimit, stream.beginSnapshot(oversized, 1, 0));
    try stream.beginSnapshot(try a.dupe(u8, "valid"), 1, 0);
    try std.testing.expectEqual(.needs_snapshot, stream.cancel());
    try std.testing.expectEqual(.idle, stream.cancel());
    try stream.beginSnapshot(try a.dupe(u8, "again"), 2, 1);
    try std.testing.expectError(error.SurfaceConsumerTimedOut, stream.tick(11));
    try std.testing.expect(!stream.must_disconnect);
    try stream.beginSnapshot(try a.dupe(u8, "last"), 3, 11);
    try complete(&stream, 11);
    try std.testing.expectError(error.NonMonotonicSurfaceClock, stream.tick(10));
    try std.testing.expectEqual(@as(u64, 3), stream.completed_sequence.?);
}

test "surface stream full size snapshot emits bounded frames without further allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const a = failing.allocator();
    const source = try a.alloc(u8, maximum_snapshot_bytes);
    @memset(source, 'x');
    var stream = try Stream.init(a, .{});
    defer stream.deinit();
    try stream.beginSnapshot(source, 1, 0);
    var bytes: usize = 0;
    var surface_frames: usize = 0;
    while (try stream.next(protocol.maximum_surface_bytes + header_bytes, 1)) |frame| {
        if (frame.kind == .surface) {
            try std.testing.expect(frame.payload.len <= protocol.maximum_surface_bytes);
            bytes += frame.payload.len;
            surface_frames += 1;
        }
        try stream.ackFrame(1);
    }
    try std.testing.expectEqual(maximum_snapshot_bytes, bytes);
    try std.testing.expectEqual(@as(usize, 128), surface_frames);
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
    try std.testing.expectEqual(@as(usize, 1), failing.deallocations);
    try std.testing.expectEqual(@as(usize, 0), stream.ownedBytes());
}
