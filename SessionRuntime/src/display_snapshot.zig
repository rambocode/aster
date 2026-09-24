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
        try appendAligned(allocator, &output, terminal, .primary, primary, false, maximum);
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
        try appendAligned(allocator, &output, terminal, .primary, primary, true, maximum);
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

/// 写入整屏格式化输出，并把接收端补齐到源终端的物理总行数。
///
/// Ghostty 格式化器总是裁掉末尾空行。活动区底部有空行而滚动历史又非空时（Codex 等
/// 内联 TUI 先用 DECSTBM 把旧内容推进历史，再 `ESC [ J` 清掉下方），接收端就少滚动了
/// 这些行：它的顶行落在历史里，而不是源终端活动区的顶行。之后所有按活动区坐标写的
/// 内容——光标回放、增量里的绝对定位——都会整体上移，用户看到的就是光标飘在提示符
/// 上方十几行的空行里。这里按格式化输出实际含有的行数补发换行，让接收端恰好滚动
/// 「历史行数」次；没有历史时输出与原来逐字节相同。
///
/// `restore_terminal_state`：`formatActiveScreen` 会在内容之后带上滚动区/原点模式等
/// 终端级状态，补行前必须先中和它们（否则换行只在区内滚动），补完再由 `screenState`
/// 原样恢复；`formatScreen` 只含屏幕级状态，无需处理。
fn appendAligned(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    terminal: *const vt.Terminal,
    screen: vt.Screen,
    formatted: []const u8,
    restore_terminal_state: bool,
    maximum: usize,
) !void {
    try append(allocator, output, formatted, maximum);
    const metrics = try terminal.metricsForScreen(screen);
    if (metrics.total_rows <= metrics.rows or metrics.rows == 0) return;
    // VT 输出中每个非末尾物理行恰好以一个 `\r\n` 结束（含中间空行），末行的换行被
    // 格式化器延后并最终省略；其它状态序列都不含 `\r\n`。
    const emitted = std.mem.count(u8, formatted, "\r\n") + 1;
    const trailing = metrics.total_rows -| emitted;
    if (trailing == 0) return;
    if (restore_terminal_state) try append(allocator, output, "\x1b[?6l\x1b[?69l\x1b[r", maximum);
    var buffer: [32]u8 = undefined;
    const home = try std.fmt.bufPrint(&buffer, "\x1b[{d};1H", .{@min(emitted, metrics.rows)});
    try append(allocator, output, home, maximum);
    for (0..trailing) |_| try append(allocator, output, "\r\n", maximum);
    if (restore_terminal_state) {
        const state = try terminal.screenState(allocator, screen, false, maximum - output.items.len);
        defer allocator.free(state);
        try append(allocator, output, state, maximum);
    }
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

test "restore replays the shell's DECSCUSR cursor shape after RIS" {
    var source = try vt.Terminal.init(80, 24, 100);
    defer source.deinit();
    // Shell integration typically switches to a steady bar at the prompt.
    source.write("prompt$ \x1b[6 q");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    // RIS comes first and would reset the shape; the request must follow it.
    const ris = std.mem.indexOf(u8, bytes, "\x1bc") orelse return error.TestUnexpectedResult;
    const shape = std.mem.lastIndexOf(u8, bytes, "\x1b[6 q") orelse return error.TestUnexpectedResult;
    try std.testing.expect(shape > ris);
    // A receiver that parses the frame keeps the request and replays it again.
    var destination = try vt.Terminal.init(80, 24, 100);
    defer destination.deinit();
    destination.write(bytes);
    const again = try capture(std.testing.allocator, &destination, 65536);
    defer std.testing.allocator.free(again);
    try std.testing.expect(std.mem.indexOf(u8, again, "\x1b[6 q") != null);
}

test "restore emits no DECSCUSR when the program never set a cursor shape" {
    var source = try vt.Terminal.init(80, 24, 100);
    defer source.deinit();
    source.write("plain prompt$ ");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    // DECSCA (`"q`) is part of protection replay; only the ` q` shape request must be absent.
    try std.testing.expect(std.mem.indexOf(u8, bytes, " q") == null);
}

test "restore keeps per-screen cursor shape for primary and alternate" {
    var source = try vt.Terminal.init(80, 24, 100);
    defer source.deinit();
    // Bar at the shell prompt, then a full-screen program on the alternate
    // screen asks for a steady block.
    source.write("\x1b[6 q\x1b[?1049h\x1b[2 q");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    const bar = std.mem.indexOf(u8, bytes, "\x1b[6 q") orelse return error.TestUnexpectedResult;
    const block = std.mem.lastIndexOf(u8, bytes, "\x1b[2 q") orelse return error.TestUnexpectedResult;
    const enter_alt = std.mem.indexOf(u8, bytes, "\x1b[?1049h") orelse return error.TestUnexpectedResult;
    // Primary shape is applied before entering the alternate screen; the
    // active alternate shape is the last word.
    try std.testing.expect(bar < enter_alt);
    try std.testing.expect(block > enter_alt);
}


/// 对齐断言：总行数、活动区光标、每一行内容都一致，且之后的增量输出继续落在同一位置。
fn expectAligned(source: *vt.Terminal) !void {
    const a = std.testing.allocator;
    const bytes = try capture(a, source, 65536);
    defer a.free(bytes);
    var destination = try vt.Terminal.init(10, 4, 100);
    defer destination.deinit();
    destination.write(bytes);
    try expectSameScreens(source, &destination);
    // 增量是原始字节直通：只有活动区对齐，后续输出才会落在同一行。
    source.write("\r\nnext");
    destination.write("\r\nnext");
    try expectSameScreens(source, &destination);
}

fn expectSameScreens(source: *const vt.Terminal, destination: *const vt.Terminal) !void {
    const a = std.testing.allocator;
    const metrics = try source.screenMetrics();
    try std.testing.expectEqual(metrics.total_rows, (try destination.screenMetrics()).total_rows);
    try std.testing.expectEqual(try source.cursorRow(), try destination.cursorRow());
    try std.testing.expectEqual(try source.cursorColumn(), try destination.cursorColumn());
    for (0..metrics.total_rows) |row| {
        const expected = try source.formatRow(a, .primary, @intCast(row), 4096);
        defer a.free(expected);
        const actual = try destination.formatRow(a, .primary, @intCast(row), 4096);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "history with blank rows below the cursor keeps the receiver aligned" {
    var source = try vt.Terminal.init(10, 4, 100);
    defer source.deinit();
    // 六行把两行推进历史，再像内联 TUI 那样清掉活动区，只在首行留一个字符：
    // 活动区末尾三行为空，格式化器会把它们裁掉。
    source.write("R1\r\nR2\r\nR3\r\nR4\r\nR5\r\nR6\x1b[H\x1b[JX");
    try std.testing.expectEqual(@as(u16, 0), try source.cursorRow());
    try expectAligned(&source);
}

test "alignment padding survives an active scroll region and origin mode" {
    var source = try vt.Terminal.init(10, 4, 100);
    defer source.deinit();
    source.write("R1\r\nR2\r\nR3\r\nR4\r\nR5\r\nR6\x1b[H\x1b[JX\x1b[2;3r\x1b[?6h\x1b[1;2HY");
    try expectAligned(&source);
}

test "entirely blank active area with history still scrolls the receiver into place" {
    var source = try vt.Terminal.init(10, 4, 100);
    defer source.deinit();
    source.write("R1\r\nR2\r\nR3\r\nR4\r\nR5\r\nR6\x1b[H\x1b[J");
    try expectAligned(&source);
}

test "primary screen alignment is restored when reconnecting inside the alternate screen" {
    const a = std.testing.allocator;
    var source = try vt.Terminal.init(10, 4, 100);
    defer source.deinit();
    source.write("R1\r\nR2\r\nR3\r\nR4\r\nR5\r\nR6\x1b[H\x1b[JX\x1b[?1049hALT");
    const bytes = try capture(a, &source, 65536);
    defer a.free(bytes);
    var destination = try vt.Terminal.init(10, 4, 100);
    defer destination.deinit();
    destination.write(bytes);
    source.write("\x1b[?1049l\r\nback");
    destination.write("\x1b[?1049l\r\nback");
    try expectSameScreens(&source, &destination);
}

test "snapshot without history is unchanged by alignment" {
    const a = std.testing.allocator;
    var source = try vt.Terminal.init(10, 4, 100);
    defer source.deinit();
    source.write("ONE\r\nTWO");
    const bytes = try capture(a, &source, 65536);
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?69l") == null);
    var destination = try vt.Terminal.init(10, 4, 100);
    defer destination.deinit();
    destination.write(bytes);
    try expectSameScreens(&source, &destination);
}

test "alignment counting survives wrapped rows, wide characters and styled blank rows" {
    const a = std.testing.allocator;
    const scripts = [_][]const u8{
        // 恰好占满一行 + 软换行两行 + 宽字符跨行边界。
        "0123456789ABCDEFGHIJ\r\n中文中文中文\r\nX\r\nY\r\nZ\r\nW\x1b[H\x1b[JQ",
        // 带背景色的空格行与 EL 清出的行夹在中间。
        "A\r\n\x1b[41m          \x1b[0m\r\n\x1b[2K\r\nB\r\nC\r\nD\r\nE\x1b[H\x1b[JQ",
        // 顶部空行 + 尾部宽字符占位。
        "\r\n\r\nA\r\nB\r\nC\r\nD\r\n123456789中\x1b[H\x1b[JQ\x1b[2;1H",
        // 光标停在待换行位（pending wrap）。
        "A\r\nB\r\nC\r\nD\r\nE\r\nF\x1b[H\x1b[J0123456789",
    };
    for (scripts) |script| {
        var source = try vt.Terminal.init(10, 4, 100);
        defer source.deinit();
        source.write(script);
        const bytes = try capture(a, &source, 65536);
        defer a.free(bytes);
        var destination = try vt.Terminal.init(10, 4, 100);
        defer destination.deinit();
        destination.write(bytes);
        try expectSameScreens(&source, &destination);
        source.write("\r\nnext 中");
        destination.write("\r\nnext 中");
        try expectSameScreens(&source, &destination);
    }
}

test "restore does not paint the gap after a background run" {
    var source = try vt.Terminal.init(40, 6, 100);
    defer source.deinit();
    // Claude Code 的 Clawd 头部：黑底色块之后用 CHA 跳过 3 格再写标题，跳过的格子是空白。
    // 快照若在黑底样式未关闭时补空格，接收端这 3 格会被涂成黑块。
    source.write("\x1b[?1049h\x1b[2J\x1b[H\r\x1b[1B\x1b[38;2;215;119;87m \xe2\x96\x90\x1b[48;2;0;0;0m\xe2\x96\x9b\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x9b\xe2\x96\x88\x1b[12G\x1b[39m\x1b[49m\x1b[1mClaude Code");
    const bytes = try capture(std.testing.allocator, &source, 65536);
    defer std.testing.allocator.free(bytes);
    const run = std.mem.indexOf(u8, bytes, "\xe2\x96\x9b\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x9b\xe2\x96\x88") orelse return error.TestUnexpectedResult;
    const gap = std.mem.indexOfPos(u8, bytes, run, "   ") orelse return error.TestUnexpectedResult;
    // 黑底色块与空白之间必须先复位样式。
    const reset = std.mem.indexOfPos(u8, bytes, run, "\x1b[0m") orelse return error.TestUnexpectedResult;
    try std.testing.expect(reset < gap);
    var destination = try vt.Terminal.init(40, 6, 100);
    defer destination.deinit();
    destination.write(bytes);
    const expected = try source.formatActiveScreen(std.testing.allocator, true, 65536);
    defer std.testing.allocator.free(expected);
    const actual = try destination.formatActiveScreen(std.testing.allocator, true, 65536);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
