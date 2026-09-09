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
        for (bytes) |byte| {
            if (byte == 0x18 or byte == 0x1a) {
                self.state = .ground;
                allowed = false;
                continue;
            }
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
                            self.osc_allowed = self.osc_code == 0 or self.osc_code == 1 or self.osc_code == 2 or self.osc_code == 8;
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
        }
        return allowed and self.state == .ground;
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
    for ([_][]const u8{ "hello中\r\n", "\x1b[2;3H\x1b[31mred\x1b[0m", "\x1b[?2004h", "\x1b[>1u", "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\" }) |value| {
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
