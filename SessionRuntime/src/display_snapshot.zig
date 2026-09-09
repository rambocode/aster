const std = @import("std");
const vt = @import("vt.zig");

/// Reconstructs both text screens from a clean receiver state. The existing
/// terminal formatter supplies active input modes and screen styles. Graphics
/// and non-active saved mode stacks still need separate snapshot extensions.
pub fn capture(allocator: std.mem.Allocator, terminal: *const vt.Terminal, maximum: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try append(allocator, &output, "\x1bc", maximum);
    const saved_modes = try terminal.savedModes(allocator, maximum);
    defer allocator.free(saved_modes);
    try append(allocator, &output, saved_modes, maximum);
    const active = try terminal.activeScreen();
    if (active == .alternate) {
        const primary = (try terminal.formatScreen(allocator, .primary, true, maximum)) orelse return error.PrimaryScreenMissing;
        defer allocator.free(primary);
        try append(allocator, &output, primary, maximum);
        const primary_cursor = try terminal.cursorReplay(allocator, .primary, maximum);
        defer allocator.free(primary_cursor);
        try append(allocator, &output, primary_cursor, maximum);
        // The active formatter emits the original alternate-screen entry mode,
        // including 1049's saved primary cursor, before reconstructing content.
        try append(allocator, &output, "\x1b[0\"q", maximum);
        const current = try terminal.formatActiveScreen(allocator, true, maximum);
        defer allocator.free(current);
        try append(allocator, &output, current, maximum);
    } else {
        const primary = try terminal.formatActiveScreen(allocator, true, maximum);
        defer allocator.free(primary);
        try append(allocator, &output, primary, maximum);
        if (try terminal.formatScreen(allocator, .alternate, true, maximum)) |alternate| {
            defer allocator.free(alternate);
            try append(allocator, &output, "\x1b[?47h\x1b[0\"q", maximum);
            try append(allocator, &output, alternate, maximum);
            const alternate_cursor = try terminal.cursorReplay(allocator, .alternate, maximum);
            defer allocator.free(alternate_cursor);
            try append(allocator, &output, alternate_cursor, maximum);
            try append(allocator, &output, "\x1b[?47l", maximum);
        }
    }
    const cursor_state = try terminal.cursorReplay(allocator, active, maximum);
    defer allocator.free(cursor_state);
    try append(allocator, &output, cursor_state, maximum);
    return output.toOwnedSlice(allocator);
}

fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8, maximum: usize) !void {
    if (bytes.len > maximum - output.items.len) return error.FrameTooLarge;
    try output.appendSlice(allocator, bytes);
}

