//! Streaming CLI entry point for the session event stream.
//!
//! `aster-session event subscribe <state-parent> <name>` opens one ordinary
//! control connection to a named session, completes the handshake, and then
//! relays every broadcast event to stdout as JSON Lines. The envelope is copied
//! byte for byte off the wire: this process is a pipe, not a translator, so the
//! shape stays exactly what `protocol/events.schema.json` describes and the
//! consumer alone decides what a sequence gap or a foreign target means.
const std = @import("std");
const transport = @import("service_client.zig");
const handshake = @import("handshake.zig");
const identity = @import("service_identity.zig");
const requests = @import("operation_request.zig");
const replies = @import("operation_response.zig");
const control = @import("service_control.zig");
const protocol = @import("protocol.zig");
const c = @cImport({
    @cInclude("bridge_signals.h");
    @cInclude("signal.h");
});

/// Bound on connect, handshake and each keepalive round trip.
const handshake_timeout_ms: u32 = 10_000;
/// The reactor drops a control connection that has been silent for 30s, and a
/// pure listener never writes. One cheap `health.check` well inside that window
/// keeps the subscription alive without asking the service for new behaviour.
const keepalive_interval_ns: u64 = 10 * std.time.ns_per_s;
/// Events that arrive between the handshake and the baseline reply are held
/// back so the first stdout line is still the handshake line. The one-shot
/// client uses the same bound before it declares the peer unreasonable.
const maximum_deferred_events: usize = 256;

/// Runs the subscription until a stop signal arrives (clean return) or the
/// connection ends (error, reported by the caller as a non-zero exit).
pub fn run(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8) !void {
    const wake = c.session_bridge_signals_start();
    if (wake < 0) return error.ServiceSignalSetupFailed;
    defer c.session_bridge_signals_stop();

    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    const info = try std.posix.fstat(parent.fd);
    if (info.uid != std.posix.geteuid() or info.mode & 0o077 != 0) return error.UnsafeStateParent;

    var deadline = try transport.Deadline.init(handshake_timeout_ms);
    const stream = try transport.connect(parent, name, &deadline);
    defer stream.close();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const hello_bytes = try transport.readFrame(allocator, stream, &deadline);
    defer allocator.free(hello_bytes);
    const hello = try std.json.parseFromSlice(handshake.Hello, arena.allocator(), hello_bytes, .{ .ignore_unknown_fields = true });
    // A P1-only service never broadcasts structural events; refusing here beats
    // handing the client an eternally silent stream it cannot distinguish from
    // an idle session.
    try hello.value.negotiateRequired(&.{ "health_check", "session_snapshot" });

    var frames = Frames{ .allocator = allocator };
    defer frames.deinit();

    // The baseline revision comes from a real correlated reply, not from the
    // handshake frame, because Hello carries no revision at all.
    var deferred: std.ArrayList([]u8) = .empty;
    defer {
        for (deferred.items) |item| allocator.free(item);
        deferred.deinit(allocator);
    }
    const request_id = try sendHealthCheck(allocator, stream, &deadline, hello.value);
    const revision = try awaitRevision(allocator, stream, &deadline, &frames, hello.value, &request_id, &deferred);

    const line = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "subscribed",
        .protocolMajor = hello.value.protocolMajor,
        .protocolMinor = hello.value.protocolMinor,
        .serverID = hello.value.serverID,
        .serverEpoch = hello.value.serverEpoch,
        .sessionID = hello.value.sessionID,
        .revision = revision,
    }, .{});
    defer allocator.free(line);
    try writeLine(line);
    for (deferred.items) |item| try writeLine(item);

    try relay(allocator, stream, &frames, hello.value, wake);
}

