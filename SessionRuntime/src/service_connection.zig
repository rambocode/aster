const std = @import("std");
const protocol = @import("protocol.zig");
const Control = @import("service_control.zig").Control;

pub const maximum_pending_bytes = 2 * protocol.maximum_control_bytes + 10;
pub const maximum_surface_pending_bytes = 8 * 1024 * 1024;
const read_budget = 16 * 1024;
const write_budget = 64 * 1024;

/// Owns one authenticated, nonblocking socket and its bounded framing state.
/// Errors terminate only this connection. Control is borrowed per tick, so
/// moving a connection never leaves pointers into an old service value.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    decoder: protocol.Decoder,
    pending: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    read_eof: bool = false,
    failed: bool = false,
    received_bytes: u64 = 0,
    completed_requests: u64 = 0,
    generation: u64 = 0,
    event_sequence: u64 = 0,
    deferred_requests: usize = 0,
    surface_bound: bool = false,
    close_after_flush: bool = false,

    /// Takes ownership of stream even if initialization fails. The listener
    /// must have authenticated peer UID and enabled nonblocking I/O first.
    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, control: *const Control) !Connection {
        var value = Connection{ .allocator = allocator, .stream = stream, .decoder = protocol.Decoder.init(allocator) };
        errdefer value.deinit();
        const hello = try std.json.Stringify.valueAlloc(allocator, control.hello(), .{});
        defer allocator.free(hello);
        try value.enqueue(hello);
        return value;
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close();
        self.decoder.deinit();
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn finished(self: *const Connection) bool {
        return (self.read_eof or self.close_after_flush) and !self.surface_bound and self.deferred_requests == 0 and self.sent == self.pending.items.len;
    }

    /// Bounded read/parse/write work lets the service visit every other client
    /// and PTY. A half-closed peer still receives already-generated responses.
    pub fn tick(self: *Connection, control: *Control) !void {
        if (self.failed) return error.ConnectionFailed;
        errdefer self.failed = true;
        var writable: usize = write_budget;
        try self.flush(&writable);
        var buffer: [4096]u8 = undefined;
        var remaining: usize = read_budget;
        while (!self.read_eof and !self.close_after_flush and remaining != 0) {
            const count = self.stream.read(buffer[0..@min(buffer.len, remaining)]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (count == 0) {
                try self.decoder.finish();
                self.read_eof = true;
                break;
            }
            remaining -= count;
            self.received_bytes +|= count;
            var offset: usize = 0;
            while (offset < count and !self.close_after_flush) {
                var consumed: usize = 0;
                const frame = try self.decoder.feed(buffer[offset..count], &consumed);
                offset += consumed;
                if (frame) |value| {
                    if (value.kind != .control) return error.UnexpectedFrameKind;
                    if (self.deferred_requests >= 64) return error.TooManyPendingRequests;
                    if (try control.respondForConnection(self.allocator, value.payload, self.generation)) |response| {
                        defer self.allocator.free(response);
                        try self.enqueue(response);
                    } else self.deferred_requests += 1;
                    self.completed_requests +|= 1;
                }
            }
        }
        try self.flush(&writable);
    }

    /// Shutdown drains generated replies without reading or accepting new work.
    pub fn drain(self: *Connection) !bool {
        if (self.failed) return error.ConnectionFailed;
        errdefer self.failed = true;
        var writable: usize = write_budget;
        try self.flush(&writable);
        return self.sent == self.pending.items.len;
    }

    /// Deferred completion and events retain the same output bounds as normal
    /// replies. A slow or vanished peer never owns the terminal mutation.
    pub fn deliver(self: *Connection, bytes: []const u8, completes_request: bool) !void {
        if (self.failed) return error.ConnectionFailed;
        try self.enqueue(bytes);
        if (completes_request) {
            if (self.deferred_requests == 0) return error.UnexpectedDeferredReply;
            self.deferred_requests -= 1;
        }
    }

    /// Called only after domain authorization binds a dedicated surface
    /// connection to one attachment. This does not grant PTY write ownership.
    pub fn bindSurface(self: *Connection) !void {
        if (self.surface_bound) return error.SurfaceAlreadyBound;
        self.surface_bound = true;
    }

    pub fn availableWireBytes(self: *const Connection) usize {
        const maximum = if (self.surface_bound) maximum_surface_pending_bytes else maximum_pending_bytes;
        return maximum - (self.pending.items.len - self.sent);
    }

    /// Surface begin/chunk/end use this path; they are not request completions
    /// or lifecycle events and do not consume either counter.
    pub fn deliverSurfaceFrame(self: *Connection, kind: protocol.Kind, bytes: []const u8) !void {
        if (!self.surface_bound) return error.SurfaceNotBound;
        if (self.failed) return error.ConnectionFailed;
        try self.enqueueFrame(kind, bytes);
    }

    fn enqueue(self: *Connection, bytes: []const u8) !void {
        return self.enqueueFrame(.control, bytes);
    }

    fn enqueueFrame(self: *Connection, kind: protocol.Kind, bytes: []const u8) !void {
        const frame_limit = if (kind == .control) protocol.maximum_control_bytes else protocol.maximum_surface_bytes;
        if (bytes.len == 0 or bytes.len > frame_limit) return error.InvalidResponseSize;
        const maximum = if (self.surface_bound) maximum_surface_pending_bytes else maximum_pending_bytes;
        const remaining = self.pending.items.len - self.sent;
        if (remaining + bytes.len + 5 > maximum) return error.SlowConsumer;
        if (self.sent != 0 and (self.sent >= self.pending.items.len / 2 or self.pending.items.len + bytes.len + 5 > maximum)) {
            std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[self.sent..]);
            self.pending.shrinkRetainingCapacity(remaining);
            self.sent = 0;
        }
        // Allocate before appending the header so failure cannot leave a partial
        // frame in an otherwise reusable queue.
        try self.pending.ensureUnusedCapacity(self.allocator, bytes.len + 5);
        var header: [5]u8 = undefined;
        header[0] = @intFromEnum(kind);
        std.mem.writeInt(u32, header[1..5], @intCast(bytes.len), .big);
        self.pending.appendSliceAssumeCapacity(&header);
        self.pending.appendSliceAssumeCapacity(bytes);
    }

    fn flush(self: *Connection, remaining: *usize) !void {
        while (self.sent < self.pending.items.len and remaining.* != 0) {
            const bytes = self.pending.items[self.sent..][0..@min(self.pending.items.len - self.sent, remaining.*)];
            // Per-write suppression works on Linux and macOS without changing
            // the whole process's SIGPIPE disposition.
            const written = std.posix.send(self.stream.handle, bytes, std.posix.MSG.NOSIGNAL) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (written == 0) return error.ConnectionClosed;
            self.sent += written;
            remaining.* -= written;
        }
        if (self.sent == self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            self.sent = 0;
        }
    }
};

