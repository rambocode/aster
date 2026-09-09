const std = @import("std");
const Request = @import("operation_request.zig").Request;
const replies = @import("operation_response.zig");
const registry = @import("session_registry.zig");
const journal = @import("idempotency_log.zig");

const Retry = @TypeOf(@as(replies.Failure, undefined).@"error".retry);

/// Registry-scope endpoint over one private state parent directory.
///
/// Registry requests carry no target: they address the whole named-session
/// registry, not a single service. A request delivered over a session's control
/// socket is served against the state parent that session lives in, and the CLI
/// serves the very same code against the directory the user named, so both
/// entry points share one implementation and one set of rules.
///
/// `log` is the serving session's durable journal. It is present for socket
/// requests so a retried session.create/stop/delete replays its first outcome;
/// the CLI passes null because each invocation mints a fresh request identity
/// and never retries a mutation on its own.
pub const Endpoint = struct {
    registry: registry.Registry,
    log: ?*journal.Log = null,
    /// Current service incarnation; required whenever `log` is present.
    epoch: ?[16]u8 = null,


    pub fn respond(self: *Endpoint, a: std.mem.Allocator, r: Request) ![]u8 {
        return self.dispatch(a, r) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try failure(a, r, errorCode(err), errorRetry(err)),
        };
    }

    fn dispatch(self: *Endpoint, a: std.mem.Allocator, r: Request) ![]u8 {
        if (r.scope != .registry) return error.WrongScope;
        switch (r.operation) {
            .@"session.list" => {
                try only(r.params, &.{});
                var listing = try self.registry.list(a);
                defer listing.deinit();
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                var array = std.json.Array.init(arena.allocator());
                for (listing.sessions) |session| try array.append(try sessionValue(arena.allocator(), session));
                return success(a, r, .{ .sessions = std.json.Value{ .array = array } });
            },
            .@"session.attach" => {
                try only(r.params, &.{"sessionID"});
                const session = try self.registry.attach(a, try idParam(r.params, "sessionID"));
                return self.encodeSession(a, r, session);
            },
            .@"session.create" => {
                try only(r.params, &.{"name"});
                const name = try stringParam(r.params, "name");
                return self.durableAction(a, r, Action{ .create = name });
            },
            .@"session.stop" => {
                try only(r.params, &.{"sessionID"});
                return self.durableAction(a, r, Action{ .stop = try idParam(r.params, "sessionID") });
            },
            .@"session.delete" => {
                try only(r.params, &.{"sessionID"});
                return self.durableAction(a, r, Action{ .delete = try idParam(r.params, "sessionID") });
            },
            else => return error.UnsupportedOperation,
        }
    }

    const Action = union(enum) { create: []const u8, stop: [36]u8, delete: [36]u8 };

    /// Reserve, execute, then persist the outcome. Without a journal the action
    /// still runs exactly as specified; only replay of a repeated request
    /// identity is unavailable, and the CLI never repeats one.
    fn durableAction(self: *Endpoint, a: std.mem.Allocator, r: Request, action: Action) ![]u8 {
        const timestamp = r.createdAtUnixMs orelse return error.InvalidRequest;
        const log = self.log orelse return self.execute(a, r, action);
        const epoch = self.epoch orelse return self.execute(a, r, action);
        if (log.poisoned) return error.LogRequiresReopen;
        const intent = journal.Intent{
            .key = .{ .client_id = try binaryID(r.clientID), .request_id = try binaryID(r.requestID) },
            .fingerprint = try fingerprint(a, r),
            .epoch = epoch,
            .created_ms = timestamp,
            .operation = r.operation,
        };
        const wall: u64 = @intCast(@max(0, std.time.milliTimestamp()));
        if (try log.lookup(intent, epoch, wall)) |decision| return try replay(a, r, decision);
        const decision = try log.reserve(intent, epoch, wall);
        if (decision != .reserved) return try replay(a, r, decision);
        // Record deterministic failures too, so a retried session.create keeps
        // reporting session_exists instead of degrading into uncertainty.
        const response = self.execute(a, r, action) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try failure(a, r, errorCode(err), errorRetry(err)),
        };
        log.complete(intent.key, intent.fingerprint, response) catch {
            log.poisoned = true;
            a.free(response);
            return failure(a, r, "outcome_unknown", .after_query);
        };
        return response;
    }

    fn replay(a: std.mem.Allocator, r: Request, decision: journal.Decision) ![]u8 {
        return switch (decision) {
            .conflict => failure(a, r, "invalid_request", .never),
            .request_expired => failure(a, r, "request_expired", .after_query),
            .outcome_unknown => failure(a, r, "outcome_unknown", .after_query),
            .reserved => error.InvalidRequest,
            .replay => |old| a.dupe(u8, old.response),
        };
    }

    fn execute(self: *Endpoint, a: std.mem.Allocator, r: Request, action: Action) ![]u8 {
        switch (action) {
            .create => |name| return self.encodeSession(a, r, try self.registry.create(a, name)),
            .stop => |id| return self.encodeSession(a, r, try self.registry.stop(a, id)),
            .delete => |id| return success(a, r, .{ .deleted = try self.registry.delete(a, id) }),
        }
    }

    fn encodeSession(_: *Endpoint, a: std.mem.Allocator, r: Request, session: registry.Session) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        return success(a, r, try sessionValue(arena.allocator(), session));
    }
};

