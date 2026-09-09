const std = @import("std");
const scope = @import("process_scope.zig");
const Process = @import("pty.zig").Process;
const c = @cImport({
    @cInclude("pty_startup.h");
    @cInclude("errno.h");
});

pub const Failure = struct { stage: c_int, errno_value: c_int };
pub const Outcome = union(enum) {
    pending,
    ready,
    failed: Failure,
    timed_out,
    cancelled,
    transferred,
};

/// An owned, unreaped PTY child with a nonblocking exec handshake. Keep this
/// value in one owner; copying it duplicates descriptor/PID ownership.
pub const Startup = struct {
    raw: c.struct_session_pty_startup,
    timer: std.time.Timer,
    outcome: Outcome = .pending,
    deadline_ns: u64 = 5 * std.time.ns_per_s,
    cleanup_started: bool = false,
    scope_cleanup: bool = false,
    scope_context: ?scope.Context = null,

    /// argv/env/cwd must be prepared and validated by the parent. Their memory
    /// need only remain valid through begin: fork gives the child its own copy.
    /// Resource/exec failures are returned by poll with stage and errno intact.
    pub fn begin(cwd: [:0]const u8, executable: [:0]const u8, argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, rows: u16, columns: u16) !Startup {
        return beginGeometry(cwd, executable, argv, env, .{ .rows = rows, .columns = columns });
    }

    /// Initial character/pixel dimensions are applied by forkpty before exec.
    pub fn beginGeometry(cwd: [:0]const u8, executable: [:0]const u8, argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, geometry: @import("geometry.zig").Geometry) !Startup {
        try geometry.validate();
        var self = Startup{ .raw = undefined, .timer = try std.time.Timer.start() };
        _ = c.session_pty_startup_begin(&self.raw, cwd, executable, @ptrCast(@constCast(argv)), @ptrCast(@constCast(env)), geometry.rows, geometry.columns, geometry.pixel_width, geometry.pixel_height);
        return self;
    }

    /// Descriptor to add to the reactor poll set while outcome is pending.
    /// Return null after resolution; never read the report fd outside poll.
    pub fn reportDescriptor(self: *const Startup) ?std.posix.fd_t {
        return if (self.outcome == .pending and self.raw.report >= 0) self.raw.report else null;
    }

    /// Cap the reactor's wait at the fixed startup deadline. Repeated calls
    /// never reset or extend the deadline, including interrupted reads.
    pub fn maximumWaitMilliseconds(self: *Startup, requested: i32) i32 {
        if (self.outcome != .pending) return requested;
        const remaining = self.deadline_ns -| self.timer.read();
        const milliseconds: i32 = @intCast((remaining + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        return if (requested < 0) milliseconds else @min(requested, milliseconds);
    }

    /// Read at most one fixed-size report. Does not block or reap the child.
    /// Timeout/failure starts cancellation; retain ownership until reap returns
    /// true, then release this object. Successful exec does not imply exit zero.
    pub fn poll(self: *Startup) Outcome {
        if (self.outcome != .pending) return self.outcome;
        if (self.raw.failure != 0) {
            self.outcome = .{ .failed = .{ .stage = self.raw.stage, .errno_value = self.raw.failure } };
        } else if (self.timer.read() >= self.deadline_ns) {
            self.outcome = .timed_out;
        } else {
            switch (c.session_pty_startup_poll(&self.raw)) {
                0 => return .pending,
                1 => self.outcome = .ready,
                else => self.outcome = .{ .failed = .{ .stage = self.raw.stage, .errno_value = self.raw.failure } },
            }
        }
        if (self.outcome != .ready) self.startCleanup();
        return self.outcome;
    }

    /// Move the child and master into the existing Process representation.
    /// This object becomes inert; only the recipient may signal or reap it.
    pub fn takeProcess(self: *Startup) !Process {
        if (self.outcome != .ready or self.cleanup_started) return error.StartupNotReady;
        const process = Process{ .pid = self.raw.pid, .master = self.raw.master };
        self.raw.pid = -1;
        self.raw.master = -1;
        self.outcome = .transferred;
        return process;
    }

    fn startCleanup(self: *Startup) void {
        if (self.cleanup_started or self.outcome == .transferred) return;
        self.cleanup_started = true;
        c.session_pty_startup_cancel(&self.raw);
    }

    /// Cancel once without waiting. It is valid to cancel a ready startup
    /// before transfer; cancellation never signals a transferred child.
    pub fn cancel(self: *Startup) void {
        if (self.outcome == .transferred or self.cleanup_started) return;
        self.outcome = .cancelled;
        self.startCleanup();
    }

    /// Nonblocking cleanup progress. The reactor must retain cancelled/failed
    /// objects and call this again on child-exit wakeups or bounded timer ticks.
    pub fn reap(self: *Startup) !bool {
        if (!self.cleanup_started) return error.CleanupNotStarted;
        if (self.scope_cleanup) {
            if (self.raw.pid <= 0) return true;
            if (self.scope_context == null) self.scope_context = try scope.Context.init();
            const result = try self.scope_context.?.step(self.raw.pid, true);
            if (result.complete) {
                self.raw.pid = -1;
                self.scope_context.?.deinit();
                self.scope_context = null;
            }
            return result.complete;
        }
        return switch (c.session_pty_startup_reap(&self.raw, 0)) {
            0 => false,
            1 => true,
            else => error.StartupReapFailed,
        };
    }

    /// Final owner teardown for tests/process shutdown. May wait for SIGKILL
    /// completion; use cancel plus reap in the live reactor instead.
    pub fn deinit(self: *Startup) void {
        self.tryDeinit() catch |err| std.log.err("startup cleanup incomplete: {s}; ownership retained", .{@errorName(err)});
    }

    pub fn tryDeinit(self: *Startup) !void {
        if (self.outcome == .transferred) return;
        self.cancel();
        if (self.scope_cleanup) {
            var clock = try std.time.Timer.start();
            while (!try self.reap()) {
                if (clock.read() >= 2 * std.time.ns_per_s) return error.StartupCleanupTimedOut;
                std.Thread.sleep(std.time.ns_per_ms);
            }
        } else {
            while (c.session_pty_startup_reap(&self.raw, 1) == 0) {}
        }
    }
};

fn awaitOutcome(startup: *Startup) !Outcome {
    var limit = try std.time.Timer.start();
    while (limit.read() < 6 * std.time.ns_per_s) {
        const result = startup.poll();
        if (result != .pending) return result;
        var descriptors = [_]std.posix.pollfd{.{ .fd = startup.reportDescriptor().?, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.poll(&descriptors, startup.maximumWaitMilliseconds(50));
    }
    return error.TestTimedOut;
}

test "asynchronous startup transfers a real child exactly once" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf ASYNC_READY; sleep 1" };
    const env = [_:null]?[*:0]const u8{};
    var startup = try Startup.begin("/", "/bin/sh", &argv, &env, 24, 80);
    defer startup.deinit();
    try std.testing.expectEqual(.ready, try awaitOutcome(&startup));
    var process = try startup.takeProcess();
    defer process.destroy();
    try std.testing.expect(process.pid > 0 and process.master >= 0);
    const master_flags = try std.posix.fcntl(process.master, std.posix.F.GETFL, 0);
    const nonblock_mask: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    try std.testing.expect(master_flags & nonblock_mask != 0);
    try std.testing.expect((try std.posix.fcntl(process.master, std.posix.F.GETFD, 0)) & std.posix.FD_CLOEXEC != 0);
    try std.testing.expectError(error.StartupNotReady, startup.takeProcess());
    startup.cancel();
    try std.testing.expectEqual(.transferred, startup.poll());
    var descriptors = [_]std.posix.pollfd{.{ .fd = process.master, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&descriptors, 2000);
    var buffer: [128]u8 = undefined;
    const count = try std.posix.read(process.master, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..count], "ASYNC_READY") != null);
}

test "asynchronous startup preserves cwd and exec failure stage and errno" {
    const argv = [_:null]?[*:0]const u8{"/bin/sh"};
    const env = [_:null]?[*:0]const u8{};
    for ([_]bool{ true, false }) |bad_cwd| {
        var startup = try Startup.begin(if (bad_cwd) "/aster-absent-directory" else "/", if (bad_cwd) "/bin/sh" else "/aster-absent-executable", &argv, &env, 24, 80);
        defer startup.deinit();
        const outcome = try awaitOutcome(&startup);
        try std.testing.expect(outcome == .failed);
        try std.testing.expectEqual(@as(c_int, if (bad_cwd) 1 else 2), outcome.failed.stage);
        try std.testing.expectEqual(@as(c_int, c.ENOENT), outcome.failed.errno_value);
        try std.testing.expect(startup.raw.master == -1 and startup.reportDescriptor() == null);
    }
}

test "asynchronous startup cancellation closes flooding PTY before reaping" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "while :; do printf flood; done" };
    const env = [_:null]?[*:0]const u8{};
    var startup = try Startup.begin("/", "/bin/sh", &argv, &env, 24, 80);
    defer startup.deinit();
    try std.testing.expectEqual(.ready, try awaitOutcome(&startup));
    startup.cancel();
    startup.cancel();
    try std.testing.expectEqual(.cancelled, startup.poll());
    try std.testing.expectEqual(@as(c_int, -1), startup.raw.master);
    var limit = try std.time.Timer.start();
    while (!try startup.reap()) {
        if (limit.read() > 2 * std.time.ns_per_s) return error.TestTimedOut;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(c_int, -1), startup.raw.pid);
    startup.cancel();
    try std.testing.expect(try startup.reap());
}

