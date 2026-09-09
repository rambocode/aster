const std = @import("std");
const Geometry = @import("geometry.zig").Geometry;
const validID = @import("operation_request.zig").validID;
pub const ID = [36]u8;

/// Copied from a live, validated attachment by its domain owner. This is never
/// reconstructed from an untrusted client's claimed owner connection.
pub const Attachment = struct {
    id: ID,
    terminal_id: ID,
    client_id: ID,
    control_generation: u64,
};
pub const Interest = struct {
    id: ID,
    attachment: Attachment,
    surface_generation: u64,
    geometry: Geometry,
    needs_snapshot: bool = true,
};

/// Bounded subscription ownership, independent of PTY lifetime. Every surface
/// uses its own connection; losing a control owner removes its subscriptions.
/// Callers drop returned surface generations so partial transactions cannot be
/// accidentally appended to a newly bound stream.
pub const Registry = struct {
    entries: std.ArrayList(Interest) = .empty,
    allocator: std.mem.Allocator,
    maximum: usize,

    pub fn init(allocator: std.mem.Allocator, maximum: usize) !Registry {
        if (maximum == 0 or maximum > 64) return error.InvalidSurfaceLimit;
        var self = Registry{ .allocator = allocator, .maximum = maximum };
        try self.entries.ensureTotalCapacity(allocator, maximum);
        return self;
    }
    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Geometry records a projection request only, never resizes a PTY.
    /// Repeat binding on the same connection is idempotent for equal inputs.
    pub fn subscribe(self: *Registry, stream_id: ID, attachment: Attachment, client_id: ID, surface_generation: u64, geometry: Geometry) !ID {
        if (!validID(&stream_id) or !validID(&attachment.id) or !validID(&attachment.terminal_id) or !validID(&attachment.client_id)) return error.InvalidSurfaceIdentity;
        if (!std.mem.eql(u8, &attachment.client_id, &client_id)) return error.AttachmentNotOwned;
        if (surface_generation == 0 or attachment.control_generation == 0 or surface_generation == attachment.control_generation) return error.DedicatedSurfaceConnectionRequired;
        try geometry.validate();
        if (geometry.columns > 4096 or @as(usize, geometry.rows) * geometry.columns > 262144) return error.SurfaceGeometryLimit;
        for (self.entries.items) |entry| {
            if (entry.surface_generation == surface_generation) {
                if (std.meta.eql(entry.attachment, attachment) and std.meta.eql(entry.geometry, geometry)) return entry.id;
                return error.SurfaceAlreadyBound;
            }
            if (std.mem.eql(u8, &entry.id, &stream_id)) return error.SurfaceIDConflict;
        }
        if (self.entries.items.len == self.maximum) return error.SurfaceLimitReached;
        self.entries.appendAssumeCapacity(.{ .id = stream_id, .attachment = attachment, .surface_generation = surface_generation, .geometry = geometry });
        return stream_id;
    }

    pub fn find(self: *Registry, stream_id: ID) ?*Interest {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, &entry.id, &stream_id)) return entry;
        return null;
    }
    pub fn requestSnapshot(self: *Registry, stream_id: ID, generation: u64, client_id: ID) !void {
        const entry = self.find(stream_id) orelse return error.SurfaceNotFound;
        if (!owns(entry.*, generation, client_id)) return error.AttachmentNotOwned;
        entry.needs_snapshot = true;
    }
    pub fn unsubscribe(self: *Registry, stream_id: ID, generation: u64, client_id: ID) !?u64 {
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, &entry.id, &stream_id)) continue;
            if (!owns(entry, generation, client_id)) return error.AttachmentNotOwned;
            return self.entries.orderedRemove(index).surface_generation;
        }
        return null;
    }
    fn owns(entry: Interest, generation: u64, client_id: ID) bool {
        return std.mem.eql(u8, &entry.attachment.client_id, &client_id) and
            (generation == entry.attachment.control_generation or generation == entry.surface_generation);
    }

    /// Removes one matching interest per call, allowing allocation-free cleanup
    /// even when a control connection owned many surfaces. Call until null.
    pub fn disconnectOne(self: *Registry, generation: u64) ?u64 {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.surface_generation == generation or entry.attachment.control_generation == generation)
                return self.entries.orderedRemove(index).surface_generation;
        }
        return null;
    }
    pub fn releaseAttachmentOne(self: *Registry, attachment_id: ID) ?u64 {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, &entry.attachment.id, &attachment_id))
                return self.entries.orderedRemove(index).surface_generation;
        }
        return null;
    }
};

