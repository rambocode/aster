const std = @import("std");
const pty = @import("pty.zig");
const scope = @import("process_scope.zig");
const vt = @import("vt.zig");
const history = @import("history_budget.zig");
const Geometry = @import("geometry.zig").Geometry;
const c = @cImport({
    @cInclude("sys/wait.h");
    @cInclude("sys/ioctl.h");
});

/// One owned process/VT pair, independent of client connection lifetimes.
/// Allocate at a stable address: Ghostty's response callback borrows responses.
pub const Session = struct {
    allocator: std.mem.Allocator,
    process: pty.Process,
    terminal: vt.Terminal,
    responses: vt.ResponseSink = .{},
    pending_input: std.ArrayList(u8) = .empty,
    input_offset: usize = 0,
    output_sequence: u64 = 0,
    delta_base: u64 = 0,
    delta_safe: bool = false,
    /// Scroll requires a viewport-aware surface snapshot. Current ANSI snapshots
    /// cannot clear this flag because they do not restore the viewport offset.
    viewport_snapshot_required: bool = false,
    delta_bytes: std.ArrayList(u8) = .empty,
    delta_filter: @import("delta_filter.zig").Filter = .{},
    eof: bool = false,
    exit_status: ?u32 = null,
    termination_timer: ?std.time.Timer = null,
    termination_grace_ns: u64 = 0,
    force_sent: bool = false,
    started: bool = false,
    /// P1 pool enables this only after process_scope.initialize succeeds.
    scope_cleanup: bool = false,
    cleanup_complete: bool = false,
    /// Last cleanup failure is retained for owner diagnostics and retry policy.
    cleanup_error: ?anyerror = null,
    cleanup_context: ?scope.Context = null,
    history_limit: usize = history.terminal_limit,
    history_usage: history.Usage = .{},
    /// If true, this terminal is excluded from disk screen history.
    history_excluded: bool = false,
    /// Agent lifecycle hooks (Aster's `aster-agent-hook.sh`) announce state with
    /// a private OSC 6974 written to the terminal. Ghostty's VT drops OSCs it
    /// does not know, and a display bridge replays *screen state*, so the
    /// directive would never reach any client through the surface stream and
    /// a hidden pane would never learn about it at all. The server therefore
    /// scans raw PTY output here and hands each payload to the service, which
    /// is the authority for remote agent state (P5.2). Payloads are bounded and
    /// the pending list is small; a flood only drops directives, never output.
    agent_directives: std.ArrayList([]u8) = .empty,
    /// Bytes after an unterminated OSC 6974 prefix carried to the next chunk.
    directive_carry: std.ArrayList(u8) = .empty,
    pub const input_limit = 65536;
    pub const directive_prefix = "\x1b]6974;";
    pub const directive_limit = 256;
    pub const pending_directive_limit = 16;

    pub fn create(allocator: std.mem.Allocator, cwd: [:0]const u8, executable: [:0]const u8, argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, rows: u16, cols: u16) !*Session {
        const self = try prepare(allocator, .{ .rows = rows, .columns = cols });
        errdefer self.destroy();
        var process = try pty.Process.spawn(cwd, executable, argv, env, rows, cols);
        self.adoptProcess(&process);
        return self;
    }

    /// Prepare the stable VT and response callback before creating a child.
    /// All fallible initial VT/graphics/geometry work occurs at this boundary.
    pub fn prepare(allocator: std.mem.Allocator, geometry: Geometry) !*Session {
        try geometry.validate();
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        var terminal = try vt.Terminal.init(geometry.columns, geometry.rows, history.terminal_limit);
        errdefer terminal.deinit();
        try terminal.enableGraphics(16 * 1024 * 1024);
        if (geometry.pixel_width != 0) try terminal.resizeGeometry(geometry);
        self.* = .{ .allocator = allocator, .process = .{ .pid = -1, .master = -1 }, .terminal = terminal };
        try self.terminal.setResponseSink(&self.responses);
        return self;
    }

    /// Transfer an already-started child into this prepared session. This path
    /// cannot allocate or fail after the exec handshake has succeeded.
    pub fn adoptProcess(self: *Session, process: *pty.Process) void {
        std.debug.assert(!self.started and self.process.pid == -1);
        std.debug.assert(process.pid > 0 and process.master >= 0);
        self.process = process.*;
        process.* = .{ .pid = -1, .master = -1 };
        self.started = true;
    }

    /// Retire broken I/O without blocking the service on waitpid. Continue
    /// pollReap calls until the owned direct child is reaped.
    pub fn abort(self: *Session) !void {
        if (self.scope_cleanup) {
            defer {
                self.process.closeMaster();
                self.eof = true;
                self.pending_input.clearRetainingCapacity();
                self.input_offset = 0;
            }
            self.force_sent = true;
            if (self.termination_timer == null) self.termination_timer = try std.time.Timer.start();
            return self.pollExit();
        }
        defer {
            self.process.closeMaster();
            self.eof = true;
            self.force_sent = true;
            self.termination_timer = null;
            self.pending_input.clearRetainingCapacity();
            self.input_offset = 0;
        }
        if (self.process.pid > 0) try self.process.requestTermination(true);
    }

    pub fn pollReap(self: *Session) !void {
        try self.pollExit();
    }

    /// Legacy compatibility wrapper. P1 owners should use tryDestroy so failure
    /// can retain the record. A failed fallback deliberately retains ownership.
    pub fn destroy(self: *Session) void {
        self.tryDestroy() catch |err| {
            std.log.err("terminal cleanup incomplete: {s}; ownership retained", .{@errorName(err)});
        };
    }

    /// Final bounded fallback, never viewer detach. Failure leaves this Session
    /// and its unreaped root intact; callers must not discard their owning record.
    pub fn tryDestroy(self: *Session) !void {
        if (self.scope_cleanup and self.started and !self.cleanupComplete()) {
            var deadline = try std.time.Timer.start();
            self.abort() catch |err| {
                self.cleanup_error = err;
                return err;
            };
            while (!self.cleanupComplete() and deadline.read() < 2 * std.time.ns_per_s) {
                try self.pollReap();
                if (!self.cleanupComplete()) std.Thread.sleep(5 * std.time.ns_per_ms);
            }
            if (!self.cleanupComplete()) {
                self.cleanup_error = error.ProcessCleanupTimedOut;
                return error.ProcessCleanupTimedOut;
            }
        } else if (!self.scope_cleanup) self.process.destroy();
        if (self.scope_cleanup) self.process.closeMaster();
        if (self.cleanup_context) |*context| context.deinit();
        self.terminal.deinit();
        self.pending_input.deinit(self.allocator);
        self.delta_bytes.deinit(self.allocator);
        for (self.agent_directives.items) |bytes| self.allocator.free(bytes);
        self.agent_directives.deinit(self.allocator);
        self.directive_carry.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Process cleanup is separate from PTY output EOF. Owners must wait for both
    /// when publishing terminal exit or completing a stop transaction.
    pub fn cleanupComplete(self: *const Session) bool {
        if (!self.started) return true;
        return if (self.scope_cleanup) self.cleanup_complete else self.process.pid <= 0;
    }

    pub fn send(self: *Session, bytes: []const u8) !void {
        if (!self.started) return error.TerminalStarting;
        if (self.eof or self.exit_status != null) return error.TerminalExited;
        if (self.termination_timer != null) return error.TerminalTerminating;
        try self.enqueueInput(bytes);
    }

    fn enqueueInput(self: *Session, bytes: []const u8) !void {
        const remaining = self.pending_input.items.len - self.input_offset;
        if (bytes.len > input_limit - remaining) return error.InputQueueFull;
        if (self.input_offset != 0) {
            std.mem.copyForwards(u8, self.pending_input.items[0..remaining], self.pending_input.items[self.input_offset..]);
            self.pending_input.shrinkRetainingCapacity(remaining);
            self.input_offset = 0;
        }
        try self.pending_input.appendSlice(self.allocator, bytes);
    }

    /// Nonblocking, idempotent termination. Repeating this request never extends
    /// the original grace period. The owner continues ticking to drain/reap.
    pub fn requestTermination(self: *Session, grace_ms: u32) !void {
        if (grace_ms > 60_000) return error.InvalidTerminationGrace;
        if (self.process.pid <= 0 or self.termination_timer != null or (!self.scope_cleanup and self.exit_status != null)) return;
        if (self.scope_cleanup) {
            self.termination_timer = try std.time.Timer.start();
            self.termination_grace_ns = @as(u64, grace_ms) * std.time.ns_per_ms;
            self.pending_input.clearRetainingCapacity();
            self.input_offset = 0;
            return self.pollExit();
        }
        const timer = try std.time.Timer.start();
        try self.process.requestTermination(false);
        self.pending_input.clearRetainingCapacity();
        self.input_offset = 0;
        self.termination_timer = timer;
        self.termination_grace_ns = @as(u64, grace_ms) * std.time.ns_per_ms;
    }

    /// The enclosing service poll must not sleep beyond termination deadlines.
    /// An unreaped child with a closed master still needs bounded reap checks.
    pub fn maximumWaitMilliseconds(self: *Session, requested: i32) i32 {
        var limit = requested;
        if ((self.eof or (self.scope_cleanup and self.termination_timer != null)) and self.process.pid > 0) limit = if (limit < 0) 10 else @min(limit, 10);
        if (!self.force_sent) if (self.termination_timer) |*timer| {
            const elapsed = timer.read();
            const left = if (elapsed >= self.termination_grace_ns) 0 else self.termination_grace_ns - elapsed;
            const milliseconds: i32 = @intCast((left + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
            limit = if (limit < 0) milliseconds else @min(limit, milliseconds);
        };
        return limit;
    }

    fn pollExit(self: *Session) !void {
        if (self.process.pid <= 0) return;
        if (self.scope_cleanup) {
            self.pollScope() catch |err| {
                self.cleanup_error = err;
                return err;
            };
            return;
        }
        var status: c_int = 0;
        const result = c.waitpid(self.process.pid, &status, c.WNOHANG);
        if (result == self.process.pid) {
            self.exit_status = @bitCast(status);
            self.process.pid = -1;
            self.termination_timer = null;
            self.pending_input.clearRetainingCapacity();
            self.input_offset = 0;
        } else if (result < 0 and std.posix.errno(result) != .INTR) return error.ChildWaitFailed;
    }

    fn pollScope(self: *Session) !void {
        if (try scope.observe(self.process.pid)) |status| {
            self.exit_status = status;
            self.pending_input.clearRetainingCapacity();
            self.input_offset = 0;
            // Natural root exit still owns its original SID descendants.
            if (self.termination_timer == null) {
                self.termination_timer = try std.time.Timer.start();
                self.termination_grace_ns = std.time.ns_per_s;
            }
        }
        if (self.termination_timer) |*timer| {
            const force = self.force_sent or timer.read() >= self.termination_grace_ns;
            if (self.cleanup_context == null) self.cleanup_context = try scope.Context.init();
            const result = try self.cleanup_context.?.step(self.process.pid, force);
            self.force_sent = force;
            if (result.complete) {
                self.exit_status = result.status.?;
                self.process.pid = -1;
                self.cleanup_complete = true;
                self.termination_timer = null;
            } else if (force) {
                // Break writers waiting for slave output, but keep the root and
                // cleanup deadline until every owned SID member is handled.
                self.process.closeMaster();
                self.eof = true;
            }
        }
    }

    /// One bounded event-loop tick. Always drains PTY output even without viewers.
    /// Returns whether visible terminal state changed. Call regularly until EOF.
    pub fn tick(self: *Session, timeout_ms: i32) !bool {
        if (!self.started) return error.TerminalStarting;
        try self.pollExit();
        if (!self.scope_cleanup) if (self.termination_timer) |*timer| {
            if (!self.force_sent and timer.read() >= self.termination_grace_ns) {
                try self.process.requestTermination(true);
                self.force_sent = true;
                self.process.closeMaster();
                self.eof = true;
                self.pending_input.clearRetainingCapacity();
                self.input_offset = 0;
            }
        };
        self.delta_base = self.output_sequence;
        self.delta_safe = false;
        self.delta_bytes.clearRetainingCapacity();
        var changed = false;
        if (!self.eof) {
            var descriptors = [_]std.posix.pollfd{.{
                .fd = self.process.master,
                .events = std.posix.POLL.IN | (if (self.pending_input.items.len > self.input_offset) @as(i16, std.posix.POLL.OUT) else @as(i16, 0)),
                .revents = 0,
            }};
            _ = try std.posix.poll(&descriptors, self.maximumWaitMilliseconds(timeout_ms));
            if (descriptors[0].revents & std.posix.POLL.OUT != 0) {
                const n = std.posix.write(self.process.master, self.pending_input.items[self.input_offset..]) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                self.input_offset += n;
                if (self.input_offset == self.pending_input.items.len) {
                    self.pending_input.clearRetainingCapacity();
                    self.input_offset = 0;
                }
            }
            if (descriptors[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                // Limit work per tick so a high-output terminal cannot starve peers.
                var budget: usize = 65536;
                while (budget > 0) {
                    var buffer: [8192]u8 = undefined;
                    const n = std.posix.read(self.process.master, buffer[0..@min(buffer.len, budget)]) catch |err| switch (err) {
                        error.WouldBlock => break,
                        error.InputOutput => 0, // Linux PTY reports EIO after slave closes.
                        else => return err,
                    };
                    if (n == 0) {
                        self.eof = true;
                        break;
                    }
                    try self.delta_bytes.appendSlice(self.allocator, buffer[0..n]);
                    try self.scanAgentDirectives(buffer[0..n]);
                    self.terminal.write(buffer[0..n]);
                    try self.enforceHistoryLimit();
                    const response = try self.responses.bytes();
                    if (response.len != 0) {
                        // Replies needed by an exit trap remain allowed during
                        // grace, but never enqueue data for an already dead child.
                        if (self.exit_status == null) try self.enqueueInput(response);
                        self.responses.used = 0;
                    }
                    self.output_sequence +%= 1;
                    changed = true;
                    budget -= n;
                }
            }
        }
        try self.pollExit();
        if (self.delta_bytes.items.len != 0) self.delta_safe = self.delta_filter.consume(self.delta_bytes.items) and !self.viewport_snapshot_required;
        return changed;
    }

    /// Extracts complete `ESC ] 6974 ; payload (BEL | ESC \\)` sequences from one
    /// output chunk. A prefix split across chunks is carried over (bounded by
    /// `directive_limit`); anything longer is discarded as not-a-directive.
    fn scanAgentDirectives(self: *Session, chunk: []const u8) !void {
        var owned: ?[]u8 = null;
        defer if (owned) |bytes| self.allocator.free(bytes);
        const data = if (self.directive_carry.items.len == 0) chunk else blk: {
            const joined = try self.allocator.alloc(u8, self.directive_carry.items.len + chunk.len);
            @memcpy(joined[0..self.directive_carry.items.len], self.directive_carry.items);
            @memcpy(joined[self.directive_carry.items.len..], chunk);
            self.directive_carry.clearRetainingCapacity();
            owned = joined;
            break :blk joined;
        };
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, data, cursor, directive_prefix)) |start| {
            const payload_start = start + directive_prefix.len;
            var end: usize = payload_start;
            var terminator_len: usize = 0;
            var abandoned = false;
            while (end < data.len) : (end += 1) {
                const byte = data[end];
                if (byte == 0x07) {
                    terminator_len = 1;
                    break;
                }
                if (byte == 0x1b) {
                    if (end + 1 < data.len and data[end + 1] == '\\') {
                        terminator_len = 2;
                        break;
                    }
                    // A lone ESC at the very end may be half of ST: carry it.
                    if (end + 1 == data.len) break;
                    abandoned = true;
                    break;
                }
                // Any other control byte, or an over-long payload, means this was
                // not a directive; resume scanning right here so a real directive
                // that follows is not swallowed together with the garbage.
                if (byte < 0x20 or byte == 0x7f or end - payload_start >= directive_limit) {
                    abandoned = true;
                    break;
                }
            }
            if (abandoned) {
                cursor = end;
                continue;
            }
            if (terminator_len == 0) {
                // Ran out of data without a terminator: carry the bounded tail.
                try self.directive_carry.appendSlice(self.allocator, data[start..]);
                return;
            }
            const payload = data[payload_start..end];
            if (payload.len != 0 and self.agent_directives.items.len < pending_directive_limit) {
                try self.agent_directives.append(self.allocator, try self.allocator.dupe(u8, payload));
            }
            cursor = end + terminator_len;
        }
    }

    /// Hands one pending hook directive payload to the service; caller frees it.
    pub fn takeAgentDirective(self: *Session) ?[]u8 {
        if (self.agent_directives.items.len == 0) return null;
        return self.agent_directives.orderedRemove(0);
    }

    /// Returns null only while graphics are waiting for client pixel geometry.
    /// No source process is restarted and no image cache is dropped in this state.
    pub fn snapshotForClient(self: *Session, maximum: usize) !?[]u8 {
        const has_images = try self.terminal.imageCount(.primary) != 0 or try self.terminal.imageCount(.alternate) != 0;
        if (has_images) {
            const pixels = try self.terminal.pixelSize();
            if (pixels.width == 0 or pixels.height == 0) return null;
            return try @import("terminal_snapshot.zig").capture(self.allocator, &self.terminal, maximum);
        }
        return try @import("display_snapshot.zig").capture(self.allocator, &self.terminal, maximum);
    }

    /// Change server-side history position without sending bytes to the PTY.
    /// Caller must validate the writer lease before entering this method.
    pub fn scroll(self: *Session, rows: i32) !void {
        if (!self.started) return error.TerminalStarting;
        if (self.eof or self.exit_status != null) return error.TerminalExited;
        if (self.termination_timer != null) return error.TerminalTerminating;
        if (try self.terminal.scrollViewport(rows)) {
            self.delta_base = self.output_sequence;
            self.output_sequence +%= 1;
            self.delta_safe = false;
            self.delta_bytes.clearRetainingCapacity();
            self.viewport_snapshot_required = true;
        }
    }

    pub fn resize(self: *Session, rows: u16, cols: u16) !void {
        try self.resizeGeometry(.{ .rows = rows, .columns = cols });
    }

    pub fn resizeGeometry(self: *Session, geometry: Geometry) !void {
        try geometry.validate();
        if (!self.started) return error.TerminalStarting;
        if (self.eof or self.exit_status != null) return error.TerminalExited;
        if (self.termination_timer != null) return error.TerminalTerminating;
        var dimensions = c.winsize{ .ws_row = geometry.rows, .ws_col = geometry.columns, .ws_xpixel = geometry.pixel_width, .ws_ypixel = geometry.pixel_height };
        if (c.ioctl(self.process.master, c.TIOCSWINSZ, &dimensions) != 0) return error.PtyResizeFailed;
        try self.terminal.resizeGeometry(geometry);
        try self.enforceHistoryLimit();
    }

    /// Prune only retained history allocations. Active rows, PTY and graphics
    /// remain intact; consumers must resnapshot when old rows were removed.
    pub fn enforceHistoryLimit(self: *Session) !void {
        const result = try history.trim(&self.terminal, self.history_limit);
        self.history_usage = result.remaining;
        if (result.removed_rows != 0) try self.markHistoryTrimmed();
    }

    /// Shared-budget eviction already changed the VT; invalidate old projections
    /// before refreshing accounting so failures cannot expose a stale delta.
    pub fn markHistoryTrimmed(self: *Session) !void {
        self.output_sequence +%= 1;
        self.delta_safe = false;
        self.delta_bytes.clearRetainingCapacity();
        self.viewport_snapshot_required = true;
        self.history_usage = try history.usage(&self.terminal);
    }
};

test "real PTY output reaches VT and continues without any viewer" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf 'old\\r\\033[2K中A'; sleep 0.1; printf 'DONE'" };
    const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const session = try Session.create(std.testing.allocator, "/", "/bin/sh", &argv, &env, 24, 80);
    defer session.destroy();
    var timer = try std.time.Timer.start();
    while (!(session.eof and session.exit_status != null) and timer.read() < 3 * std.time.ns_per_s) _ = try session.tick(50);
    try std.testing.expect(session.eof and session.exit_status != null);
    try std.testing.expectEqual(@as(u32, 0), session.exit_status.?);
    const screen = try session.terminal.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "中ADONE") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "old") == null);
    try std.testing.expectError(error.TerminalExited, session.send("must not execute"));
}

