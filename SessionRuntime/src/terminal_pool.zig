const std = @import("std");
const Session = @import("session.zig").Session;
const Geometry = @import("geometry.zig").Geometry;
const history = @import("session_history.zig");
const history_budget = @import("history_budget.zig");
const Startup = @import("pty_startup.zig").Startup;
const validID = @import("operation_request.zig").validID;

/// Prepared launch values. The RPC adapter resolves executables and merges the
/// execution machine's environment; this boundary never invokes a shell wrapper.
pub const Launch = struct {
    cwd: []const u8,
    argv: []const []const u8,
    environment: []const []const u8 = &.{},
    geometry: Geometry = .{ .rows = 24, .columns = 80 },
};

pub const Limits = struct {
    maximum_terminals: usize = 32,
    maximum_cells: usize = 262144,
    maximum_columns: u16 = 4096,
    maximum_history_bytes: usize = history_budget.session_limit,
    scope_cleanup: bool = false,
};

pub const Entry = struct {
    id: [36]u8,
    cwd: [:0]u8,
    original_pid: std.posix.pid_t,
    session: *Session,
    failure: ?anyerror = null,
    cleanup_failure: ?anyerror = null,
    /// Owner-side latch for "this exit was already published". It lives on the
    /// record instead of on a slot index because slots are reused now: an index
    /// mask would follow the wrong terminal after a record is retired.
    exit_reported: bool = false,
};

/// How many already-reclaimed terminals keep a reportable summary after losing
/// their slot. The bound is deliberately small: a summary must outlive its slot
/// long enough for a client that was mid-request when the terminal exited to
/// still read the real exit code, but a shared workspace runs for weeks, so an
/// unbounded exit journal would be the same leak this record retirement fixes.
/// Eight covers the observable window (one pending create/terminate per client
/// connection plus the queued exit events) without holding VT memory, because a
/// retired record owns nothing except its ID, cwd text and exit status.
pub const recent_exit_capacity: usize = 8;

/// Post-mortem summary of a terminal whose PTY/VT/child were already released.
/// It carries no Session: a retired terminal can never be reported as running.
pub const Retired = struct {
    id: [36]u8,
    cwd: [:0]u8,
    exit_status: ?u32,
    unavailable: bool,
};

pub const CreationFailure = struct {
    reason: anyerror,
    startup: ?@import("pty_startup.zig").Failure = null,
};
pub const Completion = struct {
    id: [36]u8,
    result: union(enum) { created: std.posix.pid_t, failed: CreationFailure, cancelled },
    cleanup_failure: ?anyerror = null,
};
pub const PendingStatus = struct {
    outcome: @import("pty_startup.zig").Outcome,
    cleanup_failure: ?anyerror,
};
const Pending = struct {
    id: [36]u8,
    cwd: [:0]u8,
    session: *Session,
    startup: Startup,
    cleanup_failure: ?anyerror = null,
};

