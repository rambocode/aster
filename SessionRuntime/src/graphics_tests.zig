const std = @import("std");
const vt = @import("vt.zig");

test "inline RGBA image is decoded and copied without borrowed lifetime" {
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(1024);
    // Two actual pixels: opaque red and half-transparent green.
    terminal.write("\x1b_Ga=t,f=32,s=2,v=1,i=42,q=2;/wAA/wD/AIA=\x1b\\");
    var image = (try terminal.copyImage(std.testing.allocator, 42, 1024)) orelse return error.ImageMissing;
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128 }, image.pixels);
    terminal.write("\x1b_Ga=d,d=I,i=42,q=2\x1b\\");
    try std.testing.expect((try terminal.copyImage(std.testing.allocator, 42, 1024)) == null);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128 }, image.pixels);
}

test "image copy respects allocation limit and rejects excessive configuration" {
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try std.testing.expectError(error.InvalidImageLimit, terminal.enableGraphics(17 * 1024 * 1024));
    try terminal.enableGraphics(1024);
    terminal.write("\x1b_Ga=t,f=32,s=1,v=1,i=7,q=2;/wAA/w==\x1b\\");
    try std.testing.expectError(error.ImageTooLarge, terminal.copyImage(std.testing.allocator, 7, 3));
}

test "cached pixels replay through chunked inline transmission without replies" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(u8, 64 * 32 * 4);
    defer allocator.free(pixels);
    for (pixels, 0..) |*byte, i| byte.* = @truncate(i * 37);
    const original: vt.Image = .{ .width = 64, .height = 32, .channels = 4, .pixels = pixels };
    const wire = try original.transmission(allocator, 91, 32768);
    defer allocator.free(wire);
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(16384);
    var replies: vt.ResponseSink = .{};
    try terminal.setResponseSink(&replies);
    // Split the actual APC commands across arbitrary transport reads.
    var offset: usize = 0;
    while (offset < wire.len) {
        const count = @min(17, wire.len - offset);
        terminal.write(wire[offset..][0..count]);
        offset += count;
    }
    var restored = (try terminal.copyImage(allocator, 91, 16384)) orelse return error.ImageMissing;
    defer restored.deinit(allocator);
    try std.testing.expectEqualSlices(u8, pixels, restored.pixels);
    try std.testing.expectEqual(@as(usize, 0), (try replies.bytes()).len);
    try std.testing.expectError(error.ImageTooLarge, original.transmission(allocator, 91, 10));
}

test "file and temporary-file graphics cannot read or delete a real file" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "pixel.bin", .data = &.{ 255, 0, 0, 255 } });
    const path = try temporary.dir.realpathAlloc(allocator, "pixel.bin");
    defer allocator.free(path);
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(path.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, path);
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(1024);
    // Verify the policy survives lazy creation of a second screen, not merely
    // that graphics happened to be disabled there.
    for ([_][]const u8{ "", "\x1b[?1049h" }) |transition| {
        terminal.write(transition);
        terminal.write("\x1b_Ga=t,f=32,s=1,v=1,i=51,q=2;/wAA/w==\x1b\\");
        var inline_image = (try terminal.copyImage(allocator, 51, 1024)) orelse return error.AlternateImageMissing;
        defer inline_image.deinit(allocator);
        for ([_][]const u8{ "f", "t" }) |medium| {
            const command = try std.fmt.allocPrint(allocator, "\x1b_Ga=t,t={s},f=32,s=1,v=1,i=49,q=2;{s}\x1b\\", .{ medium, encoded });
            defer allocator.free(command);
            terminal.write(command);
            try std.testing.expect((try terminal.copyImage(allocator, 49, 1024)) == null);
            const data = try temporary.dir.readFileAlloc(allocator, "pixel.bin", 4);
            defer allocator.free(data);
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, data);
        }
    }
}

