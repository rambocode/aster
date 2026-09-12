const std = @import("std");
const vt = @import("vt.zig");
const wire = @import("graphics_wire.zig");

/// Rebuilds one screen's rows and pinned graphics in history order. The caller
/// supplies a fresh selected screen of the same geometry, then restores terminal
/// modes/cursors separately. This content pass never clamps off-screen anchors.
pub fn captureContent(allocator: std.mem.Allocator, terminal: *const vt.Terminal, maximum: usize) ![]u8 {
    return captureScreenContent(allocator, terminal, try terminal.activeScreen(), maximum);
}

pub fn captureScreenContent(allocator: std.mem.Allocator, terminal: *const vt.Terminal, active: vt.Screen, maximum: usize) ![]u8 {
    return captureScreenPrefix(allocator, terminal, active, (try terminal.metricsForScreen(active)).total_rows, maximum);
}

/// Replays a history prefix ending immediately after the requested last row.
/// Receiver geometry must match and its retained history must keep any image
/// anchor intersecting the final viewport. The wire protocol cannot verify that
/// receiver capacity; this is not an arbitrary raw-TTY compatibility guarantee.
pub fn captureScreenPrefix(allocator: std.mem.Allocator, terminal: *const vt.Terminal, active: vt.Screen, end_row_exclusive: usize, maximum: usize) ![]u8 {
    const metrics = try terminal.metricsForScreen(active);
    if (end_row_exclusive > metrics.total_rows or end_row_exclusive < metrics.rows) return error.InvalidHistoryPrefix;
    if (metrics.rows == 0 or end_row_exclusive > maximum) return error.HistoryTooLarge;
    const ids = try terminal.imageIDs(allocator, active, 4096);
    defer allocator.free(ids);
    const placements = try terminal.screenPlacements(allocator, active, 8192);
    defer allocator.free(placements);
    for (placements) |placement| {
        if (placement.virtual) continue;
        const anchor = placement.anchor orelse return error.ImageAnchorMissing;
        if (anchor.row >= metrics.total_rows or anchor.column >= metrics.columns) return error.ImageAnchorOutOfBounds;
    }
    // Stable sorting preserves the iterator order within a row and avoids a
    // history-rows × placements scan for every snapshot.
    std.sort.block(vt.Placement, placements, {}, struct {
        fn less(_: void, left: vt.Placement, right: vt.Placement) bool {
            if (left.virtual != right.virtual) return left.virtual;
            if (left.virtual) return false;
            return left.anchor.?.row < right.anchor.?.row;
        }
    }.less);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (ids) |id| {
        var image = (try terminal.copyScreenImage(allocator, active, id, maximum)) orelse return error.ImageMissing;
        defer image.deinit(allocator);
        const bytes = try image.transmission(allocator, id, maximum - output.items.len);
        defer allocator.free(bytes);
        try append(allocator, &output, bytes, maximum);
    }
    try append(allocator, &output, if (try terminal.graphemeClustering()) "\x1b[?2027h" else "\x1b[?2027l", maximum);
    try append(allocator, &output, "\x1b[?6l\x1b[?69l\x1b[r\x1b[H", maximum);
    var placement_index: usize = 0;
    while (placement_index < placements.len and placements[placement_index].virtual) : (placement_index += 1) {
        const command = try wire.placement(allocator, placements[placement_index], null, maximum - output.items.len);
        defer allocator.free(command);
        try append(allocator, &output, command, maximum);
    }
    for (0..end_row_exclusive) |row| {
        if (row != 0) try append(allocator, &output, "\r\n", maximum);
        const visible_row = @min(row, metrics.rows - 1);
        const home = try std.fmt.allocPrint(allocator, "\x1b[{d};1H\x1b[0m\x1b[0\"q\x1b[2K", .{visible_row + 1});
        defer allocator.free(home);
        try append(allocator, &output, home, maximum);
        while (placement_index < placements.len and placements[placement_index].anchor.?.row == row) : (placement_index += 1) {
            const placement = placements[placement_index];
            const anchor = placement.anchor.?;
            const command = try wire.placement(allocator, placement, .{ .row = @intCast(visible_row), .column = anchor.column }, maximum - output.items.len);
            defer allocator.free(command);
            try append(allocator, &output, command, maximum);
            try append(allocator, &output, home, maximum);
        }
        const text = try terminal.formatRow(allocator, active, @intCast(row), maximum - output.items.len);
        defer allocator.free(text);
        try append(allocator, &output, text, maximum);
    }
    return output.toOwnedSlice(allocator);
}

fn append(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8, maximum: usize) !void {
    if (bytes.len > maximum - output.items.len) return error.FrameTooLarge;
    try output.appendSlice(allocator, bytes);
}

test "history reconstruction preserves partially visible and fully offscreen images" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "\r\nROW1\r\nROW2\r\nROW3", "\r\nROW1\r\nROW2\r\nROW3\r\nROW4\r\nROW5\r\nROW6" }) |scroll| {
        var source = try vt.Terminal.init(10, 3, 100);
        defer source.deinit();
        try source.enableGraphics(4096);
        try source.resizeGeometry(.{ .rows = 3, .columns = 10, .pixel_width = 100, .pixel_height = 60 });
        source.write("ROW0\x1b[1;2H\x1b_Ga=T,f=32,s=1,v=1,i=61,p=4,c=2,r=3,C=1,q=2;/wAA/w==\x1b\\");
        source.write(scroll);
        const snapshot = try captureContent(allocator, &source, 65536);
        defer allocator.free(snapshot);
        var destination = try vt.Terminal.init(10, 3, 100);
        defer destination.deinit();
        try destination.enableGraphics(4096);
        try destination.resizeGeometry(.{ .rows = 3, .columns = 10, .pixel_width = 100, .pixel_height = 60 });
        destination.write(snapshot);
        const expected = try source.placements(allocator, 8);
        defer allocator.free(expected);
        const actual = try destination.placements(allocator, 8);
        defer allocator.free(actual);
        try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqual((try source.screenMetrics()).total_rows, (try destination.screenMetrics()).total_rows);
        const original_text = try source.formatActiveScreen(allocator, false, 65536);
        defer allocator.free(original_text);
        const restored_text = try destination.formatActiveScreen(allocator, false, 65536);
        defer allocator.free(restored_text);
        try std.testing.expectEqualStrings(original_text, restored_text);
    }
}

