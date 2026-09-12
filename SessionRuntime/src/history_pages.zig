const std = @import("std");
const vt = @import("vt.zig");

/// IDs are scoped to terminal identity + screen lifetime. Repeated observations
/// retain serials; allocation/reuse changes them. Clear the observer on screen
/// replacement, never sort different terminals by their local serial values.
pub const Page = vt.HistoryPage;

pub fn capture(allocator: std.mem.Allocator, terminal: *const vt.Terminal, screen: vt.Screen, maximum_pages: usize) ![]Page {
    return terminal.historyPages(allocator, screen, maximum_pages);
}

/// Removes exactly the currently oldest history page's history rows, including
/// only the historical portion of a mixed page. expected_serial rejects stale
/// FIFO decisions. Caller must serialize this with terminal writes/resizes.
pub fn trimOldest(allocator: std.mem.Allocator, terminal: *vt.Terminal, screen: vt.Screen, expected_serial: u64, maximum_pages: usize) !vt.HistoryTrim {
    const pages = try capture(allocator, terminal, screen, maximum_pages);
    defer allocator.free(pages);
    if (pages.len == 0) return error.HistoryPageMissing;
    if (pages[0].serial != expected_serial) return error.StaleHistoryPage;
    const usage = try terminal.historyUsage(screen);
    if (pages[0].charged_bytes > usage.charged_bytes) return error.InvalidHistoryUsage;
    return terminal.trimHistory(screen, usage.charged_bytes - pages[0].charged_bytes);
}

fn fill(terminal: *vt.Terminal, count: usize) void {
    for (0..count) |_| terminal.write("ROW\r\n");
}

test "history pages retain stable serials and oldest prefix eviction preserves successors" {
    const a = std.testing.allocator;
    var terminal = try vt.Terminal.init(80, 3, 16 * 1024 * 1024);
    defer terminal.deinit();
    fill(&terminal, 1000);
    const before = try capture(a, &terminal, .primary, 4096);
    defer a.free(before);
    const again = try capture(a, &terminal, .primary, 4096);
    defer a.free(again);
    try std.testing.expectEqualDeep(before, again);
    try std.testing.expect(before.len > 1);
    var bytes: usize = 0;
    var rows: usize = 0;
    for (before) |page| {
        try std.testing.expectEqual(rows, page.first_row);
        bytes += page.charged_bytes;
        rows += page.rows;
    }
    const usage = try terminal.historyUsage(.primary);
    try std.testing.expectEqual(usage.charged_bytes, bytes);
    try std.testing.expectEqual(usage.rows, rows);
    const result = try trimOldest(a, &terminal, .primary, before[0].serial, 4096);
    try std.testing.expectEqual(before[0].rows, result.removed_rows);
    const after = try capture(a, &terminal, .primary, 4096);
    defer a.free(after);
    try std.testing.expectEqual(before.len - 1, after.len);
    for (after, before[1..]) |actual, expected| {
        try std.testing.expectEqual(expected.serial, actual.serial);
        try std.testing.expectEqual(expected.rows, actual.rows);
        try std.testing.expectEqual(expected.charged_bytes, actual.charged_bytes);
        try std.testing.expectEqual(expected.first_row - before[0].rows, actual.first_row);
    }
    try std.testing.expectError(error.StaleHistoryPage, trimOldest(a, &terminal, .primary, before[0].serial, 4096));
}

test "history pages reused pooled nodes receive new serials" {
    const a = std.testing.allocator;
    var terminal = try vt.Terminal.init(80, 3, 16 * 1024 * 1024);
    defer terminal.deinit();
    fill(&terminal, 1000);
    const before = try capture(a, &terminal, .primary, 4096);
    defer a.free(before);
    try std.testing.expect(before.len > 1);
    const discarded = before[0].serial;
    _ = try trimOldest(a, &terminal, .primary, discarded, 4096);
    fill(&terminal, 1000);
    const after = try capture(a, &terminal, .primary, 4096);
    defer a.free(after);
    var fresh = false;
    for (after) |page| {
        try std.testing.expect(page.serial != discarded);
        if (page.serial > before[before.len - 1].serial) fresh = true;
    }
    try std.testing.expect(fresh);
}

test "history pages mixed-page eviction preserves active styled rows and cursor" {
    const a = std.testing.allocator;
    var terminal = try vt.Terminal.init(10, 3, 16 * 1024 * 1024);
    defer terminal.deinit();
    terminal.write("OLD\r\n\x1b[31m中\r\nTHREE\r\nFOUR");
    const pages = try capture(a, &terminal, .primary, 4096);
    defer a.free(pages);
    try std.testing.expectEqual(@as(usize, 1), pages.len);
    const metrics = try terminal.screenMetrics();
    var saved: [3][]u8 = undefined;
    for (&saved, 0..) |*row, i| row.* = try terminal.formatRow(a, .primary, @intCast(metrics.total_rows - metrics.rows + i), 65536);
    defer for (saved) |row| a.free(row);
    const cursor = try terminal.cursorReplay(a, .primary, 65536);
    defer a.free(cursor);
    const result = try trimOldest(a, &terminal, .primary, pages[0].serial, 4096);
    try std.testing.expectEqual(pages[0].rows, result.removed_rows);
    try std.testing.expectEqual(@as(usize, 0), result.remaining.charged_bytes);
    for (saved, 0..) |expected, i| {
        const actual = try terminal.formatRow(a, .primary, @intCast(i), 65536);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
    const actual_cursor = try terminal.cursorReplay(a, .primary, 65536);
    defer a.free(actual_cursor);
    try std.testing.expectEqualStrings(cursor, actual_cursor);
}
