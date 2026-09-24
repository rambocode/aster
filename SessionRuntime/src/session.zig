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
    /// 只在视口离开底部期间保持：回到底部后普通快照与增量就能表达画面（见 `refreshViewportPin`）。
    viewport_snapshot_required: bool = false,
    delta_bytes: std.ArrayList(u8) = .empty,
    /// 上一轮读到、但止于未完成序列/半个 UTF-8 字符的尾巴；下一轮放回 `delta_bytes` 开头再判。
    delta_carry: std.ArrayList(u8) = .empty,
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
    /// True for terminals adopted from another service via live handoff.
    /// Adopted processes are NOT children of this service, so waitpid/waitid
    /// would return ECHILD. Exit detection uses kill(pid,0) + PTY EOF instead.
    adopted: bool = false,
    /// FD from session_scope_watch_exit for adopted process exit monitoring.
    /// macOS: kqueue with EVFILT_PROC NOTE_EXIT (provides exit status).
    /// Linux: pidfd_open (exit notification only, no status for non-children).
    exit_watch_fd: std.posix.fd_t = -1,
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
        } else if (!self.scope_cleanup) {
            if (self.adopted) {
                // 接管终端非本进程子进程，kill + close master 但跳过 waitpid
                if (self.process.pid > 0) {
                    std.posix.kill(self.process.pid, std.posix.SIG.KILL) catch {};
                    self.process.pid = -1;
                }
                self.process.closeMaster();
                // 关闭退出监听 FD（kqueue/pidfd）
                if (self.exit_watch_fd >= 0) {
                    scope.closeWatch(self.exit_watch_fd);
                    self.exit_watch_fd = -1;
                }
            } else {
                self.process.destroy();
            }
        }
        if (self.scope_cleanup) self.process.closeMaster();
        if (self.cleanup_context) |*context| context.deinit();
        self.terminal.deinit();
        self.pending_input.deinit(self.allocator);
        self.delta_bytes.deinit(self.allocator);
        self.delta_carry.deinit(self.allocator);
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
        // Adopted processes are not children of this service: waitpid/waitid
        // return ECHILD. Detect exit via PTY EOF (slave side closed) combined
        // with kill(pid,0). Zombies stay visible to kill until reaped by
        // init, so EOF on the master is the reliable death signal.
        if (self.adopted) {
            // 接管终端的退出检测：优先使用平台 watcher（macOS kqueue / Linux pidfd），
            // PTY EOF 作为兜底。macOS 可从 kqueue 获取退出码，Linux 无法获取非子进程退出码。
            const watched = scope.pollExit(self.exit_watch_fd);
            if (watched != null or self.eof) {
                // 接管终端退出：平台 watcher 返回 -1 表示退出码不可得（非子进程），
                // 用 null 传递给 terminal.list/terminal.exited，不伪造 0。
                const raw = watched orelse @as(u32, @bitCast(@as(i32, -1)));
                self.exit_status = raw;
                self.process.pid = -1;
                self.termination_timer = null;
                self.pending_input.clearRetainingCapacity();
                self.input_offset = 0;
                if (self.exit_watch_fd >= 0) {
                    scope.closeWatch(self.exit_watch_fd);
                    self.exit_watch_fd = -1;
                }
            }
            return;
        }
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
    /// `read_budget` caps bytes read per tick; the pool scales it so aggregate
    /// VT work stays O(1) regardless of terminal count.
    pub fn tick(self: *Session, timeout_ms: i32, read_budget: usize) !bool {
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
        // 上一轮留下的尾巴排在最前：它对 VT 还没有可见效果，客户端也还没收到。
        if (self.delta_carry.items.len != 0) {
            try self.delta_bytes.appendSlice(self.allocator, self.delta_carry.items);
            self.delta_carry.clearRetainingCapacity();
        }
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
                var budget: usize = read_budget;
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
        if (self.delta_bytes.items.len != 0) try self.finishDelta();
        // 读到的全是未完成尾巴时可见状态没变，不算变化；退出仍须让轮询方看到。
        return changed and (self.delta_bytes.items.len != 0 or self.eof);
    }

    /// 尾巴超过这个长度（例如 kitty 图形传输、超长 OSC）就不再等它完整，退回逐块判定。
    const carry_limit: usize = 65536;

    /// 把本轮字节切成「可交付前缀 + 未完成尾巴」。
    ///
    /// PTY 每次 read 约 1 KiB，TUI 的一帧常被切在转义序列或 UTF-8 中间；以前切开的两半各自
    /// 都过不了检查，一帧就变成两次全量快照（RIS 会清掉客户端回滚历史并跳回底部，用户往上翻
    /// 时画面不停闪）。尾巴对 VT 尚无可见效果，所以留到下一轮和后续字节一起判定是无损的：
    /// 即使中间发了快照，快照里也不含尾巴的效果，下一轮重放尾巴不会重复作用。
    fn finishDelta(self: *Session) !void {
        const split = self.delta_filter.consumeSplit(self.delta_bytes.items);
        const tail = self.delta_bytes.items.len - split.complete;
        if (tail != 0 and tail <= carry_limit) {
            try self.delta_carry.appendSlice(self.allocator, self.delta_bytes.items[split.complete..]);
            self.delta_bytes.shrinkRetainingCapacity(split.complete);
            // 切点是 ground 边界：尾巴下一轮从头解析，过滤器回到初始态。
            self.delta_filter = .{};
        }
        if (self.delta_bytes.items.len == 0) {
            // 全是尾巴：把本轮的序号推进撤回，客户端与服务端仍视为同一状态。
            self.output_sequence = self.delta_base;
            self.delta_safe = false;
            return;
        }
        // 尾巴过长没有切走时块不自洽（止于序列中间），只能走快照；过滤器保留解析状态继续判后续块。
        const self_contained = self.delta_bytes.items.len == split.complete;
        try self.refreshViewportPin();
        self.delta_safe = split.allowed and self_contained and !self.viewport_snapshot_required;
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
            try self.refreshViewportPin();
        }
    }

    /// 视口回到底部时撤销「必须发视口快照」。
    ///
    /// 这个标志以前一经 `scroll` 置位就永不清除：远端查看端往上翻过一次历史，之后该终端的
    /// 每次输出都退回全量快照（以 RIS 开头，清屏并清掉客户端回滚），所有客户端画面持续闪烁。
    /// 视口在底部时，普通快照和增量表达的就是当前画面；回到底部那一刻序号已推进、增量已清空，
    /// 客户端会先取一次快照再接增量，不会漏状态。
    fn refreshViewportPin(self: *Session) !void {
        if (!self.viewport_snapshot_required) return;
        const viewport = try self.terminal.viewport();
        if (viewport.offset + viewport.length >= viewport.total) self.viewport_snapshot_required = false;
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
    /// remain intact, so the delta stream stays valid (see `markHistoryTrimmed`).
    pub fn enforceHistoryLimit(self: *Session) !void {
        const result = try history.trim(&self.terminal, self.history_limit);
        self.history_usage = result.remaining;
        if (result.removed_rows != 0) try self.markHistoryTrimmed();
    }

    /// 共享预算或本终端配额淘汰了最旧的历史页，只刷新记账。
    ///
    /// 淘汰只删历史前缀，活动区、光标、模式都不变：客户端照原样应用同一批增量，得到的
    /// 活动区与服务端一致，客户端自己的回滚历史由它自己的上限管理。以前这里推进序号、
    /// 清空增量并把 `viewport_snapshot_required` 置为 true，而该标志从不清除——Claude Code
    /// 这类带真彩色和超链接的输出攒到几千行历史就触发淘汰，之后每次 PTY 读都退回全量快照
    /// （以 RIS 开头，清屏、清客户端回滚并跳回底部），画面持续闪烁。按锚点取历史的请求
    /// 读的是当前 VT，已淘汰的页本来就解析不到，不需要靠重发快照来失效。
    pub fn markHistoryTrimmed(self: *Session) !void {
        self.history_usage = try history.usage(&self.terminal);
    }
};