// Pipe-only fixtures exercise partial reports and deadlines without delaying
// a real pre-exec child or introducing unsafe post-fork test hooks.
fn reportFixture() !struct { startup: Startup, writer: std.posix.fd_t } {
    const pipe = try std.posix.pipe();
    errdefer {
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
    }
    const flags = try std.posix.fcntl(pipe[0], std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(pipe[0], std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
    return .{ .startup = .{ .raw = .{ .pid = -1, .master = -1, .report = pipe[0], .stage = 0, .failure = 0, .bytes = undefined, .received = 0 }, .timer = try std.time.Timer.start() }, .writer = pipe[1] };
}

test "partial startup report fails on EOF rather than pretending exec success" {
    var fixture = try reportFixture();
    defer fixture.startup.deinit();
    _ = try std.posix.write(fixture.writer, &.{1});
    std.posix.close(fixture.writer);
    try std.testing.expectEqual(.pending, fixture.startup.poll());
    const result = fixture.startup.poll();
    try std.testing.expect(result == .failed);
    try std.testing.expectEqual(@as(c_int, c.EPROTO), result.failed.errno_value);
}

test "pending startup uses a fixed bounded deadline and cancellation" {
    var fixture = try reportFixture();
    defer fixture.startup.deinit();
    defer std.posix.close(fixture.writer);
    try std.testing.expectEqual(.pending, fixture.startup.poll());
    try std.testing.expect(fixture.startup.maximumWaitMilliseconds(-1) <= 5000);
    fixture.startup.deadline_ns = 0;
    try std.testing.expectEqual(@as(i32, 0), fixture.startup.maximumWaitMilliseconds(1000));
    try std.testing.expectEqual(.timed_out, fixture.startup.poll());
    try std.testing.expectEqual(.timed_out, fixture.startup.poll());
    try std.testing.expect(try fixture.startup.reap());
}

test "startup cancellation is safe before handshake resolves" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "sleep 30" };
    const env = [_:null]?[*:0]const u8{};
    var startup = try Startup.begin("/", "/bin/sh", &argv, &env, 24, 80);
    defer startup.deinit();
    try std.testing.expect(startup.reportDescriptor() != null);
    const fd = startup.reportDescriptor().?;
    try std.testing.expect((try std.posix.fcntl(fd, std.posix.F.GETFD, 0)) & std.posix.FD_CLOEXEC != 0);
    startup.cancel();
    try std.testing.expectEqual(.cancelled, startup.poll());
    try std.testing.expectError(error.StartupNotReady, startup.takeProcess());
}

test "startup rejects malformed complete child reports" {
    var fixture = try reportFixture();
    defer fixture.startup.deinit();
    defer std.posix.close(fixture.writer);
    const report = [_]c_int{ 99, c.ENOENT };
    _ = try std.posix.write(fixture.writer, std.mem.asBytes(&report));
    const result = fixture.startup.poll();
    try std.testing.expect(result == .failed);
    try std.testing.expectEqual(@as(c_int, c.EPROTO), result.failed.errno_value);
}