test "real PNG decoder handles RGBA grayscale palette and 16-bit RGB" {
    const cases = [_]struct { png: []const u8, pixels: []const u8 }{
        .{ .png = @embedFile("testdata/rgba.png"), .pixels = &.{ 255, 0, 0, 255, 0, 255, 0, 128 } },
        .{ .png = @embedFile("testdata/gray.png"), .pixels = &.{ 25, 25, 25, 255, 200, 200, 200, 255 } },
        .{ .png = @embedFile("testdata/palette.png"), .pixels = &.{ 255, 0, 0, 255, 0, 255, 0, 64 } },
        .{ .png = @embedFile("testdata/rgb16.png"), .pixels = &.{ 255, 0, 128, 255 } },
    };
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(4096);
    for (cases, 0..) |case, index| {
        const id: u32 = @intCast(index + 100);
        try feedPNG(&terminal, id, case.png);
        var image = (try terminal.copyImage(std.testing.allocator, id, 4096)) orelse return error.PNGImageMissing;
        defer image.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, case.pixels, image.pixels);
    }
}

test "invalid and oversized PNGs fail without preventing later valid decoding" {
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(4096);
    for ([_][]const u8{ "not a PNG", @embedFile("testdata/rgba.png")[0..24], @embedFile("testdata/rgba.png")[0..43], @embedFile("testdata/oversized.png") }, 0..) |png, index| {
        const id: u32 = @intCast(index + 200);
        try feedPNG(&terminal, id, png);
        try std.testing.expect((try terminal.copyImage(std.testing.allocator, id, 4096)) == null);
    }
    try feedPNG(&terminal, 250, @embedFile("testdata/rgba.png"));
    var image = (try terminal.copyImage(std.testing.allocator, 250, 4096)) orelse return error.PNGRecoveryFailed;
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), image.pixels.len);
}

fn feedPNG(terminal: *vt.Terminal, id: u32, png: []const u8) !void {
    const allocator = std.testing.allocator;
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(png.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, png);
    const command = try std.fmt.allocPrint(allocator, "\x1b_Ga=t,f=100,i={d},q=2;{s}\x1b\\", .{ id, encoded });
    defer allocator.free(command);
    terminal.write(command);
}

test "placement geometry uses real cells and preserves explicit offsets and z" {
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(4096);
    try terminal.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    terminal.write("\x1b[3;4H\x1b_Ga=T,f=32,s=1,v=1,i=17,p=9,c=2,r=3,X=2,Y=4,z=-1,C=1,q=2;/wAA/w==\x1b\\");
    const placements = try terminal.placements(std.testing.allocator, 8);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(usize, 1), placements.len);
    const item = placements[0];
    try std.testing.expectEqual(@as(u32, 17), item.image_id);
    try std.testing.expectEqual(@as(u32, 9), item.placement_id);
    try std.testing.expectEqual(@as(u32, 2), item.x_offset);
    try std.testing.expectEqual(@as(u32, 4), item.y_offset);
    try std.testing.expectEqual(@as(i32, -1), item.z);
    try std.testing.expectEqual(@as(u32, 20), item.pixel_width);
    try std.testing.expectEqual(@as(u32, 60), item.pixel_height);
    try std.testing.expectEqual(@as(i32, 3), item.viewport.?.column);
    try std.testing.expectEqual(@as(i32, 2), item.viewport.?.row);
    try std.testing.expectError(error.TooManyPlacements, terminal.placements(std.testing.allocator, 0));
}

test "cache enumeration includes unused images and keeps screen ownership" {
    const allocator = std.testing.allocator;
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(4096);
    terminal.write("\x1b_Ga=t,f=32,s=1,v=1,i=90,q=2;/wAA/w==\x1b\\\x1b_Ga=t,f=32,s=1,v=1,i=4,q=2;/wAA/w==\x1b\\");
    terminal.write("\x1b[?1049h\x1b_Ga=t,f=32,s=1,v=1,i=3,q=2;/wAA/w==\x1b\\");
    const primary = try terminal.imageIDs(allocator, .primary, 8);
    defer allocator.free(primary);
    const alternate = try terminal.imageIDs(allocator, .alternate, 8);
    defer allocator.free(alternate);
    try std.testing.expectEqualSlices(u32, &.{ 4, 90 }, primary);
    try std.testing.expectEqualSlices(u32, &.{3}, alternate);
    try std.testing.expectEqual(vt.Screen.alternate, try terminal.activeScreen());
    try std.testing.expectError(error.TooManyImages, terminal.imageIDs(allocator, .primary, 1));
}

