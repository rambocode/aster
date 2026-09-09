const std = @import("std");
const vt = @import("vt.zig");
const wire = @import("graphics_wire.zig");

/// Encodes visible and virtual placements and their pixels. Unsupported
/// off-screen anchors fail explicitly; production full snapshots must
/// integrate those anchors before enabling this path for arbitrary sessions.
pub fn captureVisible(allocator: std.mem.Allocator, terminal: *const vt.Terminal, maximum: usize) ![]u8 {
    const placements = try terminal.placements(allocator, 8192);
    defer allocator.free(placements);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const image_ids = try terminal.imageIDs(allocator, try terminal.activeScreen(), 4096);
    defer allocator.free(image_ids);
    for (image_ids) |id| {
        var image = (try terminal.copyImage(allocator, id, maximum)) orelse return error.ImageMissing;
        defer image.deinit(allocator);
        const transmission = try image.transmission(allocator, id, maximum - output.items.len);
        defer allocator.free(transmission);
        try append(allocator, &output, transmission, maximum);
    }
    for (placements) |placement| {
        const position: ?wire.Position = if (placement.virtual) null else pinned: {
            const point = placement.viewport orelse return error.OffscreenPlacementNotEncoded;
            if (point.row < 0 or point.column < 0) return error.PartialPlacementNotEncoded;
            break :pinned .{ .row = @intCast(point.row), .column = @intCast(point.column) };
        };
        const command = try wire.placement(allocator, placement, position, maximum - output.items.len);
        defer allocator.free(command);
        try append(allocator, &output, command, maximum);
    }
    if (placements.len != 0) {
        const cursor = try terminal.cursorReplay(allocator, try terminal.activeScreen(), maximum - output.items.len);
        defer allocator.free(cursor);
        try append(allocator, &output, cursor, maximum);
    }
    return output.toOwnedSlice(allocator);
}

fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8, maximum: usize) !void {
    if (bytes.len > maximum - output.items.len) return error.FrameTooLarge;
    try output.appendSlice(allocator, bytes);
}

test "visible placement roundtrip keeps pixels crop offsets size and z" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    var pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 0, 255 };
    const image: vt.Image = .{ .width = 2, .height = 2, .channels = 4, .pixels = &pixels };
    const transmission = try image.transmission(allocator, 17, 4096);
    defer allocator.free(transmission);
    source.write(transmission);
    source.write("\x1b[3;4H\x1b_Ga=p,i=17,p=9,c=2,r=3,X=2,Y=4,x=1,y=0,w=1,h=2,z=-1,C=1,q=2\x1b\\");
    const snapshot = try captureVisible(allocator, &source, 16384);
    defer allocator.free(snapshot);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    try destination.enableGraphics(4096);
    try destination.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    var replies: vt.ResponseSink = .{};
    try destination.setResponseSink(&replies);
    destination.write(snapshot);
    const expected = try source.placements(allocator, 8);
    defer allocator.free(expected);
    const actual = try destination.placements(allocator, 8);
    defer allocator.free(actual);
    try std.testing.expectEqual(@as(usize, 1), actual.len);
    try std.testing.expectEqualDeep(expected, actual);
    var copied = (try destination.copyImage(allocator, 17, 4096)) orelse return error.ImageMissing;
    defer copied.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &pixels, copied.pixels);
    try std.testing.expectEqual(@as(usize, 0), (try replies.bytes()).len);
    try std.testing.expectEqual(try source.cursorColumn(), try destination.cursorColumn());
}

test "multiple placements share one image transmission and keep their identities" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    source.write("\x1b_Ga=t,f=32,s=1,v=1,i=21,q=2;/wAA/w==\x1b\\");
    source.write("\x1b[2;3H\x1b_Ga=p,i=21,p=1,c=1,r=1,C=1,q=2\x1b\\");
    source.write("\x1b[4;5H\x1b_Ga=p,i=21,p=2,c=2,r=2,C=1,q=2\x1b\\");
    const snapshot = try captureVisible(allocator, &source, 16384);
    defer allocator.free(snapshot);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, snapshot, "a=t,"));
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    try destination.enableGraphics(4096);
    try destination.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    destination.write(snapshot);
    const actual = try destination.placements(allocator, 8);
    defer allocator.free(actual);
    try std.testing.expectEqual(@as(usize, 2), actual.len);
    for (actual) |placement| {
        try std.testing.expectEqual(@as(u32, 21), placement.image_id);
        switch (placement.placement_id) {
            1 => try std.testing.expectEqual(@as(i32, 1), placement.viewport.?.row),
            2 => try std.testing.expectEqual(@as(i32, 3), placement.viewport.?.row),
            else => return error.UnexpectedPlacement,
        }
    }
}

test "uploaded image without a placement survives cache replay" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    source.write("\x1b_Ga=t,f=32,s=1,v=1,i=81,q=2;/wAA/w==\x1b\\");
    const snapshot = try captureVisible(allocator, &source, 16384);
    defer allocator.free(snapshot);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    try destination.enableGraphics(4096);
    destination.write(snapshot);
    var restored = (try destination.copyImage(allocator, 81, 4096)) orelse return error.ImageMissing;
    defer restored.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, restored.pixels);
}

test "virtual placement survives replay without inventing a viewport anchor" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    source.write("\x1b_Ga=t,f=32,s=1,v=1,i=31,q=2;/wAA/w==\x1b\\");
    source.write("\x1b_Ga=p,U=1,i=31,p=7,c=2,r=3,z=-1,q=2\x1b\\");
    const snapshot = try captureVisible(allocator, &source, 16384);
    defer allocator.free(snapshot);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    try destination.enableGraphics(4096);
    try destination.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    destination.write(snapshot);
    const expected = try source.placements(allocator, 8);
    defer allocator.free(expected);
    const actual = try destination.placements(allocator, 8);
    defer allocator.free(actual);
    try std.testing.expectEqual(@as(usize, 1), actual.len);
    try std.testing.expect(actual[0].virtual);
    try std.testing.expect(actual[0].viewport == null);
    try std.testing.expectEqualDeep(expected, actual);
}

test "virtual graphics compose with placeholder text and styling snapshots" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    source.write("\x1b_Ga=t,f=32,s=1,v=1,i=31,q=2;/wAA/w==\x1b\\\x1b_Ga=p,U=1,i=31,p=7,c=1,r=1,q=2\x1b\\");
    source.write("\x1b[?2027h\x1b[38;2;0;0;31m\x1b[58;2;0;0;7m\u{10eeee}\u{0305}\u{0305}");
    const text = try @import("display_snapshot.zig").capture(allocator, &source, 65536);
    defer allocator.free(text);
    const graphics = try captureVisible(allocator, &source, 16384);
    defer allocator.free(graphics);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    try destination.enableGraphics(4096);
    try destination.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    destination.write(text);
    destination.write(graphics);
    const original_text = try source.formatActiveScreen(allocator, true, 65536);
    defer allocator.free(original_text);
    const restored_text = try destination.formatActiveScreen(allocator, true, 65536);
    defer allocator.free(restored_text);
    try std.testing.expectEqualStrings(original_text, restored_text);
    const placements = try destination.placements(allocator, 8);
    defer allocator.free(placements);
    try std.testing.expectEqual(@as(usize, 1), placements.len);
    try std.testing.expect(placements[0].virtual);
    try std.testing.expectEqual(@as(u32, 31), placements[0].image_id);
    try std.testing.expectEqual(@as(u32, 7), placements[0].placement_id);
    var image = (try destination.copyImage(allocator, 31, 4096)) orelse return error.ImageMissing;
    defer image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels);
}