test "real PTY output reaches VT and continues without any viewer" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf 'old\\r\\033[2K中A'; sleep 0.1; printf 'DONE'" };
    const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const session = try Session.create(std.testing.allocator, "/", "/bin/sh", &argv, &env, 24, 80);
    defer session.destroy();
    var timer = try std.time.Timer.start();
    while (!(session.eof and session.exit_status != null) and timer.read() < 3 * std.time.ns_per_s) _ = try session.tick(50, 65536);
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
    while (!(session.eof and session.exit_status != null) and timer.read() < 3 * std.time.ns_per_s) _ = try session.tick(50, 65536);
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
    // 只删历史，不让增量流失效（否则之后每次输出都退回全量快照）。
    try std.testing.expect(!session.viewport_snapshot_required);
    try std.testing.expectEqual(@as(u64, 0), session.output_sequence);
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
        _ = try session.tick(10, 65536);
        const text = try session.terminal.formatActiveScreen(a, false, 65536);
        defer a.free(text);
        ready = std.mem.indexOf(u8, text, "CHILD_READY") != null;
    }
    try std.testing.expect(ready);
    try session.requestTermination(100);
    while ((!session.cleanupComplete() or !session.eof) and clock.read() < 5 * std.time.ns_per_s) _ = try session.tick(10, 65536);
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
    while ((!session.cleanupComplete() or !session.eof) and clock.read() < 3 * std.time.ns_per_s) _ = try session.tick(10, 65536);
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
            _ = try session.tick(10, 65536);
            const bytes = try session.terminal.formatActiveScreen(std.testing.allocator, false, 65536);
            defer std.testing.allocator.free(bytes);
            ready = std.mem.indexOf(u8, bytes, "JOB_READY") != null;
        }
        try std.testing.expect(ready);
        try session.requestTermination(100);
        while ((!session.cleanupComplete() or !session.eof) and clock.read() < 5 * std.time.ns_per_s) _ = try session.tick(10, 65536);
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
        _ = try session.tick(10, 65536);
        const bytes = try session.terminal.formatActiveScreen(std.testing.allocator, false, 65536);
        defer std.testing.allocator.free(bytes);
        ready = std.mem.indexOf(u8, bytes, "HANDLER_READY") != null;
    }
    try std.testing.expect(ready);
    clock.reset();
    try session.requestTermination(1000);
    while ((!session.cleanupComplete() or !session.eof) and clock.read() < 3 * std.time.ns_per_s) {
        try session.requestTermination(1000);
        _ = try session.tick(10, 65536);
    }
    try std.testing.expect(session.cleanupComplete() and session.eof);
    try std.testing.expect(clock.read() >= 150 * std.time.ns_per_ms);
    const bytes = try session.terminal.formatActiveScreen(std.testing.allocator, false, 65536);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "TERM_COUNT=1") != null);
    try std.testing.expect(std.posix.W.IFEXITED(session.exit_status.?));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(session.exit_status.?));
}