/// Service-owned process/VT records. There is deliberately no client reference
/// count: detaching viewers must not retire a terminal. Session allocations stay
/// at stable addresses even when records move. Serialize mutations on the owner.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    entries: std.ArrayList(Entry) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    completions: std.ArrayList(Completion) = .empty,
    /// Bounded FIFO of summaries for records that gave their slot back.
    retired: std.ArrayList(Retired) = .empty,
    next_entry: usize = 0,
    history_manager: history.Manager,
    history_stats: history.Stats = .{ .charged_bytes = 0, .removed_rows = 0, .removed_pages = 0, .tracked_pages = 0 },
    history_failures: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Pool {
        if (limits.maximum_terminals == 0 or limits.maximum_terminals > 64 or
            limits.maximum_cells == 0 or limits.maximum_columns == 0 or limits.maximum_history_bytes > history_budget.session_limit) return error.InvalidTerminalLimits;
        if (limits.scope_cleanup) try @import("process_scope.zig").initialize();
        var entries: std.ArrayList(Entry) = .empty;
        try entries.ensureTotalCapacity(allocator, limits.maximum_terminals);
        errdefer entries.deinit(allocator);
        var pending: std.ArrayList(Pending) = .empty;
        try pending.ensureTotalCapacity(allocator, limits.maximum_terminals);
        errdefer pending.deinit(allocator);
        var completions: std.ArrayList(Completion) = .empty;
        try completions.ensureTotalCapacity(allocator, limits.maximum_terminals);
        errdefer completions.deinit(allocator);
        var retired: std.ArrayList(Retired) = .empty;
        try retired.ensureTotalCapacity(allocator, recent_exit_capacity);
        return .{ .allocator = allocator, .limits = limits, .entries = entries, .pending = pending, .completions = completions, .retired = retired, .history_manager = history.Manager.init(allocator) };
    }

    pub fn deinit(self: *Pool) void {
        self.tryDeinit() catch |err| std.log.err("pool cleanup incomplete: {s}; records retained", .{@errorName(err)});
    }

    /// A failed destructor retains the unfinished record. Product service code
    /// quiesces first, so this is only a bounded final cleanup fallback.
    pub fn tryDeinit(self: *Pool) !void {
        while (self.pending.items.len != 0) {
            const pending = &self.pending.items[self.pending.items.len - 1];
            try pending.startup.tryDeinit();
            try pending.session.tryDestroy();
            self.allocator.free(pending.cwd);
            self.pending.items.len -= 1;
        }
        while (self.entries.items.len != 0) {
            const entry = &self.entries.items[self.entries.items.len - 1];
            try entry.session.tryDestroy();
            self.allocator.free(entry.cwd);
            self.entries.items.len -= 1;
        }
        for (self.retired.items) |record| self.allocator.free(record.cwd);
        self.retired.clearRetainingCapacity();
        self.history_manager.deinit();
        self.pending.deinit(self.allocator);
        self.completions.deinit(self.allocator);
        self.retired.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn beginShutdown(self: *Pool) void {
        for (self.pending.items) |*pending| pending.startup.cancel();
        for (self.entries.items) |*entry| {
            entry.session.requestTermination(1000) catch |err| {
                entry.cleanup_failure = err;
            };
        }
    }

    pub fn quiescent(self: *const Pool) bool {
        if (self.pending.items.len != 0) return false;
        for (self.entries.items) |entry| {
            if (!entry.session.cleanupComplete() or !entry.session.eof) return false;
        }
        return true;
    }

    /// Creates one process only after all validation/allocation preconditions.
    /// A startup failure does not insert a record or consume a terminal slot.
    pub fn create(self: *Pool, id: [36]u8, launch: Launch) !void {
        try self.validateLaunch(id, launch);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        const args = try marshal(temporary, launch.argv);
        const env = try marshal(temporary, launch.environment);
        const cwd = try self.allocator.dupeZ(u8, launch.cwd);
        errdefer self.allocator.free(cwd);
        const executable = try temporary.dupeZ(u8, launch.argv[0]);
        const session = try Session.create(self.allocator, cwd, executable, args.ptr, env.ptr, launch.geometry.rows, launch.geometry.columns);
        errdefer session.destroy();
        session.scope_cleanup = self.limits.scope_cleanup;
        if (launch.geometry.pixel_width != 0) try session.resizeGeometry(launch.geometry);
        self.entries.appendAssumeCapacity(.{ .id = id, .cwd = cwd, .original_pid = session.process.pid, .session = session });
    }

    fn containsID(self: *Pool, id: [36]u8) bool {
        if (self.find(id) != null) return true;
        if (self.findRetired(id) != null) return true;
        for (self.pending.items) |item| if (std.mem.eql(u8, &item.id, &id)) return true;
        for (self.completions.items) |item| if (std.mem.eql(u8, &item.id, &id)) return true;
        return false;
    }

    /// True once a record owns no operating-system resource at all: the child is
    /// reaped, its PTY master is closed and no cleanup is outstanding.
    fn reclaimed(entry: *const Entry) bool {
        if (!entry.session.cleanupComplete() or entry.session.cleanup_error != null) return false;
        return entry.session.exit_status != null or entry.failure != null;
    }

    /// Post-mortem summary of a terminal that already gave its slot back, or
    /// null once even that summary aged out of the bounded window.
    pub fn findRetired(self: *Pool, id: [36]u8) ?*Retired {
        for (self.retired.items) |*record| if (std.mem.eql(u8, &record.id, &id)) return record;
        return null;
    }

    /// Releases one record's VT, history and graphics memory and keeps only its
    /// summary. Fails without mutating anything when the final teardown cannot
    /// complete, so a record that still owns a process is never dropped.
    fn retire(self: *Pool, index: usize) !void {
        const entry = self.entries.items[index];
        const status = entry.session.exit_status;
        try entry.session.tryDestroy();
        // Only after teardown succeeded: the ID must not exist twice, and the
        // FIFO order of history observations must forget this lifecycle.
        self.history_manager.forget(entry.id);
        if (self.retired.items.len == recent_exit_capacity) self.allocator.free(self.retired.orderedRemove(0).cwd);
        self.retired.appendAssumeCapacity(.{ .id = entry.id, .cwd = entry.cwd, .exit_status = status, .unavailable = entry.failure != null });
        _ = self.entries.orderedRemove(index);
    }

    /// Frees the oldest fully reclaimed slot so a new terminal can use it.
    ///
    /// Why the eviction victim is a reclaimed record and never a live one: the
    /// documented limit exists to bound live PTYs, VTs and child processes, so a
    /// record that owns none of those is pure bookkeeping and can go. Killing a
    /// `running`/`terminating` terminal to admit a new one would silently destroy
    /// a user's work, so that case still reports resource_limit. Oldest-first
    /// keeps the surviving summaries the most recent ones.
    fn reclaimSlot(self: *Pool) bool {
        for (self.entries.items, 0..) |*entry, index| {
            if (!reclaimed(entry)) continue;
            self.retire(index) catch |err| {
                self.entries.items[index].cleanup_failure = err;
                continue;
            };
            return true;
        }
        return false;
    }

    fn validateLaunch(self: *Pool, id: [36]u8, launch: Launch) !void {
        if (!validID(&id)) return error.InvalidTerminalID;
        if (self.containsID(id)) return error.TerminalAlreadyExists;
        // The limit counts live resources. A pool full of exited-and-reaped
        // records must not block a long-lived workspace forever, so retire the
        // oldest dead record instead of refusing the launch.
        if (self.entries.items.len + self.pending.items.len >= self.limits.maximum_terminals and !self.reclaimSlot())
            return error.TerminalLimitReached;
        try launch.geometry.validate();
        if (launch.geometry.columns > self.limits.maximum_columns or
            @as(usize, launch.geometry.rows) * launch.geometry.columns > self.limits.maximum_cells)
            return error.TerminalGeometryLimit;
        if (launch.cwd.len == 0 or launch.cwd.len > 32768 or !std.fs.path.isAbsolute(launch.cwd) or
            std.mem.indexOfScalar(u8, launch.cwd, 0) != null) return error.InvalidTerminalDirectory;
        if (launch.argv.len == 0 or launch.argv.len > 128 or !std.fs.path.isAbsolute(launch.argv[0]))
            return error.InvalidTerminalArguments;
        for (launch.argv) |arg| {
            if (arg.len > 4096 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidTerminalArguments;
        }
        if (launch.environment.len > 128) return error.InvalidTerminalEnvironment;
        for (launch.environment, 0..) |item, index| {
            const equal = std.mem.indexOfScalar(u8, item, '=') orelse return error.InvalidTerminalEnvironment;
            if (equal == 0 or equal > 256 or item.len - equal - 1 > 8192 or
                std.mem.indexOfScalar(u8, item, 0) != null) return error.InvalidTerminalEnvironment;
            for (launch.environment[0..index]) |previous| {
                const previous_equal = std.mem.indexOfScalar(u8, previous, '=').?;
                if (std.mem.eql(u8, item[0..equal], previous[0..previous_equal])) return error.DuplicateEnvironmentName;
            }
        }
    }

    /// Reserve a bounded terminal slot and completion slot, prepare VT state,
    /// and fork without waiting for exec. Errors here leave no owned child.
    /// Consume takeCompletion to observe every accepted creation's result.
    pub fn beginCreate(self: *Pool, id: [36]u8, launch: Launch) !void {
        try self.validateLaunch(id, launch);
        if (self.completions.items.len + self.pending.items.len >= self.limits.maximum_terminals)
            return error.CreationCompletionBackpressure;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        const args = try marshal(temporary, launch.argv);
        const env = try marshal(temporary, launch.environment);
        const executable = try temporary.dupeZ(u8, launch.argv[0]);
        const cwd = try self.allocator.dupeZ(u8, launch.cwd);
        errdefer self.allocator.free(cwd);
        const session = try Session.prepare(self.allocator, launch.geometry);
        session.scope_cleanup = self.limits.scope_cleanup;
        errdefer session.destroy();
        var startup = try Startup.beginGeometry(cwd, executable, args.ptr, env.ptr, launch.geometry);
        startup.scope_cleanup = self.limits.scope_cleanup;
        self.pending.appendAssumeCapacity(.{ .id = id, .cwd = cwd, .session = session, .startup = startup });
    }

    /// Cancel an accepted creation, retaining its child until nonblocking reap
    /// finishes. Cancellation is idempotent while that record remains pending.
    pub fn cancelCreate(self: *Pool, id: [36]u8) !void {
        for (self.pending.items) |*pending| {
            if (!std.mem.eql(u8, &pending.id, &id)) continue;
            pending.startup.cancel();
            return;
        }
        for (self.completions.items) |completion| {
            if (std.mem.eql(u8, &completion.id, &id) and completion.result == .cancelled) return;
        }
        return error.PendingCreationNotFound;
    }

    /// Inspect a pending operation, including cleanup errors which retain PID
    /// ownership. A caller can surface these rather than silently waiting.
    pub fn pendingStatus(self: *Pool, id: [36]u8) ?PendingStatus {
        for (self.pending.items) |pending| {
            if (std.mem.eql(u8, &pending.id, &id)) return .{ .outcome = pending.startup.outcome, .cleanup_failure = pending.cleanup_failure };
        }
        return null;
    }

    /// Move the oldest completion to its caller. No accepted request's result
    /// is overwritten; unconsumed completions apply bounded admission pressure.
    pub fn takeCompletion(self: *Pool) ?Completion {
        if (self.completions.items.len == 0) return null;
        return self.completions.orderedRemove(0);
    }

    /// Collect startup reports and PTY readiness without allocations. A buffer
    /// of limits.maximum_terminals pollfd values always suffices.
    pub fn pollDescriptors(self: *Pool, buffer: []std.posix.pollfd) ![]std.posix.pollfd {
        var count: usize = 0;
        for (self.pending.items) |*pending| {
            if (pending.startup.reportDescriptor()) |fd| {
                if (count == buffer.len) return error.PollBufferTooSmall;
                buffer[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
        }
        for (self.entries.items) |entry| {
            const session = entry.session;
            if (entry.failure != null or session.eof or session.process.master < 0) continue;
            if (count == buffer.len) return error.PollBufferTooSmall;
            buffer[count] = .{ .fd = session.process.master, .events = std.posix.POLL.IN | (if (session.pending_input.items.len > session.input_offset) @as(i16, std.posix.POLL.OUT) else @as(i16, 0)), .revents = 0 };
            count += 1;
        }
        return buffer[0..count];
    }

    /// Include this bound in the shared reactor wait. Cleanup is polled at most
    /// 10 ms apart even if the surrounding service has no SIGCHLD wake source.
    pub fn maximumWaitMilliseconds(self: *Pool, requested: i32) i32 {
        var limit = requested;
        for (self.pending.items) |*pending| {
            limit = pending.startup.maximumWaitMilliseconds(limit);
            if (pending.startup.cleanup_started) limit = if (limit < 0) 10 else @min(limit, 10);
        }
        for (self.entries.items) |entry| limit = entry.session.maximumWaitMilliseconds(limit);
        return limit;
    }

    fn pollPending(self: *Pool) void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const pending = &self.pending.items[index];
            const outcome = pending.startup.poll();
            if (outcome == .pending) {
                index += 1;
                continue;
            }
            if (outcome == .ready) {
                // Readiness and ownership are established by the state machine;
                // transfer performs no allocation and cannot fail here.
                var process = pending.startup.takeProcess() catch unreachable;
                pending.session.adoptProcess(&process);
                const pid = pending.session.process.pid;
                self.entries.appendAssumeCapacity(.{ .id = pending.id, .cwd = pending.cwd, .original_pid = pid, .session = pending.session });
                self.completions.appendAssumeCapacity(.{ .id = pending.id, .result = .{ .created = pid } });
                _ = self.pending.orderedRemove(index);
                continue;
            }
            const reaped = pending.startup.reap() catch |err| {
                pending.cleanup_failure = err;
                index += 1;
                continue;
            };
            if (!reaped) {
                index += 1;
                continue;
            }
            const result: Completion = .{ .id = pending.id, .cleanup_failure = pending.cleanup_failure, .result = switch (outcome) {
                .cancelled => .cancelled,
                .timed_out => .{ .failed = .{ .reason = error.PtyStartupTimedOut } },
                .failed => |failure| .{ .failed = .{ .reason = switch (failure.stage) {
                    1 => error.WorkingDirectoryUnavailable,
                    2 => error.ExecutableUnavailable,
                    else => error.PtyStartupFailed,
                }, .startup = failure } },
                else => unreachable,
            } };
            self.completions.appendAssumeCapacity(result);
            pending.session.destroy(); // Prepared only: no child or PTY owned.
            self.allocator.free(pending.cwd);
            _ = self.pending.orderedRemove(index);
        }
    }

    /// Records borrow the pool until its next mutation. Read paths do not create
    /// PTYs or reconstruct exited commands.
    pub fn find(self: *Pool, id: [36]u8) ?*Entry {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, &entry.id, &id)) return entry;
        return null;
    }

    pub fn terminate(self: *Pool, id: [36]u8, grace_ms: u32) !void {
        const entry = self.find(id) orelse return error.TerminalNotFound;
        if (entry.failure != null) return error.TerminalUnavailable;
        try entry.session.requestTermination(grace_ms);
    }

    /// Observe after each producer turn so FIFO ordering follows actual VT
    /// processing. Metadata allocation failure drops retained history only;
    /// it never ends an otherwise healthy owned process.
    pub fn enforceHistoryBudget(self: *Pool) void {
        var items: [64]history.Item = undefined;
        for (self.entries.items, 0..) |entry, index| items[index] = .{ .id = entry.id, .session = entry.session };
        self.history_stats = self.history_manager.enforce(items[0..self.entries.items.len], self.limits.maximum_history_bytes) catch {
            self.history_failures +|= 1;
            self.history_manager.deinit();
            self.history_manager = history.Manager.init(self.allocator);
            self.history_stats = .{ .charged_bytes = 0, .removed_rows = 0, .removed_pages = 0, .tracked_pages = 0 };
            for (self.entries.items) |*entry| {
                const prior_rows = entry.session.history_usage.rows;
                const limit = entry.session.history_limit;
                entry.session.history_limit = 0;
                entry.session.enforceHistoryLimit() catch |err| {
                    // A failure of the nonallocating VT trim means this VT is
                    // invalid, independently of the other processes in the pool.
                    entry.failure = err;
                    entry.session.abort() catch |cleanup| {
                        entry.cleanup_failure = cleanup;
                    };
                };
                entry.session.history_limit = limit;
                self.history_stats.charged_bytes +|= entry.session.history_usage.charged_bytes;
                self.history_stats.removed_rows +|= prior_rows -| entry.session.history_usage.rows;
            }
            return;
        };
    }

    /// Never waits on any individual PTY. Every live record gets one bounded
    /// read even if there are no attached clients. I/O failure retires that
    /// process and remains observable on its record without losing other PTYs.
    pub fn tick(self: *Pool) void {
        self.pollPending();
        const count = self.entries.items.len;
        if (count == 0) return;
        var observed = false;
        for (0..count) |offset| {
            const entry = &self.entries.items[(self.next_entry + offset) % count];
            if (entry.failure != null) {
                entry.session.pollReap() catch |err| {
                    entry.cleanup_failure = err;
                };
                continue;
            }
            const changed = entry.session.tick(0) catch |err| {
                entry.failure = err;
                entry.session.abort() catch |cleanup_error| {
                    entry.cleanup_failure = cleanup_error;
                };
                continue;
            };
            if (changed) {
                self.enforceHistoryBudget();
                observed = true;
            }
        }
        if (!observed) self.enforceHistoryBudget();
        self.next_entry = (self.next_entry + 1) % count;
    }
};