fn testID(last: u8) ID {
    var id = "00000000-0000-4000-8000-000000000000".*;
    id[35] = last;
    return id;
}
fn testAttachment(last: u8) Attachment {
    return .{ .id = testID(last), .terminal_id = testID('a'), .client_id = testID('b'), .control_generation = 1 };
}

test "surface interest binds dedicated owner and equal retries do not allocate a new stream" {
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const owner = testAttachment('1');
    const geometry = Geometry{ .rows = 24, .columns = 80 };
    try std.testing.expectError(error.AttachmentNotOwned, registry.subscribe(testID('c'), owner, testID('d'), 2, geometry));
    try std.testing.expectError(error.DedicatedSurfaceConnectionRequired, registry.subscribe(testID('c'), owner, owner.client_id, 1, geometry));
    try std.testing.expectEqual(testID('c'), try registry.subscribe(testID('c'), owner, owner.client_id, 2, geometry));
    try std.testing.expectEqual(testID('c'), try registry.subscribe(testID('d'), owner, owner.client_id, 2, geometry));
    try std.testing.expectError(error.SurfaceAlreadyBound, registry.subscribe(testID('d'), owner, owner.client_id, 2, .{ .rows = 20, .columns = 40 }));
    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    try std.testing.expectEqual(geometry, registry.entries.items[0].geometry);
}

test "surface interest release and reconnect cannot inherit old stream ownership" {
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const owner = testAttachment('1');
    _ = try registry.subscribe(testID('c'), owner, owner.client_id, 2, .{ .rows = 24, .columns = 80 });
    try std.testing.expectError(error.AttachmentNotOwned, registry.requestSnapshot(testID('c'), 3, owner.client_id));
    try std.testing.expectError(error.AttachmentNotOwned, registry.unsubscribe(testID('c'), 2, testID('e')));
    try std.testing.expectEqual(@as(?u64, 2), registry.disconnectOne(1));
    try std.testing.expect(registry.find(testID('c')) == null);
    try std.testing.expectEqual(@as(?u64, null), registry.disconnectOne(1));
    _ = try registry.subscribe(testID('d'), testAttachment('2'), owner.client_id, 3, .{ .rows = 24, .columns = 80 });
    try std.testing.expectError(error.SurfaceNotFound, registry.requestSnapshot(testID('c'), 3, owner.client_id));
    try std.testing.expectEqual(@as(?u64, 3), registry.releaseAttachmentOne(testID('2')));
}

test "surface interest bounds capacity and permits owner snapshot without changing projection" {
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const owner = testAttachment('1');
    _ = try registry.subscribe(testID('c'), owner, owner.client_id, 2, .{ .rows = 24, .columns = 80 });
    try std.testing.expectError(error.SurfaceLimitReached, registry.subscribe(testID('d'), testAttachment('2'), owner.client_id, 3, .{ .rows = 24, .columns = 80 }));
    registry.entries.items[0].needs_snapshot = false;
    try registry.requestSnapshot(testID('c'), 1, owner.client_id);
    try std.testing.expect(registry.entries.items[0].needs_snapshot);
    try std.testing.expectEqual(@as(u16, 80), registry.entries.items[0].geometry.columns);
}
