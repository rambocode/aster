const std = @import("std");
const vt = @import("vt.zig");

pub const terminal_limit: usize = 16 * 1024 * 1024;
pub const session_limit: usize = 256 * 1024 * 1024;
pub const Usage = struct { rows: usize = 0, charged_bytes: usize = 0, reclaimable_bytes: usize = 0 };
pub const Trim = struct { removed_rows: usize, remaining: Usage };

/// Both screens count toward one terminal's retained-text-history budget.
/// Allocation charge is conservative for mixed pages; graphics and idle page
/// pool reserves belong to separate budgets. This is not an RSS measurement.
pub fn usage(terminal: *const vt.Terminal) !Usage {
    var result: Usage = .{};
    for ([_]vt.Screen{ .primary, .alternate }) |screen| {
        if (!try terminal.hasScreen(screen)) continue;
        const current = try terminal.historyUsage(screen);
        result.rows = try std.math.add(usize, result.rows, current.rows);
        result.charged_bytes = try std.math.add(usize, result.charged_bytes, current.charged_bytes);
        result.reclaimable_bytes = try std.math.add(usize, result.reclaimable_bytes, current.reclaimable_bytes);
    }
    return result;
}

/// Enforces the caller's allocation budget using oldest history prefixes.
/// Ghostty's alternate screen has no scrollback. Both screens are checked so
/// accounting remains explicit if that invariant changes in a later version.
/// Nonzero removal requires the owner to invalidate its cached projections.
pub fn trim(terminal: *vt.Terminal, maximum: usize) !Trim {
    var current = try usage(terminal);
    var removed: usize = 0;
    for ([_]vt.Screen{ .primary, .alternate }) |screen| {
        if (current.charged_bytes <= maximum) break;
        if (!try terminal.hasScreen(screen)) continue;
        const screen_usage = try terminal.historyUsage(screen);
        const excess = current.charged_bytes - maximum;
        const target = screen_usage.charged_bytes -| excess;
        const result = try terminal.trimHistory(screen, target);
        removed = try std.math.add(usize, removed, result.removed_rows);
        current = try usage(terminal);
    }
    if (current.charged_bytes > maximum) return error.HistoryBudgetNotSatisfied;
    return .{ .removed_rows = removed, .remaining = current };
}

test "history budget counts mixed page and clears history without changing active cells" {
    const a = std.testing.allocator;
    var terminal = try vt.Terminal.init(10, 3, terminal_limit);
    defer terminal.deinit();
    terminal.write("OLD\r\n\x1b[31m中\r\nTHREE\r\nFOUR");
    _ = try terminal.scrollViewport(-1);
    const initial = try usage(&terminal);
    try std.testing.expect(initial.rows > 0);
    try std.testing.expect(initial.charged_bytes > 0);
    const before_metrics = try terminal.screenMetrics();
    var active: std.ArrayList([]u8) = .empty;
    defer {
        for (active.items) |row| a.free(row);
        active.deinit(a);
    }
    try active.ensureTotalCapacity(a, before_metrics.rows);
    for (0..before_metrics.rows) |index| {
        active.appendAssumeCapacity(try terminal.formatRow(a, .primary, @intCast(before_metrics.total_rows - before_metrics.rows + index), 65536));
    }
    const cursor = try terminal.cursorReplay(a, .primary, 65536);
    defer a.free(cursor);
    const result = try trim(&terminal, 0);
    try std.testing.expectEqual(initial.rows, result.removed_rows);
    try std.testing.expectEqual(@as(usize, 0), result.remaining.charged_bytes);
    const after_metrics = try terminal.screenMetrics();
    try std.testing.expectEqual(before_metrics.rows, after_metrics.rows);
    for (active.items, 0..) |expected, index| {
        const after = try terminal.formatRow(a, .primary, @intCast(after_metrics.total_rows - after_metrics.rows + index), 65536);
        defer a.free(after);
        try std.testing.expectEqualStrings(expected, after);
    }
    const after_cursor = try terminal.cursorReplay(a, .primary, 65536);
    defer a.free(after_cursor);
    try std.testing.expectEqualStrings(cursor, after_cursor);
    try std.testing.expectEqual(@as(usize, 0), (try trim(&terminal, 0)).removed_rows);
}

test "history budget trims oldest pages and retains newest historical rows" {
    const a = std.testing.allocator;
    var terminal = try vt.Terminal.init(80, 3, terminal_limit);
    defer terminal.deinit();
    for (0..1000) |index| {
        var buffer: [64]u8 = undefined;
        terminal.write(try std.fmt.bufPrint(&buffer, "ROW{d}\r\n", .{index}));
    }
    const initial = try usage(&terminal);
    try std.testing.expect(initial.reclaimable_bytes > 0);
    const target = initial.charged_bytes / 2;
    const result = try trim(&terminal, target);
    try std.testing.expect(result.removed_rows > 0);
    try std.testing.expect(result.remaining.rows > 0);
    try std.testing.expect(result.remaining.charged_bytes <= target);
    const row = try terminal.formatRow(a, .primary, 0, 65536);
    defer a.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "ROW0") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "ROW") != null);
}

test "history budget excludes graphics pixels and active-only terminals" {
    var terminal = try vt.Terminal.init(10, 3, terminal_limit);
    defer terminal.deinit();
    try terminal.enableGraphics(4096);
    terminal.write("LIVE\x1b_Ga=t,f=32,s=1,v=1,i=31,q=2;/wAA/w==\x1b\\");
    const result = try trim(&terminal, 0);
    try std.testing.expectEqual(@as(usize, 0), result.remaining.charged_bytes);
    try std.testing.expectEqual(@as(usize, 1), try terminal.imageCount(.primary));
}
