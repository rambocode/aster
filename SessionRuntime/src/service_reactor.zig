const std = @import("std");
const Instance = @import("service_instance.zig").ServiceInstance;
const Control = @import("service_control.zig").Control;
const Connection = @import("service_connection.zig").Connection;

pub const Limits = struct {
    maximum_clients: usize = 64,
    idle_timeout_ns: u64 = 30 * std.time.ns_per_s,
    frame_timeout_ns: u64 = 5 * std.time.ns_per_s,
};

pub const Statistics = struct {
    refused_connections: u64 = 0,
    rejected_peers: u64 = 0,
    failed_connections: u64 = 0,
    expired_connections: u64 = 0,
};

/// Single-threaded control scheduler. The caller owns the service instance and
/// supplies monotonic elapsed nanoseconds. A step visits every admitted client;
/// accepting a flood is capped independently of connection I/O work.
pub const Reactor = struct {
    allocator: std.mem.Allocator,
    control: Control,
    limits: Limits,
    clients: std.ArrayList(Client) = .empty,
    statistics: Statistics = .{},
    last_now: u64 = 0,
    next_generation: u64 = 1,
    in_step: bool = false,

    const Client = struct {
        connection: Connection,
        last_read: u64,
        frame_started: ?u64 = null,
        disconnected: bool = false,
        input_closed: bool = false,
        drop_requested: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, instance: *const Instance, limits: Limits) !Reactor {
        if (limits.maximum_clients == 0 or limits.maximum_clients > 64 or
            limits.idle_timeout_ns == 0 or limits.frame_timeout_ns == 0) return error.InvalidServiceLimits;
        var clients: std.ArrayList(Client) = .empty;
        try clients.ensureTotalCapacity(allocator, limits.maximum_clients);
        return .{ .allocator = allocator, .control = Control.init(instance.identity, instance.epoch), .limits = limits, .clients = clients };
    }

    /// Close connections before closing ServiceInstance. No PTY lifecycle is
    /// inferred from these connection closures.
    pub fn deinit(self: *Reactor) void {
        for (self.clients.items) |*client| {
            self.notifyDisconnect(client);
            client.connection.deinit();
        }
        self.clients.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn step(self: *Reactor, instance: *Instance, now: u64) !void {
        if (now < self.last_now) return error.NonMonotonicServiceClock;
        self.last_now = now;
        std.debug.assert(!self.in_step);
        self.in_step = true;
        defer {
            self.in_step = false;
            self.removeRequested();
        }
        for (0..8) |_| {
            const accepted = instance.socket.accept() catch |err| switch (err) {
                error.PeerRejected => {
                    self.statistics.rejected_peers +|= 1;
                    continue;
                },
                else => return err,
            } orelse break;
            if (self.clients.items.len == self.limits.maximum_clients) {
                accepted.stream.close();
                self.statistics.refused_connections +|= 1;
                continue;
            }
            if (self.next_generation == std.math.maxInt(u64)) {
                accepted.stream.close();
                return error.ConnectionGenerationExhausted;
            }
            var connection = Connection.init(self.allocator, accepted.stream, &self.control) catch |err| switch (err) {
                error.OutOfMemory => {
                    self.statistics.refused_connections +|= 1;
                    continue;
                },
                else => return err,
            };
            connection.generation = self.next_generation;
            self.next_generation += 1;
            self.clients.appendAssumeCapacity(.{ .connection = connection, .last_read = now });
        }
        var index: usize = 0;
        while (index < self.clients.items.len) {
            const client = &self.clients.items[index];
            const expired = (!client.connection.surface_bound and now - client.last_read >= self.limits.idle_timeout_ns) or
                (if (client.frame_started) |started| now - started >= self.limits.frame_timeout_ns else false);
            if (client.drop_requested) {
                index += 1;
                continue;
            }
            if (expired) {
                self.statistics.expired_connections +|= 1;
                self.remove(index);
                continue;
            }
            const before_bytes = client.connection.received_bytes;
            const before_requests = client.connection.completed_requests;
            client.connection.tick(&self.control) catch {
                self.statistics.failed_connections +|= 1;
                self.remove(index);
                continue;
            };
            if (client.connection.read_eof) self.notifyInputClosed(client);
            if (client.connection.finished()) {
                self.remove(index);
                continue;
            }
            if (client.connection.received_bytes != before_bytes) client.last_read = now;
            const partial = !client.connection.decoder.complete and client.connection.decoder.header_used != 0;
            if (!partial) {
                client.frame_started = null;
            } else if (client.frame_started == null or client.connection.completed_requests != before_requests) {
                client.frame_started = now;
            }
            index += 1;
        }
    }

    pub fn drain(self: *Reactor) bool {
        var index: usize = 0;
        var complete = true;
        while (index < self.clients.items.len) {
            const done = self.clients.items[index].connection.drain() catch {
                self.remove(index);
                continue;
            };
            complete = complete and done;
            index += 1;
        }
        return complete;
    }

    fn notifyInputClosed(self: *Reactor, client: *Client) void {
        if (client.input_closed) return;
        client.input_closed = true;
        if (self.control.handler) |handler| {
            if (handler.input_closed) |callback| callback(handler.context, client.connection.generation);
        }
    }

    fn notifyDisconnect(self: *Reactor, client: *Client) void {
        if (client.disconnected) return;
        client.disconnected = true;
        if (self.control.handler) |handler| handler.disconnect(handler.context, client.connection.generation);
    }

    /// Deliver to the original connection generation only. Closed generations
    /// are never reused; failed output removes that peer without retrying work.
    /// Sequence only events visible to this connection. Reading a proposed
    /// sequence does not consume it; enqueue success commits it below.
    pub fn nextEventSequence(self: *const Reactor, generation: u64) ?u64 {
        for (self.clients.items) |client| {
            if (client.connection.generation == generation) {
                if (client.connection.event_sequence == std.math.maxInt(u64)) return null;
                return client.connection.event_sequence + 1;
            }
        }
        return null;
    }

    pub fn drop(self: *Reactor, generation: u64) void {
        for (self.clients.items, 0..) |*client, index| {
            if (client.connection.generation == generation) {
                if (self.in_step) {
                    client.drop_requested = true;
                } else self.remove(index);
                return;
            }
        }
    }

    fn removeRequested(self: *Reactor) void {
        var index: usize = 0;
        while (index < self.clients.items.len) {
            if (self.clients.items[index].drop_requested) self.remove(index) else index += 1;
        }
    }

    pub fn deliver(self: *Reactor, generation: u64, bytes: []const u8, completes_request: bool) bool {
        for (self.clients.items, 0..) |*client, index| {
            if (client.connection.generation != generation) continue;
            if (!completes_request and client.connection.event_sequence == std.math.maxInt(u64)) {
                self.remove(index);
                return false;
            }
            client.connection.deliver(bytes, completes_request) catch {
                self.statistics.failed_connections +|= 1;
                self.remove(index);
                return false;
            };
            if (!completes_request) client.connection.event_sequence += 1;
            return true;
        }
        return false;
    }

    /// Snapshot generations before broadcasting so slow-peer removal cannot
    /// invalidate iteration. Surface streams never receive lifecycle events.
    pub fn controlGenerations(self: *const Reactor, buffer: []u64) ![]u64 {
        var used: usize = 0;
        for (self.clients.items) |client| {
            if (client.connection.surface_bound or client.connection.close_after_flush or client.drop_requested) continue;
            if (used == buffer.len) return error.ConnectionBufferTooSmall;
            buffer[used] = client.connection.generation;
            used += 1;
        }
        return buffer[0..used];
    }

    pub fn bindSurface(self: *Reactor, generation: u64) !void {
        for (self.clients.items) |*client| {
            if (client.connection.generation == generation) return client.connection.bindSurface();
        }
        return error.ConnectionClosed;
    }

    /// Called within the unsubscribe handler. Let its response enqueue before
    /// the normal step removes this connection after all queued bytes drain.
    pub fn finishSurface(self: *Reactor, generation: u64) void {
        for (self.clients.items) |*client| {
            if (client.connection.generation != generation) continue;
            client.connection.surface_bound = false;
            client.connection.close_after_flush = true;
            return;
        }
    }

    pub fn availableSurfaceWireBytes(self: *const Reactor, generation: u64) ?usize {
        for (self.clients.items) |client| {
            if (client.connection.generation == generation and client.connection.surface_bound)
                return client.connection.availableWireBytes();
        }
        return null;
    }

    /// Returns false after closing a failed/slow peer. No surface failure
    /// changes PTY ownership or the status of any other connection.
    pub fn deliverSurfaceFrame(self: *Reactor, generation: u64, kind: @import("protocol.zig").Kind, bytes: []const u8) bool {
        for (self.clients.items, 0..) |*client, index| {
            if (client.connection.generation != generation) continue;
            client.connection.deliverSurfaceFrame(kind, bytes) catch {
                self.statistics.failed_connections +|= 1;
                self.remove(index);
                return false;
            };
            return true;
        }
        return false;
    }

    fn remove(self: *Reactor, index: usize) void {
        var client = self.clients.orderedRemove(index);
        self.notifyDisconnect(&client);
        client.connection.deinit();
    }

    /// Wait for listener/client readiness, never beyond the nearest deadline.
    /// The next step uses a freshly sampled monotonic timestamp.
    pub fn wait(self: *const Reactor, instance: *const Instance, now: u64, maximum_ms: u32) !void {
        return self.waitWithWake(instance, now, maximum_ms, null);
    }

    pub fn waitWithWake(self: *const Reactor, instance: *const Instance, now: u64, maximum_ms: u32, wake_fd: ?std.posix.fd_t) !void {
        return self.waitWithDescriptors(instance, now, maximum_ms, wake_fd, &.{});
    }

    /// PTY output, pending input and exec-report descriptors share the same
    /// wait as control connections. The owner ticks each resource after wake;
    /// readiness never transfers ownership or closes a borrowed descriptor.
    pub fn waitWithDescriptors(self: *const Reactor, instance: *const Instance, now: u64, maximum_ms: u32, wake_fd: ?std.posix.fd_t, extra: []const std.posix.pollfd) !void {
        if (now < self.last_now or maximum_ms > 60_000 or extra.len > 128) return error.InvalidServiceWait;
        var timeout = @as(u64, maximum_ms) * std.time.ns_per_ms;
        var fds: [194]std.posix.pollfd = undefined;
        fds[0] = .{ .fd = instance.socket.server.stream.handle, .events = std.posix.POLL.IN, .revents = 0 };
        for (self.clients.items, 0..) |client, index| {
            var deadline = if (client.connection.surface_bound) std.math.maxInt(u64) else client.last_read +| self.limits.idle_timeout_ns;
            if (client.frame_started) |started| deadline = @min(deadline, started +| self.limits.frame_timeout_ns);
            timeout = @min(timeout, if (deadline <= now) 0 else deadline - now);
            fds[index + 1] = .{ .fd = client.connection.stream.handle, .events = (if (client.connection.read_eof or client.connection.close_after_flush) @as(i16, 0) else std.posix.POLL.IN) |
                (if (client.connection.sent < client.connection.pending.items.len) std.posix.POLL.OUT else @as(i16, 0)), .revents = 0 };
        }
        var count = self.clients.items.len + 1;
        if (wake_fd) |fd| {
            fds[count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        for (extra) |descriptor| {
            if (descriptor.fd < 0) return error.InvalidServiceWait;
            fds[count] = .{ .fd = descriptor.fd, .events = descriptor.events, .revents = 0 };
            count += 1;
        }
        _ = try std.posix.poll(fds[0..count], @intCast((timeout + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    instance: Instance,
    reactor: Reactor,
    fn init(limits: Limits) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var instance = try Instance.open(tmp.dir, "session");
        errdefer instance.close() catch {};
        const reactor = try Reactor.init(std.testing.allocator, &instance, limits);
        return .{ .tmp = tmp, .instance = instance, .reactor = reactor };
    }
    fn deinit(self: *Fixture) void {
        self.reactor.deinit();
        self.instance.close() catch @panic("test service cleanup failed");
        self.tmp.cleanup();
    }
};

fn connect() !std.net.Stream {
    return std.net.connectUnixSocket(@import("service_socket.zig").socket_name);
}

test "connection limit and malformed peer preserve listener availability" {
    var fixture = try Fixture.init(.{ .maximum_clients = 1 });
    defer fixture.deinit();
    const first = try connect();
    defer first.close();
    try fixture.reactor.step(&fixture.instance, 0);
    const excess = try connect();
    defer excess.close();
    try fixture.reactor.step(&fixture.instance, 1);
    try std.testing.expectEqual(@as(usize, 1), fixture.reactor.clients.items.len);
    try std.testing.expectEqual(@as(u64, 1), fixture.reactor.statistics.refused_connections);
    try first.writeAll(&.{ 2, 0, 0, 0, 1, 0 });
    try fixture.reactor.step(&fixture.instance, 2);
    try std.testing.expectEqual(@as(usize, 0), fixture.reactor.clients.items.len);
    try std.testing.expectEqual(@as(u64, 1), fixture.reactor.statistics.failed_connections);
    const fresh = try connect();
    defer fresh.close();
    try fixture.reactor.step(&fixture.instance, 3);
    try std.testing.expectEqual(@as(usize, 1), fixture.reactor.clients.items.len);
    var poll = [_]std.posix.pollfd{.{ .fd = fresh.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try std.posix.poll(&poll, 1000) > 0);
    var header: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try fresh.read(&header));
    try std.testing.expectEqual(@as(u8, 1), header[0]);
}

test "idle and incomplete-frame deadlines are independent of incoming trickles" {
    var fixture = try Fixture.init(.{ .idle_timeout_ns = 100, .frame_timeout_ns = 50 });
    defer fixture.deinit();
    const idle = try connect();
    defer idle.close();
    const partial = try connect();
    defer partial.close();
    try fixture.reactor.step(&fixture.instance, 0);
    try partial.writeAll(&.{1});
    try fixture.reactor.step(&fixture.instance, 10);
    try partial.writeAll(&.{0});
    try fixture.reactor.step(&fixture.instance, 40);
    try fixture.reactor.step(&fixture.instance, 60);
    try std.testing.expectEqual(@as(usize, 1), fixture.reactor.clients.items.len);
    try fixture.reactor.step(&fixture.instance, 100);
    try std.testing.expectEqual(@as(usize, 0), fixture.reactor.clients.items.len);
    try std.testing.expectEqual(@as(u64, 2), fixture.reactor.statistics.expired_connections);
}

test "accept work is capped and clock rollback is rejected" {
    var fixture = try Fixture.init(.{});
    defer fixture.deinit();
    var peers: [10]std.net.Stream = undefined;
    var count: usize = 0;
    defer for (peers[0..count]) |peer| peer.close();
    for (&peers) |*peer| {
        peer.* = try connect();
        count += 1;
    }
    try fixture.reactor.step(&fixture.instance, 10);
    try std.testing.expectEqual(@as(usize, 8), fixture.reactor.clients.items.len);
    try fixture.reactor.step(&fixture.instance, 11);
    try std.testing.expectEqual(@as(usize, 10), fixture.reactor.clients.items.len);
    try std.testing.expectError(error.NonMonotonicServiceClock, fixture.reactor.step(&fixture.instance, 9));
    try std.testing.expectError(error.InvalidServiceWait, fixture.reactor.wait(&fixture.instance, 9, 1));
    try fixture.reactor.wait(&fixture.instance, 11, 0);
}

test "service wait wakes for borrowed terminal descriptors without consuming bytes" {
    var fixture = try Fixture.init(.{});
    defer fixture.deinit();
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    defer std.posix.close(pipe[1]);
    _ = try std.posix.write(pipe[1], "PTY");
    const extra = [_]std.posix.pollfd{.{ .fd = pipe[0], .events = std.posix.POLL.IN, .revents = 0 }};
    var timer = try std.time.Timer.start();
    try fixture.reactor.waitWithDescriptors(&fixture.instance, 0, 1000, null, &extra);
    try std.testing.expect(timer.read() < 500 * std.time.ns_per_ms);
    var bytes: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try std.posix.read(pipe[0], &bytes));
    try std.testing.expectEqualStrings("PTY", &bytes);
    const invalid = [_]std.posix.pollfd{.{ .fd = -1, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectError(error.InvalidServiceWait, fixture.reactor.waitWithDescriptors(&fixture.instance, 0, 1, null, &invalid));
}

test "deferred replies keep half closed peer until delivery and never reuse generations" {
    var fixture = try Fixture.init(.{});
    defer fixture.deinit();
    const first = try connect();
    defer first.close();
    try fixture.reactor.step(&fixture.instance, 0);
    const generation = fixture.reactor.clients.items[0].connection.generation;
    fixture.reactor.clients.items[0].connection.deferred_requests = 1;
    try std.posix.shutdown(first.handle, .send);
    try fixture.reactor.step(&fixture.instance, 1);
    try std.testing.expectEqual(@as(usize, 1), fixture.reactor.clients.items.len);
    try std.testing.expect(fixture.reactor.deliver(generation, "{\"type\":\"response\"}", true));
    try fixture.reactor.step(&fixture.instance, 2);
    try std.testing.expectEqual(@as(usize, 0), fixture.reactor.clients.items.len);
    const second = try connect();
    defer second.close();
    try fixture.reactor.step(&fixture.instance, 3);
    try std.testing.expect(fixture.reactor.clients.items[0].connection.generation > generation);
    try std.testing.expect(!fixture.reactor.deliver(generation, "{}", true));
    try std.testing.expectEqual(@as(usize, 0), fixture.reactor.clients.items[0].connection.deferred_requests);
}

test "targeted events use contiguous per connection sequences" {
    var fixture = try Fixture.init(.{});
    defer fixture.deinit();
    const a = try connect();
    defer a.close();
    const b = try connect();
    defer b.close();
    try fixture.reactor.step(&fixture.instance, 0);
    const first = fixture.reactor.clients.items[0].connection.generation;
    const second = fixture.reactor.clients.items[1].connection.generation;
    try std.testing.expectEqual(@as(?u64, 1), fixture.reactor.nextEventSequence(first));
    try std.testing.expect(fixture.reactor.deliver(first, "{}", false));
    try std.testing.expectEqual(@as(?u64, 1), fixture.reactor.nextEventSequence(second));
    try std.testing.expect(fixture.reactor.deliver(second, "{}", false));
    try std.testing.expectEqual(@as(?u64, 2), fixture.reactor.nextEventSequence(first));
    try std.testing.expect(fixture.reactor.deliver(first, "{}", false));
    try std.testing.expectEqual(@as(?u64, 3), fixture.reactor.nextEventSequence(first));
    try std.testing.expectEqual(@as(?u64, 2), fixture.reactor.nextEventSequence(second));
}

test "surface receive only connection outlives control request idle timeout" {
    var fixture = try Fixture.init(.{});
    defer fixture.deinit();
    const surface = try connect();
    defer surface.close();
    try fixture.reactor.step(&fixture.instance, 0);
    const generation = fixture.reactor.clients.items[0].connection.generation;
    try fixture.reactor.bindSurface(generation);
    try fixture.reactor.step(&fixture.instance, 31 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 1), fixture.reactor.clients.items.len);
    try std.testing.expect(fixture.reactor.availableSurfaceWireBytes(generation) != null);
}