test "real child receives queued input and reports terminal resize" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "read answer; printf 'RECEIVED:%s:' \"$answer\"; stty size" };
    const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const session = try Session.create(std.testing.allocator, "/", "/bin/sh", &argv, &env, 24, 80);
    defer session.destroy();
    try session.resize(32, 100);
    try session.send("hello\n");
    var timer = try std.time.Timer.start();
    while (!(session.eof and session.exit_status != null) and timer.read() < 3 * std.time.ns_per_s) _ = try session.tick(50);
    const screen = try session.terminal.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "RECEIVED:hello:32 100") != null);
}

test {
    _ = @import("display_snapshot.zig");
}

test {
    _ = @import("graphics_tests.zig");
}

test "measured pixel geometry reaches both PTY and VT without guessed defaults" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "read line" };
    const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const session = try Session.create(std.testing.allocator, "/", "/bin/sh", &argv, &env, 24, 80);
    defer session.destroy();
    try session.resizeGeometry(.{ .rows = 30, .columns = 100, .pixel_width = 1000, .pixel_height = 600 });
    var size: c.winsize = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(session.process.master, c.TIOCGWINSZ, &size));
    try std.testing.expectEqual(@as(u16, 1000), size.ws_xpixel);
    try std.testing.expectEqual(@as(u16, 600), size.ws_ypixel);
    const pixels = try session.terminal.pixelSize();
    try std.testing.expectEqual(@as(u32, 1000), pixels.width);
    try std.testing.expectEqual(@as(u32, 600), pixels.height);
    try std.testing.expectError(error.InvalidPixelDimensions, session.resizeGeometry(.{ .rows = 30, .columns = 100, .pixel_width = 50, .pixel_height = 600 }));
    try std.testing.expectEqual(@as(u32, 1000), (try session.terminal.pixelSize()).width);
    try session.resize(24, 80);
    try std.testing.expectEqual(@as(u32, 0), (try session.terminal.pixelSize()).width);
}

