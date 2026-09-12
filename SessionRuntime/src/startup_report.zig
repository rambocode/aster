const std = @import("std");

/// Private parent/child startup report, unrelated to the public RPC wire format.
/// The writer must close after its single report. A complete frame without EOF
/// is not ready: this catches retained writers and incomplete initialization.
pub const Outcome = enum(u8) { ready = 1, already_running = 2, initialization_failed = 3 };
const magic = "ASR1";
const frame_size = 5;

pub const Channel = struct {
    reader: Reader,
    writer: Writer,

    /// Both descriptors are nonblocking and close-on-exec. After fork each side
    /// closes the descriptor it does not own before doing any startup work.
    pub fn create() !Channel {
        const pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        return .{ .reader = .{ .fd = pipe[0] }, .writer = .{ .fd = pipe[1] } };
    }
};

pub const Reader = struct {
    fd: ?std.posix.fd_t,

    pub fn close(self: *Reader) void {
        if (self.fd) |fd| std.posix.close(fd);
        self.fd = null;
    }

    /// Consumes the descriptor. Timeout, EOF before a complete report, malformed
    /// reports and unavailable channels fail closed; none imply startup success.
    /// A timeout does not prove the child stopped: the caller must query its
    /// service identity before deciding whether another start is safe.
    pub fn wait(self: *Reader, timeout_ms: u32) !Outcome {
        defer self.close();
        if (timeout_ms == 0 or timeout_ms > 60_000) return error.InvalidStartupTimeout;
        const fd = self.fd orelse return error.StartupChannelClosed;
        var timer = try std.time.Timer.start();
        const budget = @as(u64, timeout_ms) * std.time.ns_per_ms;
        var buffer: [frame_size + 1]u8 = undefined;
        var used: usize = 0;
        while (true) {
            const elapsed = timer.read();
            if (elapsed >= budget) return error.StartupTimedOut;
            const remaining = (budget - elapsed + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, @intCast(remaining)) == 0) continue;
            if (fds[0].revents & std.posix.POLL.NVAL != 0) return error.StartupChannelClosed;
            const count = std.posix.read(fd, buffer[used..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) {
                if (used != frame_size) return error.StartupReportTruncated;
                if (!std.mem.eql(u8, buffer[0..4], magic)) return error.InvalidStartupReport;
                return switch (buffer[4]) {
                    1 => .ready,
                    2 => .already_running,
                    3 => .initialization_failed,
                    else => error.InvalidStartupReport,
                };
            }
            used += count;
            if (used > frame_size) return error.InvalidStartupReport;
        }
    }
};

pub const Writer = struct {
    fd: ?std.posix.fd_t,

    pub fn close(self: *Writer) void {
        if (self.fd) |fd| std.posix.close(fd);
        self.fd = null;
    }

    /// Reports once and closes even on error. The five-byte write is atomic for
    /// an empty POSIX pipe. A disappeared parent must not be treated as notified.
    pub fn finish(self: *Writer, outcome: Outcome) !void {
        defer self.close();
        const fd = self.fd orelse return error.StartupChannelClosed;
        const frame = [_]u8{ 'A', 'S', 'R', '1', @intFromEnum(outcome) };
        if (try std.posix.write(fd, &frame) != frame.len) return error.StartupReportTruncated;
    }
};

test "startup outcomes are explicit and consume both descriptors" {
    for ([_]Outcome{ .ready, .already_running, .initialization_failed }) |outcome| {
        var channel = try Channel.create();
        defer channel.reader.close();
        defer channel.writer.close();
        try channel.writer.finish(outcome);
        try std.testing.expectEqual(outcome, try channel.reader.wait(100));
        try std.testing.expect(channel.writer.fd == null and channel.reader.fd == null);
        try std.testing.expectError(error.StartupChannelClosed, channel.writer.finish(.ready));
    }
}

test "partial oversized and unknown reports never announce readiness" {
    for ([_][]const u8{ "", "AS", "ASR1", "BAD!\x01", "ASR1\xff", "ASR1\x01extra" }) |bytes| {
        var channel = try Channel.create();
        defer channel.reader.close();
        defer channel.writer.close();
        _ = try std.posix.write(channel.writer.fd.?, bytes);
        channel.writer.close();
        if (bytes.len < frame_size) {
            try std.testing.expectError(error.StartupReportTruncated, channel.reader.wait(100));
        } else {
            try std.testing.expectError(error.InvalidStartupReport, channel.reader.wait(100));
        }
    }
}

