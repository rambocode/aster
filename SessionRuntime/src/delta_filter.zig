const std = @import("std");

/// Tracks VT boundaries across PTY reads. A block is eligible only when both
/// endpoints are in ground state and every operation is safe to mirror. Unsafe
/// blocks are represented by a generated snapshot instead, never raw passthrough.
pub const Filter = struct {
    state: enum { ground, escape, escape_intermediate, charset, csi, osc, osc_escape, string, string_escape } = .ground,
    csi: [128]u8 = undefined,
    csi_len: usize = 0,
    csi_overflow: bool = false,
    osc_code: u32 = 0,
    osc_header: bool = false,
    osc_allowed: bool = false,
    utf8_uncertain: bool = false,

    pub fn consume(self: *Filter, bytes: []const u8) bool {
        var allowed = bytes.len != 0 and self.state == .ground and !self.utf8_uncertain;
        const valid_utf8 = std.unicode.utf8ValidateSlice(bytes);
        if (!valid_utf8) allowed = false;
        // After a fragmented/invalid UTF-8 read, one complete UTF-8 block still
        // resynchronizes via snapshot (the source decoder may emit replacement).
        self.utf8_uncertain = !valid_utf8;
        for (bytes) |byte| if (!self.step(byte)) {
            allowed = false;
        };
        return allowed and self.state == .ground;
    }

    pub const Split = struct {
        /// 可作为自洽增量交付的前缀长度：止于最后一个「解析器在 ground 且 UTF-8 完整」的位置。
        complete: usize,
        /// 只描述 `complete` 之前的部分是否可镜像。
        allowed: bool,
    };

    /// 与 `consume` 同一套判定，但把块切成「完整前缀 + 未完成尾巴」。
    ///
    /// PTY 每次 read 最多给约 1 KiB，TUI 的一帧常被切在转义序列或 UTF-8 字符中间；按整块
    /// 判定时切开的两半都不安全，一帧就变成两次全量快照。未完成的序列对 VT 还没有可见效果，
    /// 所以调用方可以只交付前缀、把尾巴留到下一次读再连同后续字节一起判定。
    /// 前缀本身非法 UTF-8 时不切（`complete` 为 0），行为退回 `consume`。
    pub fn consumeSplit(self: *Filter, bytes: []const u8) Split {
        var allowed = bytes.len != 0 and self.state == .ground and !self.utf8_uncertain;
        var complete: usize = 0;
        var allowed_at_complete = false;
        var utf8_pending: u3 = 0;
        var utf8_invalid = false;
        for (bytes, 0..) |byte, index| {
            if (utf8_pending > 0) {
                if (byte & 0xC0 == 0x80) utf8_pending -= 1 else {
                    utf8_invalid = true;
                    utf8_pending = 0;
                }
            } else if (byte >= 0x80) {
                const length = std.unicode.utf8ByteSequenceLength(byte) catch blk: {
                    utf8_invalid = true;
                    break :blk 1;
                };
                utf8_pending = @intCast(length - 1);
            }
            if (!self.step(byte)) allowed = false;
            if (self.state == .ground and utf8_pending == 0 and !utf8_invalid) {
                complete = index + 1;
                allowed_at_complete = allowed;
            }
        }
        // 序列长度合法不等于编码合法（过长编码、代理区）：前缀仍要过完整校验。
        if (utf8_invalid or !std.unicode.utf8ValidateSlice(bytes[0..complete])) {
            self.utf8_uncertain = true;
            return .{ .complete = 0, .allowed = false };
        }
        self.utf8_uncertain = false;
        return .{ .complete = complete, .allowed = allowed_at_complete and complete != 0 };
    }

    /// 喂入一个字节；返回它是否仍可镜像（查询、宿主副作用与未知序列返回 false）。
    fn step(self: *Filter, byte: u8) bool {
        if (byte == 0x18 or byte == 0x1a) {
            self.state = .ground;
            return false;
        }
        var allowed = true;
        switch (self.state) {
            .ground => {
                if (byte == 0x1b) self.state = .escape else if (byte < 0x20 and byte != 7 and byte != 8 and byte != 9 and byte != 10 and byte != 13 and byte != 14 and byte != 15) allowed = false;
            },
            .escape => if (!self.escape(byte)) {
                allowed = false;
            },
            .charset, .escape_intermediate => {
                if (self.state == .escape_intermediate) allowed = false;
                if (byte >= 0x30 and byte <= 0x7e) self.state = .ground else {
                    allowed = false;
                    if (byte == 0x1b) self.state = .escape;
                }
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    if (self.csi_overflow or !safeCSI(self.csi[0..self.csi_len], byte)) allowed = false;
                    self.state = .ground;
                } else if (byte == 0x1b) {
                    self.state = .escape;
                    allowed = false;
                } else if (byte >= 0x20 and byte <= 0x3f) {
                    if (self.csi_len < self.csi.len) {
                        self.csi[self.csi_len] = byte;
                        self.csi_len += 1;
                    } else self.csi_overflow = true;
                } else allowed = false;
            },
            .osc => {
                if (byte == 7) {
                    if (!self.osc_allowed) allowed = false;
                    self.state = .ground;
                } else if (byte == 0x1b) self.state = .osc_escape else if (self.osc_header) {
                    if (byte == ';') {
                        self.osc_header = false;
                        // 133（shell 集成提示符标记）与 6974（Aster 私有 Agent/徽章指令）只改客户端
                        // 状态、没有宿主副作用；不放行的话受管 Pane 收不到命令边界与 hook 信号。
                        self.osc_allowed = self.osc_code == 0 or self.osc_code == 1 or self.osc_code == 2 or self.osc_code == 7 or self.osc_code == 8 or
                            self.osc_code == 133 or self.osc_code == 6974;
                    } else if (byte >= '0' and byte <= '9' and self.osc_code < 10000) {
                        self.osc_code = self.osc_code * 10 + byte - '0';
                    } else {
                        self.osc_header = false;
                        self.osc_allowed = false;
                    }
                }
            },
            .osc_escape => {
                if (byte == '\\') {
                    if (!self.osc_allowed) allowed = false;
                    self.state = .ground;
                } else {
                    allowed = false;
                    _ = self.escape(byte);
                }
            },
            .string => {
                allowed = false;
                if (byte == 0x1b) self.state = .string_escape;
            },
            .string_escape => {
                allowed = false;
                if (byte == '\\') self.state = .ground else _ = self.escape(byte);
            },
        }
        return allowed;
    }

    fn escape(self: *Filter, byte: u8) bool {
        self.state = .ground;
        switch (byte) {
            '[' => {
                self.state = .csi;
                self.csi_len = 0;
                self.csi_overflow = false;
            },
            ']' => {
                self.state = .osc;
                self.osc_code = 0;
                self.osc_header = true;
                self.osc_allowed = false;
            },
            'P', '_', '^', 'X' => {
                self.state = .string;
                return false;
            },
            '(', ')', '*', '+', '-', '.', '/' => self.state = .charset,
            0x1b => {
                self.state = .escape;
                return false;
            },
            '7', '8', 'D', 'E', 'H', 'M', 'c', '=', '>', 'N', 'O', 'n', 'o', '|', '}', '~' => {},
            else => {
                if (byte < 0x20 or byte == 0x7f) self.state = .escape else if (byte >= 0x20 and byte <= 0x2f) self.state = .escape_intermediate;
                return false;
            },
        }
        return true;
    }
};