test {
    _ = @import("graphics_snapshot.zig");
}

test {
    _ = @import("history_snapshot.zig");
}

test {
    _ = @import("terminal_snapshot.zig");
}

test {
    _ = @import("delta_tests.zig");
}

test "scroll session fences lifecycle and marks viewport snapshot without PTY input" {
    const session = try Session.prepare(std.testing.allocator, .{ .rows = 3, .columns = 20 });
    defer session.destroy();
    try std.testing.expectError(error.TerminalStarting, session.scroll(-1));
    // This state-only test owns no child. A started session permits viewport control.
    session.started = true;
    session.terminal.write("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    try session.scroll(-1);
    try std.testing.expectEqual(@as(u64, 1), session.output_sequence);
    try std.testing.expect(session.viewport_snapshot_required and !session.delta_safe);
    try std.testing.expectEqual(@as(usize, 0), session.pending_input.items.len);
    try session.scroll(0);
    try std.testing.expectEqual(@as(u64, 1), session.output_sequence);
    session.termination_timer = try std.time.Timer.start();
    try std.testing.expectError(error.TerminalTerminating, session.scroll(-1));
    session.termination_timer = null;
    session.exit_status = 0;
    try std.testing.expectError(error.TerminalExited, session.scroll(-1));
}

test "scroll viewport is not restored by current display snapshot" {
    const session = try Session.prepare(std.testing.allocator, .{ .rows = 3, .columns = 20 });
    defer session.destroy();
    session.started = true;
    session.terminal.write("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    try session.scroll(-1);
    const source = try session.terminal.viewport();
    const bytes = (try session.snapshotForClient(65536)).?;
    defer std.testing.allocator.free(bytes);
    var receiver = try vt.Terminal.init(20, 3, 1000);
    defer receiver.deinit();
    receiver.write(bytes);
    try std.testing.expect(!std.meta.eql(source, try receiver.viewport()));
    try std.testing.expect(session.viewport_snapshot_required);
}

test "session history quota removes old rows without changing live cells or graphics" {
    const session = try Session.prepare(std.testing.allocator, .{ .rows = 3, .columns = 20 });
    defer session.destroy();
    session.history_limit = 0;
    session.terminal.write("OLD\r\nLIVE1\r\nLIVE2\r\nLIVE3\x1b_Ga=t,f=32,s=1,v=1,i=31,q=2;/wAA/w==\x1b\\");
    try session.enforceHistoryLimit();
    try std.testing.expectEqual(@as(usize, 0), session.history_usage.charged_bytes);
    try std.testing.expect(session.viewport_snapshot_required);
    try std.testing.expectEqual(@as(usize, 1), try session.terminal.imageCount(.primary));
    const row = try session.terminal.formatRow(std.testing.allocator, .primary, 0, 4096);
    defer std.testing.allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "LIVE1") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "OLD") == null);
}