fn marshal(allocator: std.mem.Allocator, values: []const []const u8) ![:null]?[*:0]const u8 {
    const result = try allocator.allocSentinel(?[*:0]const u8, values.len, null);
    for (values, 0..) |value, index| result[index] = (try allocator.dupeZ(u8, value)).ptr;
    return result;
}

fn testID(value: u8) [36]u8 {
    var id = "00000000-0000-4000-8000-000000000000".*;
    id[35] = value;
    return id;
}

fn waitForExit(pool: *Pool) !void {
    var clock = try std.time.Timer.start();
    while (clock.read() < 3 * std.time.ns_per_s) {
        pool.tick();
        var done = true;
        for (pool.entries.items) |entry| {
            try std.testing.expect(entry.failure == null);
            if (!entry.session.eof or entry.session.exit_status == null) done = false;
        }
        if (done) return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.TestProcessesDidNotExit;
}

test "multiple unobserved PTYs retain independent output and real exit status" {
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "printf FIRST; exit 7" } });
    try pool.create(testID('2'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "printf SECOND; exit 3" } });
    try waitForExit(&pool);
    const first = pool.find(testID('1')).?;
    const second = pool.find(testID('2')).?;
    try std.testing.expectEqual(@as(u8, 7), std.posix.W.EXITSTATUS(first.session.exit_status.?));
    try std.testing.expectEqual(@as(u8, 3), std.posix.W.EXITSTATUS(second.session.exit_status.?));
    const text = try first.session.terminal.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "FIRST") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SECOND") == null);
    try std.testing.expect(first.session.process.pid == -1 and second.session.process.pid == -1);
}