test "a frame split across reads is delivered as one safe delta instead of two snapshots" {
    // 第一段止于 CSI 中间，第二段补完并继续输出。
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf 'ok\\033[3'; sleep 0.3; printf '1mred\\033[0m'; sleep 0.3" };
    const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const session = try Session.create(std.testing.allocator, "/", "/bin/sh", &argv, &env, 24, 80);
    defer session.destroy();
    var delivered: std.ArrayList(u8) = .empty;
    defer delivered.deinit(std.testing.allocator);
    var unsafe_rounds: usize = 0;
    var sequence_before_tail: ?u64 = null;
    var timer = try std.time.Timer.start();
    while (!(session.eof and session.exit_status != null) and timer.read() < 3 * std.time.ns_per_s) {
        const changed = try session.tick(20, 65536);
        if (session.delta_bytes.items.len != 0) {
            if (session.delta_safe) try delivered.appendSlice(std.testing.allocator, session.delta_bytes.items) else unsafe_rounds += 1;
        }
        if (session.delta_carry.items.len != 0) {
            try std.testing.expectEqualStrings("\x1b[3", session.delta_carry.items);
            // 本轮只有尾巴、没有可交付前缀时序号不推进，客户端不会被要求重同步。
            if (session.delta_bytes.items.len == 0) try std.testing.expectEqual(session.delta_base, session.output_sequence);
            sequence_before_tail = session.output_sequence;
        }
        _ = changed;
    }
    try std.testing.expect(sequence_before_tail != null);
    try std.testing.expectEqual(@as(usize, 0), unsafe_rounds);
    try std.testing.expectEqualStrings("ok\x1b[31mred\x1b[0m", delivered.items);
    try std.testing.expectEqual(@as(usize, 0), session.delta_carry.items.len);
}


