const std = @import("std");
const vt = @import("vt.zig");
const history = @import("history_snapshot.zig");

/// Composes screen content, graphics and terminal context without writing to the
/// source. The receiving terminal must already have matching pixel geometry.
pub fn capture(allocator: std.mem.Allocator, terminal: *const vt.Terminal, maximum: usize) ![]u8 {
    const active = try terminal.activeScreen();
    const legacy = try terminal.modeEnabled(47);
    const alternate_mode = try terminal.modeEnabled(1047);
    const saved_mode = try terminal.modeEnabled(1049);
    const has_alternate = try terminal.hasScreen(.alternate);
    if (active == .alternate and (!has_alternate or !(legacy or alternate_mode or saved_mode))) return error.InconsistentScreenModes;
    if (active == .primary and legacy and alternate_mode and saved_mode) return error.InconsistentScreenModes;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try append(allocator, &output, "\x1bc", maximum);
    try owned(allocator, &output, try terminal.savedModes(allocator, maximum - output.items.len), maximum);
    try owned(allocator, &output, try terminal.screenState(allocator, .primary, true, maximum - output.items.len), maximum);
    try screen(allocator, &output, terminal, .primary, maximum);
    if (has_alternate) {
        // Restore the source primary save slot before 1049 saves it again;
        // global origin/style may have changed while the source was on alt.
        if (saved_mode) try append(allocator, &output, "\x1b8\x1b[?1049h", maximum);
        if (legacy) try append(allocator, &output, "\x1b[?47h", maximum);
        if (alternate_mode) try append(allocator, &output, "\x1b[?1047h", maximum);
        if (!legacy and !alternate_mode and !saved_mode) try append(allocator, &output, "\x1b[?47h", maximum);
        try screen(allocator, &output, terminal, .alternate, maximum);
        if (active == .primary) {
            try append(allocator, &output, if (!legacy) "\x1b[?47l" else if (!saved_mode) "\x1b[?1049l" else "\x1b[?1047l", maximum);
            try state(allocator, &output, terminal, .primary, maximum);
        }
    }
    return output.toOwnedSlice(allocator);
}

fn screen(allocator: std.mem.Allocator, output: *std.ArrayList(u8), terminal: *const vt.Terminal, which: vt.Screen, maximum: usize) !void {
    try owned(allocator, output, try history.captureScreenContent(allocator, terminal, which, maximum - output.items.len), maximum);
    try state(allocator, output, terminal, which, maximum);
}
fn state(allocator: std.mem.Allocator, output: *std.ArrayList(u8), terminal: *const vt.Terminal, which: vt.Screen, maximum: usize) !void {
    try owned(allocator, output, try terminal.screenState(allocator, which, false, maximum - output.items.len), maximum);
    try owned(allocator, output, try terminal.cursorReplay(allocator, which, maximum - output.items.len), maximum);
}
fn owned(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []u8, maximum: usize) !void {
    defer allocator.free(bytes);
    try append(allocator, output, bytes, maximum);
}
fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8, maximum: usize) !void {
    if (bytes.len > maximum - output.items.len) return error.FrameTooLarge;
    try output.appendSlice(allocator, bytes);
}

test "composed graphics snapshot restores both buffers context and caches" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |return_to_primary| {
        var source = try vt.Terminal.init(12, 4, 100);
        defer source.deinit();
        try source.enableGraphics(4096);
        try source.resizeGeometry(.{ .rows = 4, .columns = 12, .pixel_width = 120, .pixel_height = 80 });
        source.write("MAIN\x1b[1;2H\x1b_Ga=T,f=32,s=1,v=1,i=17,p=1,c=1,r=3,C=1,q=2;/wAA/w==\x1b\\\r\nROW1\r\nROW2\r\nROW3\r\nROW4\r\nROW5");
        source.write("\x1b[?2004h\x1b[?1006h\x1b[>1u\x1b[>3u\x1b[?1049h\x1b[1;1HALT\x1b[2;2H\x1b_Ga=T,f=32,s=1,v=1,i=17,p=2,c=1,r=1,C=1,q=2;AP8A/w==\x1b\\\x1b[2;4r\x1b[?6h\x1b[2;3H\x1b[?1048h\x1b7");
        if (return_to_primary) source.write("\x1b[?1049l");
        const snapshot = try capture(allocator, &source, 131072);
        defer allocator.free(snapshot);
        var destination = try vt.Terminal.init(12, 4, 100);
        defer destination.deinit();
        try destination.enableGraphics(4096);
        try destination.resizeGeometry(.{ .rows = 4, .columns = 12, .pixel_width = 120, .pixel_height = 80 });
        var replies: vt.ResponseSink = .{};
        try destination.setResponseSink(&replies);
        destination.write(snapshot);
        try std.testing.expectEqual(@as(usize, 0), (try replies.bytes()).len);
        try std.testing.expectEqual(try source.activeScreen(), try destination.activeScreen());
        for ([_]vt.Screen{ .primary, .alternate }) |which| {
            const metrics = try source.metricsForScreen(which);
            try std.testing.expectEqualDeep(metrics, try destination.metricsForScreen(which));
            for (0..metrics.total_rows) |row| {
                const expected = try source.formatRow(allocator, which, @intCast(row), 4096);
                defer allocator.free(expected);
                const actual = try destination.formatRow(allocator, which, @intCast(row), 4096);
                defer allocator.free(actual);
                try std.testing.expectEqualStrings(expected, actual);
            }
            const expected = try source.screenPlacements(allocator, which, 8);
            defer allocator.free(expected);
            const actual = try destination.screenPlacements(allocator, which, 8);
            defer allocator.free(actual);
            try std.testing.expectEqualDeep(expected, actual);
            var original = (try source.copyScreenImage(allocator, which, 17, 4096)).?;
            defer original.deinit(allocator);
            var restored = (try destination.copyScreenImage(allocator, which, 17, 4096)).?;
            defer restored.deinit(allocator);
            try std.testing.expectEqualSlices(u8, original.pixels, restored.pixels);
        }
        var expected_replies: vt.ResponseSink = .{};
        try source.setResponseSink(&expected_replies);
        const queries = "\x1b[6n\x1b[?2004$p\x1b[?1006$p\x1b[?47$p\x1b[?1049$p\x1b[?1048$p\x1b[?u";
        source.write(queries);
        destination.write(queries);
        try std.testing.expectEqualStrings(try expected_replies.bytes(), try replies.bytes());
    }
}