test "session default history quota stays within sixteen MiB under sustained output" {
    const session = try Session.prepare(std.testing.allocator, .{ .rows = 24, .columns = 80 });
    defer session.destroy();
    session.terminal.write("OLDEST\r\n");
    const row = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789\r\n";
    for (0..300) |_| {
        for (0..256) |_| session.terminal.write(row);
        try session.enforceHistoryLimit();
        try std.testing.expect(session.history_usage.charged_bytes <= history.terminal_limit);
    }
    try std.testing.expect(session.history_usage.rows > 0);
    try std.testing.expect(session.history_usage.rows < 300 * 256);
    const first = try session.terminal.formatRow(std.testing.allocator, .primary, 0, 4096);
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "OLDEST") == null);
}

test "scope session root exit preserves cleanup until resistant descendants finish" {
    try scope.initialize();
    const a = std.testing.allocator;
    const script = "trap 'printf ROOT_EXIT; exit 7' TERM; (trap '' TERM HUP; printf CHILD_READY; while :; do sleep 1; done) & wait";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script };
    const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const session = try Session.create(a, "/", "/bin/sh", &argv, &env, 24, 80);
    session.scope_cleanup = true;
    defer session.destroy();
    var clock = try std.time.Timer.start();
    var ready = false;
    while (!ready and clock.read() < 3 * std.time.ns_per_s) {
        _ = try session.tick(10);
        const text = try session.terminal.formatActiveScreen(a, false, 65536);
        defer a.free(text);
        ready = std.mem.indexOf(u8, text, "CHILD_READY") != null;
    }
    try std.testing.expect(ready);
    try session.requestTermination(100);
    while ((!session.cleanupComplete() or !session.eof) and clock.read() < 5 * std.time.ns_per_s) _ = try session.tick(10);
    try std.testing.expect(session.cleanupComplete());
    try std.testing.expect(session.eof);
    try std.testing.expectEqual(@as(std.posix.pid_t, -1), session.process.pid);
    try std.testing.expect(session.cleanup_error == null);
    const text = try session.terminal.formatActiveScreen(a, false, 65536);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "ROOT_EXIT") != null);
}