pub fn sessionValue(arena: std.mem.Allocator, session: registry.Session) !std.json.Value {
    var object = std.json.ObjectMap.init(arena);
    try object.put("sessionID", .{ .string = try arena.dupe(u8, &session.sessionID) });
    try object.put("name", .{ .string = try arena.dupe(u8, session.name()) });
    try object.put("state", .{ .string = @tagName(session.state) });
    if (session.serverID) |value| try object.put("serverID", .{ .string = try arena.dupe(u8, &value) });
    if (session.serverEpoch) |value| try object.put("serverEpoch", .{ .string = try arena.dupe(u8, &value) });
    return .{ .object = object };
}

/// Registry responses carry neither target nor revision: the registry is not a
/// single service instance and has no session revision of its own.
fn success(a: std.mem.Allocator, r: Request, result: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, replies.Response(@TypeOf(result)){
        .type = "response",
        .requestID = r.requestID,
        .scope = r.scope,
        .operation = r.operation,
        .result = result,
    }, .{ .emit_null_optional_fields = false });
}

fn failure(a: std.mem.Allocator, r: Request, code: []const u8, retry: Retry) ![]u8 {
    return std.json.Stringify.valueAlloc(a, replies.Failure{
        .type = "error",
        .requestID = r.requestID,
        .operation = @tagName(r.operation),
        .scope = r.scope,
        .@"error" = .{ .code = code, .message = code, .retry = retry },
    }, .{ .emit_null_optional_fields = false });
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.SessionExists => "session_exists",
        error.SessionNotFound, error.SessionNotStarted, error.FileNotFound => "session_not_found",
        error.SessionRunning => "session_running",
        error.WrongScope => "wrong_scope",
        error.UnsupportedOperation => "unsupported_operation",
        error.ResourceLimit => "resource_limit",
        error.LogRequiresReopen => "outcome_unknown",
        error.StartupOutcomeUnknown => "outcome_unknown",
        error.InvalidSessionName, error.InvalidRequest, error.InvalidStateName, error.SelfSessionTarget => "invalid_request",
        error.UnsafeStateParent, error.UnsafeStateDirectory, error.UnsafeStateLock, error.UnsafeServiceSocket => "permission_denied",
        else => "internal_error",
    };
}

fn errorRetry(err: anyerror) Retry {
    return switch (err) {
        error.StartupOutcomeUnknown, error.LogRequiresReopen => .after_query,
        error.ResourceLimit => .backoff,
        else => .never,
    };
}

fn only(value: std.json.Value, names: []const []const u8) !void {
    if (value != .object) return error.InvalidRequest;
    for (value.object.keys()) |key| {
        var found = false;
        for (names) |name| if (std.mem.eql(u8, key, name)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidRequest;
    }
}

fn stringParam(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidRequest;
    const item = value.object.get(name) orelse return error.InvalidRequest;
    if (item != .string) return error.InvalidRequest;
    return item.string;
}

fn idParam(value: std.json.Value, name: []const u8) ![36]u8 {
    const text = try stringParam(value, name);
    if (!@import("operation_request.zig").validID(text)) return error.InvalidRequest;
    return text[0..36].*;
}

fn binaryID(value: []const u8) ![16]u8 {
    if (!@import("operation_request.zig").validID(value)) return error.InvalidRequest;
    var compact: [32]u8 = undefined;
    var index: usize = 0;
    for (value) |byte| if (byte != '-') {
        compact[index] = byte;
        index += 1;
    };
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, &compact) catch return error.InvalidRequest;
    return result;
}