/// Reads frames until this connection ends or a stop signal arrives. Events go
/// to stdout verbatim; keepalive replies are consumed and dropped.
fn relay(allocator: std.mem.Allocator, stream: std.net.Stream, frames: *Frames, hello: handshake.Hello, wake: std.posix.fd_t) !void {
    var since_keepalive = try std.time.Timer.start();
    while (true) {
        const signal = c.session_bridge_signals_take();
        if (signal < 0) return error.ServiceSignalReadFailed;
        if (signal == c.SIGTERM or signal == c.SIGINT or signal == c.SIGHUP) return;
        while (try frames.take()) |bytes| {
            defer allocator.free(bytes);
            if (try classify(allocator, bytes) == .event) try writeLine(bytes);
        }
        if (since_keepalive.read() >= keepalive_interval_ns) {
            var beat = try transport.Deadline.init(handshake_timeout_ms);
            _ = try sendHealthCheck(allocator, stream, &beat, hello);
            since_keepalive.reset();
        }
        var fds = [_]std.posix.pollfd{
            .{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = wake, .events = std.posix.POLL.IN, .revents = 0 },
        };
        // poll restarts itself on EINTR; the wake pipe is what actually makes a
        // stop signal visible without waiting out the timeout.
        _ = try std.posix.poll(&fds, 250);
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            if (!try frames.fill(stream.handle)) return error.ServiceDisconnected;
        } else if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
            return error.ServiceDisconnected;
        }
    }
}

const Message = enum { event, other };

/// Classifies one frame without rewriting it. Embedded newlines would corrupt
/// the JSON Lines contract, so a frame carrying one fails the subscription
/// instead of silently splitting into two bogus records.
fn classify(allocator: std.mem.Allocator, bytes: []const u8) !Message {
    if (std.mem.indexOfScalar(u8, bytes, '\n') != null or std.mem.indexOfScalar(u8, bytes, '\r') != null)
        return error.InvalidServiceFrame;
    const scratch = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(scratch);
    var bounded = std.heap.FixedBufferAllocator.init(scratch);
    const tag = std.json.parseFromSlice(struct { type: []const u8 }, bounded.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidServiceFrame;
    defer tag.deinit();
    return if (std.mem.eql(u8, tag.value.type, "event")) .event else .other;
}

/// Issues one empty `health.check` and returns its requestID so the caller can
/// correlate the reply. Also serves as the idle keepalive.
fn sendHealthCheck(allocator: std.mem.Allocator, stream: std.net.Stream, deadline: *transport.Deadline, hello: handshake.Hello) ![36]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_id = identity.uuidText(identity.newUUID());
    const client_id = identity.uuidText(identity.newUUID());
    const request = requests.Request{
        .type = "request",
        .requestID = &request_id,
        .clientID = &client_id,
        .scope = .session,
        .operation = .@"health.check",
        .target = .{ .serverID = hello.serverID, .serverEpoch = hello.serverEpoch, .sessionID = hello.sessionID },
        .params = .{ .object = std.json.ObjectMap.init(arena.allocator()) },
    };
    try request.validateEnvelope();
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), request, .{ .emit_null_optional_fields = false });
    if (encoded.len > protocol.maximum_control_bytes) return error.RequestTooLarge;
    var header: [5]u8 = undefined;
    header[0] = 1;
    std.mem.writeInt(u32, header[1..5], @intCast(encoded.len), .big);
    try transport.writeAll(stream, &header, deadline);
    try transport.writeAll(stream, encoded, deadline);
    return request_id;
}

/// Waits for the correlated `health.check` reply and returns its revision.
/// Events seen first are retained in order: dropping them here would open a
/// silent gap the consumer could never detect.
fn awaitRevision(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    deadline: *transport.Deadline,
    frames: *Frames,
    hello: handshake.Hello,
    request_id: []const u8,
    deferred: *std.ArrayList([]u8),
) !u64 {
    while (true) {
        if (try frames.take()) |bytes| {
            var retained = false;
            defer if (!retained) allocator.free(bytes);
            switch (try classify(allocator, bytes)) {
                .event => {
                    if (deferred.items.len == maximum_deferred_events) return error.TooManyEventsBeforeReply;
                    try deferred.append(allocator, bytes);
                    retained = true;
                },
                .other => return try baselineRevision(allocator, bytes, hello, request_id),
            }
            continue;
        }
        try deadline.wait(stream.handle, std.posix.POLL.IN);
        if (!try frames.fill(stream.handle)) return error.ServiceDisconnected;
    }
}