test "invalid launches and capacity checks do not consume slots" {
    var pool = try Pool.init(std.testing.allocator, .{ .maximum_terminals = 1 });
    defer pool.deinit();
    try std.testing.expectError(error.InvalidTerminalArguments, pool.create(testID('1'), .{ .cwd = "/", .argv = &.{"sh"} }));
    try std.testing.expectError(error.DuplicateEnvironmentName, pool.create(testID('1'), .{ .cwd = "/", .argv = &.{"/bin/sh"}, .environment = &.{ "KEY=a", "KEY=b" } }));
    try std.testing.expectError(error.TerminalGeometryLimit, pool.create(testID('1'), .{ .cwd = "/", .argv = &.{"/bin/sh"}, .geometry = .{ .rows = 65535, .columns = 65535 } }));
    try std.testing.expectError(error.ExecutableUnavailable, pool.create(testID('1'), .{ .cwd = "/", .argv = &.{"/aster-missing-executable"} }));
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "read line" } });
    try std.testing.expectError(error.TerminalAlreadyExists, pool.create(testID('1'), .{ .cwd = "/", .argv = &.{"/bin/sh"} }));
    try std.testing.expectError(error.TerminalLimitReached, pool.create(testID('2'), .{ .cwd = "/", .argv = &.{"/bin/sh"} }));
}

