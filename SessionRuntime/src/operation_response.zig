const std = @import("std");
const kinds = @import("operation_kind.zig");
const Request = @import("operation_request.zig").Request;
pub const Target = @typeInfo(@TypeOf(@as(Request, undefined).target)).optional.child;

pub fn Response(comptime Result: type) type {
    return struct {
        type: []const u8,
        requestID: []const u8,
        operation: kinds.Operation,
        scope: kinds.Scope,
        target: ?Target = null,
        revision: ?u64 = null,
        result: Result,

        pub fn validate(self: @This(), request: Request) !void {
            try request.validateEnvelope();
            if (!std.mem.eql(u8, self.type, "response") or !std.mem.eql(u8, self.requestID, request.requestID) or
                self.operation != request.operation or self.scope != request.scope) return error.RequestMismatch;
            if (self.scope == .session) {
                const target = self.target orelse return error.TargetMismatch;
                const expected = request.target orelse return error.TargetMismatch;
                if (!sameTarget(target, expected) or self.revision == null) return error.TargetMismatch;
            } else if (self.target != null or self.revision != null) return error.TargetMismatch;
        }
    };
}

pub const Failure = struct {
    type: []const u8,
    requestID: []const u8,
    operation: []const u8,
    scope: kinds.Scope,
    target: ?Target = null,
    /// Present on revision_conflict: the authoritative session revision at the
    /// moment the optimistic-concurrency check rejected the request. Optional
    /// elsewhere, so older decoders keep working; it never replaces a real
    /// session.snapshot, it only saves the loser one round trip.
    currentRevision: ?u64 = null,
    @"error": struct {
        code: []const u8,
        message: []const u8,
        retry: enum { never, after_query, after_reconnect, backoff },
    },
    pub fn validate(self: Failure, request: Request) !void {
        try request.validateEnvelope();
        if (!std.mem.eql(u8, self.type, "error") or !std.mem.eql(u8, self.requestID, request.requestID) or
            !std.mem.eql(u8, self.operation, @tagName(request.operation)) or self.scope != request.scope) return error.RequestMismatch;
        if (self.target) |target| {
            const expected = request.target orelse return error.TargetMismatch;
            if (!sameTarget(target, expected)) return error.TargetMismatch;
        }
        if (self.@"error".code.len == 0 or self.@"error".code.len > 64 or self.@"error".message.len > 4096) return error.InvalidError;
        if (self.@"error".code[0] < 'a' or self.@"error".code[0] > 'z') return error.InvalidError;
        for (self.@"error".code) |byte| {
            if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_')) return error.InvalidError;
        }
    }
};

pub fn Event(comptime Body: type) type {
    return struct {
        type: []const u8,
        event: []const u8,
        eventID: []const u8,
        target: Target,
        sequence: u64,
        revision: u64,
        body: Body,
        pub fn validate(self: @This(), expected_event: []const u8, expected: Target, after: ?u64, minimum_revision: ?u64) !void {
            if (!@import("operation_request.zig").validID(self.eventID)) return error.InvalidEventID;
            if (!std.mem.eql(u8, self.event, expected_event)) return error.EventMismatch;
            if (!std.mem.eql(u8, self.type, "event") or !sameTarget(self.target, expected)) return error.TargetMismatch;
            if (after) |sequence| {
                if (self.sequence <= sequence) return error.StaleEvent;
                if (self.sequence != sequence + 1) return error.SequenceGap;
            }
            if (minimum_revision) |minimum| {
                if (self.revision < minimum) return error.StaleRevision;
            }
        }
    };
}

fn sameTarget(left: Target, right: Target) bool {
    return std.mem.eql(u8, left.serverID, right.serverID) and std.mem.eql(u8, left.serverEpoch, right.serverEpoch) and
        std.mem.eql(u8, left.sessionID, right.sessionID);
}

test "response error and event fixtures correlate and preserve nested counters" {
    const allocator = std.testing.allocator;
    const Fixture = struct { name: []const u8, kind: []const u8, requestJSON: []const u8, valueJSON: []const u8, afterSequence: ?u64, minimumRevision: ?u64 = null, result: []const u8 };
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "protocol/reply-fixtures.json", 1024 * 1024);
    defer allocator.free(bytes);
    const fixtures = try std.json.parseFromSlice([]Fixture, allocator, bytes, .{});
    defer fixtures.deinit();
    const Attachment = struct { attachmentID: []const u8, terminalID: []const u8, readOnly: bool, lease: struct { leaseID: []const u8, leaseEpoch: u64 } };
    const Revoked = struct { terminalID: []const u8, leaseID: []const u8, leaseEpoch: u64, reason: []const u8 };
    for (fixtures.value) |fixture| {
        const request = try std.json.parseFromSlice(Request, allocator, fixture.requestJSON, .{});
        defer request.deinit();
        var failure: ?anyerror = null;
        if (std.mem.eql(u8, fixture.kind, "response")) {
            const value = try std.json.parseFromSlice(Response(Attachment), allocator, fixture.valueJSON, .{});
            defer value.deinit();
            value.value.validate(request.value) catch |err| {
                failure = err;
            };
            if (failure == null) {
                const encoded = try std.json.Stringify.valueAlloc(allocator, value.value, .{ .emit_null_optional_fields = false });
                defer allocator.free(encoded);
                const again = try std.json.parseFromSlice(Response(Attachment), allocator, encoded, .{});
                defer again.deinit();
                try std.testing.expectEqual(std.math.maxInt(u64), again.value.revision.?);
                try std.testing.expectEqual(std.math.maxInt(u64), again.value.result.lease.leaseEpoch);
            }
        } else if (std.mem.eql(u8, fixture.kind, "error")) {
            const value = try std.json.parseFromSlice(Failure, allocator, fixture.valueJSON, .{});
            defer value.deinit();
            value.value.validate(request.value) catch |err| {
                failure = err;
            };
            if (failure == null) {
                const encoded = try std.json.Stringify.valueAlloc(allocator, value.value, .{ .emit_null_optional_fields = false });
                defer allocator.free(encoded);
                const again = try std.json.parseFromSlice(Failure, allocator, encoded, .{});
                defer again.deinit();
                try again.value.validate(request.value);
                try std.testing.expectEqualStrings(value.value.@"error".code, again.value.@"error".code);
            }
        } else {
            const value = try std.json.parseFromSlice(Event(Revoked), allocator, fixture.valueJSON, .{});
            defer value.deinit();
            value.value.validate("lease.revoked", request.value.target.?, fixture.afterSequence, fixture.minimumRevision) catch |err| {
                failure = err;
            };
            if (failure == null) {
                const encoded = try std.json.Stringify.valueAlloc(allocator, value.value, .{});
                defer allocator.free(encoded);
                const again = try std.json.parseFromSlice(Event(Revoked), allocator, encoded, .{});
                defer again.deinit();
                try std.testing.expectEqual(std.math.maxInt(u64), again.value.sequence);
                try std.testing.expectEqual(std.math.maxInt(u64), again.value.body.leaseEpoch);
            }
        }
        const result: []const u8 = if (failure) |err| switch (err) {
            error.RequestMismatch => "requestMismatch",
            error.TargetMismatch => "targetMismatch",
            error.InvalidError => "invalidError",
            error.StaleEvent => "staleEvent",
            error.SequenceGap => "sequenceGap",
            error.EventMismatch => "eventMismatch",
            error.InvalidEventID => "invalidEventID",
            error.StaleRevision => "staleRevision",
            else => return err,
        } else "ok";
        try std.testing.expectEqualStrings(fixture.result, result);
    }
}
