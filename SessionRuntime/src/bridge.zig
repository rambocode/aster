const std = @import("std");
const protocol = @import("protocol.zig");
const Hello = @import("handshake.zig").Hello;
const Assembler = @import("snapshot.zig").Assembler;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
    @cInclude("bridge_signals.h");
});

/// P0 terminal-side bridge. Owns only a socket and the host terminal's raw mode;
/// socket EOF, prefix detach or process exit never terminate the remote child.
pub fn run(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const stream = try std.net.connectUnixSocket(socket_path);
    defer stream.close();
    const signal_fd = c.session_bridge_signals_start();
    if (signal_fd < 0) return error.SignalSetupFailed;
    defer c.session_bridge_signals_stop();
    var original: c.termios = undefined;
    const has_tty = c.isatty(0) == 1;
    var raw_installed = false;
    defer if (raw_installed) {
        _ = c.tcsetattr(0, c.TCSANOW, &original);
    };
    var handshake_complete = false;
    var handshake_timer = try std.time.Timer.start();
    var decoder = protocol.Decoder.init(allocator);
    defer decoder.deinit();
    var snapshot: ?Assembler = null;
    defer if (snapshot) |*value| value.deinit();
    var screen_ready = false;
    var last_sequence: ?u64 = null;
    var pending_sequence: u64 = 0;
    var pending_delta = false;
    var discard_transaction = false;
    var resync_requested = false;
    var snapshot_timer = try std.time.Timer.start();
    var prefix_pending = false;
    while (true) {
        if (!handshake_complete and handshake_timer.read() >= 5 * std.time.ns_per_s) return error.HandshakeTimeout;
        if (handshake_complete and (!screen_ready or snapshot != null) and snapshot_timer.read() >= 5 * std.time.ns_per_s) return error.SnapshotTimeout;
        const input_was_ready = screen_ready;
        var descriptors = [_]std.posix.pollfd{
            .{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (handshake_complete and (screen_ready or last_sequence != null)) 0 else -1, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = try std.posix.poll(&descriptors, if (handshake_complete and screen_ready and snapshot == null) -1 else 100);
        if (descriptors[2].revents & std.posix.POLL.IN != 0) {
            const event = c.session_bridge_signals_take();
            if (event < 0) return error.SignalReadFailed;
            if (event != 0 and event != c.SIGWINCH) return error.BridgeInterrupted;
            if (event == c.SIGWINCH and handshake_complete) try sendSize(allocator, stream);
        }
        if (descriptors[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            var input: [8192]u8 = undefined;
            const count = try stream.read(&input);
            if (count == 0) {
                try decoder.finish();
                if (!handshake_complete) return error.HandshakeClosed;
                if (snapshot != null) return error.IncompleteSnapshot;
                return;
            }
            var offset: usize = 0;
            while (offset < count) {
                var consumed: usize = 0;
                const frame = try decoder.feed(input[offset..count], &consumed);
                offset += consumed;
                if (frame) |message| {
                    if (!handshake_complete) {
                        if (message.kind != .control) return error.HandshakeRequired;
                        const parsed = try std.json.parseFromSlice(Hello, allocator, message.payload, .{ .ignore_unknown_fields = true });
                        defer parsed.deinit();
                        try parsed.value.negotiateRequired(&.{ "p0_active_screen", "snapshot_transaction_v1", "terminal_delta_v1" });
                        if (has_tty) {
                            if (c.tcgetattr(0, &original) != 0) return error.TerminalModeUnavailable;
                            var raw = original;
                            c.cfmakeraw(&raw);
                            if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return error.TerminalModeUnavailable;
                            raw_installed = true;
                        }
                        try sendSize(allocator, stream);
                        handshake_complete = true;
                        snapshot_timer.reset();
                        continue;
                    }
                    if (message.kind == .control) {
                        const Event = struct {
                            type: enum { snapshot_begin, snapshot_end, delta_begin, delta_end },
                            length: ?usize = null,
                            sha256: ?[]const u8 = null,
                            sequence: ?u64 = null,
                            baseSequence: ?u64 = null,
                        };
                        const parsed = try std.json.parseFromSlice(Event, allocator, message.payload, .{});
                        defer parsed.deinit();
                        switch (parsed.value.type) {
                            .snapshot_begin, .delta_begin => {
                                if (snapshot != null) return error.OverlappingSnapshot;
                                pending_sequence = parsed.value.sequence orelse return error.MissingSequence;
                                pending_delta = parsed.value.type == .delta_begin;
                                discard_transaction = false;
                                if (pending_delta) {
                                    const applied = last_sequence orelse return error.DeltaBeforeSnapshot;
                                    const base = parsed.value.baseSequence orelse return error.MissingBaseSequence;
                                    if (pending_sequence <= base) return error.InvalidSequence;
                                    if (base != applied or !screen_ready) {
                                        discard_transaction = true;
                                        screen_ready = false;
                                        prefix_pending = false;
                                        if (!resync_requested) {
                                            try send(allocator, stream, .{ .op = "snapshot" });
                                            resync_requested = true;
                                        }
                                    }
                                } else {
                                    if (parsed.value.baseSequence != null) return error.InvalidBaseSequence;
                                    if (last_sequence) |applied| {
                                        if (pending_sequence < applied) return error.StaleSnapshot;
                                    }
                                }
                                var digest: [32]u8 = undefined;
                                const hex = parsed.value.sha256 orelse return error.MissingDigest;
                                if (hex.len != 64) return error.InvalidDigest;
                                _ = try std.fmt.hexToBytes(&digest, hex);
                                snapshot_timer.reset();
                                const length = parsed.value.length orelse return error.MissingLength;
                                if (pending_delta and length > 65536) return error.DeltaTooLarge;
                                snapshot = try Assembler.init(allocator, length, digest);
                            },
                            .snapshot_end, .delta_end => {
                                const current = if (snapshot) |*value| value else return error.UnexpectedSnapshotEnd;
                                if ((parsed.value.type == .delta_end) != pending_delta) return error.UnexpectedTransactionEnd;
                                const complete = try current.finish();
                                // Only integrity-checked transactions reach the host VT.
                                if (!discard_transaction) {
                                    if (pending_delta) {
                                        var safety: @import("delta_filter.zig").Filter = .{};
                                        if (!safety.consume(complete)) return error.UnsafeDelta;
                                    }
                                    try std.fs.File.stdout().writeAll(complete);
                                    last_sequence = pending_sequence;
                                    screen_ready = true;
                                    if (!pending_delta) resync_requested = false;
                                }
                                current.deinit();
                                snapshot = null;
                            },
                        }
                    } else {
                        const current = if (snapshot) |*value| value else return error.SnapshotRequired;
                        if (message.payload.len < 5) return error.InvalidChunkLength;
                        const index = std.mem.readInt(u32, message.payload[0..4], .big);
                        try current.append(index, message.payload[4..]);
                    }
                }
            }
        }
        if (descriptors[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            var input: [4096]u8 = undefined;
            const count = try std.posix.read(0, &input);
            if (count == 0) {
                try send(allocator, stream, .{ .op = "release" });
                return;
            }
            if (!input_was_ready or !screen_ready) {
                prefix_pending = false;
                continue;
            }
            var forwarded: std.ArrayList(u8) = .empty;
            defer forwarded.deinit(allocator);
            for (input[0..count]) |byte| {
                if (prefix_pending) {
                    prefix_pending = false;
                    if (byte == 'q') {
                        if (forwarded.items.len != 0) try sendInput(allocator, stream, forwarded.items);
                        try send(allocator, stream, .{ .op = "release" });
                        return;
                    }
                    try forwarded.append(allocator, 2);
                    if (byte == 2) continue;
                } else if (byte == 2) {
                    prefix_pending = true;
                    continue;
                }
                try forwarded.append(allocator, byte);
            }
            if (forwarded.items.len != 0) try sendInput(allocator, stream, forwarded.items);
        }
    }
}

fn sendInput(allocator: std.mem.Allocator, stream: std.net.Stream, bytes: []const u8) !void {
    // PTY input is arbitrary bytes, including a UTF-8 code point split by read.
    // Encode base64 instead of pretending every OS read is a UTF-8 string.
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, bytes);
    try send(allocator, stream, .{ .op = "input", .data = encoded });
}
fn send(allocator: std.mem.Allocator, stream: std.net.Stream, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    var header: [5]u8 = undefined;
    header[0] = 1;
    std.mem.writeInt(u32, header[1..5], @intCast(json.len), .big);
    try stream.writeAll(&header);
    try stream.writeAll(json);
}

fn sendSize(allocator: std.mem.Allocator, stream: std.net.Stream) !void {
    if (c.isatty(0) != 1) return;
    var size: c.winsize = std.mem.zeroes(c.winsize);
    if (c.ioctl(0, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeUnavailable;
    if (size.ws_row == 0 or size.ws_col == 0) return;
    try send(allocator, stream, .{ .op = "resize", .rows = size.ws_row, .cols = size.ws_col, .pixelWidth = size.ws_xpixel, .pixelHeight = size.ws_ypixel });
}
