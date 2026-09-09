const std = @import("std");
const reports = @import("startup_report.zig");
const identities = @import("service_identity.zig");
const client = @import("service_client.zig");
const StateDirectory = @import("state_directory.zig").StateDirectory;
const c = @cImport({
    @cInclude("daemon.h");
});

/// CLI-only launcher: parent is single-threaded and exits after reporting.
/// Readiness is bound to a parent-generated epoch so a replacement server cannot
/// be mistaken for the child we just launched. Unknown outcomes never kill PIDs.
pub fn start(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8) ![]u8 {
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    return startAt(allocator, parent, name);
}

/// Same contract as `start`, driven by an already-open registry parent handle so
/// a running service can start a sibling session without re-resolving a path.
pub fn startAt(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8) ![]u8 {
    try StateDirectory.validateName(name);
    const info = try std.posix.fstat(parent.fd);
    if (info.uid != std.posix.geteuid() or info.mode & 0o077 != 0) return error.UnsafeStateParent;
    var clock = try std.time.Timer.start();
    const epoch = identities.newUUID();
    var channel = try reports.Channel.create();
    defer channel.reader.close();
    defer channel.writer.close();
    // The standalone launcher owns its children even if its invoking shell
    // ignored SIGCHLD; waitpid must not encounter an auto-reaped child.
    const child_action = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.CHLD, &child_action, null);
    const pid = try std.posix.fork();
    if (pid == 0) {
        channel.reader.close();
        var parent_fd = parent.fd;
        var report_fd = channel.writer.fd.?;
        const prepared = c.session_daemon_prepare(&parent_fd, &report_fd);
        channel.writer.fd = report_fd;
        if (prepared != 0) {
            channel.writer.finish(.initialization_failed) catch {};
            std.posix.exit(1);
        }
        @import("service_server.zig").run(allocator, .{ .fd = parent_fd }, name, &channel.writer, epoch) catch std.posix.exit(1);
        std.posix.exit(0);
    }
    channel.writer.close();
    const outcome = channel.reader.wait(5000) catch return error.StartupOutcomeUnknown;
    if (outcome != .ready) _ = std.posix.waitpid(pid, 0);
    if (outcome == .initialization_failed) return error.ServiceInitializationFailed;
    const expected_epoch = identities.uuidText(epoch);
    while (true) {
        const elapsed = clock.read() / std.time.ns_per_ms;
        if (elapsed >= 5000) return error.StartupOutcomeUnknown;
        const reply = client.status(allocator, parent, name, @intCast(@min(3000, 5000 - elapsed))) catch |err| switch (err) {
            error.FileNotFound, error.ConnectionRefused, error.ServiceDisconnected, error.ServiceTimedOut => {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer allocator.free(reply.bytes);
        if (reply.is_error) return error.StartupVerificationFailed;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply.bytes, .{});
        defer parsed.deinit();
        if (outcome == .ready and !std.mem.eql(u8, parsed.value.object.get("target").?.object.get("serverEpoch").?.string, &expected_epoch))
            return error.StartupOutcomeUnknown;
        return std.json.Stringify.valueAlloc(allocator, .{
            .type = "server_start",
            .state = if (outcome == .ready) "started" else "already_running",
            .pid = if (outcome == .ready) @as(?std.posix.pid_t, pid) else null,
            .status = parsed.value,
        }, .{});
    }
}