fn safeCSI(parameters: []const u8, final: u8) bool {
    // Window operations, device reports and queries are never mirrored. The
    // authoritative VT handles their responses; snapshots carry resulting state.
    if (final == 'u' and std.mem.indexOfScalar(u8, parameters, '?') != null) return false;
    if (final == 'q') return std.mem.eql(u8, parameters, " q") or
        (parameters.len >= 1 and parameters[parameters.len - 1] == '"') or
        (parameters.len >= 1 and parameters[parameters.len - 1] == ' ');
    // Intermediate bytes can turn familiar finals into different operations.
    for (parameters) |byte| if (byte < 0x30) {
        return false;
    };
    return std.mem.indexOfScalar(u8, "@ABCDEFGHIJKLMPSTXZ`abdefghlmrsu", final) != null and final != ' ';
}

test "ordinary terminal drawing is eligible but queries and host side effects are not" {
    for ([_][]const u8{ "hello中\r\n", "\x1b[2;3H\x1b[31mred\x1b[0m", "\x1b[?2004h", "\x1b[>1u", "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\", "\x1b]133;A\x07prompt", "\x1b]6974;AgentState=processing;Provider=codex;SessionID=abc\x07" }) |value| {
        var filter: Filter = .{};
        try std.testing.expect(filter.consume(value));
    }
    for ([_][]const u8{ "\x1b[6n", "\x1b[c", "\x1b[?u", "\x1b[?2004$p", "\x1b[8;40;80t", "\x1b]52;c;secret\x07", "\x1b_Ga=T;pixels\x1b\\", "\x1bP$qm\x1b\\" }) |value| {
        var filter: Filter = .{};
        try std.testing.expect(!filter.consume(value));
        try std.testing.expect(filter.consume("next"));
    }
}