test "history pass composes offscreen pinned images with virtual placeholders" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(10, 3, 100);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .rows = 3, .columns = 10, .pixel_width = 100, .pixel_height = 60 });
    source.write("ROW0\x1b[1;2H\x1b_Ga=T,f=32,s=1,v=1,i=61,p=4,c=2,r=3,C=1,q=2;/wAA/w==\x1b\\");
    source.write("\x1b_Ga=t,f=32,s=1,v=1,i=62,q=2;AP8A/w==\x1b\\\x1b_Ga=p,U=1,i=62,p=7,c=1,r=1,q=2\x1b\\");
    source.write("\r\nROW1\r\nROW2\r\nROW3\r\n\x1b[?2027h\x1b[38;2;0;0;62m\x1b[58;2;0;0;7m\u{10eeee}\u{0305}\u{0305}\r\nROW5");
    const snapshot = try captureContent(allocator, &source, 65536);
    defer allocator.free(snapshot);
    var destination = try vt.Terminal.init(10, 3, 100);
    defer destination.deinit();
    try destination.enableGraphics(4096);
    try destination.resizeGeometry(.{ .rows = 3, .columns = 10, .pixel_width = 100, .pixel_height = 60 });
    destination.write(snapshot);
    const metrics = try source.screenMetrics();
    try std.testing.expectEqual(metrics.total_rows, (try destination.screenMetrics()).total_rows);
    for (0..metrics.total_rows) |row| {
        const expected = try source.formatRow(allocator, .primary, @intCast(row), 4096);
        defer allocator.free(expected);
        const actual = try destination.formatRow(allocator, .primary, @intCast(row), 4096);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
    const expected = try source.placements(allocator, 8);
    defer allocator.free(expected);
    const actual = try destination.placements(allocator, 8);
    defer allocator.free(actual);
    try std.testing.expectEqual(@as(usize, 2), actual.len);
    for (expected) |item| {
        var found = false;
        for (actual) |candidate| {
            if (candidate.image_id == item.image_id and candidate.placement_id == item.placement_id) {
                try std.testing.expectEqualDeep(item, candidate);
                found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "inactive primary graphics replay uses its own cache and history" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(10, 3, 100);
    defer source.deinit();
    try source.enableGraphics(4096);
    try source.resizeGeometry(.{ .rows = 3, .columns = 10, .pixel_width = 100, .pixel_height = 60 });
    source.write("MAIN\x1b[1;2H\x1b_Ga=T,f=32,s=1,v=1,i=17,p=1,c=1,r=1,C=1,q=2;/wAA/w==\x1b\\\r\nROW1\r\nROW2\r\nROW3\r\nROW4");
    source.write("\x1b[?47h\x1b[1;1HALT\x1b[1;2H\x1b_Ga=T,f=32,s=1,v=1,i=17,p=2,c=1,r=1,C=1,q=2;AP8A/w==\x1b\\");
    try source.resizeGeometry(.{ .rows = 4, .columns = 12, .pixel_width = 120, .pixel_height = 80 });
    const original_column = try source.cursorColumn();
    var primary_image = (try source.copyScreenImage(allocator, .primary, 17, 4096)) orelse return error.ImageMissing;
    defer primary_image.deinit(allocator);
    var alternate_image = (try source.copyScreenImage(allocator, .alternate, 17, 4096)) orelse return error.ImageMissing;
    defer alternate_image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, primary_image.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, alternate_image.pixels);
    const snapshot = try captureScreenContent(allocator, &source, .primary, 65536);
    defer allocator.free(snapshot);
    try std.testing.expectEqual(vt.Screen.alternate, try source.activeScreen());
    try std.testing.expectEqual(original_column, try source.cursorColumn());
    var destination = try vt.Terminal.init(12, 4, 100);
    defer destination.deinit();
    try destination.enableGraphics(4096);
    try destination.resizeGeometry(.{ .rows = 4, .columns = 12, .pixel_width = 120, .pixel_height = 80 });
    destination.write(snapshot);
    const expected = try source.screenPlacements(allocator, .primary, 8);
    defer allocator.free(expected);
    const actual = try destination.placements(allocator, 8);
    defer allocator.free(actual);
    try std.testing.expectEqualDeep(expected, actual);
    const metrics = try source.metricsForScreen(.primary);
    try std.testing.expectEqual(metrics.total_rows, (try destination.screenMetrics()).total_rows);
    for (0..metrics.total_rows) |row| {
        const original = try source.formatRow(allocator, .primary, @intCast(row), 4096);
        defer allocator.free(original);
        const restored = try destination.formatRow(allocator, .primary, @intCast(row), 4096);
        defer allocator.free(restored);
        try std.testing.expectEqualStrings(original, restored);
    }
    var image = (try destination.copyImage(allocator, 17, 4096)) orelse return error.ImageMissing;
    defer image.deinit(allocator);
    try std.testing.expectEqualSlices(u8, primary_image.pixels, image.pixels);
}