test "offscreen image retains its full-history anchor while viewport changes" {
    const allocator = std.testing.allocator;
    var terminal = try vt.Terminal.init(10, 3, 100);
    defer terminal.deinit();
    try terminal.enableGraphics(4096);
    try terminal.resizeGeometry(.{ .rows = 3, .columns = 10, .pixel_width = 100, .pixel_height = 60 });
    terminal.write("ROW0\x1b[1;2H\x1b_Ga=T,f=32,s=1,v=1,i=61,p=4,c=2,r=3,C=1,q=2;/wAA/w==\x1b\\");
    terminal.write("\r\nROW1\r\nROW2\r\nROW3");
    const partial = try terminal.placements(allocator, 8);
    defer allocator.free(partial);
    try std.testing.expectEqual(@as(usize, 1), partial.len);
    try std.testing.expectEqual(@as(u32, 0), partial[0].anchor.?.row);
    try std.testing.expectEqual(@as(u32, 1), partial[0].anchor.?.column);
    try std.testing.expectEqual(@as(i32, -1), partial[0].viewport.?.row);
    terminal.write("\r\nROW4\r\nROW5\r\nROW6");
    const hidden = try terminal.placements(allocator, 8);
    defer allocator.free(hidden);
    try std.testing.expectEqual(@as(usize, 1), hidden.len);
    try std.testing.expect(hidden[0].viewport == null);
    try std.testing.expectEqualDeep(partial[0].anchor, hidden[0].anchor);
    const first = try terminal.formatRow(allocator, .primary, 0, 1024);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "ROW0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "ROW4") == null);
    try std.testing.expectError(error.InvalidScreenRow, terminal.formatRow(allocator, .primary, 999, 1024));
}

test "graphics received before pixel geometry retain cache and explicit placement" {
    const allocator = std.testing.allocator;
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(4096);
    terminal.write("\x1b_Ga=T,f=32,s=1,v=1,i=71,p=1,c=1,r=1,C=1,q=2;/wAA/w==\x1b\\");
    try terminal.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    var image = (try terminal.copyImage(allocator, 71, 4096)) orelse return error.ImageMissing;
    defer image.deinit(allocator);
    const placements = try terminal.placements(allocator, 8);
    defer allocator.free(placements);
    try std.testing.expectEqual(@as(usize, 1), placements.len);
}

test "placement resolved source preserves raw crop and normalizes default and oversized extents" {
    const allocator = std.testing.allocator;
    var terminal = try vt.Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(4096);
    try terminal.resizeGeometry(.{ .rows = 24, .columns = 80, .pixel_width = 800, .pixel_height = 480 });
    var pixels = [_]u8{255} ** (4 * 3 * 4);
    const image: vt.Image = .{ .width = 4, .height = 3, .channels = 4, .pixels = &pixels };
    const transmission = try image.transmission(allocator, 101, 4096);
    defer allocator.free(transmission);
    terminal.write(transmission);
    const cases = [_]struct { crop: []const u8, raw: vt.SourceRectangle, resolved: vt.SourceRectangle }{
        .{ .crop = "", .raw = .{}, .resolved = .{ .width = 4, .height = 3 } },
        .{ .crop = ",x=1,y=1", .raw = .{ .x = 1, .y = 1 }, .resolved = .{ .x = 1, .y = 1, .width = 3, .height = 2 } },
        .{ .crop = ",x=1,y=1,w=2,h=1", .raw = .{ .x = 1, .y = 1, .width = 2, .height = 1 }, .resolved = .{ .x = 1, .y = 1, .width = 2, .height = 1 } },
        .{ .crop = ",x=2,y=1,w=99,h=99", .raw = .{ .x = 2, .y = 1, .width = 99, .height = 99 }, .resolved = .{ .x = 2, .y = 1, .width = 2, .height = 2 } },
    };
    for (cases) |case| {
        const command = try std.fmt.allocPrint(allocator, "\x1b_Ga=p,i=101,p=1,c=4,r=3,C=1,q=2{s}\x1b\\", .{case.crop});
        defer allocator.free(command);
        terminal.write(command);
        const placements = try terminal.placements(allocator, 8);
        defer allocator.free(placements);
        try std.testing.expectEqual(@as(usize, 1), placements.len);
        const actual = placements[0];
        try std.testing.expectEqualDeep(case.raw, vt.SourceRectangle{ .x = actual.source_x, .y = actual.source_y, .width = actual.source_width, .height = actual.source_height });
        try std.testing.expectEqualDeep(case.resolved, actual.resolved_source);
        try std.testing.expectEqual(@as(u32, 40), actual.pixel_width);
        try std.testing.expectEqual(@as(u32, 60), actual.pixel_height);
    }
}