test "reconnecting in alternate screen retains primary text and cursor" {
    var source = try vt.Terminal.init(80, 24, 100);
    defer source.deinit();
    source.write("PRIMARY\x1b[?1049hALT中");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    var destination = try vt.Terminal.init(80, 24, 100);
    defer destination.deinit();
    destination.write("stale client content");
    destination.write(bytes);
    try std.testing.expectEqual(vt.Screen.alternate, try destination.activeScreen());
    const alternate = try destination.formatActiveScreen(std.testing.allocator, false, 65536);
    defer std.testing.allocator.free(alternate);
    try std.testing.expect(std.mem.indexOf(u8, alternate, "ALT中") != null);
    destination.write("\x1b[?1049l");
    const primary = try destination.formatActiveScreen(std.testing.allocator, false, 65536);
    defer std.testing.allocator.free(primary);
    try std.testing.expect(std.mem.indexOf(u8, primary, "PRIMARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, primary, "stale client") == null);
    try std.testing.expectEqual(@as(u16, 7), try destination.cursorColumn());
}

test "reconnecting on primary also preserves inactive alternate content" {
    var source = try vt.Terminal.init(80, 24, 100);
    defer source.deinit();
    source.write("PRIMARY\x1b[?47hALTERNATE\x1b[?47l");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    var destination = try vt.Terminal.init(80, 24, 100);
    defer destination.deinit();
    destination.write(bytes);
    try std.testing.expectEqual(vt.Screen.primary, try destination.activeScreen());
    destination.write("\x1b[?47h");
    const alternate = try destination.formatActiveScreen(std.testing.allocator, false, 65536);
    defer std.testing.allocator.free(alternate);
    try std.testing.expect(std.mem.indexOf(u8, alternate, "ALTERNATE") != null);
}

test "snapshot restores bracketed paste mouse and keyboard modes" {
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    source.write("\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[>1u");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    destination.write(bytes);
    var original_responses: vt.ResponseSink = .{};
    var restored_responses: vt.ResponseSink = .{};
    try source.setResponseSink(&original_responses);
    try destination.setResponseSink(&restored_responses);
    const queries = "\x1b[?2004$p\x1b[?1000$p\x1b[?1006$p\x1b[?u";
    source.write(queries);
    destination.write(queries);
    const expected = try original_responses.bytes();
    try std.testing.expect(std.mem.indexOf(u8, expected, "[?2004;1$y") != null);
    try std.testing.expect(std.mem.indexOf(u8, expected, "[?1000;1$y") != null);
    try std.testing.expect(std.mem.indexOf(u8, expected, "[?1006;1$y") != null);
    try std.testing.expect(std.mem.indexOf(u8, expected, "[?1u") != null);
    try std.testing.expectEqualStrings(expected, try restored_responses.bytes());
}

test "snapshot preserves vertical and horizontal origin regions" {
    for ([_][]const u8{ "TOP\x1b[5;20r\x1b[?6h\x1b[2;3HORIGIN", "TOP\x1b[?69h\x1b[5;40s\x1b[5;20r\x1b[?6h\x1b[2;3HORIGIN" }) |sequence| {
        var source = try vt.Terminal.init(80, 24, 0);
        defer source.deinit();
        source.write(sequence);
        const bytes = try capture(std.testing.allocator, &source, 65536);
        defer std.testing.allocator.free(bytes);
        var destination = try vt.Terminal.init(80, 24, 0);
        defer destination.deinit();
        destination.write(bytes);
        const original = try source.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(original);
        const restored = try destination.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(restored);
        try std.testing.expectEqualStrings(original, restored);
        var expected: vt.ResponseSink = .{};
        var actual: vt.ResponseSink = .{};
        try source.setResponseSink(&expected);
        try destination.setResponseSink(&actual);
        source.write("\x1b[6n");
        destination.write("\x1b[6n");
        try std.testing.expectEqualStrings(try expected.bytes(), try actual.bytes());
    }
}

test "snapshot retains saved cursor separately from current cursor" {
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    source.write("\x1b[31mABC\x1b7\x1b[32m\x1b[10;20HCURRENT");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    destination.write(bytes);
    var expected: vt.ResponseSink = .{};
    var actual: vt.ResponseSink = .{};
    try source.setResponseSink(&expected);
    try destination.setResponseSink(&actual);
    // DECRQSS SGR is not answered by this pinned VT. Instead compare the
    // styled cells actually produced by subsequent prints before/after restore.
    for ([_][]const u8{ "X", "\x1b8Y" }) |operation| {
        source.write(operation);
        destination.write(operation);
        const styled_source = try source.formatActiveScreen(std.testing.allocator, true, 65536);
        defer std.testing.allocator.free(styled_source);
        const styled_destination = try destination.formatActiveScreen(std.testing.allocator, true, 65536);
        defer std.testing.allocator.free(styled_destination);
        try std.testing.expectEqualStrings(styled_source, styled_destination);
    }
    source.write("\x1b[6n\x1bP$qm\x1b\\\x1b8\x1b[6n\x1bP$qm\x1b\\");
    destination.write("\x1b[6n\x1bP$qm\x1b\\\x1b8\x1b[6n\x1bP$qm\x1b\\");
    const replies = try expected.bytes();
    try std.testing.expectEqualStrings(replies, try actual.bytes());
}

test "saved charset restoration does not change the current charset" {
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    source.write("\x1b(0\x1b7\x1b(B");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    destination.write(bytes);
    for ([_][]const u8{ "q", "\x1b8q" }) |operation| {
        source.write(operation);
        destination.write(operation);
        const expected = try source.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(expected);
        const actual = try destination.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "saved protection does not leak into the current cursor" {
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    source.write("\x1b[1\"q\x1b7\x1b[0\"q");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    destination.write(bytes);
    for ([_][]const u8{ "X\r\x1b[?2K", "\x1b8Y\r\x1b[?2K" }) |operation| {
        source.write(operation);
        destination.write(operation);
        const expected = try source.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(expected);
        const actual = try destination.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "snapshot preserves current and saved pending-wrap behavior" {
    const cases = [_]struct { before: []const u8, after: []const u8 }{
        .{ .before = "ABCDE", .after = "X" },
        .{ .before = "ABCDE\x1b7\x1b[1;1HB", .after = "\x1b8X" },
        .{ .before = "ABC中", .after = "X" },
        .{ .before = "\x1b[1\"qABC中\x1b[0\"q", .after = "X\x1b[1;1H\x1b[?2K" },
        .{ .before = "ABCDe\u{0301}", .after = "X" },
    };
    for (cases) |case| {
        var source = try vt.Terminal.init(5, 3, 0);
        defer source.deinit();
        source.write(case.before);
        const bytes = try capture(std.testing.allocator, &source, 65536);
        defer std.testing.allocator.free(bytes);
        var destination = try vt.Terminal.init(5, 3, 0);
        defer destination.deinit();
        destination.write(bytes);
        source.write(case.after);
        destination.write(case.after);
        const expected = try source.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(expected);
        const actual = try destination.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "inactive screen saved cursors survive reconnect in either direction" {
    for ([_]struct { before: []const u8, after: []const u8 }{
        .{ .before = "ABC\x1b7\x1b[10;20HMAIN\x1b[?47hALT", .after = "\x1b[?47l\x1b8\x1b[6n" },
        .{ .before = "MAIN\x1b[?47hABC\x1b7\x1b[10;20HLATER\x1b[?47l", .after = "\x1b[?47h\x1b8\x1b[6n" },
    }) |case| {
        var source = try vt.Terminal.init(80, 24, 0);
        defer source.deinit();
        source.write(case.before);
        const bytes = try capture(std.testing.allocator, &source, 65536);
        defer std.testing.allocator.free(bytes);
        var destination = try vt.Terminal.init(80, 24, 0);
        defer destination.deinit();
        destination.write(bytes);
        var expected: vt.ResponseSink = .{};
        var actual: vt.ResponseSink = .{};
        try source.setResponseSink(&expected);
        try destination.setResponseSink(&actual);
        source.write(case.after);
        destination.write(case.after);
        try std.testing.expectEqualStrings(try expected.bytes(), try actual.bytes());
    }
}

test "nested keyboard mode stack survives snapshot including a disabled top" {
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    source.write("\x1b[>1u\x1b[>3u\x1b[>0u");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    destination.write(bytes);
    var expected: vt.ResponseSink = .{};
    var actual: vt.ResponseSink = .{};
    try source.setResponseSink(&expected);
    try destination.setResponseSink(&actual);
    const operations = "\x1b[?u\x1b[<1u\x1b[?u\x1b[<1u\x1b[?u\x1b[<1u\x1b[?u";
    source.write(operations);
    destination.write(operations);
    try std.testing.expectEqualStrings("\x1b[?0u\x1b[?3u\x1b[?1u\x1b[?0u", try expected.bytes());
    try std.testing.expectEqualStrings(try expected.bytes(), try actual.bytes());
}

test "saved DEC modes survive snapshot independently of current values" {
    var source = try vt.Terminal.init(80, 24, 0);
    defer source.deinit();
    source.write("\x1b[?2004h\x1b[?2004s\x1b[?2004l\x1b[?1006h\x1b[?1006s\x1b[?1006l\x1b[?7l\x1b[?7s\x1b[?7h");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    var destination = try vt.Terminal.init(80, 24, 0);
    defer destination.deinit();
    destination.write(bytes);
    var expected: vt.ResponseSink = .{};
    var actual: vt.ResponseSink = .{};
    try source.setResponseSink(&expected);
    try destination.setResponseSink(&actual);
    const commands = "\x1b[?2004$p\x1b[?1006$p\x1b[?7$p\x1b[?2004r\x1b[?1006r\x1b[?7r\x1b[?2004$p\x1b[?1006$p\x1b[?7$p";
    source.write(commands);
    destination.write(commands);
    try std.testing.expectEqualStrings("\x1b[?2004;2$y\x1b[?1006;2$y\x1b[?7;1$y\x1b[?2004;1$y\x1b[?1006;1$y\x1b[?7;2$y", try expected.bytes());
    try std.testing.expectEqualStrings(try expected.bytes(), try actual.bytes());
}
