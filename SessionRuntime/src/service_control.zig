const std = @import("std");
const builtin = @import("builtin");
const identities = @import("service_identity.zig");
const Hello = @import("handshake.zig").Hello;
const Request = @import("operation_request.zig").Request;
const replies = @import("operation_response.zig");
const protocol = @import("protocol.zig");

/// Optional terminal domain endpoint. Deferred replies are delivered by the
/// service after completion; request slices must be copied before returning.
pub const Handler = struct {
    context: *anyopaque,
    respond: *const fn (*anyopaque, std.mem.Allocator, Request, u64) anyerror!?[]u8,
    disconnect: *const fn (*anyopaque, u64) void,
    input_closed: ?*const fn (*anyopaque, u64) void = null,
};

/// Registry-scope endpoint. Registry requests carry no target, so the service
/// serves them against the state parent directory it lives in.
pub const RegistryHandler = struct {
    context: *anyopaque,
    respond: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror![]u8,
};

pub const version = "0.1.0-dev";
pub const capabilities = [_][]const u8{ "health_check", "server_lifecycle", "server_replace", "live_handoff" };
pub const Status = struct {
    version: []const u8 = version,
    protocolMajor: u16 = protocol.major,
    protocolMinor: u16 = protocol.minor,
    capabilities: []const []const u8 = &capabilities,
};

/// Owns handshake strings; returned Hello slices borrow this instance. Only
/// implemented handlers advertise capabilities. Caller authenticates the peer
/// before constructing a control connection or sending any handshake.
pub const Control = struct {
    server_id: [36]u8,
    session_id: [36]u8,
    epoch: [36]u8,
    revision: u64 = 0,
    stop_requested: bool = false,
    /// Set by server.handoff handler; main loop reads and clears to trigger performHandoff.
    handoff_requested: bool = false,
    handler: ?Handler = null,
    registry: ?RegistryHandler = null,
    advertised_capabilities: []const []const u8 = &capabilities,

    pub fn init(identity: identities.Identity, epoch: [16]u8) Control {
        return .{ .server_id = identities.uuidText(identity.server_id), .session_id = identities.uuidText(identity.session_id), .epoch = identities.uuidText(epoch) };
    }

    pub fn hello(self: *const Control) Hello {
        return .{ .type = .hello, .protocolMajor = protocol.major, .protocolMinor = protocol.minor, .serverID = &self.server_id, .serverEpoch = &self.epoch, .sessionID = &self.session_id, .platform = if (builtin.os.tag == .macos)
            (if (builtin.cpu.arch == .aarch64) .@"macos-aarch64" else .@"macos-x86_64")
        else
            (if (builtin.cpu.arch == .aarch64) .@"linux-aarch64" else .@"linux-x86_64"), .capabilities = self.advertised_capabilities };
    }

    /// Encodes one control reply owned by allocator. Protocol/envelope errors
    /// fail the connection; valid requests get a correlated result or failure.
    /// Parsing uses bounded depth and temporary storage, independent of the
    /// long-lived connection allocator.
    pub fn respond(self: *Control, allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        return try self.respondForConnection(allocator, bytes, 0) orelse error.DeferredResponse;
    }

    pub fn respondForConnection(self: *Control, allocator: std.mem.Allocator, bytes: []const u8, generation: u64) !?[]u8 {
        if (bytes.len == 0 or bytes.len > protocol.maximum_control_bytes) return error.ControlFrameTooLarge;
        try checkDepth(bytes);
        const scratch = try allocator.alloc(u8, @min(4 * 1024 * 1024, @max(65536, bytes.len * 8)));
        defer allocator.free(scratch);
        var bounded = std.heap.FixedBufferAllocator.init(scratch);
        const parsed = std.json.parseFromSlice(Request, bounded.allocator(), bytes, .{}) catch
            return error.InvalidControlRequest;
        defer parsed.deinit();
        const request = parsed.value;
        request.validateEnvelope() catch return error.InvalidControlRequest;
        if (request.scope == .registry) {
            // The registry is a directory of independent services, so a stopping
            // instance still refuses new work rather than acting for its peers.
            if (self.stop_requested) return try failure(allocator, request, "service_stopping", "Service is stopping.", .after_reconnect);
            if (self.registry) |handler| return try handler.respond(handler.context, allocator, request);
            return try failure(allocator, request, "unsupported_operation", "This endpoint serves one session.", .never);
        }
        if (request.scope != .session)
            return try failure(allocator, request, "unsupported_operation", "This endpoint serves one session.", .never);
        const target = request.target.?;
        if (!std.mem.eql(u8, target.serverID, &self.server_id) or
            !std.mem.eql(u8, target.sessionID, &self.session_id) or
            !std.mem.eql(u8, target.serverEpoch, &self.epoch))
            return try failure(allocator, request, "stale_server_epoch", "Service instance changed; reconnect.", .after_reconnect);
        if (self.stop_requested and request.operation != .@"server.stop" and request.operation != .@"server.status" and request.operation != .@"health.check" and request.operation != .@"terminal.list" and request.operation != .@"request.status")
            return try failure(allocator, request, "service_stopping", "Service is stopping.", .after_reconnect);
        switch (request.operation) {
            .@"server.stop" => {
                if (request.params.object.count() != 0)
                    return try failure(allocator, request, "invalid_request", "This operation accepts no parameters.", .never);
                const response = try self.success(allocator, request, .{ .stopping = true });
                self.stop_requested = true;
                return response;
            },
            .@"server.status", .@"health.check" => {
                if (request.params.object.count() != 0)
                    return try failure(allocator, request, "invalid_request", "This operation accepts no parameters.", .never);
                if (request.operation == .@"server.status")
                    return try self.success(allocator, request, Status{ .capabilities = self.advertised_capabilities });
                return try self.success(allocator, request, .{ .alive = true });
            },
            // P8.3: server.replace (cold) dispatched to domain handler.
            .@"server.replace" => {
                if (self.handler) |handler| return handler.respond(handler.context, allocator, request, generation);
                return try failure(allocator, request, "capability_not_available", "This install does not support live handoff.", .never);
            },
            // P8.4: server.handoff (live) sets flag for main loop to trigger performHandoff.
            .@"server.handoff" => {
                if (self.handler == null)
                    return try failure(allocator, request, "capability_not_available", "This install does not support live handoff.", .never);
                const response = try self.success(allocator, request, .{ .accepted = true });
                self.handoff_requested = true;
                return response;
            },
            else => {
                if (self.handler) |handler| return handler.respond(handler.context, allocator, request, generation);
                return try failure(allocator, request, "missing_capability", "The required capability is unavailable.", .never);
            },
        }
    }

    fn success(self: *const Control, allocator: std.mem.Allocator, request: Request, result: anytype) ![]u8 {
        const response = replies.Response(@TypeOf(result)){
            .type = "response",
            .requestID = request.requestID,
            .operation = request.operation,
            .scope = request.scope,
            .target = request.target,
            .revision = self.revision,
            .result = result,
        };
        return std.json.Stringify.valueAlloc(allocator, response, .{ .emit_null_optional_fields = false });
    }
};

