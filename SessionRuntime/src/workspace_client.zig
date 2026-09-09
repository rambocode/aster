const std = @import("std");
const transport = @import("service_client.zig");
const handshake = @import("handshake.zig");
const identity = @import("service_identity.zig");
const requests = @import("operation_request.zig");
const replies = @import("operation_response.zig");
const Operation = @import("operation_kind.zig").Operation;

/// Terminal to launch inside a newly created structural node. argv is passed
/// literally; the execution machine resolves it and validates the directory.
pub const Spec = struct { cwd: []const u8, argv: []const []const u8 };

pub const Command = union(enum) {
    snapshot,
    workspace_list,
    workspace_create: struct { title: []const u8, spec: Spec, revision: u64 },
    workspace_update: struct { workspace_id: []const u8, title: []const u8, revision: u64 },
    workspace_close: struct { workspace_id: []const u8, revision: u64 },
    tab_create: struct { workspace_id: []const u8, title: []const u8, spec: Spec, revision: u64 },
    tab_update: struct { tab_id: []const u8, title: []const u8, revision: u64 },
    tab_close: struct { tab_id: []const u8, revision: u64 },
    pane_split: struct { pane_id: []const u8, direction: []const u8, spec: Spec, revision: u64 },
    pane_update: struct { pane_id: []const u8, title: []const u8, revision: u64 },
    pane_close: struct { pane_id: []const u8, revision: u64 },
};

/// Single-threaded CLI client for session-scope workspace operations.
///
/// `expectedRevision` is always supplied by the caller, never read back from the
/// server first. That is what makes concurrent submission testable: two
/// processes can deliberately submit the same revision, and exactly one of them
/// must win. A failed mutation is never retried here; the caller reconciles with
/// session.snapshot.
pub fn execute(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, command: Command, timeout_ms: u32) !transport.Reply {
    const request_id = identity.uuidText(identity.newUUID());
    const client_id = identity.uuidText(identity.newUUID());
    const timestamp = std.time.milliTimestamp();
    const created: ?u64 = if (timestamp >= 0) @intCast(timestamp) else null;
    return transact(allocator, parent_path, name, command, timeout_ms, &request_id, &client_id, created) catch |err| {
        return .{ .is_error = true, .bytes = try std.json.Stringify.valueAlloc(allocator, .{
            .type = "client_error",
            .requestID = &request_id,
            .clientID = &client_id,
            .code = @errorName(err),
            .retry = "after_query",
        }, .{ .emit_null_optional_fields = false }) };
    };
}

