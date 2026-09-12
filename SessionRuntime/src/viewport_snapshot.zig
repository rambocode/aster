const std = @import("std");
const vt = @import("vt.zig");
const Geometry = @import("geometry.zig").Geometry;
const terminal_snapshot = @import("terminal_snapshot.zig");
pub const Limits = struct { maximum_bytes: usize = 16 * 1024 * 1024, maximum_history_rows: usize = 1000, graphics_bytes: u64 = 16 * 1024 * 1024 };

/// Structured receiver contract, NOT ANSI-only viewport projection. replay
/// reconstructs both screens/history/image anchors; native receiver scrolling
/// must then apply viewport.offset. Never acknowledge synchronization after
/// sending replay alone. Surface framing supplies identity/sequence/integrity.
/// Only the active viewport is captured, not inactive viewport preferences.
pub const Snapshot = struct {
    version: u32 = 1,
    geometry: Geometry,
    active_screen: vt.Screen,
    viewport: vt.Terminal.Viewport,
    primary_rows: usize,
    alternate_rows: ?usize,
    primary_images: usize,
    alternate_images: usize,
    graphics_bytes_required: u64,
    replay: []u8,
    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.replay);
        self.* = undefined;
    }
};

/// Read-only capture from a reactor-confined source. Never move the source
/// viewport or write temporary escape commands into its VT or PTY.
pub fn capture(allocator: std.mem.Allocator, source: *const vt.Terminal, limits: Limits) !Snapshot {
    try validateLimits(limits);
    const primary = try source.metricsForScreen(.primary);
    const alternate: ?vt.Terminal.Metrics = if (try source.hasScreen(.alternate)) try source.metricsForScreen(.alternate) else null;
    const pixels = try source.pixelSize();
    if (pixels.width > std.math.maxInt(u16) or pixels.height > std.math.maxInt(u16)) return error.InvalidSnapshotGeometry;
    const geometry = Geometry{ .rows = primary.rows, .columns = primary.columns, .pixel_width = @intCast(pixels.width), .pixel_height = @intCast(pixels.height) };
    var result = Snapshot{ .geometry = geometry, .active_screen = try source.activeScreen(), .viewport = try source.viewport(), .primary_rows = primary.total_rows, .alternate_rows = if (alternate) |value| value.total_rows else null, .primary_images = try source.imageCount(.primary), .alternate_images = if (alternate != null) try source.imageCount(.alternate) else 0, .graphics_bytes_required = @max(try imageBytes(allocator, source, .primary, limits), if (alternate != null) try imageBytes(allocator, source, .alternate, limits) else 0), .replay = &.{} };
    try validateMetadata(result, limits);
    const has_images = result.primary_images != 0 or result.alternate_images != 0;
    if (has_images and (pixels.width == 0 or pixels.height == 0)) return error.PixelGeometryRequired;
    result.replay = try terminal_snapshot.capture(allocator, source, limits.maximum_bytes);
    return result;
}