const Retry = @TypeOf(@as(replies.Failure, undefined).@"error".retry);
fn failure(allocator: std.mem.Allocator, request: Request, code: []const u8, message: []const u8, retry: Retry) ![]u8 {
    const response = replies.Failure{ .type = "error", .requestID = request.requestID, .operation = @tagName(request.operation), .scope = request.scope, .@"error" = .{ .code = code, .message = message, .retry = retry } };
    return std.json.Stringify.valueAlloc(allocator, response, .{ .emit_null_optional_fields = false });
}

/// Enforces bounded nesting while respecting strings; callers still parse and validate JSON.
pub fn checkDepth(bytes: []const u8) !void {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') quoted = false;
            continue;
        }
        switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > 64) return error.InvalidControlRequest;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidControlRequest;
                depth -= 1;
            },
            else => {},
        }
    }
    if (quoted or depth != 0) return error.InvalidControlRequest;
}

fn testControl() Control {
    return Control.init(.{ .server_id = identities.newUUID(), .session_id = identities.newUUID() }, identities.newUUID());
}

fn testRequest(allocator: std.mem.Allocator, control: *const Control, operation: @TypeOf(@as(Request, undefined).operation), params: []const u8) ![]u8 {
    const value = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
    defer value.deinit();
    const request = Request{ .type = "request", .requestID = "00000000-0000-4000-8000-000000000001", .clientID = "00000000-0000-4000-8000-000000000002", .scope = operation.metadata().scope, .operation = operation, .target = if (operation.metadata().scope == .session) .{ .serverID = &control.server_id, .serverEpoch = &control.epoch, .sessionID = &control.session_id } else null, .params = value.value };
    return std.json.Stringify.valueAlloc(allocator, request, .{ .emit_null_optional_fields = false });
}

test "handshake advertises implemented capabilities and borrows stable identity" {
    const control = testControl();
    const hello = control.hello();
    try hello.negotiateRequired(&.{"health_check"});
    try std.testing.expectError(error.MissingCapabilities, hello.negotiate());
    try std.testing.expectEqualStrings(&control.server_id, hello.serverID);
    try std.testing.expectEqual(@as(usize, 4), hello.capabilities.len);
}