const Instance = @import("service_instance.zig").ServiceInstance;
const socket_name = @import("service_socket.zig").socket_name;
const Fixture = struct {
    tmp: std.testing.TmpDir,
    instance: Instance,
    control: Control,
    client: std.net.Stream,
    connection: Connection,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var instance = try Instance.open(tmp.dir, "session");
        errdefer instance.close() catch {};
        const control = Control.init(instance.identity, instance.epoch);
        const client = try std.net.connectUnixSocket(socket_name);
        errdefer client.close();
        const accepted = (try instance.socket.accept()).?;
        const connection = try Connection.init(std.testing.allocator, accepted.stream, &control);
        return .{ .tmp = tmp, .instance = instance, .control = control, .client = client, .connection = connection };
    }

    fn deinit(self: *Fixture) void {
        self.connection.deinit();
        self.client.close();
        self.instance.close() catch @panic("test service cleanup failed");
        self.tmp.cleanup();
    }
};

fn healthFrame(control: *const Control) ![]u8 {
    const allocator = std.testing.allocator;
    const body = try std.fmt.allocPrint(allocator, "{{\"type\":\"request\",\"requestID\":\"00000000-0000-4000-8000-000000000001\",\"clientID\":\"00000000-0000-4000-8000-000000000002\",\"scope\":\"session\",\"operation\":\"health.check\",\"target\":{{\"serverID\":\"{s}\",\"serverEpoch\":\"{s}\",\"sessionID\":\"{s}\"}},\"params\":{{}}}}", .{ control.server_id, control.epoch, control.session_id });
    defer allocator.free(body);
    const wire = try allocator.alloc(u8, body.len + 5);
    wire[0] = 1;
    std.mem.writeInt(u32, wire[1..5], @intCast(body.len), .big);
    @memcpy(wire[5..], body);
    return wire;
}

