const std = @import("std");
const c = @cImport({
    @cInclude("process_scope.h");
    @cInclude("errno.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
});
/// Process-global service initialization, confined to the sole child-reaping
/// thread. Linux adopts orphan descendants; unsupported macOS fails closed.
pub fn initialize() !void {
    try check(c.session_scope_initialize());
}
/// Observes the owned direct child without releasing PID/SID identity.
pub fn observe(root: std.posix.pid_t) !?u32 {
    var exited: c_int = 0;
    var status: c_int = 0;
    try check(c.session_scope_observe(root, &exited, &status));
    return if (exited != 0) @bitCast(status) else null;
}
pub const Result = struct { complete: bool, status: ?u32 };
/// Owned per-terminal cleanup transaction. Never reuse it for a different root.
pub const Context = struct {
    handle: *c.struct_session_scope_context,
    pub fn init() !Context {
        var handle: ?*c.struct_session_scope_context = null;
        try check(c.session_scope_context_create(&handle));
        return .{ .handle = handle.? };
    }
    pub fn deinit(self: *Context) void {
        c.session_scope_context_destroy(self.handle);
        self.* = undefined;
    }
    /// One bounded pass. Successful TERM is remembered by stable identity;
    /// scanning continues for new descendants, and forced KILL can be repeated.
    pub fn step(self: *Context, root: std.posix.pid_t, force: bool) !Result {
        var complete: c_int = 0;
        var status: c_int = 0;
        try check(c.session_scope_context_step(self.handle, root, @intFromBool(force), &complete, &status));
        return .{ .complete = complete != 0, .status = if (complete != 0) @bitCast(status) else null };
    }
};
/// Create a watcher FD for a non-child process exit. Returns -1 on failure.
/// macOS: kqueue EVFILT_PROC NOTE_EXIT; Linux: pidfd_open.
pub fn watchExit(pid: std.posix.pid_t) std.posix.fd_t {
    return c.session_scope_watch_exit(pid);
}

/// Non-blocking check: did the watched process exit?
/// Returns exit status (waitpid-form on macOS, 0 on Linux), or null if still running.
pub fn pollExit(watch_fd: std.posix.fd_t) ?u32 {
    if (watch_fd < 0) return null;
    var exited: c_int = 0;
    var status: c_int = 0;
    if (c.session_scope_poll_exit(watch_fd, &exited, &status) != 0) return null;
    return if (exited != 0) @bitCast(status) else null;
}

/// Close a watcher FD.
pub fn closeWatch(watch_fd: std.posix.fd_t) void {
    c.session_scope_close_watch(watch_fd);
}

fn check(code: c_int) !void {
    if (code == 0) return;
    return switch (code) {
        c.ENOTSUP => error.UnsupportedCleanup,
        c.ECHILD => error.ProcessNotOwned,
        c.EINVAL => error.InvalidProcessScope,
        c.EPERM, c.EACCES => error.ProcessScopePermissionDenied,
        c.ENOMEM => error.OutOfMemory,
        c.EINTR => error.ProcessScopeInterrupted,
        else => error.ProcessScopeFailed,
    };
}
test "process scope rejects unowned identities" {
    try std.testing.expectError(error.InvalidProcessScope, observe(-1));
    try std.testing.expectError(error.ProcessNotOwned, observe(c.getpid()));
}

test "process scope WNOWAIT retains direct child until cleanup completes" {
    try initialize();
    const child = c.fork();
    if (child < 0) return error.TestForkFailed;
    if (child == 0) {
        if (c.setsid() < 0) c._exit(99);
        c._exit(7);
    }
    var reaped = false;
    defer if (!reaped) {
        _ = c.kill(child, c.SIGKILL);
        _ = c.waitpid(child, null, 0);
    };
    var clock = try std.time.Timer.start();
    var observed: ?u32 = null;
    while (observed == null and clock.read() < 3 * std.time.ns_per_s) {
        observed = try observe(child);
        if (observed == null) std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(?u32, 7 << 8), observed);
    try std.testing.expectEqual(observed, try observe(child));
    var context = try Context.init();
    defer context.deinit();
    const result = try context.step(child, true);
    reaped = result.complete;
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(observed, result.status);
    try std.testing.expectError(error.ProcessNotOwned, observe(child));
}