test "split control strings never leak their payload as printable deltas" {
    var filter: Filter = .{};
    try std.testing.expect(!filter.consume("\x1b]52;c;"));
    try std.testing.expect(!filter.consume("secret"));
    try std.testing.expect(!filter.consume("\x07"));
    try std.testing.expect(filter.consume("safe"));
    try std.testing.expect(!filter.consume("\x1b[3"));
    try std.testing.expect(!filter.consume("1mred"));
    try std.testing.expect(filter.consume("text"));
}

test "fragmented UTF-8 requires a clean snapshot boundary before resuming deltas" {
    var filter: Filter = .{};
    try std.testing.expect(!filter.consume(&.{0xe4}));
    try std.testing.expect(!filter.consume(&.{ 0xb8, 0xad }));
    try std.testing.expect(!filter.consume("first clean"));
    try std.testing.expect(filter.consume("second clean"));
}

test "escape intermediates and ignored controls retain parser boundaries" {
    var filter: Filter = .{};
    try std.testing.expect(!filter.consume("\x1b%"));
    try std.testing.expect(!filter.consume("G"));
    try std.testing.expect(filter.consume("text"));
    try std.testing.expect(!filter.consume("\x1b("));
    try std.testing.expect(!filter.consume(&.{0}));
    try std.testing.expect(!filter.consume("0"));
    try std.testing.expect(filter.consume("qq"));
    try std.testing.expect(!filter.consume("\x1b"));
    try std.testing.expect(!filter.consume(&.{0}));
    try std.testing.expect(!filter.consume("[31mred"));
}

test "consumeSplit hands back an incomplete tail instead of condemning the block" {
    var filter: Filter = .{};
    // 切在 CSI 中间：前缀可交付，尾巴留下。
    var split = filter.consumeSplit("hello\x1b[3");
    try std.testing.expectEqual(@as(usize, 5), split.complete);
    try std.testing.expect(split.allowed);
    // 切点是 ground 边界，调用方会重置过滤器再喂「尾巴 + 后续」。
    filter = .{};
    split = filter.consumeSplit("\x1b[31mred\xe4\xb8");
    try std.testing.expectEqual(@as(usize, 8), split.complete);
    try std.testing.expect(split.allowed);
    filter = .{};
    split = filter.consumeSplit("\xe4\xb8\xadok\x1b]0;tit");
    try std.testing.expectEqual(@as(usize, 5), split.complete);
    try std.testing.expect(split.allowed);
    // 前缀里有查询：前缀不可镜像，但切点仍然给出，尾巴照样可留。
    filter = .{};
    split = filter.consumeSplit("\x1b[6nabc\x1b[");
    try std.testing.expectEqual(@as(usize, 7), split.complete);
    try std.testing.expect(!split.allowed);
    // 全是尾巴：什么都不交付。
    filter = .{};
    split = filter.consumeSplit("\x1b]52;c;c2Vj");
    try std.testing.expectEqual(@as(usize, 0), split.complete);
    try std.testing.expect(!split.allowed);
    // 非法 UTF-8 不切，走原来的整块快照路径。
    filter = .{};
    split = filter.consumeSplit("ab\xff\x1b[");
    try std.testing.expectEqual(@as(usize, 0), split.complete);
    try std.testing.expect(!split.allowed);
    try std.testing.expect(!filter.consume("next"));
    try std.testing.expect(filter.consume("clean"));
    // 上一块在 CSI 中间结束且未被切走（回退模式）：本块从非 ground 开始，整段不可镜像。
    filter = .{};
    try std.testing.expect(!filter.consume("\x1b[3"));
    split = filter.consumeSplit("1mred");
    try std.testing.expectEqual(@as(usize, 5), split.complete);
    try std.testing.expect(!split.allowed);
}