test "a full pool reuses the oldest reclaimed slot and keeps its exit observable" {
    var pool = try Pool.init(std.testing.allocator, .{ .maximum_terminals = 2 });
    defer pool.deinit();
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "exit 5" } });
    try pool.create(testID('2'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "exit 6" } });
    try waitForExit(&pool);
    // Both records are reaped, so a third terminal must be admitted: the limit
    // bounds live PTYs, not the history of a long-lived workspace.
    try pool.create(testID('3'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "read line" } });
    try std.testing.expectEqual(@as(usize, 2), pool.entries.items.len);
    try std.testing.expect(pool.find(testID('1')) == null);
    const retired = pool.findRetired(testID('1')).?;
    try std.testing.expectEqual(@as(u8, 5), std.posix.W.EXITSTATUS(retired.exit_status.?));
    try std.testing.expectEqualStrings("/", retired.cwd);
    try std.testing.expect(!retired.unavailable);
    try std.testing.expectError(error.TerminalAlreadyExists, pool.create(testID('1'), .{ .cwd = "/", .argv = &.{"/bin/sh"} }));
    // The remaining reclaimed record goes next; after that every record owns a
    // live child and the resource limit applies again.
    try pool.create(testID('4'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "read line" } });
    try std.testing.expect(pool.find(testID('2')) == null and pool.findRetired(testID('2')) != null);
    try std.testing.expect(pool.find(testID('3')).?.session.process.pid > 0);
    try std.testing.expectError(error.TerminalLimitReached, pool.create(testID('5'), .{ .cwd = "/", .argv = &.{"/bin/sh"} }));
    try std.testing.expectEqual(@as(usize, 2), pool.entries.items.len);
    try std.testing.expect(pool.find(testID('4')).?.session.exit_status == null);
}

