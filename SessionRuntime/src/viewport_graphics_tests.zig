const std = @import("std");
const vt = @import("vt.zig");
const projection = @import("viewport_projection.zig");

test "viewport graphics prefix retains native clipping virtual text and omits live suffix" {
    const a = std.testing.allocator;
    var source = try vt.Terminal.init(10, 3, 1024 * 1024);
    defer source.deinit();
    try source.enableGraphics(65536);
    try source.resizeGeometry(.{ .columns = 10, .rows = 3, .pixel_width = 100, .pixel_height = 60 });
    var pixels = [_]u8{ 255, 0, 0, 128 } ** 16;
    const image: vt.Image = .{ .width = 4, .height = 4, .channels = 4, .pixels = &pixels };
    const transmission = try image.transmission(a, 31, 65536);
    defer a.free(transmission);
    source.write(transmission);
    source.write("ROW0\x1b[1;2H\x1b_Ga=p,i=31,p=1,c=3,r=4,x=1,y=1,w=2,h=3,X=2,Y=3,z=-1,C=1,q=2\x1b\\");
    source.write("\x1b_Ga=p,U=1,i=31,p=7,c=1,r=1,z=1,q=2\x1b\\\r\n\x1b[?2027h\x1b[38;2;0;0;31m\x1b[58;2;0;0;7m\u{10eeee}\u{0305}\u{0305}\x1b[0m中\r\nROW2\r\nROW3\r\nLIVE4\r\nLIVE5");
    source.write("\x1b_Ga=p,i=31,p=9,c=1,r=1,z=2,C=1,q=2\x1b\\");
    _ = try source.scrollViewport(-2);
    const viewport = try source.viewport();
    try std.testing.expectEqual(@as(u64, 1), viewport.offset);
    const before = try source.placements(a, 16);
    defer a.free(before);
    const cursor = try source.cursorReplay(a, .primary, 65536);
    defer a.free(cursor);
    const source_text = try source.formatActiveScreen(a, true, 65536);
    defer a.free(source_text);
    const bytes = try projection.capture(a, &source, 65536);
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "LIVE4") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "LIVE5") == null);
    var receiver = try vt.Terminal.init(10, 3, 1024 * 1024);
    defer receiver.deinit();
    try receiver.enableGraphics(65536);
    try receiver.resizeGeometry(.{ .columns = 10, .rows = 3, .pixel_width = 100, .pixel_height = 60 });
    receiver.write(bytes);
    const restored = try receiver.placements(a, 16);
    defer a.free(restored);
    try std.testing.expectEqual(@as(usize, 2), restored.len);
    for (restored) |actual| {
        var matched = false;
        for (before) |expected| {
            if (actual.placement_id != expected.placement_id) continue;
            try std.testing.expectEqualDeep(expected, actual);
            if (!actual.virtual) try std.testing.expectEqual(@as(i32, -1), actual.viewport.?.row);
            matched = true;
        }
        try std.testing.expect(matched);
    }
    const receiver_viewport = try receiver.viewport();
    for (0..3) |row| {
        const expected = try source.formatRow(a, .primary, @intCast(viewport.offset + row), 65536);
        defer a.free(expected);
        const actual = try receiver.formatRow(a, .primary, @intCast(receiver_viewport.offset + row), 65536);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
    var copied = (try receiver.copyImage(a, 31, 65536)).?;
    defer copied.deinit(a);
    try std.testing.expectEqualSlices(u8, &pixels, copied.pixels);
    try std.testing.expect(!try receiver.modeEnabled(25));
    try std.testing.expectEqualDeep(viewport, try source.viewport());
    const after_cursor = try source.cursorReplay(a, .primary, 65536);
    defer a.free(after_cursor);
    try std.testing.expectEqualStrings(cursor, after_cursor);
    const after_text = try source.formatActiveScreen(a, true, 65536);
    defer a.free(after_text);
    try std.testing.expectEqualStrings(source_text, after_text);
    try std.testing.expectError(error.FrameTooLarge, projection.capture(a, &source, 3));
    try std.testing.expectError(error.FrameTooLarge, projection.capture(a, &source, bytes.len - 1));
    try std.testing.expectEqual(@as(u32, 100), (try source.pixelSize()).width);
    try std.testing.expectEqual(@as(u32, 60), (try source.pixelSize()).height);
    try std.testing.expectError(error.InvalidHistoryPrefix, @import("history_snapshot.zig").captureScreenPrefix(a, &source, .primary, 1, 65536));
}

test "viewport graphics limitation zero receiver history relocates distant intersecting anchor" {
    const a = std.testing.allocator;
    var source = try vt.Terminal.init(80, 3, 16 * 1024 * 1024);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .columns = 80, .rows = 3, .pixel_width = 800, .pixel_height = 60 });
    source.write("\x1b_Ga=T,f=32,s=1,v=1,i=61,p=1,c=1,r=2000,C=1,q=2;/wAA/w==\x1b\\");
    for (0..1000) |_| source.write("ROW\r\n");
    _ = try source.scrollViewport(-10);
    const expected = try source.placements(a, 8);
    defer a.free(expected);
    try std.testing.expectEqual(@as(usize, 1), expected.len);
    try std.testing.expect(expected[0].viewport.?.row < -100);
    std.debug.print("source viewport={any} placement viewport={any}\n", .{ try source.viewport(), expected[0].viewport });
    const bytes = try projection.capture(a, &source, 1024 * 1024);
    defer a.free(bytes);
    for ([_]usize{ 0, 16 * 1024 * 1024 }) |history_bytes| {
        var receiver = try vt.Terminal.init(80, 3, history_bytes);
        defer receiver.deinit();
        try receiver.enableGraphics(4096);
        try receiver.resizeGeometry(.{ .columns = 80, .rows = 3, .pixel_width = 800, .pixel_height = 60 });
        receiver.write(bytes);
        const actual = try receiver.placements(a, 8);
        defer a.free(actual);
        std.debug.print("receiver history={d} total_rows={d} placements={d}\n", .{ history_bytes, (try receiver.screenMetrics()).total_rows, actual.len });
        for (actual) |placement| std.debug.print("anchor={any} viewport={any}\n", .{ placement.anchor, placement.viewport });
        if (history_bytes != 0) {
            try std.testing.expectEqualDeep(expected, actual);
        } else {
            // The pinned VT accepts the prefix but history removal relocates
            // its tracked anchor to row zero, so native sampling starts at the
            // image top instead of clipping the distant original image region.
            try std.testing.expectEqual(@as(usize, 3), (try receiver.screenMetrics()).total_rows);
            try std.testing.expectEqual(@as(usize, 1), actual.len);
            try std.testing.expectEqual(@as(i32, 0), actual[0].viewport.?.row);
            try std.testing.expect(actual[0].viewport.?.row != expected[0].viewport.?.row);
        }
    }
}
