const std = @import("std");
const kinds = @import("operation_kind.zig");

pub const Request = struct {
    type: []const u8,
    requestID: []const u8,
    clientID: []const u8,
    scope: kinds.Scope,
    operation: kinds.Operation,
    target: ?struct { serverID: []const u8, serverEpoch: []const u8, sessionID: []const u8 } = null,
    expectedRevision: ?u64 = null,
    createdAtUnixMs: ?u64 = null,
    lease: ?struct { leaseID: []const u8, leaseEpoch: u64 } = null,
    controlSequence: ?u64 = null,
    params: std.json.Value,
    extensions: ?std.json.Value = null,

    pub fn validateEnvelope(self: Request) !void {
        const metadata = self.operation.metadata();
        if (!std.mem.eql(u8, self.type, "request") or !validID(self.requestID) or !validID(self.clientID)) return error.InvalidIdentity;
        if (self.scope != metadata.scope) return error.WrongScope;
        if (self.scope == .session) {
            const target = self.target orelse return error.InvalidTarget;
            if (!validID(target.serverID) or !validID(target.serverEpoch) or !validID(target.sessionID)) return error.InvalidTarget;
        } else if (self.target != null) return error.InvalidTarget;
        if ((self.createdAtUnixMs != null) != metadata.requires_created_at or (self.expectedRevision != null) != metadata.requires_revision or (self.lease != null) != metadata.requires_lease or
            (self.controlSequence != null) != metadata.requires_control_sequence) return error.InvalidPreconditions;
        if (self.lease) |lease| {
            if (!validID(lease.leaseID)) return error.InvalidIdentity;
        }
        if (self.params != .object) return error.InvalidParameters;
        if (self.operation == .@"terminal.attach") {
            const takeover = self.params.object.get("takeover");
            if (takeover) |flag| {
                if (flag != .bool) return error.InvalidParameters;
                if (flag.bool and self.params.object.get("expectedLeaseEpoch") == null) return error.InvalidPreconditions;
            }
            if (self.params.object.get("expectedLeaseEpoch")) |value| {
                switch (value) {
                    .integer => |n| {
                        if (n < 0) return error.InvalidParameters;
                    },
                    .number_string => |n| {
                        _ = std.fmt.parseInt(u64, n, 10) catch return error.InvalidParameters;
                    },
                    else => return error.InvalidParameters,
                }
            }
        }
        if (self.extensions) |extensions| {
            if (extensions != .object or extensions.object.count() > 32) return error.InvalidParameters;
            for (extensions.object.values()) |value| {
                if (value != .string or value.string.len > 4096) return error.InvalidParameters;
            }
        }
    }
};

pub fn validID(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

test "operation envelopes share identity scope and counter fixtures with Swift" {
    const allocator = std.testing.allocator;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "protocol/envelope-fixtures.json", 2 * 1024 * 1024);
    defer allocator.free(bytes);
    const Fixture = struct { name: []const u8, result: []const u8, value: Request };
    const parsed = try std.json.parseFromSlice([]Fixture, allocator, bytes, .{});
    defer parsed.deinit();
    var covered = std.AutoHashMap(kinds.Operation, void).init(allocator);
    defer covered.deinit();
    for (parsed.value) |fixture| {
        const result: []const u8 = if (fixture.value.validateEnvelope()) |_| "ok" else |err| switch (err) {
            error.InvalidIdentity => "invalidIdentity",
            error.WrongScope => "wrongScope",
            error.InvalidTarget => "invalidTarget",
            error.InvalidPreconditions => "invalidPreconditions",
            error.InvalidParameters => "invalidParameters",
        };
        try std.testing.expectEqualStrings(fixture.result, result);
        try covered.put(fixture.value.operation, {});
        const encoded = try std.json.Stringify.valueAlloc(allocator, fixture.value, .{ .emit_null_optional_fields = false });
        defer allocator.free(encoded);
        const roundtrip = try std.json.parseFromSlice(Request, allocator, encoded, .{});
        defer roundtrip.deinit();
        try std.testing.expectEqual(fixture.value.operation, roundtrip.value.operation);
        try std.testing.expectEqual(fixture.value.controlSequence, roundtrip.value.controlSequence);
        try std.testing.expectEqual(fixture.value.createdAtUnixMs, roundtrip.value.createdAtUnixMs);
        if (std.mem.eql(u8, fixture.result, "ok")) try roundtrip.value.validateEnvelope();
        if (std.mem.eql(u8, fixture.name, "maximum counters")) {
            try std.testing.expectEqual(std.math.maxInt(u64), roundtrip.value.controlSequence.?);
            try std.testing.expectEqual(std.math.maxInt(u64), roundtrip.value.lease.?.leaseEpoch);
        }
    }
    try std.testing.expectEqual(@typeInfo(kinds.Operation).@"enum".fields.len, covered.count());
}
