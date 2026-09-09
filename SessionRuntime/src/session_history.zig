const std = @import("std");
const Session = @import("session.zig").Session;
const vt = @import("vt.zig");
const pages = @import("history_pages.zig");
const budget = @import("history_budget.zig");

pub const Item = struct { id: [36]u8, session: *Session };
pub const Stats = struct { charged_bytes: usize, removed_rows: usize, removed_pages: usize, tracked_pages: usize };
pub const maximum_items = 64;
pub const maximum_pages_per_screen = 4096;
pub const maximum_records = 32768;
const Key = struct { id: [36]u8, instance: usize, screen: vt.Screen, serial: u64 };
const Record = struct { key: Key, page: pages.Page, order: u64 };
const Group = struct { session: *Session, screen: vt.Screen, next: usize, end: usize };

/// One session-owner-thread FIFO observer. Order means first observation of a
/// page entering history, not its local Ghostty serial or byte-arrival time.
/// Call after each producer's output turn for inter-terminal arrival ordering.
/// Terminal IDs must identify one lifecycle; forget() before reusing an ID for
/// a replacement Session/screen. Entries disappearing from an observation are
/// removed, including resets, pruning and removed terminals.
pub const Manager = struct {
    allocator: std.mem.Allocator,
    orders: std.AutoHashMap(Key, u64),
    next_order: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator, .orders = std.AutoHashMap(Key, u64).init(allocator) };
    }
    pub fn deinit(self: *Manager) void {
        self.orders.deinit();
    }
    /// Explicit lifecycle fence for replacement of a terminal under the same ID.
    pub fn forget(self: *Manager, id: [36]u8) void {
        // Removal invalidates iterators, so restart after each matching key.
        // Lifecycle cleanup never allocates or discards unrelated FIFO order.
        while (true) {
            var found: ?Key = null;
            var it = self.orders.keyIterator();
            while (it.next()) |key| {
                if (std.mem.eql(u8, &key.id, &id)) {
                    found = key.*;
                    break;
                }
            }
            _ = self.orders.remove(found orelse break);
        }
    }

    /// Enforces each terminal's <=16 MiB policy first, then the aggregate limit.
    /// Only oldest history prefixes are removed; no PTY lifecycle operation is
    /// performed. Errors propagate to the owner for isolation/retry.
    pub fn enforce(self: *Manager, items: []const Item, limit_bytes: usize) !Stats {
        if (items.len > maximum_items) return error.HistoryTerminalLimit;
        for (items, 0..) |item, i| {
            for (items[0..i]) |previous| {
                if (std.mem.eql(u8, &item.id, &previous.id) or item.session == previous.session) return error.DuplicateHistoryTerminal;
            }
            if (item.session.history_limit > budget.terminal_limit) return error.InvalidTerminalHistoryLimit;
        }
        var observed = std.AutoHashMap(Key, u64).init(self.allocator);
        defer observed.deinit();
        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(self.allocator);
        var groups: [maximum_items * 2]Group = undefined;
        var group_count: usize = 0;
        var charged: usize = 0;
        var next_order = self.next_order;
        for (items) |item| {
            try item.session.enforceHistoryLimit();
            for ([_]vt.Screen{ .primary, .alternate }) |screen| {
                if (!try item.session.terminal.hasScreen(screen)) continue;
                const descriptors = try pages.capture(self.allocator, &item.session.terminal, screen, maximum_pages_per_screen);
                defer self.allocator.free(descriptors);
                if (descriptors.len > maximum_records - records.items.len) return error.HistoryRecordLimit;
                const start = records.items.len;
                for (descriptors) |page| {
                    const key = Key{ .id = item.id, .instance = @intFromPtr(item.session), .screen = screen, .serial = page.serial };
                    const order = self.orders.get(key) orelse fresh: {
                        if (next_order == std.math.maxInt(u64)) return error.HistoryObservationOverflow;
                        const value = next_order;
                        next_order += 1;
                        break :fresh value;
                    };
                    try observed.putNoClobber(key, order);
                    try records.append(self.allocator, .{ .key = key, .page = page, .order = order });
                    charged = try std.math.add(usize, charged, page.charged_bytes);
                }
                groups[group_count] = .{ .session = item.session, .screen = screen, .next = start, .end = records.items.len };
                group_count += 1;
            }
        }
        // Commit a complete observation before trimming. On a later error the
        // next call reconciles disappeared pages against the actual VT state.
        std.mem.swap(std.AutoHashMap(Key, u64), &self.orders, &observed);
        self.next_order = next_order;
        var result = Stats{ .charged_bytes = charged, .removed_rows = 0, .removed_pages = 0, .tracked_pages = self.orders.count() };
        while (result.charged_bytes > limit_bytes) {
            var selected: ?usize = null;
            for (groups[0..group_count], 0..) |group, i| {
                if (group.next == group.end) continue;
                if (selected == null or records.items[group.next].order < records.items[groups[selected.?].next].order) selected = i;
            }
            const group = &groups[selected orelse return error.HistoryBudgetNotSatisfied];
            const record = records.items[group.next];
            const trimmed = try pages.trimOldest(self.allocator, &group.session.terminal, group.screen, record.key.serial, maximum_pages_per_screen);
            if (trimmed.removed_rows != record.page.rows) return error.HistoryPageChanged;
            try group.session.markHistoryTrimmed();
            _ = self.orders.remove(record.key);
            group.next += 1;
            result.removed_rows += trimmed.removed_rows;
            result.removed_pages += 1;
            result.charged_bytes -= record.page.charged_bytes;
        }
        result.tracked_pages = self.orders.count();
        return result;
    }
};