test "recent exit summaries stay bounded and older terminals become unknown" {
    var pool = try Pool.init(std.testing.allocator, .{ .maximum_terminals = 2 });
    defer pool.deinit();
    const serials = "0123456789ab";
    const first = testID(serials[0]);
    for (serials) |serial| {
        try pool.create(testID(serial), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "exit 0" } });
        try waitForExit(&pool);
    }
    try std.testing.expectEqual(recent_exit_capacity, pool.retired.items.len);
    // Beyond the window a terminal is unknown everywhere: no live record can be
    // mistaken for it, and no stale summary claims to still know its state.
    try std.testing.expect(pool.find(first) == null and pool.findRetired(first) == null);
    const newest_retired = pool.retired.items[pool.retired.items.len - 1];
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(newest_retired.exit_status.?));
}

test "arguments are literal and a noisy terminal does not prevent another from exiting" {
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "while :; do printf FLOOD; done" } });
    try pool.create(testID('2'), .{ .cwd = "/", .argv = &.{ "/usr/bin/printf", "%s", "$(printf expanded);literal" } });
    var clock = try std.time.Timer.start();
    while (pool.find(testID('2')).?.session.exit_status == null and clock.read() < 3 * std.time.ns_per_s) {
        pool.tick();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    pool.tick();
    const quiet = pool.find(testID('2')).?;
    try std.testing.expect(quiet.session.exit_status != null);
    const text = try quiet.session.terminal.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "$(printf expanded);literal") != null);
    try std.testing.expect(pool.find(testID('1')).?.session.process.pid > 0);
}

test "prepared cwd and environment reach the child without interpolation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();
    const expected = try std.fmt.allocPrint(std.testing.allocator, "EXPECT_DIR={s}", .{cwd});
    defer std.testing.allocator.free(expected);
    try pool.create(testID('1'), .{ .cwd = cwd, .argv = &.{ "/bin/sh", "-c", "[ \"$PWD\" = \"$EXPECT_DIR\" ] || exit 8; printf 'ENV:%s' \"$VALUE\"" }, .environment = &.{ expected, "VALUE=literal$(printf BAD)" } });
    try waitForExit(&pool);
    const entry = pool.find(testID('1')).?;
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(entry.session.exit_status.?));
    try std.testing.expectEqualStrings(cwd, entry.cwd);
    const text = try entry.session.terminal.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "ENV:literal$(printf BAD)") != null);
}

fn waitForText(pool: *Pool, id: [36]u8, marker: []const u8) !void {
    var clock = try std.time.Timer.start();
    while (clock.read() < 3 * std.time.ns_per_s) {
        pool.tick();
        const text = try pool.find(id).?.session.terminal.formatActiveScreen(std.testing.allocator, false, 32768);
        const found = std.mem.indexOf(u8, text, marker) != null;
        std.testing.allocator.free(text);
        if (found) return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.TestOutputMissing;
}

test "graceful termination drains the exit trap and preserves actual status" {
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "trap 'printf TERM_DONE; exit 0' TERM; printf READY; while :; do read line; done" } });
    try waitForText(&pool, testID('1'), "READY");
    try pool.terminate(testID('1'), 500);
    const entry = pool.find(testID('1')).?;
    try std.testing.expectError(error.TerminalTerminating, entry.session.send("unexpected\n"));
    try std.testing.expectError(error.TerminalTerminating, entry.session.resize(25, 81));
    try waitForExit(&pool);
    try std.testing.expect(std.posix.W.IFEXITED(entry.session.exit_status.?));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(entry.session.exit_status.?));
    try waitForText(&pool, testID('1'), "TERM_DONE");
    try pool.terminate(testID('1'), 500);
    try std.testing.expectError(error.ProcessAlreadyReaped, entry.session.process.requestTermination(true));
}

test "ignored TERM escalates without delaying another terminal or extending grace" {
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "trap '' TERM; printf READY; while :; do read line; done" } });
    try waitForText(&pool, testID('1'), "READY");
    try pool.terminate(testID('1'), 40);
    try pool.terminate(testID('1'), 60_000);
    var waiting = try std.time.Timer.start();
    _ = try pool.find(testID('1')).?.session.tick(1000);
    try std.testing.expect(waiting.read() < 500 * std.time.ns_per_ms);
    try pool.create(testID('2'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "exit 9" } });
    try waitForExit(&pool);
    const stopped = pool.find(testID('1')).?.session;
    try std.testing.expect(stopped.force_sent);
    try std.testing.expect(std.posix.W.IFSIGNALED(stopped.exit_status.?));
    try std.testing.expectEqual(@as(u32, std.posix.SIG.KILL), std.posix.W.TERMSIG(stopped.exit_status.?));
    try std.testing.expectEqual(@as(u8, 9), std.posix.W.EXITSTATUS(pool.find(testID('2')).?.session.exit_status.?));
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), stopped.process.master);
}