/// Rebuild a NEW owned candidate, validate history then apply native scrolling.
/// Caller swaps its visible receiver only on success. Errors destroy candidate
/// and never modify the caller's existing receiver. Not a raw terminal bridge.
pub fn restore(snapshot: Snapshot, limits: Limits) !vt.Terminal {
    try validateLimits(limits);
    try validateMetadata(snapshot, limits);
    if (snapshot.replay.len == 0 or snapshot.replay.len > limits.maximum_bytes) return error.FrameTooLarge;
    var receiver = try vt.Terminal.init(snapshot.geometry.columns, snapshot.geometry.rows, limits.maximum_history_rows);
    errdefer receiver.deinit();
    try receiver.enableGraphics(limits.graphics_bytes);
    try receiver.resizeGeometry(snapshot.geometry);
    receiver.write(snapshot.replay);
    if (try receiver.activeScreen() != snapshot.active_screen or (try receiver.metricsForScreen(.primary)).total_rows != snapshot.primary_rows) return error.SnapshotStateMismatch;
    if (try receiver.hasScreen(.alternate) != (snapshot.alternate_rows != null)) return error.SnapshotStateMismatch;
    if (snapshot.alternate_rows) |rows| {
        if ((try receiver.metricsForScreen(.alternate)).total_rows != rows) return error.SnapshotStateMismatch;
    }
    if (try receiver.imageCount(.primary) != snapshot.primary_images or
        (if (snapshot.alternate_rows != null) try receiver.imageCount(.alternate) else @as(usize, 0)) != snapshot.alternate_images) return error.SnapshotStateMismatch;
    _ = try receiver.scrollViewport(std.math.minInt(i32));
    _ = try receiver.scrollViewport(@intCast(snapshot.viewport.offset));
    if (!std.meta.eql(snapshot.viewport, try receiver.viewport())) return error.SnapshotStateMismatch;
    return receiver;
}
fn imageBytes(allocator: std.mem.Allocator, source: *const vt.Terminal, screen: vt.Screen, limits: Limits) !u64 {
    const ids = try source.imageIDs(allocator, screen, 4096);
    defer allocator.free(ids);
    var total: u64 = 0;
    for (ids) |id| {
        var image = (try source.copyScreenImage(allocator, screen, id, limits.maximum_bytes)) orelse return error.ImageMissing;
        defer image.deinit(allocator);
        if (image.pixels.len > limits.graphics_bytes - total) return error.GraphicsLimitExceeded;
        total += image.pixels.len;
    }
    return total;
}
fn validateLimits(limits: Limits) !void {
    if (limits.maximum_bytes == 0 or limits.maximum_bytes > 64 * 1024 * 1024 or limits.maximum_history_rows > 1_000_000 or limits.graphics_bytes == 0 or limits.graphics_bytes > 64 * 1024 * 1024) return error.InvalidSnapshotLimits;
}
fn validateMetadata(snapshot: Snapshot, limits: Limits) !void {
    if (snapshot.version != 1) return error.UnsupportedSnapshotVersion;
    try snapshot.geometry.validate();
    if (snapshot.graphics_bytes_required > limits.graphics_bytes) return error.GraphicsLimitExceeded;
    if (snapshot.primary_images > 4096 or snapshot.alternate_images > 4096 or (snapshot.alternate_rows == null and snapshot.alternate_images != 0)) return error.SnapshotStateMismatch;
    const rows: usize = snapshot.geometry.rows;
    if (snapshot.primary_rows < rows or snapshot.primary_rows - rows > limits.maximum_history_rows) return error.HistoryTooLarge;
    if (snapshot.alternate_rows) |total| {
        if (total != rows) return error.SnapshotStateMismatch;
    }
    const active_rows = switch (snapshot.active_screen) {
        .primary => snapshot.primary_rows,
        .alternate => snapshot.alternate_rows orelse return error.SnapshotStateMismatch,
    };
    if (snapshot.viewport.total != active_rows or snapshot.viewport.length != rows or snapshot.viewport.offset > active_rows - rows) return error.InvalidViewport;
}
fn expectRows(source: *const vt.Terminal, receiver: *const vt.Terminal) !void {
    const allocator = std.testing.allocator;
    const viewport = try source.viewport();
    try std.testing.expectEqualDeep(viewport, try receiver.viewport());
    const screen = try source.activeScreen();
    for (0..@intCast(viewport.length)) |i| {
        const row: u32 = @intCast(viewport.offset + i);
        const expected = try source.formatRow(allocator, screen, row, 8192);
        defer allocator.free(expected);
        const actual = try receiver.formatRow(allocator, screen, row, 8192);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "viewport snapshot historical styled wide rows and bounds leave source untouched" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(12, 3, 1000);
    defer source.deinit();
    source.write("\x1b[31m中一\x1b[0m\r\nTWO\r\n\x1b[1;4mTHREE\x1b[0m\r\nFOUR\r\nFIVE");
    for ([_]i32{ -1, std.math.minInt(i32), std.math.maxInt(i32) }) |delta| {
        _ = try source.scrollViewport(delta);
        const before = try source.viewport();
        const cursor = try source.cursorColumn();
        var snapshot = try capture(allocator, &source, .{});
        defer snapshot.deinit(allocator);
        try std.testing.expectEqualDeep(before, try source.viewport());
        try std.testing.expectEqual(cursor, try source.cursorColumn());
        var receiver = try restore(snapshot, .{});
        defer receiver.deinit();
        try expectRows(&source, &receiver);
    }
}

test "viewport snapshot partially visible graphics and alternate screen" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(10, 3, 1000);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .rows = 3, .columns = 10, .pixel_width = 100, .pixel_height = 60 });
    source.write("ROW0\x1b[1;2H\x1b_Ga=T,f=32,s=1,v=1,i=61,p=4,c=2,r=3,C=1,q=2;/wAA/w==\x1b\\");
    source.write("\r\nROW1\r\nROW2\r\nROW3\r\nROW4\r\nROW5");
    _ = try source.scrollViewport(-2);
    for ([_]bool{ false, true }) |alternate| {
        if (alternate) source.write("\x1b[?1049h\x1b[32mALT中\x1b[0m");
        const before = try source.viewport();
        var snapshot = try capture(allocator, &source, .{});
        defer snapshot.deinit(allocator);
        try std.testing.expectError(error.GraphicsLimitExceeded, restore(snapshot, .{ .graphics_bytes = 1 }));
        var receiver = try restore(snapshot, .{});
        defer receiver.deinit();
        try std.testing.expectEqualDeep(before, try source.viewport());
        try expectRows(&source, &receiver);
        const original = try source.screenPlacements(allocator, .primary, 8);
        defer allocator.free(original);
        const restored = try receiver.screenPlacements(allocator, .primary, 8);
        defer allocator.free(restored);
        if (alternate) {
            // Inactive screen viewport preferences are outside this contract;
            // anchors, clipping inputs and pixels remain identical.
            for (original) |*item| item.viewport = null;
            for (restored) |*item| item.viewport = null;
        }
        try std.testing.expectEqualDeep(original, restored);
        var pixels = (try source.copyScreenImage(allocator, .primary, 61, 4096)).?;
        defer pixels.deinit(allocator);
        var copied = (try receiver.copyScreenImage(allocator, .primary, 61, 4096)).?;
        defer copied.deinit(allocator);
        try std.testing.expectEqualSlices(u8, pixels.pixels, copied.pixels);
    }
}

test "viewport snapshot rejects invalid metadata oversized and truncated content" {
    var source = try vt.Terminal.init(12, 3, 1000);
    defer source.deinit();
    source.write("A\r\nB\r\nC\r\nD");
    try std.testing.expectError(error.HistoryTooLarge, capture(std.testing.allocator, &source, .{ .maximum_history_rows = 0 }));
    try std.testing.expectError(error.FrameTooLarge, capture(std.testing.allocator, &source, .{ .maximum_bytes = 1 }));
    var snapshot = try capture(std.testing.allocator, &source, .{});
    defer snapshot.deinit(std.testing.allocator);
    var invalid = snapshot;
    invalid.version = 2;
    try std.testing.expectError(error.UnsupportedSnapshotVersion, restore(invalid, .{}));
    invalid = snapshot;
    invalid.viewport.offset = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidViewport, restore(invalid, .{}));
    invalid = snapshot;
    invalid.replay = snapshot.replay[0..2];
    try std.testing.expectError(error.SnapshotStateMismatch, restore(invalid, .{}));
}
