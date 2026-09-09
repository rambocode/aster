const std = @import("std");
const c = @cImport({
    @cInclude("session_pty.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

pub const Process = struct {
    pid: c.pid_t,
    master: std.posix.fd_t,

    /// Spawns a child with explicit environment and cwd. Ownership includes the
    /// PTY and waitpid responsibility; network disconnect must not call destroy.
    pub fn spawn(cwd: [:0]const u8, executable: [:0]const u8, argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, rows: u16, cols: u16) !Process {
        var master: c_int = -1;
        var stage: c_int = 0;
        const pid = c.session_spawn_pty(cwd, executable, @ptrCast(@constCast(argv)), @ptrCast(@constCast(env)), &master, &stage, rows, cols);
        if (pid < 0) return switch (stage) {
            1 => error.WorkingDirectoryUnavailable,
            2 => error.ExecutableUnavailable,
            else => error.PtyStartupFailed,
        };
        return .{ .pid = pid, .master = master };
    }

    /// Signal only the still-owned child/group. No saved diagnostic PID is used
    /// after waitpid has transferred this process to the reaped state.
    pub fn requestTermination(self: *Process, force: bool) !void {
        if (self.pid <= 0) return error.ProcessAlreadyReaped;
        const signal: u8 = if (force) std.posix.SIG.KILL else std.posix.SIG.TERM;
        std.posix.kill(-self.pid, signal) catch |err| switch (err) {
            error.ProcessNotFound => try std.posix.kill(self.pid, signal),
            else => return err,
        };
    }

    pub fn closeMaster(self: *Process) void {
        if (self.master >= 0) std.posix.close(self.master);
        self.master = -1;
    }

    /// Explicit forced destruction for startup/test cleanup, never detach.
    /// Call only while this struct still owns the unreaped direct child PID.
    pub fn destroy(self: *Process) void {
        if (self.pid > 0) {
            _ = c.kill(-self.pid, c.SIGKILL);
            _ = c.kill(self.pid, c.SIGKILL);
        }
        // A dying writer can wait for its slave output to drain (notably on
        // macOS). Closing the master before waitpid breaks that dependency.
        self.closeMaster();
        if (self.pid > 0) {
            while (true) {
                const result = c.waitpid(self.pid, null, 0);
                if (result >= 0 or std.posix.errno(result) != .INTR) break;
            }
            self.pid = -1;
        }
    }
};

test "PTY uses explicit directory and environment with real shell" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf 'ASTER_PTY:%s:' \"$ASTER_PROBE\"; pwd" };
    const env = [_:null]?[*:0]const u8{"ASTER_PROBE=owned"};
    var process = try Process.spawn("/", "/bin/sh", &argv, &env, 24, 80);
    defer process.destroy();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var timer = try std.time.Timer.start();
    while (timer.read() < 3 * std.time.ns_per_s) {
        var poll = [_]std.posix.pollfd{.{ .fd = process.master, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try std.posix.poll(&poll, 100);
        var buffer: [1024]u8 = undefined;
        const count = std.posix.read(process.master, &buffer) catch |err| switch (err) {
            error.WouldBlock => continue,
            error.InputOutput => break,
            else => return err,
        };
        if (count == 0) break;
        try output.appendSlice(std.testing.allocator, buffer[0..count]);
        if (std.mem.indexOf(u8, output.items, "ASTER_PTY:owned:/") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ASTER_PTY:owned:/") != null);
}

test "startup rejects missing directory and executable without leaking a child" {
    const argv = [_:null]?[*:0]const u8{"/bin/sh"};
    const env = [_:null]?[*:0]const u8{};
    try std.testing.expectError(error.WorkingDirectoryUnavailable, Process.spawn("/aster-test-directory-that-does-not-exist", "/bin/sh", &argv, &env, 24, 80));
    try std.testing.expectError(error.ExecutableUnavailable, Process.spawn("/", "/aster-test-executable-that-does-not-exist", &argv, &env, 24, 80));
}
