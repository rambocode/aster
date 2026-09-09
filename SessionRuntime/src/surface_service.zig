const std = @import("std");
const interests = @import("surface_interest.zig");
const streams = @import("surface_stream.zig");
const Terminals = @import("terminal_service.zig").Service;
const Reactor = @import("service_reactor.zig").Reactor;
const Session = @import("session.zig").Session;
const Request = @import("operation_request.zig").Request;
const replies = @import("operation_response.zig");
const ids = @import("service_identity.zig");
const Geometry = @import("geometry.zig").Geometry;
const ID = interests.ID;
const queue_bytes = 8 * 1024 * 1024;
const Producer = struct { id: ID, stream: streams.Stream, queued: bool = false };

/// Session-thread adapter. Transport/source failures release only a surface;
/// attachments and their PTYs remain owned by terminal_service.
pub const Service = struct {
    allocator: std.mem.Allocator,
    terminals: *Terminals,
    reactor: *Reactor,
    registry: interests.Registry,
    producers: std.ArrayList(Producer) = .empty,
    cursor: usize = 0,

    pub fn init(a: std.mem.Allocator, terminals: *Terminals, reactor: *Reactor) !Service {
        var self = Service{ .allocator = a, .terminals = terminals, .reactor = reactor, .registry = try interests.Registry.init(a, 64) };
        errdefer self.registry.deinit();
        try self.producers.ensureTotalCapacity(a, 64);
        return self;
    }
    pub fn deinit(self: *Service) void {
        for (self.producers.items) |*p| p.stream.deinit();
        self.producers.deinit(self.allocator);
        self.registry.deinit();
    }
    pub fn respond(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) !?[]u8 {
        return self.dispatch(a, r, generation) catch |err| {
            if (err == error.OutOfMemory) return err;
            const code = switch (err) {
                error.AttachmentNotOwned, error.PermissionDenied => "permission_denied",
                error.SurfaceLimitReached, error.OutOfMemory => "resource_limit",
                else => "invalid_request",
            };
            return try std.json.Stringify.valueAlloc(a, replies.Failure{ .type = "error", .requestID = r.requestID, .operation = @tagName(r.operation), .scope = r.scope, .target = r.target, .@"error" = .{ .code = code, .message = code, .retry = .never } }, .{ .emit_null_optional_fields = false });
        };
    }
    fn success(self: *Service, a: std.mem.Allocator, r: Request, result: anytype) ![]u8 {
        return std.json.Stringify.valueAlloc(a, replies.Response(@TypeOf(result)){ .type = "response", .requestID = r.requestID, .operation = r.operation, .scope = r.scope, .target = r.target, .revision = self.terminals.revision, .result = result }, .{ .emit_null_optional_fields = false });
    }
    fn dispatch(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) !?[]u8 {
        const client = try id(r.clientID);
        switch (r.operation) {
            .@"surface.subscribe" => {
                const Params = struct { attachmentID: []const u8, geometry: struct { rows: u16, columns: u16, pixelWidth: u16 = 0, pixelHeight: u16 = 0 } };
                const parsed = try std.json.parseFromValue(Params, a, r.params, .{});
                defer parsed.deinit();
                const params = parsed.value;
                const attachment = try self.terminals.attachmentForSurface(try id(params.attachmentID), client);
                const entry = self.terminals.pool.find(attachment.terminal_id) orelse return error.AttachmentNotFound;
                const geometry = Geometry{ .rows = params.geometry.rows, .columns = params.geometry.columns, .pixel_width = params.geometry.pixelWidth, .pixel_height = params.geometry.pixelHeight };
                try checkGeometry(entry.session, geometry);
                const stream_id = try self.registry.subscribe(ids.uuidText(ids.newUUID()), attachment, client, generation, geometry);
                if (self.producer(stream_id) == null) {
                    errdefer {
                        _ = self.registry.disconnectOne(generation);
                    }
                    const stream = try streams.Stream.init(self.allocator, .{});
                    try self.reactor.bindSurface(generation);
                    self.producers.appendAssumeCapacity(.{ .id = stream_id, .stream = stream });
                }
                return try self.success(a, r, .{ .streamID = &stream_id, .terminalID = &attachment.terminal_id });
            },
            .@"surface.unsubscribe", .@"surface.snapshot" => {
                const parsed = try std.json.parseFromValue(struct { streamID: []const u8 }, a, r.params, .{});
                defer parsed.deinit();
                const stream_id = try id(parsed.value.streamID);
                if (r.operation == .@"surface.snapshot") {
                    try self.registry.requestSnapshot(stream_id, generation, client);
                    return try self.success(a, r, .{ .scheduled = true });
                }
                const removed = try self.registry.unsubscribe(stream_id, generation, client);
                if (removed) |surface| {
                    self.removeProducer(stream_id);
                    // A surface connection is single-use, including a partial transfer.
                    if (surface == generation) self.reactor.finishSurface(surface) else self.reactor.drop(surface);
                }
                return try self.success(a, r, .{ .unsubscribed = removed != null });
            },
            else => return null,
        }
    }
    fn producer(self: *Service, stream_id: ID) ?*Producer {
        for (self.producers.items) |*p| if (std.mem.eql(u8, &p.id, &stream_id)) return p;
        return null;
    }
    fn removeProducer(self: *Service, stream_id: ID) void {
        for (self.producers.items, 0..) |p, i| if (std.mem.eql(u8, &p.id, &stream_id)) {
            var removed = self.producers.orderedRemove(i);
            removed.stream.deinit();
            return;
        };
    }
    pub fn disconnect(self: *Service, generation: u64) void {
        while (self.registry.disconnectOne(generation)) |surface| {
            // Registry removed the identity; remaining producer ownership is found
            // by membership, with no temporary allocation on disconnect paths.
            var i: usize = 0;
            while (i < self.producers.items.len) {
                const stream_id = self.producers.items[i].id;
                if (self.registry.find(stream_id) == null) self.removeProducer(stream_id) else i += 1;
            }
            self.reactor.drop(surface);
        }
    }
    /// Fair starting position; each connection advances at most one frame per
    /// tick. Source allocations together never exceed the 32 MiB budget.
    pub fn tick(self: *Service, now_ms: u64) !void {
        const count = self.registry.entries.items.len;
        if (count == 0) return;
        var visit: [64]ID = undefined;
        for (0..count) |i| visit[i] = self.registry.entries.items[(self.cursor + i) % count].id;
        self.cursor = (self.cursor + 1) % count;
        for (visit[0..count]) |stream_id| {
            const interest = self.registry.find(stream_id) orelse continue;
            const generation = interest.surface_generation;
            if (!self.terminals.attachmentAlive(interest.attachment.id, interest.attachment.control_generation)) {
                self.disconnect(generation);
                continue;
            }
            self.advance(stream_id, now_ms) catch {
                self.disconnect(generation);
            };
        }
    }
    fn advance(self: *Service, stream_id: ID, now_ms: u64) !void {
        const interest = self.registry.find(stream_id).?;
        const p = self.producer(stream_id).?;
        const budget = self.reactor.availableSurfaceWireBytes(interest.surface_generation) orelse return error.ConnectionClosed;
        try p.stream.tick(now_ms);
        if (p.queued) {
            if (budget != queue_bytes) return;
            try p.stream.ackFrame(now_ms);
            p.queued = false;
        }
        if (p.stream.ownedBytes() == 0) {
            const entry = self.terminals.pool.find(interest.attachment.terminal_id) orelse return error.AttachmentNotFound;
            const session = entry.session;
            try checkGeometry(session, interest.geometry);
            if (!interest.needs_snapshot and p.stream.completed_sequence == session.output_sequence) {
                if (session.eof and session.exit_status != null and session.cleanupComplete()) {
                    const generation = interest.surface_generation;
                    _ = try self.registry.unsubscribe(stream_id, generation, interest.attachment.client_id);
                    self.removeProducer(stream_id);
                    // The end frame was acknowledged only after actual write.
                    // EOF now follows the verified final transaction in order.
                    self.reactor.finishSurface(generation);
                }
                return;
            }
            var used: usize = 0;
            for (self.producers.items) |other| used += other.stream.ownedBytes();
            const remaining = streams.maximum_snapshot_bytes - used;
            if (remaining == 0) return;
            const delta = !interest.needs_snapshot and session.delta_safe and p.stream.completed_sequence != null and p.stream.completed_sequence.? == session.delta_base and session.delta_bytes.items.len != 0 and session.delta_bytes.items.len <= streams.maximum_delta_bytes;
            if (delta) {
                if (session.delta_bytes.items.len > remaining) return;
                const bytes = try self.allocator.dupe(u8, session.delta_bytes.items);
                errdefer self.allocator.free(bytes);
                try p.stream.beginDelta(bytes, session.output_sequence, session.delta_base, now_ms);
            } else {
                // Reserve remaining global budget before capture. A temporarily
                // insufficient budget waits for other transactions to complete.
                const bytes = capture(session, remaining) catch |err| {
                    if (remaining < streams.maximum_snapshot_bytes and (err == error.FrameTooLarge or err == error.HistoryTooLarge or err == error.ImageTooLarge)) return;
                    return err;
                } orelse return;
                // Session capture uses the same allocator as the terminal pool;
                // transfer into this service's allocator only when different.
                const owned = if (session.allocator.ptr == self.allocator.ptr and session.allocator.vtable == self.allocator.vtable) bytes else blk: {
                    defer session.allocator.free(bytes);
                    break :blk try self.allocator.dupe(u8, bytes);
                };
                errdefer self.allocator.free(owned);
                try p.stream.beginSnapshot(owned, session.output_sequence, now_ms);
            }
            interest.needs_snapshot = false;
        }
        if (try p.stream.next(budget, now_ms)) |frame| {
            if (!self.reactor.deliverSurfaceFrame(interest.surface_generation, frame.kind, frame.payload)) return error.ConnectionClosed;
            p.queued = true;
        }
    }
};