test "scope session natural root exit drives cleanup without terminate request" {
    try scope.initialize();
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf NATURAL_EXIT; exit 9" };
    const env = [_:null]?[*:0]const u8{};
    const session = try Session.create(std.testing.allocator, "/", "/bin/sh", &argv, &env, 24, 80);
    session.scope_cleanup = true;
    defer session.destroy();
    var clock = try std.time.Timer.start();
    while ((!session.cleanupComplete() or !session.eof) and clock.read() < 3 * std.time.ns_per_s) _ = try session.tick(10);
    try std.testing.expect(session.cleanupComplete() and session.eof);
    try std.testing.expectEqual(@as(u8, 9), std.posix.W.EXITSTATUS(session.exit_status.?));
    const text = try session.terminal.formatActiveScreen(std.testing.allocator, false, 65536);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "NATURAL_EXIT") != null);
}

test "scope session handles foreground and background job control groups" {
    try scope.initialize();
    const scripts = [_][:0]const u8{
        "set -m; (trap '' TERM HUP; printf JOB_READY; while :; do sleep 1; done); printf FG_DONE",
        "set -m; (trap '' TERM HUP; printf JOB_READY; while :; do sleep 1; done) & wait",
    };
    for (scripts) |script| {
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script };
        const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
        const session = try Session.create(std.testing.allocator, "/", "/bin/sh", &argv, &env, 24, 80);
        session.scope_cleanup = true;
        defer session.destroy();
        var clock = try std.time.Timer.start();
        var ready = false;
        while (!ready and clock.read() < 3 * std.time.ns_per_s) {
            _ = try session.tick(10);
            const bytes = try session.terminal.formatActiveScreen(std.testing.allocator, false, 65536);
            defer std.testing.allocator.free(bytes);
            ready = std.mem.indexOf(u8, bytes, "JOB_READY") != null;
        }
        try std.testing.expect(ready);
        try session.requestTermination(100);
        while ((!session.cleanupComplete() or !session.eof) and clock.read() < 5 * std.time.ns_per_s) _ = try session.tick(10);
        try std.testing.expect(session.cleanupComplete() and session.eof);
        try std.testing.expect(session.cleanup_error == null);
    }
}