test "output past the history quota keeps flowing as safe deltas instead of snapshots" {
    // 配额为 0：每次读都会淘汰全部历史。增量必须一直可用，客户端重放增量后活动区与服务端一致。
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "i=0; while [ $i -lt 40 ]; do printf '\\033[38;2;1;2;3mrow %s\\033[0m\\r\\n' $i; i=$((i+1)); done; sleep 0.2; printf 'next\\r\\nlast'; sleep 0.2" };
    const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
    const session = try Session.create(std.testing.allocator, "/", "/bin/sh", &argv, &env, 5, 40);
    defer session.destroy();
    session.history_limit = 0;
    var receiver = try vt.Terminal.init(40, 5, 1000);
    defer receiver.deinit();
    var unsafe_rounds: usize = 0;
    var safe_rounds: usize = 0;
    var timer = try std.time.Timer.start();
    while (!(session.eof and session.exit_status != null) and timer.read() < 3 * std.time.ns_per_s) {
        const before = session.output_sequence;
        _ = try session.tick(20, 65536);
        if (session.delta_bytes.items.len == 0) continue;
        // 与 surface_service 相同的交付条件：序号连续且块可镜像。
        if (session.delta_safe and session.delta_base == before) {
            receiver.write(session.delta_bytes.items);
            safe_rounds += 1;
        } else unsafe_rounds += 1;
    }
    try std.testing.expect(safe_rounds >= 2);
    try std.testing.expectEqual(@as(usize, 0), unsafe_rounds);
    try std.testing.expectEqual(@as(usize, 0), session.history_usage.rows);
    try std.testing.expect(!session.viewport_snapshot_required);
    // 只比活动区：接收端保留自己的回滚历史，服务端的历史已被淘汰。
    const source_metrics = try session.terminal.screenMetrics();
    const receiver_metrics = try receiver.screenMetrics();
    try std.testing.expect(receiver_metrics.total_rows > source_metrics.total_rows);
    for (0..source_metrics.rows) |index| {
        const expected = try session.terminal.formatRow(std.testing.allocator, .primary, @intCast(source_metrics.total_rows - source_metrics.rows + index), 4096);
        defer std.testing.allocator.free(expected);
        const actual = try receiver.formatRow(std.testing.allocator, .primary, @intCast(receiver_metrics.total_rows - receiver_metrics.rows + index), 4096);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqual(try session.terminal.cursorRow(), try receiver.cursorRow());
    try std.testing.expectEqual(try session.terminal.cursorColumn(), try receiver.cursorColumn());
}

test "scrolling back to the bottom lets output flow as deltas again" {
    const session = try Session.prepare(std.testing.allocator, .{ .rows = 3, .columns = 20 });
    defer session.destroy();
    session.started = true;
    session.terminal.write("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    try session.scroll(-1);
    try std.testing.expect(session.viewport_snapshot_required);
    // 回到底部：这次移动本身仍推进序号，让客户端先取一次快照。
    const before = session.output_sequence;
    try session.scroll(1);
    try std.testing.expectEqual(before +% 1, session.output_sequence);
    try std.testing.expect(!session.delta_safe);
    try std.testing.expect(!session.viewport_snapshot_required);
}