fn id(value: []const u8) !ID {
    if (!@import("operation_request.zig").validID(value)) return error.InvalidIdentity;
    return value[0..36].*;
}
fn checkGeometry(session: *Session, geometry: Geometry) !void {
    try geometry.validate();
    const metrics = try session.terminal.screenMetrics();
    const pixels = try session.terminal.pixelSize();
    if (metrics.rows != geometry.rows or metrics.columns != geometry.columns or
        (geometry.pixel_width != 0 and (pixels.width != geometry.pixel_width or pixels.height != geometry.pixel_height))) return error.UnsupportedProjection;
}
/// History uses the read-only viewport projector. The active bottom retains
/// the existing graphics-aware capture path; neither path resizes the source.
fn capture(session: *Session, maximum: usize) !?[]u8 {
    const viewport = try session.terminal.viewport();
    if (viewport.offset + viewport.length < viewport.total)
        return try @import("viewport_projection.zig").capture(session.allocator, &session.terminal, maximum);
    return session.snapshotForClient(maximum);
}

test "surface service validates identities before ownership lookup" {
    std.testing.refAllDecls(Service);
    try std.testing.expectError(error.InvalidIdentity, id("invalid"));
    try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", &(try id("00000000-0000-4000-8000-000000000000")));
}

test "surface service rejects malformed requests without touching terminal ownership" {
    const a = std.testing.allocator;
    var terminals: Terminals = undefined;
    var reactor: Reactor = undefined;
    var service = try Service.init(a, &terminals, &reactor);
    defer service.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"attachmentID\":\"bad\",\"geometry\":{\"rows\":24,\"columns\":80}}", .{});
    defer parsed.deinit();
    const request = Request{ .type = "request", .requestID = "00000000-0000-4000-8000-000000000001", .clientID = "00000000-0000-4000-8000-000000000002", .scope = .session, .operation = .@"surface.subscribe", .params = parsed.value };
    const bytes = (try service.respond(a, request, 2)).?;
    defer a.free(bytes);
    const response = try std.json.parseFromSlice(replies.Failure, a, bytes, .{});
    defer response.deinit();
    try std.testing.expectEqualStrings("invalid_request", response.value.@"error".code);
    try std.testing.expectEqual(@as(usize, 0), service.registry.entries.items.len);
    try service.tick(100);
    service.disconnect(2);
}