test "graphics cache exhaustion evicts old pixels and preserves terminal input" {
    const allocator = std.testing.allocator;
    var terminal = try vt.Terminal.init(20, 3, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(8);
    terminal.write("BEFORE");
    for (1..4) |id| {
        var command: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&command, "\x1b_Ga=t,f=32,s=1,v=1,i={d},q=2;/wAA/w==\x1b\\", .{id});
        terminal.write(bytes);
        const ids = try terminal.imageIDs(allocator, .primary, 3);
        defer allocator.free(ids);
        try std.testing.expect(ids.len <= 2);
    }
    try std.testing.expect((try terminal.copyImage(allocator, 1, 8)) == null);
    var latest = (try terminal.copyImage(allocator, 3, 8)) orelse return error.ImageMissing;
    defer latest.deinit(allocator);
    const retained = try terminal.imageIDs(allocator, .primary, 3);
    defer allocator.free(retained);
    // A single over-quota upload must fail without displacing valid cache.
    terminal.write("\x1b_Ga=t,f=32,s=3,v=1,i=4,q=2;/wAA//8AAP//AAD/\x1b\\AFTER");
    try std.testing.expect((try terminal.copyImage(allocator, 4, 16)) == null);
    const ids = try terminal.imageIDs(allocator, .primary, 3);
    defer allocator.free(ids);
    try std.testing.expectEqualSlices(u32, retained, ids);
    const text = try terminal.formatActiveScreen(allocator, false, 4096);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "BEFOREAFTER") != null);
}

test "library graphics metadata quotas bound tiny images and virtual placements" {
    const a = std.testing.allocator;
    var terminal = try vt.Terminal.init(20, 3, 0);
    defer terminal.deinit();
    try terminal.enableGraphics(16 * 1024 * 1024);
    for (1..4098) |id| {
        var buffer: [128]u8 = undefined;
        terminal.write(try std.fmt.bufPrint(&buffer, "\x1b_Ga=t,f=32,s=1,v=1,i={d},q=2;/wAA/w==\x1b\\", .{id}));
    }
    const ids = try terminal.imageIDs(a, .primary, 4097);
    defer a.free(ids);
    try std.testing.expectEqual(@as(usize, 4096), ids.len);
    try std.testing.expect((try terminal.copyImage(a, 4097, 4)) == null);
    for (1..8194) |id| {
        var buffer: [128]u8 = undefined;
        terminal.write(try std.fmt.bufPrint(&buffer, "\x1b_Ga=p,U=1,i=1,p={d},c=1,r=1,q=2\x1b\\", .{id}));
    }
    try terminal.resizeGeometry(.{ .rows = 3, .columns = 20, .pixel_width = 200, .pixel_height = 30 });
    const placements = try terminal.placements(a, 8193);
    defer a.free(placements);
    try std.testing.expectEqual(@as(usize, 8192), placements.len);
    terminal.write("\x1b_Ga=p,U=1,i=1,p=1,c=1,r=1,z=9,q=2\x1b\\AFTER");
    const replaced = try terminal.placements(a, 8193);
    defer a.free(replaced);
    try std.testing.expectEqual(@as(usize, 8192), replaced.len);
    var found = false;
    for (replaced) |placement| if (placement.placement_id == 1) {
        try std.testing.expectEqual(@as(i32, 9), placement.z);
        found = true;
    };
    try std.testing.expect(found);
    // Every accepted placement must remain representable by a legal snapshot.
    const snapshot = try @import("graphics_snapshot.zig").captureVisible(a, &terminal, 2 * 1024 * 1024);
    defer a.free(snapshot);
    var receiver = try vt.Terminal.init(20, 3, 0);
    defer receiver.deinit();
    try receiver.enableGraphics(16 * 1024 * 1024);
    try receiver.resizeGeometry(.{ .rows = 3, .columns = 20, .pixel_width = 200, .pixel_height = 30 });
    receiver.write(snapshot);
    const restored = try receiver.placements(a, 8193);
    defer a.free(restored);
    try std.testing.expectEqual(@as(usize, 8192), restored.len);
    const text = try terminal.formatActiveScreen(a, false, 4096);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "AFTER") != null);
}