fn waitForCompletion(pool: *Pool) !Completion {
    var timer = try std.time.Timer.start();
    while (timer.read() < 6 * std.time.ns_per_s) {
        pool.tick();
        if (pool.takeCompletion()) |completion| return completion;
        var descriptors: [64]std.posix.pollfd = undefined;
        _ = try std.posix.poll(try pool.pollDescriptors(&descriptors), pool.maximumWaitMilliseconds(10));
    }
    return error.TestCreationTimedOut;
}

test "async creation reserves capacity and publishes only after exec handshake" {
    var pool = try Pool.init(std.testing.allocator, .{ .maximum_terminals = 1 });
    defer pool.deinit();
    const id = testID('1');
    try pool.beginCreate(id, .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "printf ASYNC_POOL; exit 6" }, .geometry = .{ .rows = 30, .columns = 100, .pixel_width = 1000, .pixel_height = 600 } });
    try std.testing.expect(pool.find(id) == null);
    try std.testing.expectEqual(@as(usize, 1), pool.pending.items.len);
    try std.testing.expectError(error.TerminalAlreadyExists, pool.beginCreate(id, .{ .cwd = "/", .argv = &.{"/bin/sh"} }));
    try std.testing.expectError(error.TerminalLimitReached, pool.beginCreate(testID('2'), .{ .cwd = "/", .argv = &.{"/bin/sh"} }));
    const completed = try waitForCompletion(&pool);
    try std.testing.expect(completed.result == .created);
    try std.testing.expectEqual(id, completed.id);
    const session = pool.find(id).?.session;
    try std.testing.expectEqual(@as(u32, 1000), (try session.terminal.pixelSize()).width);
    try waitForExit(&pool);
    try std.testing.expectEqual(@as(u8, 6), std.posix.W.EXITSTATUS(session.exit_status.?));
    try waitForText(&pool, id, "ASYNC_POOL");
    try std.testing.expectEqual(@as(usize, 0), pool.pending.items.len);
}

test "async failure reports stage and releases capacity after child cleanup" {
    var pool = try Pool.init(std.testing.allocator, .{ .maximum_terminals = 1 });
    defer pool.deinit();
    try pool.beginCreate(testID('1'), .{ .cwd = "/", .argv = &.{"/aster-absent-executable"} });
    const completed = try waitForCompletion(&pool);
    try std.testing.expect(completed.result == .failed);
    try std.testing.expectEqual(error.ExecutableUnavailable, completed.result.failed.reason);
    try std.testing.expectEqual(@as(c_int, 2), completed.result.failed.startup.?.stage);
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.pending.items.len);
    try pool.beginCreate(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "exit 0" } });
    try std.testing.expect((try waitForCompletion(&pool)).result == .created);
}

test "async cancellation preserves a bounded completion until consumed" {
    var pool = try Pool.init(std.testing.allocator, .{ .maximum_terminals = 1 });
    defer pool.deinit();
    try pool.beginCreate(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "while :; do printf FLOOD; done" } });
    try pool.cancelCreate(testID('1'));
    try pool.cancelCreate(testID('1'));
    var timer = try std.time.Timer.start();
    while (pool.pending.items.len > 0) {
        pool.tick();
        if (timer.read() > 3 * std.time.ns_per_s) return error.TestCreationTimedOut;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
    try std.testing.expectError(error.CreationCompletionBackpressure, pool.beginCreate(testID('2'), .{ .cwd = "/", .argv = &.{"/bin/sh"} }));
    const completed = pool.takeCompletion().?;
    try std.testing.expect(completed.result == .cancelled);
    try std.testing.expect(pool.takeCompletion() == null);
    try pool.beginCreate(testID('2'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "exit 0" } });
    try std.testing.expect((try waitForCompletion(&pool)).result == .created);
}

test "async launches and existing flooding PTY advance in the same ticks" {
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "while :; do printf FLOOD; done" } });
    try waitForText(&pool, testID('1'), "FLOOD");
    try pool.beginCreate(testID('2'), .{ .cwd = "/", .argv = &.{ "/usr/bin/printf", "%s", "LITERAL$(not-expanded)" } });
    const completed = try waitForCompletion(&pool);
    try std.testing.expect(completed.result == .created);
    try waitForText(&pool, testID('2'), "LITERAL$(not-expanded)");
    try std.testing.expect(pool.find(testID('1')).?.session.output_sequence > 0);
}

test "pool global history cap retains live processes and latest active rows" {
    var pool = try Pool.init(std.testing.allocator, .{ .maximum_history_bytes = 0 });
    defer pool.deinit();
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "sleep 60" }, .geometry = .{ .rows = 3, .columns = 20 } });
    const entry = pool.find(testID('1')).?;
    const pid = entry.session.process.pid;
    entry.session.terminal.write("OLD\r\nLIVE1\r\nLIVE2\r\nLIVE3");
    pool.tick();
    try std.testing.expectEqual(@as(usize, 0), pool.history_stats.charged_bytes);
    try std.testing.expectEqual(@as(u64, 0), pool.history_failures);
    try std.testing.expectEqual(pid, entry.session.process.pid);
    try std.testing.expect(entry.session.exit_status == null);
    const text = try entry.session.terminal.formatRow(std.testing.allocator, .primary, 0, 4096);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "LIVE1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OLD") == null);
}