fn transact(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, command: Command, timeout_ms: u32, request_id: []const u8, client_id: []const u8, created: ?u64) !transport.Reply {
    var deadline = try transport.Deadline.init(timeout_ms);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    const operation = kind(command);
    const metadata = operation.metadata();
    if (metadata.requires_created_at and created == null) return error.InvalidClientClock;
    const params = try parameters(temporary, command);
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    const stat = try std.posix.fstat(parent.fd);
    if (stat.uid != std.posix.geteuid() or stat.mode & 0o077 != 0) return error.UnsafeStateParent;
    const stream = try transport.connect(parent, name, &deadline);
    defer stream.close();
    const hello_bytes = try transport.readFrame(a, stream, &deadline);
    defer a.free(hello_bytes);
    const scratch = try a.alloc(u8, 8 * 1024 * 1024);
    defer a.free(scratch);
    var bounded = std.heap.FixedBufferAllocator.init(scratch);
    const wire = bounded.allocator();
    const hello = try std.json.parseFromSlice(handshake.Hello, wire, hello_bytes, .{ .ignore_unknown_fields = true });
    defer hello.deinit();
    try hello.value.negotiateRequired(if (metadata.capability) |capability| &.{capability} else &.{"session_snapshot"});
    const request: requests.Request = .{
        .type = "request",
        .requestID = request_id,
        .clientID = client_id,
        .scope = .session,
        .operation = operation,
        .createdAtUnixMs = if (metadata.requires_created_at) created else null,
        .expectedRevision = if (metadata.requires_revision) revision(command) else null,
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
    const tag = try std.json.parseFromSlice(std.json.Value, wire, bytes, .{});
    defer tag.deinit();
    if (tag.value != .object) return error.InvalidWorkspaceReply;
    const message = tag.value.object.get("type") orelse return error.InvalidWorkspaceReply;
    if (message != .string) return error.InvalidWorkspaceReply;
    if (std.mem.eql(u8, message.string, "error")) {
        const failure = try std.json.parseFromSlice(replies.Failure, wire, bytes, .{});
        defer failure.deinit();
        try failure.value.validate(request);
        return .{ .bytes = bytes, .is_error = true };
    }
    const parsed = try std.json.parseFromSlice(replies.Response(std.json.Value), wire, bytes, .{});
    defer parsed.deinit();
    try parsed.value.validate(request);
    return .{ .bytes = bytes, .is_error = false };
}

fn kind(command: Command) Operation {
    return switch (command) {
        .snapshot => .@"session.snapshot",
        .workspace_list => .@"workspace.list",
        .workspace_create => .@"workspace.create",
        .workspace_update => .@"workspace.update",
        .workspace_close => .@"workspace.close",
        .tab_create => .@"tab.create",
        .tab_update => .@"tab.update",
        .tab_close => .@"tab.close",
        .pane_split => .@"pane.split",
        .pane_update => .@"pane.update",
        .pane_close => .@"pane.close",
    };
}

fn revision(command: Command) u64 {
    return switch (command) {
        .snapshot, .workspace_list => 0,
        .workspace_create => |value| value.revision,
        .workspace_update => |value| value.revision,
        .workspace_close => |value| value.revision,
        .tab_create => |value| value.revision,
        .tab_update => |value| value.revision,
        .tab_close => |value| value.revision,
        .pane_split => |value| value.revision,
        .pane_update => |value| value.revision,
        .pane_close => |value| value.revision,
    };
}

fn parameters(a: std.mem.Allocator, command: Command) !std.json.Value {
    var result = std.json.ObjectMap.init(a);
    switch (command) {
        .snapshot, .workspace_list => {},
        .workspace_create => |value| {
            try result.put("title", .{ .string = try shortText(value.title) });
            try result.put("terminal", try terminalSpec(a, value.spec));
        },
        .workspace_update => |value| {
            try result.put("workspaceID", .{ .string = try validated(value.workspace_id) });
            try result.put("title", .{ .string = try shortText(value.title) });
        },
        .workspace_close => |value| try result.put("workspaceID", .{ .string = try validated(value.workspace_id) }),
        .tab_update => |value| {
            try result.put("tabID", .{ .string = try validated(value.tab_id) });
            try result.put("title", .{ .string = try shortText(value.title) });
        },
        .tab_close => |value| try result.put("tabID", .{ .string = try validated(value.tab_id) }),
        .pane_update => |value| {
            try result.put("paneID", .{ .string = try validated(value.pane_id) });
            try result.put("title", .{ .string = try shortText(value.title) });
        },
        .tab_create => |value| {
            try result.put("workspaceID", .{ .string = try validated(value.workspace_id) });
            try result.put("title", .{ .string = try shortText(value.title) });
            try result.put("terminal", try terminalSpec(a, value.spec));
        },
        .pane_split => |value| {
            try result.put("paneID", .{ .string = try validated(value.pane_id) });
            const known = for ([_][]const u8{ "left", "right", "up", "down" }) |name| {
                if (std.mem.eql(u8, name, value.direction)) break true;
            } else false;
            if (!known) return error.InvalidSplitDirection;
            try result.put("direction", .{ .string = value.direction });
            try result.put("terminal", try terminalSpec(a, value.spec));
        },
        .pane_close => |value| try result.put("paneID", .{ .string = try validated(value.pane_id) }),
    }
    return .{ .object = result };
}

fn terminalSpec(a: std.mem.Allocator, spec: Spec) !std.json.Value {
    if (spec.cwd.len == 0 or spec.cwd.len > 4096 or !std.fs.path.isAbsolute(spec.cwd) or nul(spec.cwd)) return error.InvalidTerminalDirectory;
    if (spec.argv.len == 0 or spec.argv.len > 128 or spec.argv[0].len == 0) return error.InvalidTerminalArguments;
    var argv = std.json.Array.init(a);
    for (spec.argv) |item| {
        if (item.len > 4096 or nul(item)) return error.InvalidTerminalArguments;
        try argv.append(.{ .string = item });
    }
    var object = std.json.ObjectMap.init(a);
    try object.put("cwd", .{ .string = spec.cwd });
    try object.put("argv", .{ .array = argv });
    return .{ .object = object };
}

fn shortText(value: []const u8) ![]const u8 {
    if (value.len == 0 or value.len > 128 or nul(value)) return error.InvalidTitle;
    return value;
}

fn validated(value: []const u8) ![]const u8 {
    if (!requests.validID(value)) return error.InvalidResourceID;
    return value;
}

fn nul(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) != null;
}
