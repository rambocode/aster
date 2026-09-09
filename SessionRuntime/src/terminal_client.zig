const std = @import("std");
const transport = @import("service_client.zig");
const handshake = @import("handshake.zig");
const identity = @import("service_identity.zig");
const requests = @import("operation_request.zig");
const replies = @import("operation_response.zig");
const Geometry = @import("geometry.zig").Geometry;
const Operation = @import("operation_kind.zig").Operation;

pub const Create = struct {
    cwd: []const u8,
    argv: []const []const u8,
    /// Literal NAME=value entries, transformed into the protocol object.
    environment: []const []const u8 = &.{},
    geometry: Geometry = .{ .rows = 24, .columns = 80 },
};
pub const Command = union(enum) { create: Create, list, terminate: []const u8 };

/// Single-threaded CLI only (transport uses temporary cwd for Unix socket paths).
/// Returns caller-owned schema response/error or sanitized client_error JSON.
/// One request identity and timestamp are minted per call. Never retries a write;
/// uncertain outcomes retain that identity for request.status reconciliation.
pub fn execute(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, command: Command, timeout_ms: u32) !transport.Reply {
    const request_id = identity.uuidText(identity.newUUID());
    const client_id = identity.uuidText(identity.newUUID());
    const timestamp = std.time.milliTimestamp();
    const created: ?u64 = if (command == .list) null else if (timestamp >= 0) @intCast(timestamp) else null;
    return transact(allocator, parent_path, name, command, timeout_ms, &request_id, &client_id, created) catch |err| {
        return .{ .is_error = true, .bytes = try std.json.Stringify.valueAlloc(allocator, .{
            .type = "client_error",
            .requestID = &request_id,
            .clientID = &client_id,
            .createdAtUnixMs = created,
            .code = @errorName(err),
            .retry = "after_query",
        }, .{ .emit_null_optional_fields = false }) };
    };
}