fn readExactly(stream: std.net.Stream, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var events = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&events, 1000) == 0) return error.TestReadTimedOut;
        const count = try stream.read(bytes[offset..]);
        if (count == 0) return error.TestUnexpectedEOF;
        offset += count;
    }
}

fn readJSON(stream: std.net.Stream) !std.json.Parsed(std.json.Value) {
    var header: [5]u8 = undefined;
    try readExactly(stream, &header);
    try std.testing.expectEqual(@as(u8, 1), header[0]);
    const count = std.mem.readInt(u32, header[1..5], .big);
    if (count > protocol.maximum_control_bytes) return error.InvalidFrameLength;
    const bytes = try std.testing.allocator.alloc(u8, count);
    defer std.testing.allocator.free(bytes);
    try readExactly(stream, bytes);
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{ .allocate = .alloc_always });
}

test "authenticated socket sends hello before a byte-fragmented health response" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.connection.tick(&fixture.control);
    const hello = try readJSON(fixture.client);
    defer hello.deinit();
    try std.testing.expectEqualStrings("hello", hello.value.object.get("type").?.string);
    try std.testing.expectEqualStrings(&fixture.control.server_id, hello.value.object.get("serverID").?.string);
    const wire = try healthFrame(&fixture.control);
    defer std.testing.allocator.free(wire);
    for (wire) |byte| {
        try fixture.client.writeAll(&.{byte});
        try fixture.connection.tick(&fixture.control);
    }
    const reply = try readJSON(fixture.client);
    defer reply.deinit();
    try std.testing.expect(reply.value.object.get("result").?.object.get("alive").?.bool);
}

test "write half-close drains the final reply before finishing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const wire = try healthFrame(&fixture.control);
    defer std.testing.allocator.free(wire);
    try fixture.client.writeAll(wire);
    try std.posix.shutdown(fixture.client.handle, .send);
    try fixture.connection.tick(&fixture.control);
    try std.testing.expect(fixture.connection.finished());
    const hello = try readJSON(fixture.client);
    defer hello.deinit();
    const reply = try readJSON(fixture.client);
    defer reply.deinit();
    try std.testing.expect(reply.value.object.get("result").?.object.get("alive").?.bool);
}

test "invalid frame fails only its connection" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.client.writeAll(&.{ 2, 0, 0, 0, 1, 0 });
    try std.testing.expectError(error.UnexpectedFrameKind, fixture.connection.tick(&fixture.control));
    try std.testing.expectError(error.ConnectionFailed, fixture.connection.tick(&fixture.control));
    const client = try std.net.connectUnixSocket(socket_name);
    defer client.close();
    const accepted = (try fixture.instance.socket.accept()).?;
    var other = try Connection.init(std.testing.allocator, accepted.stream, &fixture.control);
    defer other.deinit();
    const wire = try healthFrame(&fixture.control);
    defer std.testing.allocator.free(wire);
    try client.writeAll(wire);
    try other.tick(&fixture.control);
    const hello = try readJSON(client);
    defer hello.deinit();
    const reply = try readJSON(client);
    defer reply.deinit();
    try std.testing.expect(reply.value.object.get("result").?.object.get("alive").?.bool);
}

