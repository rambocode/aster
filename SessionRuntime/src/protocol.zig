const std = @import("std");

pub const major: u16 = 1;
pub const minor: u16 = 0;
pub const maximum_control_bytes: usize = 1024 * 1024;
pub const maximum_surface_bytes: usize = 256 * 1024;

pub const Kind = enum(u8) { control = 1, surface = 2 };
pub const Frame = struct { kind: Kind, payload: []const u8 };

/// Incremental bounded decoder. Returned payload borrows this decoder until the
/// next feed call. A terminal protocol error requires discarding the decoder.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    header: [5]u8 = undefined,
    header_used: usize = 0,
    payload: std.ArrayList(u8) = .empty,
    expected: usize = 0,
    kind: Kind = .control,
    complete: bool = false,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Decoder) void {
        self.payload.deinit(self.allocator);
    }

    /// Consumes at most one frame, updating consumed even for partial reads.
    /// Rejects unsupported kinds and lengths before allocating their payload.
    pub fn feed(self: *Decoder, bytes: []const u8, consumed: *usize) !?Frame {
        consumed.* = 0;
        if (self.failed) return error.DecoderFailed;
        errdefer self.failed = true;
        if (self.complete) {
            self.header_used = 0;
            self.payload.clearRetainingCapacity();
            self.complete = false;
        }
        while (self.header_used < self.header.len and consumed.* < bytes.len) {
            self.header[self.header_used] = bytes[consumed.*];
            self.header_used += 1;
            consumed.* += 1;
        }
        if (self.header_used < self.header.len) return null;
        self.kind = std.meta.intToEnum(Kind, self.header[0]) catch return error.UnknownFrameKind;
        self.expected = std.mem.readInt(u32, self.header[1..5], .big);
        const limit = if (self.kind == .control) maximum_control_bytes else maximum_surface_bytes;
        if (self.expected == 0 or self.expected > limit) return error.InvalidFrameLength;
        const count = @min(self.expected - self.payload.items.len, bytes.len - consumed.*);
        try self.payload.appendSlice(self.allocator, bytes[consumed.*..][0..count]);
        consumed.* += count;
        if (self.payload.items.len != self.expected) return null;
        self.complete = true;
        return .{ .kind = self.kind, .payload = self.payload.items };
    }

    pub fn finish(self: *const Decoder) !void {
        if (self.failed) return error.DecoderFailed;
        if (!self.complete and self.header_used != 0) return error.TruncatedFrame;
    }
};

test "fragmented frame preserves payload and reports complete boundary" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    const wire = [_]u8{ 1, 0, 0, 0, 2, '{', '}' };
    for (wire, 0..) |byte, index| {
        var consumed: usize = 0;
        const frame = try decoder.feed(&.{byte}, &consumed);
        try std.testing.expectEqual(@as(usize, 1), consumed);
        if (index == wire.len - 1) {
            try std.testing.expectEqualStrings("{}", frame.?.payload);
        } else try std.testing.expect(frame == null);
    }
    try decoder.finish();
}

test "coalesced frames consume only their own boundary" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    const wire = [_]u8{ 1, 0, 0, 0, 2, '{', '}', 2, 0, 0, 0, 1, 65 };
    var consumed: usize = 0;
    try std.testing.expectEqualStrings("{}", (try decoder.feed(&wire, &consumed)).?.payload);
    try std.testing.expectEqual(@as(usize, 7), consumed);
    try std.testing.expectEqualStrings("A", (try decoder.feed(wire[consumed..], &consumed)).?.payload);
    try decoder.finish();
}

test "oversized headers fail before allocation and poison connection" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    var consumed: usize = 0;
    try std.testing.expectError(error.InvalidFrameLength, decoder.feed(&.{ 1, 0, 16, 0, 1 }, &consumed));
    try std.testing.expectEqual(@as(usize, 0), decoder.payload.capacity);
    try std.testing.expectError(error.DecoderFailed, decoder.feed(&.{}, &consumed));
}

test "EOF rejects truncated payload" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    var consumed: usize = 0;
    _ = try decoder.feed(&.{ 2, 0, 0, 0, 2, 65 }, &consumed);
    try std.testing.expectError(error.TruncatedFrame, decoder.finish());
}

test "shared framing fixtures agree at every byte split" {
    const allocator = std.testing.allocator;
    const json = try std.fs.cwd().readFileAlloc(allocator, "protocol/framing-fixtures.json", 65536);
    defer allocator.free(json);
    const Fixture = struct {
        name: []const u8,
        wire: []const u8,
        payload: ?[]const u8 = null,
        kind: ?u8 = null,
        @"error": ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice([]Fixture, allocator, json, .{});
    defer parsed.deinit();
    for (parsed.value) |fixture| {
        for (0..fixture.wire.len + 1) |split| {
            var decoder = Decoder.init(allocator);
            defer decoder.deinit();
            var observed: ?[]const u8 = null;
            var count: usize = 0;
            for ([_][]const u8{ fixture.wire[0..split], fixture.wire[split..] }) |part| {
                var consumed: usize = 0;
                const frame = decoder.feed(part, &consumed) catch |err| {
                    observed = switch (err) {
                        error.UnknownFrameKind => "unknownFrameKind",
                        error.InvalidFrameLength => "invalidFrameLength",
                        else => return err,
                    };
                    break;
                };
                try std.testing.expectEqual(part.len, consumed);
                if (frame) |value| {
                    count += 1;
                    try std.testing.expectEqualSlices(u8, fixture.payload.?, value.payload);
                    try std.testing.expectEqual(fixture.kind.?, @intFromEnum(value.kind));
                }
            }
            if (observed == null) decoder.finish() catch |err| {
                if (err == error.TruncatedFrame) {
                    observed = "truncatedFrame";
                } else return err;
            };
            if (fixture.@"error") |expected| {
                try std.testing.expectEqualStrings(expected, observed orelse return error.MissingExpectedFailure);
            } else {
                try std.testing.expect(observed == null);
                try std.testing.expectEqual(@as(usize, 1), count);
            }
        }
    }
}

test {
    _ = @import("handshake.zig");
}

test {
    _ = @import("snapshot.zig");
}

test {
    _ = @import("delta_filter.zig");
}

test {
    _ = @import("operation_request.zig");
}

test {
    _ = @import("operation_response.zig");
}
