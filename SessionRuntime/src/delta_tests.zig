const std = @import("std");
const vt = @import("vt.zig");
const Filter = @import("delta_filter.zig").Filter;

test "mixed raw deltas and snapshots stay equivalent to authoritative VT" {
    const allocator = std.testing.allocator;
    var source = try vt.Terminal.init(40, 8, 100);
    defer source.deinit();
    var destination = try vt.Terminal.init(40, 8, 100);
    defer destination.deinit();
    var filter: Filter = .{};
    var delta_count: usize = 0;
    var snapshot_count: usize = 0;
    const chunks = [_][]const u8{
        "prompt",     "\x1b[31mred", "\x1b[0m\r\n中", "\x1b[2;3Hposition",
        "\x1b]52;c;", "c2VjcmV0",    "\x07tail",       "\x1b[6n",
        "\r\nnext",   "\x1b%",       "G",              " text",
        "\x1b(",      &.{0},         "0",              "qq",
        "\x1b(B",     &.{0xe4},      &.{ 0xb8, 0xad }, "after",
        "safe",
    };
    for (chunks) |chunk| {
        source.write(chunk);
        if (filter.consume(chunk)) {
            destination.write(chunk);
            delta_count += 1;
        } else {
            const snapshot = try @import("display_snapshot.zig").capture(allocator, &source, 131072);
            defer allocator.free(snapshot);
            destination.write(snapshot);
            snapshot_count += 1;
        }
        const expected = try source.formatActiveScreen(allocator, false, 131072);
        defer allocator.free(expected);
        const actual = try destination.formatActiveScreen(allocator, false, 131072);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expectEqual(try source.cursorColumn(), try destination.cursorColumn());
    }
    try std.testing.expect(delta_count > 5);
    try std.testing.expect(snapshot_count > 5);
}

// 远端 Shell 的 OSC 7 必须原样镜像到本地客户端，否则详情面板永远收不到远端 cwd。
// OSC 52（剪贴板）等未放行的序列仍必须走快照，本用例一并守住这条边界。
test "OSC 7 working directory blocks stay safe for raw mirroring" {
    var filter: Filter = .{};
    try std.testing.expect(filter.consume("\x1b]7;file://ubuntu/var/log\x07"));
    // ST 结尾（ESC \\）与 BEL 结尾等价，两种写法都要放行。
    try std.testing.expect(filter.consume("\x1b]7;file://ubuntu/etc\x1b\\"));
    // 与安全正文同块也保持可镜像。
    try std.testing.expect(filter.consume("done\r\n\x1b]7;file://ubuntu/tmp\x07$ "));
    // 未放行的 OSC 仍判定为不安全。
    try std.testing.expect(!filter.consume("\x1b]52;c;c2VjcmV0\x07"));
}