test "pool history metadata allocation failure discards history without terminating process" {
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();
    try pool.create(testID('1'), .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "sleep 60" }, .geometry = .{ .rows = 3, .columns = 20 } });
    const entry = pool.find(testID('1')).?;
    const pid = entry.session.process.pid;
    entry.session.terminal.write("OLD\r\nLIVE1\r\nLIVE2\r\nLIVE3");
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    pool.history_manager.allocator = fail.allocator();
    pool.enforceHistoryBudget();
    try std.testing.expectEqual(@as(u64, 1), pool.history_failures);
    try std.testing.expectEqual(@as(usize, 0), pool.history_stats.charged_bytes);
    try std.testing.expectEqual(pid, entry.session.process.pid);
    try std.testing.expect(entry.failure == null and entry.session.exit_status == null);
    try entry.session.send("still alive\n");
    pool.tick();
    try std.testing.expectEqual(pid, entry.session.process.pid);
}

test "pool real PTY global history pressure preserves FIFO ownership and input" {
    const a = std.testing.allocator;
    const limit = 2 * 1024 * 1024;
    var pool = try Pool.init(a, .{ .maximum_history_bytes = limit });
    defer pool.deinit();
    // Fill the first terminal before starting the second producer so its
    // observed history pages are unambiguously older across terminals.
    try pool.create(testID('1'), .{
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "stty -echo; printf 'FIRST_OLDEST\\n'; i=0; while [ $i -lt 100 ]; do printf 'FIRST-%04d\\n' $i; i=$((i+1)); done; printf 'FIRST_READY\\n'; while IFS= read -r line; do printf 'ACK:%s\\n' \"$line\"; done" },
        .geometry = .{ .rows = 3, .columns = 80 },
    });
    try waitForText(&pool, testID('1'), "FIRST_READY");
    const first = pool.find(testID('1')).?.session;
    const first_pid = first.process.pid;
    const before = try history_budget.usage(&first.terminal);
    std.debug.print("first history before pressure: rows={d} bytes={d} limit={d}\n", .{ before.rows, before.charged_bytes, limit });
    try std.testing.expect(before.rows > 0 and before.charged_bytes > 0 and before.charged_bytes < limit);
    const old_row = try first.terminal.formatRow(a, .primary, 0, 4096);
    defer a.free(old_row);
    try std.testing.expect(std.mem.indexOf(u8, old_row, "FIRST_OLDEST") != null);
    try std.testing.expectEqual(history_budget.terminal_limit, first.history_limit);

    try pool.create(testID('2'), .{
        .cwd = "/",
        .argv = &.{ "/bin/sh", "-c", "stty -echo; printf 'SECOND_OLDEST\\n'; i=0; while [ $i -lt 2000 ]; do printf 'SECOND-%04d\\n' $i; i=$((i+1)); done; printf 'SECOND_READY\\n'; while IFS= read -r line; do printf 'ACK:%s\\n' \"$line\"; done" },
        .geometry = .{ .rows = 3, .columns = 80 },
    });
    const second = pool.find(testID('2')).?.session;
    const second_pid = second.process.pid;
    try waitForText(&pool, testID('2'), "SECOND_READY");
    try std.testing.expectEqual(history_budget.terminal_limit, second.history_limit);
    const first_after = try history_budget.usage(&first.terminal);
    const second_after = try history_budget.usage(&second.terminal);
    // The default 16 MiB per-terminal cap remains unchanged. These short-line
    // producers exceed only the small aggregate cap, not their individual caps.
    try std.testing.expectEqual(@as(usize, 0), first_after.rows);
    try std.testing.expect(second_after.rows > 0 and second_after.rows < 2000);
    try std.testing.expect(first_after.charged_bytes + second_after.charged_bytes <= limit);
    try std.testing.expectEqual(first_after.charged_bytes + second_after.charged_bytes, pool.history_stats.charged_bytes);
    try std.testing.expectEqual(@as(u64, 0), pool.history_failures);
    const retained_row = try second.terminal.formatRow(a, .primary, 0, 4096);
    defer a.free(retained_row);
    try std.testing.expect(std.mem.indexOf(u8, retained_row, "SECOND_OLDEST") == null);
    try std.testing.expect(std.mem.indexOf(u8, retained_row, "SECOND-") != null);
    try std.testing.expectEqual(first_pid, first.process.pid);
    try std.testing.expectEqual(second_pid, second.process.pid);
    try std.testing.expect(first.exit_status == null and second.exit_status == null);

    // Drive the real PTY input queue after eviction and observe its shell's
    // response through Pool.tick, rather than mutating the VT in the test.
    try first.send("AFTER_GLOBAL_PRESSURE\n");
    try waitForText(&pool, testID('1'), "ACK:AFTER_GLOBAL_PRESSURE");
    try waitForText(&pool, testID('2'), "SECOND_READY");
    try std.testing.expect(pool.history_stats.charged_bytes <= limit);
    try std.testing.expectEqual(first_pid, first.process.pid);
    try std.testing.expectEqual(second_pid, second.process.pid);
    try std.testing.expect(first.exit_status == null and second.exit_status == null);
}
