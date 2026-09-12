const std = @import("std");
const c = @cImport({
    @cInclude("bridge_signals.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

test "service signals wake for child exit without consuming wait status" {
    const fd = c.session_bridge_signals_start();
    try std.testing.expect(fd >= 0);
    defer c.session_bridge_signals_stop();
    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) c._exit(7);
    var status: c_int = 0;
    defer _ = c.waitpid(child, &status, 0);
    var descriptors = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&descriptors, 2000);
    try std.testing.expectEqual(c.SIGCHLD, c.session_bridge_signals_take());
    try std.testing.expectEqual(child, c.waitpid(child, &status, c.WNOHANG));
    try std.testing.expectEqual(@as(u8, 7), std.posix.W.EXITSTATUS(@bitCast(status)));
    try std.testing.expectEqual(@as(c_int, 0), c.session_bridge_signals_take());
}

test "service signals preserve termination priority and restore previous child handler" {
    const previous = c.signal(c.SIGCHLD, previousChildHandler);
    defer _ = c.signal(c.SIGCHLD, previous);
    try std.testing.expect(c.session_bridge_signals_start() >= 0);
    var active = true;
    defer if (active) c.session_bridge_signals_stop();
    try std.testing.expectEqual(@as(c_int, 0), c.raise(c.SIGCHLD));
    try std.testing.expectEqual(@as(c_int, 0), c.raise(c.SIGWINCH));
    try std.testing.expectEqual(@as(c_int, 0), c.raise(c.SIGTERM));
    try std.testing.expectEqual(c.SIGTERM, c.session_bridge_signals_take());
    c.session_bridge_signals_stop();
    active = false;
    try std.testing.expect(c.signal(c.SIGCHLD, previousChildHandler) == previousChildHandler);
}

fn previousChildHandler(_: c_int) callconv(.c) void {}