fn transact(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, command: Command, timeout_ms: u32, request_id: []const u8, client_id: []const u8, created: ?u64) !transport.Reply {
    var deadline = try transport.Deadline.init(timeout_ms);
    if (command != .list and created == null) return error.InvalidClientClock;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    const params = try parameters(temporary, command);
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    const stat = try std.posix.fstat(parent.fd);
    if (stat.uid != std.posix.geteuid() or stat.mode & 0o077 != 0) return error.UnsafeStateParent;
    const stream = try transport.connect(parent, name, &deadline);
    defer stream.close();
    const hello_bytes = try transport.readFrame(a, stream, &deadline);
    defer a.free(hello_bytes);
    // Wire parsing is independently bounded even when adversarial JSON expands.
    const scratch = try a.alloc(u8, 8 * 1024 * 1024);
    defer a.free(scratch);
    var bounded = std.heap.FixedBufferAllocator.init(scratch);
    const wire = bounded.allocator();
    const hello = try std.json.parseFromSlice(handshake.Hello, wire, hello_bytes, .{ .ignore_unknown_fields = true });
    defer hello.deinit();
    try hello.value.negotiateRequired(&.{"terminal_control"});
    const request: requests.Request = .{
        .type = "request",
        .requestID = request_id,
        .clientID = client_id,
        .scope = .session,
        .operation = operation(command),
        .createdAtUnixMs = created,
        .target = .{ .serverID = hello.value.serverID, .serverEpoch = hello.value.serverEpoch, .sessionID = hello.value.sessionID },
        .params = params,
    };
    try request.validateEnvelope();
    const encoded = try std.json.Stringify.valueAlloc(temporary, request, .{ .emit_null_optional_fields = false });
    if (encoded.len > @import("protocol.zig").maximum_control_bytes) return error.RequestTooLarge;
    var header: [5]u8 = undefined;
    header[0] = 1;
    std.mem.writeInt(u32, header[1..5], @intCast(encoded.len), .big);
    try transport.writeAll(stream, &header, &deadline);
    try transport.writeAll(stream, encoded, &deadline);
    const bytes = try transport.readReply(a, stream, &deadline, request.target.?);
    errdefer a.free(bytes);
    const is_error = try validateResponse(wire, bytes, request, command);
    return .{ .bytes = bytes, .is_error = is_error };
}
fn operation(command: Command) Operation {
    return switch (command) {
        .create => .@"terminal.create",
        .list => .@"terminal.list",
        .terminate => .@"terminal.terminate",
    };
}
fn parameters(a: std.mem.Allocator, command: Command) !std.json.Value {
    var result = std.json.ObjectMap.init(a);
    switch (command) {
        .list => {},
        .terminate => |id| {
            if (!requests.validID(id)) return error.InvalidTerminalID;
            try result.put("terminalID", .{ .string = id });
        },
        .create => |spec| {
            if (spec.cwd.len == 0 or spec.cwd.len > 4096 or !std.fs.path.isAbsolute(spec.cwd) or nul(spec.cwd)) return error.InvalidTerminalDirectory;
            if (spec.argv.len == 0 or spec.argv.len > 128 or spec.argv[0].len == 0) return error.InvalidTerminalArguments;
            var argv: std.array_list.Managed(std.json.Value) = .init(a);
            for (spec.argv) |arg| {
                if (arg.len > 4096 or nul(arg)) return error.InvalidTerminalArguments;
                try argv.append(.{ .string = arg });
            }
            if (spec.environment.len > 128) return error.InvalidTerminalEnvironment;
            var env = std.json.ObjectMap.init(a);
            for (spec.environment) |item| {
                const equal = std.mem.indexOfScalar(u8, item, '=') orelse return error.InvalidTerminalEnvironment;
                if (equal == 0 or equal > 256 or item.len - equal - 1 > 8192 or nul(item)) return error.InvalidTerminalEnvironment;
                if (env.contains(item[0..equal])) return error.DuplicateEnvironmentName;
                try env.put(item[0..equal], .{ .string = item[equal + 1 ..] });
            }
            try spec.geometry.validate();
            try result.put("cwd", .{ .string = spec.cwd });
            try result.put("argv", .{ .array = argv });
            try result.put("environment", .{ .object = env });
            var geometry = std.json.ObjectMap.init(a);
            try geometry.put("rows", .{ .integer = spec.geometry.rows });
            try geometry.put("columns", .{ .integer = spec.geometry.columns });
            try geometry.put("pixelWidth", .{ .integer = spec.geometry.pixel_width });
            try geometry.put("pixelHeight", .{ .integer = spec.geometry.pixel_height });
            try result.put("geometry", .{ .object = geometry });
        },
    }
    return .{ .object = result };
}
fn nul(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) != null;
}
const Terminal = struct {
    terminalID: []const u8,
    cwd: []const u8,
    state: enum { running, terminating, exited, unavailable },
    pid: ?u32 = null,
    exitCode: ?i32 = null,
    signal: ?u8 = null,
    title: ?[]const u8 = null,
    geometry: ?struct { rows: u16, columns: u16, pixelWidth: ?u16 = null, pixelHeight: ?u16 = null } = null,
    fn validate(self: Terminal) !void {
        if (!requests.validID(self.terminalID) or self.cwd.len == 0 or self.cwd.len > 4096 or !std.fs.path.isAbsolute(self.cwd) or nul(self.cwd)) return error.InvalidTerminalReply;
        if (self.pid != null and self.pid.? == 0) return error.InvalidTerminalReply;
        if (self.signal) |signal| if (signal == 0 or signal > 128) return error.InvalidTerminalReply;
        if (self.title) |title| if (title.len > 4096) return error.InvalidTerminalReply;
        if (self.geometry) |g| if (g.rows == 0 or g.columns == 0) return error.InvalidTerminalReply;
    }
};
fn validateResponse(a: std.mem.Allocator, bytes: []const u8, request: requests.Request, command: Command) !bool {
    const tag = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer tag.deinit();
    if (tag.value != .object) return error.InvalidTerminalReply;
    const kind = tag.value.object.get("type") orelse return error.InvalidTerminalReply;
    if (kind != .string) return error.InvalidTerminalReply;
    if (std.mem.eql(u8, kind.string, "error")) {
        const failure = try std.json.parseFromSlice(replies.Failure, a, bytes, .{});
        defer failure.deinit();
        try failure.value.validate(request);
        return true;
    }
    if (command == .list) {
        const parsed = try std.json.parseFromSlice(replies.Response(struct { terminals: []Terminal }), a, bytes, .{});
        defer parsed.deinit();
        try parsed.value.validate(request);
        if (parsed.value.result.terminals.len > 1024) return error.InvalidTerminalReply;
        for (parsed.value.result.terminals) |terminal| try terminal.validate();
    } else {
        const parsed = try std.json.parseFromSlice(replies.Response(Terminal), a, bytes, .{});
        defer parsed.deinit();
        try parsed.value.validate(request);
        try parsed.value.result.validate();
        if (command == .terminate and (!std.mem.eql(u8, command.terminate, parsed.value.result.terminalID) or parsed.value.result.state != .exited)) return error.InvalidTerminalReply;
    }
    return false;
}

test "terminal client preserves literal arguments and request environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parameters(arena.allocator(), .{ .create = .{ .cwd = "/remote path", .argv = &.{ "tool", "$(literal); a" }, .environment = &.{"TOKEN=secret=value"} } });
    try std.testing.expectEqualStrings("$(literal); a", value.object.get("argv").?.array.items[1].string);
    try std.testing.expectEqualStrings("secret=value", value.object.get("environment").?.object.get("TOKEN").?.string);
    try std.testing.expectError(error.DuplicateEnvironmentName, parameters(arena.allocator(), .{ .create = .{ .cwd = "/", .argv = &.{"tool"}, .environment = &.{ "A=1", "A=2" } } }));
}