test "scope session delayed TERM handler runs once across cleanup polling" {
    try scope.initialize();
    const code =
        "import signal,time,sys\n" ++
        "count=0\n" ++
        "def terminate(signum,frame):\n" ++
        " global count\n" ++
        " count+=1\n" ++
        " time.sleep(0.2)\n" ++
        " print('TERM_COUNT='+str(count),flush=True)\n" ++
        " sys.exit(0)\n" ++
        "signal.signal(signal.SIGTERM,terminate)\n" ++
        "print('HANDLER_READY',flush=True)\n" ++
        "while True: signal.pause()\n";
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/python3", "-c", code };
    const env = [_:null]?[*:0]const u8{};
    const session = try Session.create(std.testing.allocator, "/", "/usr/bin/python3", &argv, &env, 24, 80);
    session.scope_cleanup = true;
    defer session.destroy();
    var clock = try std.time.Timer.start();
    var ready = false;
    while (!ready and clock.read() < 3 * std.time.ns_per_s) {
        _ = try session.tick(10);
        const bytes = try session.terminal.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(bytes);
        ready = std.mem.indexOf(u8, bytes, "HANDLER_READY") != null;
    }
    try std.testing.expect(ready);
    clock.reset();
    try session.requestTermination(1000);
    while ((!session.cleanupComplete() or !session.eof) and clock.read() < 3 * std.time.ns_per_s) {
        try session.requestTermination(1000);
        _ = try session.tick(10);
    }
    try std.testing.expect(session.cleanupComplete() and session.eof);
    try std.testing.expect(clock.read() >= 150 * std.time.ns_per_ms);
    const bytes = try session.terminal.formatActiveScreen(std.testing.allocator, false, 65536);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "TERM_COUNT=1") != null);
    try std.testing.expect(std.posix.W.IFEXITED(session.exit_status.?));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(session.exit_status.?));
}