test "a retained writer causes bounded timeout even after a full ready frame" {
    var channel = try Channel.create();
    defer channel.reader.close();
    defer channel.writer.close();
    _ = try std.posix.write(channel.writer.fd.?, "ASR1\x01");
    try std.testing.expectError(error.StartupTimedOut, channel.reader.wait(15));
}

test "lost parent and invalid timeouts fail explicitly" {
    var channel = try Channel.create();
    defer channel.writer.close();
    channel.reader.close();
    try std.testing.expectError(error.BrokenPipe, channel.writer.finish(.ready));
    var second = try Channel.create();
    defer second.writer.close();
    try std.testing.expectError(error.InvalidStartupTimeout, second.reader.wait(0));
}

test "detached child reports ready only after its locked socket is available" {
    const StateDirectory = @import("state_directory.zig").StateDirectory;
    const socket = @import("service_socket.zig");
    const ServiceInstance = @import("service_instance.zig").ServiceInstance;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var channel = try Channel.create();
    defer channel.reader.close();
    defer channel.writer.close();
    const stop = try std.posix.pipe();
    const pid = try std.posix.fork();
    if (pid == 0) {
        channel.reader.close();
        std.posix.close(stop[1]);
        _ = std.posix.setsid() catch std.posix.exit(2);
        var instance = ServiceInstance.open(tmp.dir, "session") catch std.posix.exit(3);
        channel.writer.finish(.ready) catch std.posix.exit(6);
        var byte: [1]u8 = undefined;
        _ = std.posix.read(stop[0], &byte) catch std.posix.exit(7);
        instance.close() catch std.posix.exit(8);
        std.posix.exit(0);
    }
    channel.writer.close();
    std.posix.close(stop[0]);
    // Even a failed assertion releases and reaps the owned test child.
    defer {
        std.posix.close(stop[1]);
        _ = std.posix.waitpid(pid, 0);
    }
    try std.testing.expectEqual(Outcome.ready, try channel.reader.wait(3000));
    try std.testing.expectError(error.AlreadyRunning, StateDirectory.acquire(tmp.dir, "session"));
    var directory = try tmp.dir.openDir("session", .{});
    defer directory.close();
    var original = try std.fs.cwd().openDir(".", .{});
    defer original.close();
    try std.posix.fchdir(directory.fd);
    defer std.posix.fchdir(original.fd) catch @panic("test cwd restoration failed");
    const client = try std.net.connectUnixSocket(socket.socket_name);
    client.close();
}

test "child initialization failure is distinct from readiness" {
    const StateDirectory = @import("state_directory.zig").StateDirectory;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("unsafe");
    var unsafe = try tmp.dir.openDir("unsafe", .{});
    defer unsafe.close();
    try std.posix.fchmod(unsafe.fd, 0o755);
    var channel = try Channel.create();
    defer channel.reader.close();
    defer channel.writer.close();
    const pid = try std.posix.fork();
    if (pid == 0) {
        channel.reader.close();
        var state = StateDirectory.acquire(tmp.dir, "unsafe") catch {
            channel.writer.finish(.initialization_failed) catch std.posix.exit(2);
            std.posix.exit(0);
        };
        state.deinit();
        std.posix.exit(3);
    }
    channel.writer.close();
    defer _ = std.posix.waitpid(pid, 0);
    try std.testing.expectEqual(Outcome.initialization_failed, try channel.reader.wait(3000));
}

test "duplicate child reports already running and leaves the lock owner intact" {
    const StateDirectory = @import("state_directory.zig").StateDirectory;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var owner = try StateDirectory.acquire(tmp.dir, "session");
    defer owner.deinit();
    const identity = try std.posix.fstat(owner.lock_fd);
    var channel = try Channel.create();
    defer channel.reader.close();
    defer channel.writer.close();
    const pid = try std.posix.fork();
    if (pid == 0) {
        channel.reader.close();
        var other = StateDirectory.acquire(tmp.dir, "session") catch |err| {
            if (err != error.AlreadyRunning) std.posix.exit(2);
            channel.writer.finish(.already_running) catch std.posix.exit(3);
            std.posix.exit(0);
        };
        other.deinit();
        std.posix.exit(4);
    }
    channel.writer.close();
    defer _ = std.posix.waitpid(pid, 0);
    try std.testing.expectEqual(Outcome.already_running, try channel.reader.wait(3000));
    try std.testing.expectEqual(identity.ino, (try std.posix.fstat(owner.lock_fd)).ino);
    try std.testing.expectError(error.AlreadyRunning, StateDirectory.acquire(tmp.dir, "session"));
}