fn fingerprint(a: std.mem.Allocator, r: Request) ![32]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), .{
        .operation = r.operation,
        .params = r.params,
        .created = r.createdAtUnixMs,
    }, .{});
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub const Outcome = struct { bytes: []u8, is_error: bool };
pub const CliAction = union(enum) { list, create: []const u8, attach: []const u8, stop: []const u8, delete: []const u8 };

/// Structured CLI entry point. It executes the very same registry endpoint the
/// control socket exposes, against the state parent the user named, and returns
/// the identical response/error envelope. Nothing here retries a mutation: each
/// invocation mints one request identity and reports what actually happened.
pub fn runCli(allocator: std.mem.Allocator, parent_path: []const u8, action: CliAction) !Outcome {
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true, .iterate = true });
    defer parent.close();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    var params = std.json.ObjectMap.init(temporary);
    const operation: @import("operation_kind.zig").Operation = switch (action) {
        .list => .@"session.list",
        .create => |name| blk: {
            try params.put("name", .{ .string = name });
            break :blk .@"session.create";
        },
        .attach => |id| blk: {
            try params.put("sessionID", .{ .string = id });
            break :blk .@"session.attach";
        },
        .stop => |id| blk: {
            try params.put("sessionID", .{ .string = id });
            break :blk .@"session.stop";
        },
        .delete => |id| blk: {
            try params.put("sessionID", .{ .string = id });
            break :blk .@"session.delete";
        },
    };
    const identities = @import("service_identity.zig");
    const request_id = identities.uuidText(identities.newUUID());
    const client_id = identities.uuidText(identities.newUUID());
    const timestamp = std.time.milliTimestamp();
    if (operation.metadata().requires_created_at and timestamp < 0) return error.InvalidClientClock;
    const request = Request{
        .type = "request",
        .requestID = &request_id,
        .clientID = &client_id,
        .scope = .registry,
        .operation = operation,
        .createdAtUnixMs = if (operation.metadata().requires_created_at) @intCast(timestamp) else null,
        .params = .{ .object = params },
    };
    try request.validateEnvelope();
    var endpoint = Endpoint{ .registry = .{ .parent = parent } };
    const bytes = try endpoint.respond(allocator, request);
    errdefer allocator.free(bytes);
    const decoded = try std.json.parseFromSlice(std.json.Value, temporary, bytes, .{});
    defer decoded.deinit();
    const kind = decoded.value.object.get("type") orelse return error.InvalidRegistryReply;
    if (kind != .string) return error.InvalidRegistryReply;
    if (std.mem.eql(u8, kind.string, "error")) {
        const parsed = try std.json.parseFromSlice(replies.Failure, temporary, bytes, .{});
        defer parsed.deinit();
        try parsed.value.validate(request);
        return .{ .bytes = bytes, .is_error = true };
    }
    const parsed = try std.json.parseFromSlice(replies.Response(std.json.Value), temporary, bytes, .{});
    defer parsed.deinit();
    try parsed.value.validate(request);
    return .{ .bytes = bytes, .is_error = false };
}

/// Resolves a CLI `<name-or-id>` argument to a stable sessionID. A canonical
/// UUID is used as given; anything else is looked up as a session name so the
/// operator never has to copy an identifier by hand.
pub fn resolveCli(allocator: std.mem.Allocator, parent_path: []const u8, name_or_id: []const u8) ![36]u8 {
    if (@import("operation_request.zig").validID(name_or_id)) return name_or_id[0..36].*;
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true, .iterate = true });
    defer parent.close();
    try registry.validateName(name_or_id);
    const view = registry.Registry{ .parent = parent };
    const session = try view.describe(allocator, name_or_id);
    return session.sessionID;
}