test "response queue is bounded before accepting more output" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.connection.tick(&fixture.control);
    const bytes = try std.testing.allocator.alloc(u8, protocol.maximum_control_bytes);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try fixture.connection.enqueue(bytes);
    try fixture.connection.enqueue(bytes);
    const before = fixture.connection.pending.items.len;
    try std.testing.expectError(error.SlowConsumer, fixture.connection.enqueue("{}"));
    try std.testing.expectEqual(before, fixture.connection.pending.items.len);
}

test "peer shutdown cannot terminate the service with SIGPIPE" {
    const pid = try std.posix.fork();
    if (pid == 0) {
        const action = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(std.posix.SIG.PIPE, &action, null);
        // Construct both ends here so the parent cannot retain a peer handle.
        var fixture = Fixture.init() catch std.posix.exit(2);
        fixture.client.close();
        const code: u8 = if (fixture.connection.tick(&fixture.control)) |_| 3 else |_| 0;
        fixture.connection.deinit();
        fixture.instance.close() catch std.posix.exit(4);
        fixture.tmp.cleanup();
        std.posix.exit(code);
    }
    const result = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.posix.W.IFEXITED(result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(result.status));
}

test "a backed-up socket leaves another client responsive" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const send_buffer: c_int = 1024;
    try std.posix.setsockopt(fixture.connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&send_buffer));
    const bytes = try std.testing.allocator.alloc(u8, protocol.maximum_control_bytes);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try fixture.connection.enqueue(bytes);
    try fixture.connection.tick(&fixture.control);
    try std.testing.expect(fixture.connection.sent <= write_budget);
    try std.testing.expect(fixture.connection.pending.items.len > fixture.connection.sent);

    const client = try std.net.connectUnixSocket(socket_name);
    defer client.close();
    const accepted = (try fixture.instance.socket.accept()).?;
    var other = try Connection.init(std.testing.allocator, accepted.stream, &fixture.control);
    defer other.deinit();
    const wire = try healthFrame(&fixture.control);
    defer std.testing.allocator.free(wire);
    try client.writeAll(wire);
    try other.tick(&fixture.control);
    const hello = try readJSON(client);
    defer hello.deinit();
    const reply = try readJSON(client);
    defer reply.deinit();
    try std.testing.expect(reply.value.object.get("result").?.object.get("alive").?.bool);
}

test "surface frames require binding and preserve independent wire kind and budget" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.connection.tick(&fixture.control);
    const hello = try readJSON(fixture.client);
    defer hello.deinit();
    try std.testing.expectError(error.SurfaceNotBound, fixture.connection.deliverSurfaceFrame(.surface, "abc"));
    try fixture.connection.bindSurface();
    try std.testing.expectError(error.SurfaceAlreadyBound, fixture.connection.bindSurface());
    try std.testing.expectEqual(maximum_surface_pending_bytes, fixture.connection.availableWireBytes());
    try fixture.connection.deliverSurfaceFrame(.surface, "abc");
    try std.testing.expectEqual(maximum_surface_pending_bytes - 8, fixture.connection.availableWireBytes());
    try std.testing.expectEqual(@as(u64, 0), fixture.connection.event_sequence);
    try fixture.connection.tick(&fixture.control);
    var frame: [8]u8 = undefined;
    try readExactly(fixture.client, &frame);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 3, 'a', 'b', 'c' }, &frame);
    const payload = try std.testing.allocator.alloc(u8, protocol.maximum_surface_bytes);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    for (0..31) |_| try fixture.connection.deliverSurfaceFrame(.surface, payload);
    try std.testing.expectError(error.SlowConsumer, fixture.connection.deliverSurfaceFrame(.surface, payload));
}