fn testID(last: u8) [36]u8 {
    var value = "00000000-0000-4000-8000-000000000000".*;
    value[35] = last;
    return value;
}
fn fill(session: *Session, count: usize) void {
    for (0..count) |_| session.terminal.write("ROW\r\n");
}

test "session history manager interleaved observations evict globally oldest page without active damage" {
    const a = std.testing.allocator;
    const first = try Session.prepare(a, .{ .columns = 80, .rows = 3 });
    defer first.destroy();
    const second = try Session.prepare(a, .{ .columns = 80, .rows = 3 });
    defer second.destroy();
    var manager = Manager.init(a);
    defer manager.deinit();
    const items = [_]Item{ .{ .id = testID('1'), .session = first }, .{ .id = testID('2'), .session = second } };
    // Second terminal's pages are older even though it is second in items.
    fill(second, 1000);
    second.terminal.write("TAIL中");
    _ = try manager.enforce(&items, budget.session_limit);
    fill(first, 1000);
    const before = try manager.enforce(&items, budget.session_limit);
    const old = try pages.capture(a, &second.terminal, .primary, maximum_pages_per_screen);
    defer a.free(old);
    const first_rows = (try budget.usage(&first.terminal)).rows;
    const active_before = try second.terminal.formatRow(a, .primary, @intCast((try second.terminal.screenMetrics()).total_rows - 1), 65536);
    defer a.free(active_before);
    const result = try manager.enforce(&items, before.charged_bytes - old[0].charged_bytes);
    try std.testing.expectEqual(@as(usize, 1), result.removed_pages);
    try std.testing.expectEqual(first_rows, (try budget.usage(&first.terminal)).rows);
    try std.testing.expect(second.output_sequence > 0 and second.viewport_snapshot_required and !second.delta_safe);
    const active_after = try second.terminal.formatRow(a, .primary, @intCast((try second.terminal.screenMetrics()).total_rows - 1), 65536);
    defer a.free(active_after);
    try std.testing.expectEqualStrings(active_before, active_after);
}

test "session history manager forgets vanished reset pages and repeated calls remain bounded" {
    const a = std.testing.allocator;
    const session = try Session.prepare(a, .{ .columns = 80, .rows = 3 });
    defer session.destroy();
    var manager = Manager.init(a);
    defer manager.deinit();
    const items = [_]Item{.{ .id = testID('1'), .session = session }};
    fill(session, 1000);
    _ = try manager.enforce(&items, budget.session_limit);
    const order_before = manager.next_order;
    for (0..20) |_| _ = try manager.enforce(&items, budget.session_limit);
    try std.testing.expectEqual(order_before, manager.next_order);
    session.terminal.write("\x1bc");
    _ = try manager.enforce(&items, budget.session_limit);
    try std.testing.expectEqual(@as(u32, 0), manager.orders.count());
    fill(session, 1000);
    _ = try manager.enforce(&items, budget.session_limit);
    var values = manager.orders.valueIterator();
    while (values.next()) |order| try std.testing.expect(order.* >= order_before);
    try std.testing.expect(manager.orders.count() <= maximum_records);
    manager.forget(items[0].id);
    try std.testing.expectEqual(@as(u32, 0), manager.orders.count());
    _ = try manager.enforce(&items, budget.session_limit);
    _ = try manager.enforce(&.{}, budget.session_limit);
    try std.testing.expectEqual(@as(u32, 0), manager.orders.count());
}

test "session history manager trims inactive primary history without touching alternate screen" {
    const a = std.testing.allocator;
    const session = try Session.prepare(a, .{ .columns = 80, .rows = 3 });
    defer session.destroy();
    var manager = Manager.init(a);
    defer manager.deinit();
    fill(session, 1000);
    session.terminal.write("\x1b[?47h\x1b[31mALT中");
    const before = try session.terminal.formatRow(a, .alternate, 0, 65536);
    defer a.free(before);
    const cursor = try session.terminal.cursorReplay(a, .alternate, 65536);
    defer a.free(cursor);
    const result = try manager.enforce(&.{.{ .id = testID('1'), .session = session }}, 0);
    try std.testing.expect(result.removed_pages > 0);
    try std.testing.expectEqual(@as(usize, 0), result.charged_bytes);
    try std.testing.expectEqual(vt.Screen.alternate, try session.terminal.activeScreen());
    const after = try session.terminal.formatRow(a, .alternate, 0, 65536);
    defer a.free(after);
    const after_cursor = try session.terminal.cursorReplay(a, .alternate, 65536);
    defer a.free(after_cursor);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualStrings(cursor, after_cursor);
}