test "status and health replies satisfy the shared response envelope" {
    const allocator = std.testing.allocator;
    var control = testControl();
    inline for (.{ .@"server.status", .@"health.check" }) |operation| {
        const bytes = try testRequest(allocator, &control, operation, "{}");
        defer allocator.free(bytes);
        const request = try std.json.parseFromSlice(Request, allocator, bytes, .{});
        defer request.deinit();
        const output = try control.respond(allocator, bytes);
        defer allocator.free(output);
        const response = try std.json.parseFromSlice(replies.Response(std.json.Value), allocator, output, .{});
        defer response.deinit();
        try response.value.validate(request.value);
        if (operation == .@"server.status") {
            try std.testing.expectEqualStrings(version, response.value.result.object.get("version").?.string);
        } else try std.testing.expect(response.value.result.object.get("alive").?.bool);
    }
}

test "stale target and unimplemented operations return bounded explicit failures" {
    const allocator = std.testing.allocator;
    var control = testControl();
    var stale = control;
    stale.epoch = identities.uuidText(identities.newUUID());
    inline for (.{
        .{ &stale, .@"server.status", "{}", "stale_server_epoch" },
        .{ &control, .@"terminal.list", "{}", "missing_capability" },
        .{ &control, .@"server.status", "{\"unexpected\":true}", "invalid_request" },
        .{ &control, .@"session.list", "{}", "unsupported_operation" },
    }) |case| {
        const bytes = try testRequest(allocator, case[0], case[1], case[2]);
        defer allocator.free(bytes);
        const output = try control.respond(allocator, bytes);
        defer allocator.free(output);
        const response = try std.json.parseFromSlice(replies.Failure, allocator, output, .{});
        defer response.deinit();
        const request = try std.json.parseFromSlice(Request, allocator, bytes, .{});
        defer request.deinit();
        try response.value.validate(request.value);
        try std.testing.expectEqualStrings(case[3], response.value.@"error".code);
        try std.testing.expect(response.value.target == null);
    }
}

test "malformed oversized and deeply nested control payloads fail closed" {
    const allocator = std.testing.allocator;
    var control = testControl();
    try std.testing.expectError(error.InvalidControlRequest, control.respond(allocator, "{}"));
    const large = try allocator.alloc(u8, protocol.maximum_control_bytes + 1);
    defer allocator.free(large);
    try std.testing.expectError(error.ControlFrameTooLarge, control.respond(allocator, large));
    try std.testing.expectError(error.InvalidControlRequest, checkDepth("[" ** 65 ++ "]" ** 65));
    try checkDepth("{\"quoted\":\"[{}]\\\"\"}");
}

test "stop validates target and params before changing service state" {
    const allocator = std.testing.allocator;
    var control = testControl();
    var stale = control;
    stale.epoch = identities.uuidText(identities.newUUID());
    const bad = try testRequest(allocator, &stale, .@"server.stop", "{}");
    defer allocator.free(bad);
    const rejected = try control.respond(allocator, bad);
    allocator.free(rejected);
    try std.testing.expect(!control.stop_requested);
    const extra = try testRequest(allocator, &control, .@"server.stop", "{\"extra\":true}");
    defer allocator.free(extra);
    const invalid = try control.respond(allocator, extra);
    allocator.free(invalid);
    try std.testing.expect(!control.stop_requested);
    const request = try testRequest(allocator, &control, .@"server.stop", "{}");
    defer allocator.free(request);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, control.respond(failing.allocator(), request));
    try std.testing.expect(!control.stop_requested);
    const accepted = try control.respond(allocator, request);
    defer allocator.free(accepted);
    try std.testing.expect(control.stop_requested);
    const repeated = try control.respond(allocator, request);
    defer allocator.free(repeated);
    try std.testing.expectEqualStrings(accepted, repeated);
}

test "terminal dispatch preserves original connection generation for deferred work" {
    const Deferred = struct {
        generation: u64 = 0,
        fn respond(context: *anyopaque, _: std.mem.Allocator, request: Request, generation: u64) anyerror!?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(.@"terminal.list", request.operation);
            self.generation = generation;
            return null;
        }
        fn disconnect(_: *anyopaque, _: u64) void {}
    };
    var domain = Deferred{};
    var control = testControl();
    control.handler = .{ .context = &domain, .respond = Deferred.respond, .disconnect = Deferred.disconnect };
    const bytes = try testRequest(std.testing.allocator, &control, .@"terminal.list", "{}");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(?[]u8, null), try control.respondForConnection(std.testing.allocator, bytes, 29));
    try std.testing.expectEqual(@as(u64, 29), domain.generation);
}
