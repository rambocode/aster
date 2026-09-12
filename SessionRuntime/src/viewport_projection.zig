const std = @import("std");
const vt = @import("vt.zig");

/// Produces an ANSI view of the selected viewport at the source geometry.
/// Only reads source state. The receiver must have the same rows/columns.
/// Graphics reconstruct the prefix through this viewport so the receiver's
/// renderer clips original placements. Receiver history must retain intersecting
/// anchors; its capacity is not currently negotiated or detectable here.
pub fn capture(allocator: std.mem.Allocator, terminal: *const vt.Terminal, maximum: usize) ![]u8 {
    const active = try terminal.activeScreen();
    const has_images = try terminal.imageCount(active) != 0;
    const metrics = try terminal.metricsForScreen(active);
    const viewport = try terminal.viewport();
    if (viewport.length > metrics.rows or viewport.offset > metrics.total_rows or
        viewport.length > metrics.total_rows - viewport.offset) return error.InvalidViewport;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try append(allocator, &output, "\x1bc", maximum);
    const palette = try terminal.paletteReplay(allocator, maximum - output.items.len);
    defer allocator.free(palette);
    try append(allocator, &output, palette, maximum);
    if (active == .alternate) try append(allocator, &output, "\x1b[?47h", maximum);
    const modes = try terminal.screenState(allocator, active, true, maximum - output.items.len);
    defer allocator.free(modes);
    try append(allocator, &output, modes, maximum);
    // Drawing uses absolute positions and disables insert/origin/margins, even
    // when the application's input state uses them. Restore modes afterwards.
    try append(allocator, &output, "\x1b[4l\x1b[?6l\x1b[?69l\x1b[r\x1b[?7h\x1b[?25l", maximum);
    if (has_images) {
        const end = std.math.cast(usize, viewport.offset + viewport.length) orelse return error.InvalidViewport;
        const prefix = try @import("history_snapshot.zig").captureScreenPrefix(allocator, terminal, active, end, maximum - output.items.len);
        defer allocator.free(prefix);
        try append(allocator, &output, prefix, maximum);
    } else for (0..@intCast(viewport.length)) |row| {
        var buffer: [80]u8 = undefined;
        const home = try std.fmt.bufPrint(&buffer, "\x1b[{d};1H\x1b[0m\x1b[0\"q\x1b[2K", .{row + 1});
        try append(allocator, &output, home, maximum);
        const index = std.math.cast(u32, viewport.offset + row) orelse return error.InvalidViewport;
        const text = try terminal.formatRow(allocator, active, index, maximum - output.items.len);
        defer allocator.free(text);
        try append(allocator, &output, text, maximum);
    }
    try append(allocator, &output, modes, maximum);
    const state = try terminal.screenState(allocator, active, false, maximum - output.items.len);
    defer allocator.free(state);
    try append(allocator, &output, state, maximum);
    if (viewport.offset + viewport.length == viewport.total) {
        const cursor = try terminal.cursorReplay(allocator, active, maximum - output.items.len);
        defer allocator.free(cursor);
        try append(allocator, &output, cursor, maximum);
        try append(allocator, &output, if (try terminal.modeEnabled(25)) "\x1b[?25h" else "\x1b[?25l", maximum);
    } else {
        // The live application cursor has no position in this historical view.
        try append(allocator, &output, "\x1b[?25l", maximum);
    }
    return output.toOwnedSlice(allocator);
}

fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8, maximum: usize) !void {
    if (bytes.len > maximum - output.items.len) return error.FrameTooLarge;
    try output.appendSlice(allocator, bytes);
}

test "viewport projection reads historical styled wide rows without changing source" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(10, 3, 100);
    defer source.deinit();
    source.write("\x1b[31m中e\u{0301}\r\nSECOND\r\nTHIRD\r\nFOURTH\r\nFIFTH\x1b[?2004h");
    _ = try source.scrollViewport(-2);
    const before = try source.viewport();
    const bytes = try capture(allocator, &source, 65536);
    defer allocator.free(bytes);
    try std.testing.expectEqualDeep(before, try source.viewport());
    var receiver = try vt.Terminal.init(10, 3, 100);
    defer receiver.deinit();
    receiver.write(bytes);
    for (0..3) |row| {
        const expected = try source.formatRow(allocator, .primary, @intCast(before.offset + row), 65536);
        defer allocator.free(expected);
        const actual = try receiver.formatRow(allocator, .primary, @intCast(row), 65536);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expect(!try receiver.modeEnabled(25));
    try std.testing.expect(try receiver.modeEnabled(2004));
    try std.testing.expectEqual(@as(usize, 3), (try receiver.screenMetrics()).total_rows);
    try std.testing.expectError(error.FrameTooLarge, capture(allocator, &source, 1));
}

test "viewport projection restores live cursor visibility with cached images" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(10, 3, 100);
    defer source.deinit();
    source.write("ABC\x1b[?25l");
    const bytes = try capture(allocator, &source, 65536);
    defer allocator.free(bytes);
    var receiver = try vt.Terminal.init(10, 3, 100);
    defer receiver.deinit();
    receiver.write(bytes);
    try std.testing.expectEqual(try source.cursorColumn(), try receiver.cursorColumn());
    try std.testing.expect(!try receiver.modeEnabled(25));
    try source.enableGraphics(4096);
    source.write("\x1b_Ga=t,f=32,s=1,v=1,i=31,q=2;/wAA/w==\x1b\\");
    try source.resizeGeometry(.{ .columns = 10, .rows = 3, .pixel_width = 100, .pixel_height = 60 });
    const with_image = try capture(allocator, &source, 65536);
    defer allocator.free(with_image);
    try std.testing.expect(std.mem.indexOf(u8, with_image, "a=t,") != null);
}

test "viewport palette projection replays OSC colors without source mutation" {
    const a = std.testing.allocator;
    var source = try vt.Terminal.init(10, 3, 65536);
    defer source.deinit();
    source.write("\x1b]4;1;rgb:12/34/56\x1b\\\x1b]10;rgb:ab/cd/ef\x1b\\\x1b]11;rgb:21/43/65\x1b\\\x1b]12;rgb:fe/dc/ba\x1b\\\x1b[31mRED\r\nTWO\r\nTHREE\r\nFOUR");
    _ = try source.scrollViewport(-1);
    const viewport = try source.viewport();
    const before = try source.paletteReplay(a, 65536);
    defer a.free(before);
    const bytes = try capture(a, &source, 65536);
    defer a.free(bytes);
    var receiver = try vt.Terminal.init(10, 3, 65536);
    defer receiver.deinit();
    receiver.write(bytes);
    // paletteReplay reads the receiver's effective C API colors. Equality here
    // checks parsed color state, not merely OSC bytes present in the capture.
    const actual = try receiver.paletteReplay(a, 65536);
    defer a.free(actual);
    try std.testing.expectEqualStrings(before, actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "4;1;rgb:12/34/56") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "10;rgb:ab/cd/ef") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "11;rgb:21/43/65") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "12;rgb:fe/dc/ba") != null);
    try std.testing.expectEqualDeep(viewport, try source.viewport());
    const after = try source.paletteReplay(a, 65536);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectError(error.FrameTooLarge, source.paletteReplay(a, 1));
    try std.testing.expectError(error.FrameTooLarge, capture(a, &source, 3));
}