/// Validates the baseline reply against the request identity and the connection
/// target before trusting its revision.
fn baselineRevision(allocator: std.mem.Allocator, bytes: []const u8, hello: handshake.Hello, request_id: []const u8) !u64 {
    const scratch = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(scratch);
    var bounded = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSlice(replies.Response(struct { alive: bool }), bounded.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidBaselineReply;
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.type, "response") or !std.mem.eql(u8, value.requestID, request_id) or
        value.operation != .@"health.check" or value.scope != .session or !value.result.alive) return error.InvalidBaselineReply;
    const target = value.target orelse return error.InvalidBaselineReply;
    if (!std.mem.eql(u8, target.serverID, hello.serverID) or !std.mem.eql(u8, target.serverEpoch, hello.serverEpoch) or
        !std.mem.eql(u8, target.sessionID, hello.sessionID)) return error.InvalidBaselineReply;
    return value.revision orelse error.InvalidBaselineReply;
}

/// One record, one write: stdout is unbuffered here so every event reaches the
/// consumer as soon as it is decoded.
fn writeLine(bytes: []const u8) !void {
    var vectors = [_]std.posix.iovec_const{
        .{ .base = bytes.ptr, .len = bytes.len },
        .{ .base = "\n", .len = 1 },
    };
    var offset: usize = 0;
    const total = bytes.len + 1;
    while (offset < total) {
        // writev can report a short write; fall back to a plain byte-offset
        // loop rather than assuming the whole record left in one call.
        if (offset == 0) {
            offset += std.posix.writev(std.posix.STDOUT_FILENO, &vectors) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            continue;
        }
        const remaining = if (offset < bytes.len) bytes[offset..] else "\n";
        offset += std.posix.write(std.posix.STDOUT_FILENO, remaining) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
    }
}

/// Incremental length-prefixed frame decoder for a non-blocking socket. The
/// one-shot client blocks per frame against a deadline; a subscription has no
/// deadline, so it must be able to stop mid-frame and come back.
const Frames = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    fn deinit(self: *Frames) void {
        self.buffer.deinit(self.allocator);
    }

    /// Reads whatever is available. Returns false only on a clean peer EOF.
    fn fill(self: *Frames, handle: std.posix.fd_t) !bool {
        var scratch: [65536]u8 = undefined;
        const count = std.posix.read(handle, &scratch) catch |err| switch (err) {
            error.WouldBlock => return true,
            error.ConnectionResetByPeer => return false,
            else => return err,
        };
        if (count == 0) return false;
        try self.buffer.appendSlice(self.allocator, scratch[0..count]);
        if (self.buffer.items.len > 4 * protocol.maximum_control_bytes) return error.ServiceFrameBacklog;
        return true;
    }

    /// Copies out the next complete frame, or null when more bytes are needed.
    fn take(self: *Frames) !?[]u8 {
        if (self.buffer.items.len < 5) return null;
        const size = std.mem.readInt(u32, self.buffer.items[1..][0..4], .big);
        if (self.buffer.items[0] != 1 or size == 0 or size > protocol.maximum_control_bytes) return error.InvalidServiceFrame;
        if (self.buffer.items.len < 5 + size) return null;
        const bytes = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(bytes);
        @memcpy(bytes, self.buffer.items[5 .. 5 + size]);
        try control.checkDepth(bytes);
        const remaining = self.buffer.items.len - (5 + size);
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[5 + size ..]);
        self.buffer.shrinkRetainingCapacity(remaining);
        return bytes;
    }
};

test "frame decoder splits concatenated frames and rejects damaged headers" {
    var frames = Frames{ .allocator = std.testing.allocator };
    defer frames.deinit();
    const first = "{\"type\":\"event\"}";
    const second = "{\"type\":\"response\"}";
    inline for (.{ first, second }) |payload| {
        var header: [5]u8 = undefined;
        header[0] = 1;
        std.mem.writeInt(u32, header[1..5], payload.len, .big);
        try frames.buffer.appendSlice(std.testing.allocator, &header);
        try frames.buffer.appendSlice(std.testing.allocator, payload);
    }
    const one = (try frames.take()).?;
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings(first, one);
    const two = (try frames.take()).?;
    defer std.testing.allocator.free(two);
    try std.testing.expectEqualStrings(second, two);
    try std.testing.expectEqual(@as(?[]u8, null), try frames.take());
    try frames.buffer.appendSlice(std.testing.allocator, &[_]u8{ 9, 0, 0, 0, 1, 0 });
    try std.testing.expectError(error.InvalidServiceFrame, frames.take());
}
