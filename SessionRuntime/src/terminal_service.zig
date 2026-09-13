const std = @import("std");
const pool_mod = @import("terminal_pool.zig");
const Pool = pool_mod.Pool;
const Request = @import("operation_request.zig").Request;
const ids = @import("service_identity.zig");
const StateDirectory = @import("state_directory.zig").StateDirectory;
const durable = @import("idempotency_log.zig");
const leases = @import("writer_lease.zig");
const replies = @import("operation_response.zig");
const preparation = @import("launch_preparation.zig");
const agent_mod = @import("agent_store.zig");
const ID = [36]u8;
pub const Reply = struct { connection_generation: u64, bytes: []u8 };
/// Lets the workspace domain own the pool completions of the terminals it
/// launched for structural creates. Returning false keeps the original
/// "unowned completion" fault for anything nobody claims.
pub const StructureHook = struct {
    context: *anyopaque,
    claim: *const fn (*anyopaque, pool_mod.Completion) bool,
};
pub const LeaseEvent = struct { connection_generation: u64, terminal_id: ID, grant: leases.Grant, reason: []const u8 };
pub const Terminal = struct {
    terminalID: []const u8,
    cwd: []const u8,
    state: enum { running, terminating, exited, unavailable },
    pid: ?u32 = null,
    exitCode: ?i32 = null,
    signal: ?u32 = null,
    geometry: ?struct { rows: u16, columns: u16, pixelWidth: u32, pixelHeight: u32 } = null,
};
const Attachment = struct { id: ID, terminal_id: ID, owner: leases.Owner, lease: ?leases.Lease };
const LeaseState = struct { terminal_id: ID, state: leases.WriterLease = .{} };
// Input ordering belongs to a connection, not an attachment or terminal. Keep
// the successful acknowledgment revision stable while correlating each retry.
const ControlCursor = struct { generation: u64, sequence: ?u64 = null, fingerprint: [32]u8 = undefined, revision: u64 = 0 };
const Pending = struct {
    intent: durable.Intent,
    request_id: ID,
    client_id: ID,
    terminal_id: ID,
    operation: @TypeOf(@as(Request, undefined).operation),
    generation: ?u64,
    completion: ?pool_mod.Completion = null,
    startup_error: ?anyerror = null,
    response: ?[]u8 = null,
    persisted: bool = false,
    completion_failed: bool = false,
    unknown_response: ?[]u8 = null,
};
const Geometry = struct {
    rows: u16,
    columns: u16,
    pixelWidth: u16 = 0,
    pixelHeight: u16 = 0,
    fn core(self: Geometry) @import("geometry.zig").Geometry {
        return .{ .rows = self.rows, .columns = self.columns, .pixel_width = self.pixelWidth, .pixel_height = self.pixelHeight };
    }
};

/// Session-thread adapter. Pool and locked state outlive this object. Mutations
/// reserve durable intent before acting; success replies require durable
/// completion. A persistence failure returns uncertainty without stopping PTYs.
/// Disconnect discards delivery rights, never an accepted mutation.
pub const Service = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    log: durable.Log,
    identity: ids.Identity,
    epoch: [16]u8,
    server_id: ID,
    session_id: ID,
    epoch_text: ID,
    clock: std.time.Timer,
    /// Standalone fallback used only when no workspace store is attached (unit
    /// tests, terminal-only servers). The terminal domain never advances it.
    revision: u64 = 0,
    /// When set, reads of the layout revision are borrowed from the workspace
    /// store so responses and terminal events quote the same number the layout
    /// transactions use. Read-only for this domain: terminal lifecycle never
    /// advances the layout revision (see `tick`).
    shared_revision: ?*const u64 = null,
    structure_hook: ?StructureHook = null,
    /// Latched durability fault; does not disable reads or existing PTY control.
    persistence_failure: ?anyerror = null,
    pending: std.ArrayList(Pending) = .empty,
    replies: std.ArrayList(Reply) = .empty,
    attachments: std.ArrayList(Attachment) = .empty,
    lease_states: std.ArrayList(LeaseState) = .empty,
    lease_events: std.ArrayList(LeaseEvent) = .empty,
    exit_events: std.ArrayList(ID) = .empty,
    /// Count of published exits; the per-record latch lives on the pool entry.
    reported_exits: u64 = 0,
    completion_encoding_failures: u64 = 0,
    control_cursors: std.ArrayList(ControlCursor) = .empty,
    /// 会话级 Agent 状态存储
    agent_store: agent_mod.Store = undefined,
    /// 待广播的 agent.changed 事件体（已编码 JSON）
    agent_events: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, pool: *Pool, state: *StateDirectory, identity: ids.Identity, epoch: [16]u8) !Service {
        const clock = try std.time.Timer.start();
        var self: Service = .{ .allocator = allocator, .pool = pool, .log = try durable.Log.open(allocator, state, .{}), .identity = identity, .epoch = epoch, .server_id = ids.uuidText(identity.server_id), .session_id = ids.uuidText(identity.session_id), .epoch_text = ids.uuidText(epoch), .clock = clock, .agent_store = agent_mod.Store.init(allocator) };
        errdefer self.deinit();
        try self.control_cursors.ensureTotalCapacity(allocator, 64);
        try self.pending.ensureTotalCapacity(allocator, 64);
        try self.replies.ensureTotalCapacity(allocator, 64);
        try self.attachments.ensureTotalCapacity(allocator, 256);
        try self.lease_states.ensureTotalCapacity(allocator, 64);
        try self.lease_events.ensureTotalCapacity(allocator, 256);
        try self.exit_events.ensureTotalCapacity(allocator, 64);
        try self.agent_events.ensureTotalCapacity(allocator, 64);
        return self;
    }
    pub fn deinit(self: *Service) void {
        for (self.pending.items) |p| {
            if (p.response) |bytes| self.allocator.free(bytes);
            if (p.unknown_response) |bytes| self.allocator.free(bytes);
        }
        for (self.replies.items) |r| self.allocator.free(r.bytes);
        self.pending.deinit(self.allocator);
        self.replies.deinit(self.allocator);
        self.attachments.deinit(self.allocator);
        self.lease_states.deinit(self.allocator);
        self.lease_events.deinit(self.allocator);
        self.exit_events.deinit(self.allocator);
        self.control_cursors.deinit(self.allocator);
        for (self.agent_events.items) |bytes| self.allocator.free(bytes);
        self.agent_events.deinit(self.allocator);
        self.agent_store.deinit();
        self.log.deinit();
    }
    /// Current layout revision, borrowed from the workspace store when attached.
    pub fn currentRevision(self: *const Service) u64 {
        return if (self.shared_revision) |shared| shared.* else self.revision;
    }
    fn now(self: *Service) u64 {
        return self.clock.read() / std.time.ns_per_ms;
    }
    pub fn target(self: *Service) @TypeOf(@as(Request, undefined).target) {
        return .{ .serverID = &self.server_id, .serverEpoch = &self.epoch_text, .sessionID = &self.session_id };
    }
    fn success(self: *Service, allocator: std.mem.Allocator, request: Request, result: anytype) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, replies.Response(@TypeOf(result)){ .type = "response", .requestID = request.requestID, .scope = request.scope, .operation = request.operation, .target = self.target(), .revision = self.currentRevision(), .result = result }, .{ .emit_null_optional_fields = false });
    }
    fn pendingRequest(self: *Service, p: *const Pending) Request {
        return .{ .type = "request", .requestID = &p.request_id, .clientID = &p.client_id, .scope = .session, .operation = p.operation, .target = self.target(), .params = .{ .object = std.json.ObjectMap.init(self.allocator) } };
    }

    pub fn respond(self: *Service, allocator: std.mem.Allocator, request: Request, connection_generation: u64) !?[]u8 {
        return self.dispatch(allocator, request, connection_generation) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try failure(allocator, request, errorCode(err), errorRetry(err)),
        };
    }
    fn dispatch(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) !?[]u8 {
        switch (r.operation) {
            .@"request.status" => return try self.requestStatus(a, r),
            .@"terminal.create", .@"terminal.terminate" => return self.mutate(a, r, generation),
            .@"terminal.list" => {
                try only(r.params, &.{});
                // Live records first, then the bounded recent-exit window, so a
                // terminal that lost its slot still reports its real exit code
                // instead of vanishing silently between two polls.
                var list: [64 + pool_mod.recent_exit_capacity]Terminal = undefined;
                var count: usize = 0;
                for (self.pool.entries.items) |*entry| {
                    list[count] = terminal(entry);
                    count += 1;
                }
                for (self.pool.retired.items) |*record| {
                    list[count] = retiredTerminal(record);
                    count += 1;
                }
                return try self.success(a, r, .{ .terminals = list[0..count] });
            },
            .@"terminal.attach", .@"terminal.observe" => return try self.attach(a, r, generation),
            .@"terminal.release" => return try self.release(a, r, generation),
            .@"terminal.control" => return try self.control(a, r, generation),
            .@"agent.list" => return try self.agentList(a, r),
            .@"agent.report" => return try self.agentReport(a, r),
            .@"agent.explain" => return try self.agentExplain(a, r),
            .@"agent.rename" => return try self.agentRename(a, r),
            .@"agent.acknowledge" => return try self.agentAcknowledge(a, r),
            else => return error.MissingCapability,
        }
    }

    fn requestStatus(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{"queriedRequestID"});
        const queried = try idParam(r.params, "queriedRequestID");
        const client = try textID(r.clientID);
        var result = try self.log.query(.{ .client_id = try binaryID(&client), .request_id = try binaryID(&queried) }, @intCast(@max(0, std.time.milliTimestamp())));
        if (result.state == .pending) {
            var active = false;
            for (self.pending.items) |pending| {
                if (std.mem.eql(u8, &pending.request_id, &queried) and std.mem.eql(u8, &pending.client_id, &client)) {
                    active = true;
                    if (result.operation == null) result.operation = pending.operation;
                    break;
                }
            }
            if (!active) result.state = .unknown;
        }
        var resource_id: ID = undefined;
        var resources: [1][]const u8 = undefined;
        var count: usize = 0;
        var forgotten = false;
        if (result.terminal_id) |value| {
            resource_id = ids.uuidText(value);
            resources[0] = &resource_id;
            count = 1;
            // A committed operation whose terminal the pool no longer knows at
            // all — neither live nor in the recent-exit window — must read as
            // invalidated. Otherwise the stored success response is all a client
            // sees and the original process looks like it is still around. An
            // in-flight or failed operation owns no live resource to invalidate.
            forgotten = result.state == .committed and
                self.pool.find(resource_id) == null and self.pool.findRetired(resource_id) == null;
        }
        const epoch_changed = if (result.epoch) |epoch| !std.mem.eql(u8, &epoch, &self.epoch) else false;
        const invalidated = epoch_changed or forgotten;
        return self.success(a, r, .{
            .queriedRequestID = &queried,
            .operation = if (result.operation) |operation| @tagName(operation) else "unknown",
            .state = result.state,
            .resourceIDs = resources[0..count],
            .resourcesInvalidated = invalidated,
        });
    }

    fn mutate(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) !?[]u8 {
        if (self.log.poisoned) return error.LogRequiresReopen;
        const timestamp = r.createdAtUnixMs orelse return error.InvalidRequest;
        const intent = durable.Intent{ .key = .{ .client_id = try binaryID(r.clientID), .request_id = try binaryID(r.requestID) }, .fingerprint = try fingerprint(a, r), .epoch = self.epoch, .created_ms = timestamp, .operation = r.operation };
        const wall: u64 = @intCast(@max(0, std.time.milliTimestamp()));
        if (try self.log.lookup(intent, self.epoch, wall)) |decision| return try self.replay(a, r, decision);
        if (self.pending.items.len >= 64) return error.ResourceLimit;
        var prepared: ?preparation.Prepared = null;
        defer if (prepared) |*value| value.deinit();
        var terminal_id: ID = undefined;
        if (r.operation == .@"terminal.create") {
            prepared = try prepareLaunch(a, r.params);
            terminal_id = ids.uuidText(ids.newUUID());
        } else {
            try only(r.params, &.{"terminalID"});
            terminal_id = try idParam(r.params, "terminalID");
            if (self.pool.find(terminal_id) == null) return error.TerminalNotFound;
        }
        // Reserve the failure reply before the durable intent or side effect.
        // Completion I/O or allocation failure must not require another allocation
        // merely to report uncertainty and keep unrelated terminals alive.
        const unknown_response = try failure(self.allocator, r, "outcome_unknown", .after_query);
        errdefer self.allocator.free(unknown_response);
        var reserved = intent;
        reserved.terminal_id = try binaryID(&terminal_id);
        const decision = try self.log.reserve(reserved, self.epoch, wall);
        if (decision != .reserved) {
            const response = try self.replay(a, r, decision);
            self.allocator.free(unknown_response);
            return response;
        }
        // Capacity was reserved before the durable boundary; recording accepted
        // work below cannot allocate, even if launching/termination fails.
        self.pending.appendAssumeCapacity(.{ .intent = reserved, .request_id = try textID(r.requestID), .client_id = try textID(r.clientID), .terminal_id = terminal_id, .operation = r.operation, .generation = generation, .unknown_response = unknown_response });
        const p = &self.pending.items[self.pending.items.len - 1];
        if (prepared) |*launch| {
            self.pool.beginCreate(terminal_id, launch.asLaunch()) catch |err| {
                p.startup_error = err;
            };
        } else self.pool.terminate(terminal_id, 1000) catch |err| {
            p.startup_error = err;
        };
        return null;
    }
    fn replay(self: *Service, a: std.mem.Allocator, r: Request, decision: durable.Decision) ![]u8 {
        switch (decision) {
            .conflict => return failure(a, r, "invalid_request", .never),
            .request_expired => return failure(a, r, "request_expired", .after_query),
            .outcome_unknown => return failure(a, r, "outcome_unknown", .after_query),
            .reserved => return error.InvalidRequest,
            .replay => |old| {
                if (!old.resources_invalidated) return a.dupe(u8, old.response);
                const decoded = try std.json.parseFromSlice(std.json.Value, a, old.response, .{});
                defer decoded.deinit();
                if (decoded.value.object.get("result")) |result| {
                    const old_id = result.object.get("terminalID") orelse return error.InvalidRequest;
                    const cwd = result.object.get("cwd") orelse return error.InvalidRequest;
                    return self.success(a, r, Terminal{ .terminalID = old_id.string, .cwd = cwd.string, .state = .unavailable });
                }
                // Error envelopes contain no live resource or target claims.
                return a.dupe(u8, old.response);
            },
        }
    }

    /// A result allocation failure cannot unwind the owning service after the
    /// process mutation already happened. Keep the durable intent unresolved and
    /// use the emergency reply reserved before execution.
    fn completionBytes(self: *Service, pending: *Pending, encoded: std.mem.Allocator.Error![]u8) []u8 {
        return encoded catch {
            self.completion_encoding_failures +|= 1;
            pending.completion_failed = true;
            const reply = pending.unknown_response.?;
            pending.unknown_response = null;
            return reply;
        };
    }

    pub fn tick(self: *Service) !void {
        while (self.pool.takeCompletion()) |completion| {
            var matched = false;
            for (self.pending.items) |*p| if (std.mem.eql(u8, &p.terminal_id, &completion.id) and p.operation == .@"terminal.create") {
                p.completion = completion;
                matched = true;
                break;
            };
            if (!matched) {
                if (self.structure_hook) |hook| matched = hook.claim(hook.context, completion);
            }
            if (!matched) return error.UnownedPoolCompletion;
        }
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const p = &self.pending.items[index];
            if (p.response == null) {
                const r = self.pendingRequest(p);
                if (p.startup_error) |err| {
                    p.response = self.completionBytes(p, failure(self.allocator, r, errorCode(err), errorRetry(err)));
                } else if (p.operation == .@"terminal.create") {
                    const completion = p.completion orelse {
                        index += 1;
                        continue;
                    };
                    p.response = switch (completion.result) {
                        .created => self.completionBytes(p, self.success(self.allocator, r, terminal(self.pool.find(p.terminal_id).?))),
                        .failed => |err| self.completionBytes(p, failure(self.allocator, r, errorCode(err.reason), errorRetry(err.reason))),
                        .cancelled => self.completionBytes(p, failure(self.allocator, r, "service_stopping", .after_reconnect)),
                    };
                } else if (self.pool.find(p.terminal_id)) |entry| {
                    if (entry.session.cleanup_error != null and !entry.session.cleanupComplete()) {
                        p.response = self.completionBytes(p, failure(self.allocator, r, "outcome_unknown", .after_query));
                    } else if (!entry.session.cleanupComplete() or !entry.session.eof) {
                        index += 1;
                        continue;
                    }
                    if (p.response == null) p.response = self.completionBytes(p, self.success(self.allocator, r, terminal(entry)));
                } else if (self.pool.findRetired(p.terminal_id)) |record| {
                    // The record gave its slot back while this stop was in
                    // flight. Report the recorded exit; the process is gone
                    // either way, so this stop did complete.
                    p.response = self.completionBytes(p, self.success(self.allocator, r, retiredTerminal(record)));
                } else {
                    p.response = self.completionBytes(p, failure(self.allocator, r, "terminal_not_found", .never));
                }
            }
            if (!p.persisted and !p.completion_failed) {
                if (self.log.complete(p.intent.key, p.intent.fingerprint, p.response.?)) |_| {
                    p.persisted = true;
                } else |err| {
                    // The action already happened. Preserve its on-disk intent,
                    // stop accepting durable mutations, and drain the existing
                    // PTYs normally. Never retry execution or unwind the service.
                    self.persistence_failure = self.persistence_failure orelse err;
                    self.log.poisoned = true;
                    self.allocator.free(p.response.?);
                    p.response = p.unknown_response.?;
                    p.unknown_response = null;
                    p.completion_failed = true;
                }
            }
            if (p.generation) |generation| {
                if (self.replies.items.len >= 64) {
                    index += 1;
                    continue;
                }
                self.replies.appendAssumeCapacity(.{ .connection_generation = generation, .bytes = p.response.? });
            } else self.allocator.free(p.response.?);
            if (p.unknown_response) |bytes| self.allocator.free(bytes);
            _ = self.pending.orderedRemove(index);
        }
        // Emit the real exit once, only after the final PTY bytes have drained.
        // Pool retains entries in stable order for this service epoch.
        //
        // Why no revision bump here: the revision is the optimistic-concurrency
        // token for *layout* transactions, and a terminal exiting is not a layout
        // edit. Advancing it on reap would reject otherwise legal transactions
        // with `revision_conflict` whenever an unrelated terminal happened to be
        // reaped inside a client's read/submit window, and would break the
        // "exactly one of two racing same-revision submissions wins" rule by
        // making both lose. The exit event still carries the current layout
        // revision, which stays monotonic and never rewinds.
        //
        // The "already reported" latch lives on the record, not on a slot index:
        // a reclaimed record can now hand its slot to a new terminal, and an
        // index-keyed mask would then suppress the newcomer's exit event.
        for (self.pool.entries.items) |*entry| {
            // Hook directives found in this terminal's output become server-side
            // agent state: the server is the authority, hidden panes and other
            // clients learn about it through agent.changed, and nothing depends
            // on a display bridge relaying a private OSC.
            while (entry.session.takeAgentDirective()) |payload| {
                defer self.allocator.free(payload);
                self.applyAgentDirective(entry.id, payload) catch |err| {
                    std.log.warn("agent directive ignored: {s}", .{@errorName(err)});
                };
            }
        }
        for (self.pool.entries.items) |*entry| {
            if (entry.exit_reported or entry.session.exit_status == null or !entry.session.eof or !entry.session.cleanupComplete()) continue;
            if (self.exit_events.items.len == 64) break;
            self.exit_events.appendAssumeCapacity(entry.id);
            entry.exit_reported = true;
            self.reported_exits +|= 1;
            // 终端退出时清理其 Agent 记录
            self.agent_store.removeTerminal(entry.id);
        }
        for (self.lease_states.items) |*state| {
            if (self.lease_events.items.len >= 256) break;
            if (try state.state.expire(self.now())) |old| self.emitLease(state.terminal_id, old, "expired");
        }
    }
    pub fn takeReply(self: *Service) ?Reply {
        return if (self.replies.items.len == 0) null else self.replies.orderedRemove(0);
    }
    /// A queued exit can outlive its record when the slot is reused, so fall back
    /// to the retired summary and skip an event whose summary already aged out
    /// rather than reporting a stale live terminal.
    pub fn takeExitEvent(self: *Service) ?Terminal {
        while (self.exit_events.items.len != 0) {
            const terminal_id = self.exit_events.orderedRemove(0);
            if (self.pool.find(terminal_id)) |entry| return terminal(entry);
            if (self.pool.findRetired(terminal_id)) |record| return retiredTerminal(record);
        }
        return null;
    }

    pub fn takeLeaseEvent(self: *Service) ?LeaseEvent {
        return if (self.lease_events.items.len == 0) null else self.lease_events.orderedRemove(0);
    }
    /// 取出下一条待广播的 agent.changed 事件体（已编码 JSON）
    pub fn takeAgentEvent(self: *Service) ?[]u8 {
        return if (self.agent_events.items.len == 0) null else self.agent_events.orderedRemove(0);
    }
    /// Returns (provider, native_session) for a terminal's agent binding, or
    /// null if no agent is tracked. Used by workspace_service to sync agent
    /// fields to the layout store before persist.
    pub fn getAgentBinding(self: *const Service, terminal_id: ID) ?struct { provider: []const u8, native_session: ?[]const u8 } {
        const agent = self.agent_store.get(terminal_id) orelse return null;
        return .{ .provider = agent.provider, .native_session = agent.native_session };
    }

    /// True if there are pending agent state changes not yet consumed.
    pub fn hasAgentChanges(self: *const Service) bool {
        return self.agent_events.items.len > 0;
    }

    // ---- agent operations ------------------------------------------------

    /// agent.list — 返回所有 Agent 状态
    fn agentList(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{});
        const agents = self.agent_store.list();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        var array = std.json.Array.init(temp);
        for (agents) |agent| try array.append(try agentValue(temp, &agent));
        return try self.success(a, r, .{ .agents = std.json.Value{ .array = array } });
    }

    /// agent.report — 客户端上报 Agent 状态
    fn agentReport(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{ "terminalID", "provider", "state", "name", "nativeSession", "source" });
        const terminal_id = try idParam(r.params, "terminalID");
        const provider = try stringParam(r.params, "provider");
        const state_str = try stringParam(r.params, "state");
        const state = agent_mod.State.fromString(state_str) orelse return error.InvalidRequest;
        const name_val = optionalString(r.params, "name");
        const native_session = optionalString(r.params, "nativeSession");
        const source = optionalString(r.params, "source");
        const accepted = try self.agent_store.report(terminal_id, provider, state, name_val, native_session, source);
        if (accepted) try self.emitAgentChanged(terminal_id);
        return try self.success(a, r, .{ .accepted = accepted });
    }

    /// agent.explain — 查询单个终端的 Agent 详情
    fn agentExplain(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{"terminalID"});
        const terminal_id = try idParam(r.params, "terminalID");
        if (self.agent_store.explain(terminal_id)) |agent| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            return try self.success(a, r, .{ .agent = try agentValue(arena.allocator(), agent) });
        }
        return try self.success(a, r, .{ .agent = null });
    }

    /// agent.rename — 重命名 Agent
    fn agentRename(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{ "terminalID", "name" });
        const terminal_id = try idParam(r.params, "terminalID");
        const name_str = try stringParam(r.params, "name");
        const accepted = try self.agent_store.rename(terminal_id, name_str);
        if (accepted) try self.emitAgentChanged(terminal_id);
        return try self.success(a, r, .{ .accepted = accepted });
    }

    /// agent.acknowledge — 标记 Agent 完成已读
    fn agentAcknowledge(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{"terminalID"});
        const terminal_id = try idParam(r.params, "terminalID");
        const accepted = self.agent_store.acknowledge(terminal_id);
        return try self.success(a, r, .{ .accepted = accepted });
    }

    /// 将 Agent 状态编码为协议 JSON 对象
    fn agentValue(arena: std.mem.Allocator, agent: *const agent_mod.Agent) !std.json.Value {
        var object = std.json.ObjectMap.init(arena);
        try object.put("terminalID", .{ .string = try arena.dupe(u8, &agent.terminal_id) });
        try object.put("provider", .{ .string = try arena.dupe(u8, agent.provider) });
        try object.put("state", .{ .string = @tagName(agent.state) });
        if (agent.name) |n| try object.put("name", .{ .string = try arena.dupe(u8, n) });
        if (agent.native_session) |ns| try object.put("nativeSession", .{ .string = try arena.dupe(u8, ns) });
        if (agent.source) |s| try object.put("source", .{ .string = try arena.dupe(u8, s) });
        try object.put("unread", .{ .bool = agent.unread });
        return .{ .object = object };
    }

    /// 解析 hook 的 OSC 6974 载荷（`AgentState=…;Provider=…[;SessionID=…]`）并作为
    /// hook 来源写入 agent_store。键集合与客户端 `AgentTerminalDirective` 一致：未知键
    /// 或缺少必需键一律拒绝，不猜测。
    fn applyAgentDirective(self: *Service, terminal_id: ID, payload: []const u8) !void {
        var agent_state: ?[]const u8 = null;
        var provider: ?[]const u8 = null;
        var session_id: ?[]const u8 = null;
        var parts = std.mem.splitScalar(u8, payload, ';');
        while (parts.next()) |part| {
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidRequest;
            const key = part[0..eq];
            const value = part[eq + 1 ..];
            if (std.mem.eql(u8, key, "AgentState")) {
                agent_state = value;
            } else if (std.mem.eql(u8, key, "Provider")) {
                provider = value;
            } else if (std.mem.eql(u8, key, "SessionID")) {
                session_id = value;
            } else return error.InvalidRequest;
        }
        const state_text = agent_state orelse return error.InvalidRequest;
        const provider_text = provider orelse return error.InvalidRequest;
        // hook 状态映射到服务端状态集合：processing→working，awaiting-input→blocked，idle/ended→idle
        // （ended 表示 Agent 进程退出，服务端没有单独的「已退出」态，按 idle 记）。
        const state: agent_mod.State = if (std.mem.eql(u8, state_text, "processing")) .working else if (std.mem.eql(u8, state_text, "awaiting-input")) .blocked else if (std.mem.eql(u8, state_text, "idle") or std.mem.eql(u8, state_text, "ended")) .idle else return error.InvalidRequest;
        const accepted = try self.agent_store.report(terminal_id, provider_text, state, null, session_id, "hook");
        if (accepted) try self.emitAgentChanged(terminal_id);
    }

    /// 编码一条 agent.changed 事件并入队待广播
    fn emitAgentChanged(self: *Service, terminal_id: ID) !void {
        if (self.agent_events.items.len >= 64) return;
        const agent = self.agent_store.get(terminal_id) orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const body = try std.json.Stringify.valueAlloc(self.allocator, try agentValue(arena.allocator(), agent), .{});
        self.agent_events.appendAssumeCapacity(body);
    }

    fn emitLease(self: *Service, terminal_id: ID, grant: leases.Grant, reason: []const u8) void {
        self.lease_events.appendAssumeCapacity(.{ .connection_generation = grant.owner.connection_generation, .terminal_id = terminal_id, .grant = grant, .reason = reason });
    }
    fn leaseState(self: *Service, terminal_id: ID) !*LeaseState {
        for (self.lease_states.items) |*state| if (std.mem.eql(u8, &state.terminal_id, &terminal_id)) return state;
        if (self.lease_states.items.len >= 64) return error.ResourceLimit;
        self.lease_states.appendAssumeCapacity(.{ .terminal_id = terminal_id });
        return &self.lease_states.items[self.lease_states.items.len - 1];
    }
    fn expireState(self: *Service, state: *LeaseState, now_ms: u64) !void {
        if (state.state.peek()) |grant| {
            if (now_ms >= grant.last_activity_ms and now_ms - grant.last_activity_ms >= leases.inactivity_ms and self.lease_events.items.len >= 256) return error.ResourceLimit;
        }
        if (try state.state.expire(now_ms)) |old| self.emitLease(state.terminal_id, old, "expired");
    }
    fn attach(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) ![]u8 {
        const observing = r.operation == .@"terminal.observe";
        try only(r.params, if (observing) &.{"terminalID"} else &.{ "terminalID", "takeover", "expectedLeaseEpoch" });
        const terminal_id = try idParam(r.params, "terminalID");
        const entry = self.pool.find(terminal_id) orelse return error.TerminalNotFound;
        if (!observing and (entry.session.exit_status != null or entry.session.termination_timer != null or entry.failure != null)) return error.TerminalNotFound;
        if (self.attachments.items.len >= 256 or self.lease_events.items.len >= 254) return error.ResourceLimit;
        const owner = leases.Owner{ .client_id = try textID(r.clientID), .connection_generation = generation };
        const attachment_id = ids.uuidText(ids.newUUID());
        if (observing) {
            var current_epoch: u64 = 0;
            for (self.lease_states.items) |state| if (std.mem.eql(u8, &state.terminal_id, &terminal_id)) {
                current_epoch = state.state.epoch;
                break;
            };
            const response = try self.success(a, r, .{ .attachmentID = &attachment_id, .terminalID = &terminal_id, .readOnly = true, .currentLeaseEpoch = current_epoch });
            self.attachments.appendAssumeCapacity(.{ .id = attachment_id, .terminal_id = terminal_id, .owner = owner, .lease = null });
            return response;
        }
        const state = try self.leaseState(terminal_id);
        var next = state.state;
        const now_ms = self.now();
        const expired = try next.expire(now_ms);
        const takeover = if (r.params.object.get("takeover")) |value| switch (value) {
            .bool => value.bool,
            else => return error.InvalidRequest,
        } else false;
        const observed_epoch: ?u64 = if (r.params.object.get("expectedLeaseEpoch")) |value| try integer(u64, value) else null;
        const token = ids.uuidText(ids.newUUID());
        var revoked: ?leases.Grant = null;
        const grant = if (takeover) blk: {
            const transfer = try next.takeover(owner, token, observed_epoch orelse return error.InvalidRequest, now_ms);
            revoked = transfer.revoked;
            break :blk transfer.granted;
        } else try next.acquire(owner, token, now_ms);
        const response = try self.success(a, r, .{ .attachmentID = &attachment_id, .terminalID = &terminal_id, .readOnly = false, .lease = .{ .leaseID = &grant.lease.lease_id, .leaseEpoch = grant.lease.lease_epoch } });
        state.state = next;
        self.attachments.appendAssumeCapacity(.{ .id = attachment_id, .terminal_id = terminal_id, .owner = owner, .lease = grant.lease });
        if (expired) |old| self.emitLease(terminal_id, old, "expired");
        if (revoked) |old| self.emitLease(terminal_id, old, "takeover");
        return response;
    }
    fn release(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) ![]u8 {
        try only(r.params, &.{"attachmentID"});
        const attachment_id = try idParam(r.params, "attachmentID");
        const client = try textID(r.clientID);
        for (self.attachments.items, 0..) |item, index| {
            if (!std.mem.eql(u8, &attachment_id, &item.id)) continue;
            if (item.owner.connection_generation != generation or !std.mem.eql(u8, &client, &item.owner.client_id)) return error.PermissionDenied;
            const response = try self.success(a, r, .{ .released = true });
            errdefer a.free(response);
            if (item.lease) |lease| {
                const state = try self.leaseState(item.terminal_id);
                const now_ms = self.now();
                try self.expireState(state, now_ms);
                // A release for a revoked attachment never revokes its successor.
                _ = state.state.release(item.owner, lease, now_ms) catch |err| switch (err) {
                    error.LeaseLost => null,
                    else => return err,
                };
            }
            _ = self.attachments.orderedRemove(index);
            return response;
        }
        return self.success(a, r, .{ .released = false });
    }
    fn control(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) ![]u8 {
        const terminal_id = try idParam(r.params, "terminalID");
        const action = try stringParam(r.params, "action");
        const entry = self.pool.find(terminal_id) orelse return error.TerminalExited;
        const state = try self.leaseState(terminal_id);
        const owner = leases.Owner{ .client_id = try textID(r.clientID), .connection_generation = generation };
        const wire_lease = r.lease orelse return error.LeaseLost;
        const lease = leases.Lease{ .lease_id = try textID(wire_lease.leaseID), .lease_epoch = wire_lease.leaseEpoch };
        const now_ms = self.now();
        try self.expireState(state, now_ms);
        try state.state.check(owner, lease, now_ms);
        const sequence = r.controlSequence orelse return error.InvalidRequest;
        const hash = try controlFingerprint(a, r);
        const cursor = try self.controlCursor(generation);
        if (cursor.sequence) |last| {
            if (sequence == last and std.mem.eql(u8, &hash, &cursor.fingerprint)) {
                const duplicate = try std.json.Stringify.valueAlloc(a, replies.Response(struct { accepted: bool }){ .type = "response", .requestID = r.requestID, .scope = r.scope, .operation = r.operation, .target = self.target(), .revision = cursor.revision, .result = .{ .accepted = true } }, .{ .emit_null_optional_fields = false });
                errdefer a.free(duplicate);
                _ = try state.state.renew(owner, lease, now_ms);
                return duplicate;
            }
            if (sequence <= last) return error.DeliveryUnknown;
        }
        if (entry.session.exit_status != null or entry.failure != null) return error.TerminalExited;
        // Encode acknowledgment before executing input: allocation failure cannot
        // turn a delivered keystroke into an untracked sequence.
        const response = try self.success(a, r, .{ .accepted = true });
        errdefer a.free(response);
        if (std.mem.eql(u8, action, "input")) {
            try only(r.params, &.{ "terminalID", "action", "data" });
            const data = try stringParam(r.params, "data");
            if (data.len > 87384) return error.InvalidRequest;
            const decoder = std.base64.standard.Decoder;
            const length = decoder.calcSizeForSlice(data) catch return error.InvalidRequest;
            if (length > 65536) return error.ResourceLimit;
            const bytes = try a.alloc(u8, length);
            defer a.free(bytes);
            decoder.decode(bytes, data) catch return error.InvalidRequest;
            try entry.session.send(bytes);
        } else if (std.mem.eql(u8, action, "resize")) {
            try only(r.params, &.{ "terminalID", "action", "geometry" });
            const geometry = try parseGeometry(a, r.params.object.get("geometry") orelse return error.InvalidRequest);
            if (geometry.columns > self.pool.limits.maximum_columns or @as(usize, geometry.rows) * geometry.columns > self.pool.limits.maximum_cells) return error.ResourceLimit;
            try entry.session.resizeGeometry(geometry);
            self.pool.enforceHistoryBudget();
        } else if (std.mem.eql(u8, action, "scroll")) {
            try only(r.params, &.{ "terminalID", "action", "rows" });
            const rows = try integer(i32, r.params.object.get("rows") orelse return error.InvalidRequest);
            try entry.session.scroll(rows);
        } else return error.InvalidRequest;
        cursor.sequence = sequence;
        cursor.fingerprint = hash;
        cursor.revision = self.currentRevision();
        _ = try state.state.renew(owner, lease, now_ms);
        return response;
    }
    fn controlCursor(self: *Service, generation: u64) !*ControlCursor {
        for (self.control_cursors.items) |*cursor| if (cursor.generation == generation) return cursor;
        if (self.control_cursors.items.len == 64) return error.ResourceLimit;
        self.control_cursors.appendAssumeCapacity(.{ .generation = generation });
        return &self.control_cursors.items[self.control_cursors.items.len - 1];
    }
    pub fn disconnect(self: *Service, generation: u64) void {
        for (self.control_cursors.items, 0..) |cursor, i| {
            if (cursor.generation == generation) {
                _ = self.control_cursors.orderedRemove(i);
                break;
            }
        }
        for (self.pending.items) |*p| if (p.generation == generation) {
            p.generation = null;
        };
        var index: usize = 0;
        while (index < self.replies.items.len) {
            if (self.replies.items[index].connection_generation != generation) {
                index += 1;
                continue;
            }
            self.allocator.free(self.replies.orderedRemove(index).bytes);
        }
        self.inputClosed(generation);
    }

    /// Resolve a surface's authority from a live server-owned attachment. The
    /// caller's separate connection does not acquire the control owner's lease.
    pub fn attachmentForSurface(self: *const Service, attachment_id: ID, client_id: ID) !@import("surface_interest.zig").Attachment {
        for (self.attachments.items) |item| {
            if (!std.mem.eql(u8, &item.id, &attachment_id)) continue;
            if (!std.mem.eql(u8, &item.owner.client_id, &client_id)) return error.PermissionDenied;
            return .{ .id = item.id, .terminal_id = item.terminal_id, .client_id = item.owner.client_id, .control_generation = item.owner.connection_generation };
        }
        return error.AttachmentNotFound;
    }

    pub fn attachmentAlive(self: *const Service, attachment_id: ID, control_generation: u64) bool {
        for (self.attachments.items) |item| {
            if (item.owner.connection_generation == control_generation and std.mem.eql(u8, &item.id, &attachment_id)) return true;
        }
        return false;
    }

    /// A read-side EOF releases write authority but preserves accepted replies.
    pub fn inputClosed(self: *Service, generation: u64) void {
        var index: usize = 0;
        while (index < self.attachments.items.len) {
            const item = self.attachments.items[index];
            if (item.owner.connection_generation != generation) {
                index += 1;
                continue;
            }
            for (self.lease_states.items) |*state| if (std.mem.eql(u8, &state.terminal_id, &item.terminal_id)) {
                _ = state.state.disconnect(item.owner);
            };
            _ = self.attachments.orderedRemove(index);
        }
    }
};

pub fn terminal(entry: *pool_mod.Entry) Terminal {
    var result = Terminal{ .terminalID = &entry.id, .cwd = entry.cwd, .state = if (entry.session.exit_status != null and entry.session.cleanupComplete()) .exited else if (entry.failure != null) .unavailable else if (entry.session.termination_timer != null) .terminating else .running };
    if (result.state == .running or result.state == .terminating) result.pid = @intCast(entry.original_pid);
    if (entry.session.terminal.screenMetrics()) |metrics| {
        if (entry.session.terminal.pixelSize()) |pixels| {
            result.geometry = .{ .rows = metrics.rows, .columns = metrics.columns, .pixelWidth = pixels.width, .pixelHeight = pixels.height };
        } else |_| {
            result.state = .unavailable;
            result.pid = null;
        }
    } else |_| {
        result.state = .unavailable;
        result.pid = null;
    }
    if (entry.session.exit_status) |status| {
        // 接管终端的 exit_status 为 0xFFFFFFFF（-1 as u32）时表示退出码不可得，
        // 两平台均无法获取非子进程的退出码。此时 exitCode 保持 null。
        const status_i32: i32 = @bitCast(status);
        if (status_i32 >= 0) {
            if (std.posix.W.IFEXITED(status)) result.exitCode = std.posix.W.EXITSTATUS(status);
            if (std.posix.W.IFSIGNALED(status)) result.signal = std.posix.W.TERMSIG(status);
        }
    }
    return result;
}
/// Wire view of a terminal that already released its slot. It never carries a
/// PID or geometry: the process and its VT are gone, so claiming either would
/// let a client mistake a dead terminal for a running one.
pub fn retiredTerminal(record: *const pool_mod.Retired) Terminal {
    var result = Terminal{ .terminalID = &record.id, .cwd = record.cwd, .state = if (record.unavailable) .unavailable else .exited };
    if (record.exit_status) |status| {
        const status_i32: i32 = @bitCast(status);
        if (status_i32 >= 0) {
            if (std.posix.W.IFEXITED(status)) result.exitCode = std.posix.W.EXITSTATUS(status);
            if (std.posix.W.IFSIGNALED(status)) result.signal = std.posix.W.TERMSIG(status);
        }
    }
    return result;
}
const Retry = @TypeOf(@as(replies.Failure, undefined).@"error".retry);
fn failure(a: std.mem.Allocator, r: Request, code: []const u8, retry: Retry) ![]u8 {
    return std.json.Stringify.valueAlloc(a, replies.Failure{ .type = "error", .requestID = r.requestID, .operation = @tagName(r.operation), .scope = r.scope, .@"error" = .{ .code = code, .message = code, .retry = retry } }, .{ .emit_null_optional_fields = false });
}
fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.LogRequiresReopen => "outcome_unknown",
        error.LeaseLost => "lease_lost",
        error.LeaseBusy => "lease_busy",
        error.TerminalNotFound => "terminal_not_found",
        error.TerminalExited, error.TerminalTerminating => "terminal_exited",
        error.DeliveryUnknown => "delivery_unknown",
        error.MissingCapability => "missing_capability",
        error.PermissionDenied => "permission_denied",
        error.InvalidTerminalDirectory, error.WorkingDirectoryUnavailable => "cwd_unavailable",
        error.ExecutableUnavailable => "executable_unavailable",
        error.ResourceLimit, error.TerminalLimitReached, error.CreationCompletionBackpressure, error.LogCapacity, error.InputQueueFull, error.TerminalGeometryLimit => "resource_limit",
        error.InvalidRequest, error.InvalidTerminalArguments, error.InvalidTerminalEnvironment, error.DuplicateEnvironmentName, error.FutureRequest, error.InvalidDimensions, error.InvalidPixelDimensions => "invalid_request",
        else => "internal_error",
    };
}
fn errorRetry(err: anyerror) Retry {
    return switch (err) {
        error.DeliveryUnknown, error.LogRequiresReopen => .after_query,
        error.ResourceLimit, error.LogCapacity, error.InputQueueFull => .backoff,
        else => .never,
    };
}
fn textID(value: []const u8) !ID {
    if (!@import("operation_request.zig").validID(value)) return error.InvalidRequest;
    return value[0..36].*;
}
fn binaryID(value: []const u8) ![16]u8 {
    _ = try textID(value);
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
fn idParam(value: std.json.Value, name: []const u8) !ID {
    return textID(try stringParam(value, name));
}
/// 可选字符串参数，缺失或 null 返回 null
fn optionalString(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const item = value.object.get(name) orelse return null;
    return if (item == .string) item.string else null;
}
fn integer(comptime T: type, value: std.json.Value) !T {
    return switch (value) {
        .integer => std.math.cast(T, value.integer) orelse error.InvalidRequest,
        .number_string => std.fmt.parseInt(T, value.number_string, 10) catch error.InvalidRequest,
        else => error.InvalidRequest,
    };
}
fn parseGeometry(a: std.mem.Allocator, value: std.json.Value) !@import("geometry.zig").Geometry {
    const parsed = std.json.parseFromValue(Geometry, a, value, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const geometry = parsed.value.core();
    try geometry.validate();
    return geometry;
}
fn prepareLaunch(a: std.mem.Allocator, params: std.json.Value) !preparation.Prepared {
    try only(params, &.{ "cwd", "argv", "environment", "geometry" });
    const cwd = try stringParam(params, "cwd");
    const argv_value = params.object.get("argv") orelse return error.InvalidRequest;
    if (argv_value != .array or argv_value.array.items.len == 0 or argv_value.array.items.len > 128) return error.InvalidRequest;
    var argv: [128][]const u8 = undefined;
    for (argv_value.array.items, 0..) |value, i| {
        if (value != .string) return error.InvalidRequest;
        argv[i] = value.string;
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    var env: std.ArrayList([]const u8) = .empty;
    if (params.object.get("environment")) |value| {
        if (value != .object or value.object.count() > 128) return error.InvalidRequest;
        var iterator = value.object.iterator();
        while (iterator.next()) |item| {
            if (item.value_ptr.* != .string or std.mem.indexOfScalar(u8, item.key_ptr.*, '=') != null) return error.InvalidRequest;
            try env.append(temporary, try std.fmt.allocPrint(temporary, "{s}={s}", .{ item.key_ptr.*, item.value_ptr.string }));
        }
    }
    var inherited: std.ArrayList([]const u8) = .empty;
    var map = try std.process.getEnvMap(temporary);
    var iterator = map.iterator();
    while (iterator.next()) |item| try inherited.append(temporary, try std.fmt.allocPrint(temporary, "{s}={s}", .{ item.key_ptr.*, item.value_ptr.* }));
    const geometry = if (params.object.get("geometry")) |value| try parseGeometry(a, value) else @import("geometry.zig").Geometry{ .rows = 24, .columns = 80 };
    return preparation.prepare(a, .{ .cwd = cwd, .argv = argv[0..argv_value.array.items.len], .environment = env.items, .geometry = geometry }, inherited.items);
}
fn canonical(a: std.mem.Allocator, value: std.json.Value) anyerror!std.json.Value {
    switch (value) {
        .object => |object| {
            const keys = try a.dupe([]const u8, object.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.less);
            var result = std.json.ObjectMap.init(a);
            for (keys) |key| try result.put(key, try canonical(a, object.get(key).?));
            return .{ .object = result };
        },
        .array => |array| {
            var result = std.array_list.Managed(std.json.Value).init(a);
            for (array.items) |item| try result.append(try canonical(a, item));
            return .{ .array = result };
        },
        else => return value,
    }
}
fn fingerprint(a: std.mem.Allocator, r: Request) ![32]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .operation = r.operation, .params = try canonical(arena.allocator(), r.params), .created = r.createdAtUnixMs, .revision = r.expectedRevision }, .{});
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn controlFingerprint(a: std.mem.Allocator, r: Request) ![32]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .client = r.clientID, .lease = r.lease, .operation = r.operation, .params = try canonical(arena.allocator(), r.params) }, .{});
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn testRequest(service: *Service, a: std.mem.Allocator, operation: @TypeOf(@as(Request, undefined).operation), serial: u8, params: []const u8) !std.json.Parsed(Request) {
    const value = try std.json.parseFromSlice(std.json.Value, a, params, .{});
    defer value.deinit();
    var request_id = "00000000-0000-4000-8000-000000000000".*;
    request_id[35] = serial;
    const r = Request{ .type = "request", .requestID = &request_id, .clientID = "00000000-0000-4000-8000-000000000099", .scope = .session, .operation = operation, .target = service.target(), .createdAtUnixMs = if (operation.metadata().requires_created_at) @intCast(std.time.milliTimestamp()) else null, .params = value.value };
    const encoded = try std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false });
    defer a.free(encoded);
    return std.json.parseFromSlice(Request, a, encoded, .{ .allocate = .alloc_always });
}
fn testAsync(service: *Service) ![]u8 {
    var timer = try std.time.Timer.start();
    while (timer.read() < 5 * std.time.ns_per_s) {
        service.pool.tick();
        try service.tick();
        if (service.takeReply()) |reply| return reply.bytes;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.TestReplyTimedOut;
}

test "terminal service durable create survives disconnect and old epoch never claims live PID" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "service");
    defer state.deinit();
    var pool = try Pool.init(a, .{});
    defer pool.deinit();
    const identity = ids.Identity{ .server_id = ids.newUUID(), .session_id = ids.newUUID() };
    const epoch = ids.newUUID();
    var service = try Service.init(a, &pool, &state, identity, epoch);
    var request = try testRequest(&service, a, .@"terminal.create", '1', "{\"cwd\":\"/\",\"argv\":[\"/bin/sh\",\"-c\",\"printf SERVICE_READY; read x\"]}");
    defer request.deinit();
    try std.testing.expect(try service.respond(a, request.value, 1) == null);
    service.disconnect(1);
    var timer = try std.time.Timer.start();
    while (service.pending.items.len > 0) {
        pool.tick();
        try service.tick();
        if (timer.read() > 5 * std.time.ns_per_s) return error.TestReplyTimedOut;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(service.takeReply() == null);
    const replay = (try service.respond(a, request.value, 2)).?;
    defer a.free(replay);
    const result = try std.json.parseFromSlice(std.json.Value, a, replay, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("running", result.value.object.get("result").?.object.get("state").?.string);
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
    service.deinit();
    service = try Service.init(a, &pool, &state, identity, ids.newUUID());
    defer service.deinit();
    request.value.target = service.target();
    const cold = (try service.respond(a, request.value, 3)).?;
    defer a.free(cold);
    const old = try std.json.parseFromSlice(std.json.Value, a, cold, .{});
    defer old.deinit();
    const terminal_result = old.value.object.get("result").?;
    try std.testing.expectEqualStrings("unavailable", terminal_result.object.get("state").?.string);
    try std.testing.expect(terminal_result.object.get("pid") == null);
}

test "terminal service writer fences observer generation sequence takeover and termination" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "service");
    defer state.deinit();
    var pool = try Pool.init(a, .{});
    defer pool.deinit();
    var service = try Service.init(a, &pool, &state, .{ .server_id = ids.newUUID(), .session_id = ids.newUUID() }, ids.newUUID());
    defer service.deinit();
    const create = try testRequest(&service, a, .@"terminal.create", '1', "{\"cwd\":\"/\",\"argv\":[\"/bin/sh\",\"-c\",\"read a; printf INPUT:%s \\\"$a\\\"; read b\"]}");
    defer create.deinit();
    try std.testing.expect(try service.respond(a, create.value, 1) == null);
    service.inputClosed(1);
    try std.testing.expectEqual(@as(?u64, 1), service.pending.items[0].generation);
    const created = try testAsync(&service);
    defer a.free(created);
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
    const id = pool.entries.items[0].id;
    const params = try std.fmt.allocPrint(a, "{{\"terminalID\":\"{s}\"}}", .{id});
    defer a.free(params);
    inline for (.{ .@"terminal.list", .@"terminal.observe", .@"terminal.attach" }) |operation| {
        const request = try testRequest(&service, a, operation, '2', if (operation == .@"terminal.list") "{}" else params);
        defer request.deinit();
        const output = (try service.respond(a, request.value, 1)).?;
        defer a.free(output);
        const value = try std.json.parseFromSlice(std.json.Value, a, output, .{});
        defer value.deinit();
        try std.testing.expect(value.value.object.get("result") != null);
    }
    const grant = service.lease_states.items[0].state.peek().?;
    const control_params = try std.fmt.allocPrint(a, "{{\"terminalID\":\"{s}\",\"action\":\"input\",\"data\":\"aGVsbG8K\"}}", .{id});
    defer a.free(control_params);
    var input = try testRequest(&service, a, .@"terminal.control", '3', control_params);
    defer input.deinit();
    input.value.lease = .{ .leaseID = &grant.lease.lease_id, .leaseEpoch = grant.lease.lease_epoch };
    input.value.controlSequence = 1;
    const rejected = (try service.respond(a, input.value, 2)).?;
    defer a.free(rejected);
    try std.testing.expect(std.mem.indexOf(u8, rejected, "lease_lost") != null);
    const accepted = (try service.respond(a, input.value, 1)).?;
    defer a.free(accepted);
    try std.testing.expect(std.mem.indexOf(u8, accepted, "accepted") != null);
    const repeated = (try service.respond(a, input.value, 1)).?;
    defer a.free(repeated);
    try std.testing.expectEqualStrings(accepted, repeated);
    try std.testing.expectEqual(@as(usize, 6), pool.entries.items[0].session.pending_input.items.len);
    const takeover_params = try std.fmt.allocPrint(a, "{{\"terminalID\":\"{s}\",\"takeover\":true,\"expectedLeaseEpoch\":1}}", .{id});
    defer a.free(takeover_params);
    const takeover = try testRequest(&service, a, .@"terminal.attach", '4', takeover_params);
    defer takeover.deinit();
    const moved = (try service.respond(a, takeover.value, 2)).?;
    defer a.free(moved);
    try std.testing.expect(service.takeLeaseEvent() != null);
    const old_input = (try service.respond(a, input.value, 1)).?;
    defer a.free(old_input);
    try std.testing.expect(std.mem.indexOf(u8, old_input, "lease_lost") != null);
    const attachment = service.attachments.items[0];
    const release_params = try std.fmt.allocPrint(a, "{{\"attachmentID\":\"{s}\"}}", .{attachment.id});
    defer a.free(release_params);
    const release = try testRequest(&service, a, .@"terminal.release", '5', release_params);
    defer release.deinit();
    a.free((try service.respond(a, release.value, 1)).?);
    const terminate = try testRequest(&service, a, .@"terminal.terminate", '6', params);
    defer terminate.deinit();
    try std.testing.expect(try service.respond(a, terminate.value, 2) == null);
    const stopped = try testAsync(&service);
    defer a.free(stopped);
    try std.testing.expect(std.mem.indexOf(u8, stopped, "exited") != null);
    const stop_replay = (try service.respond(a, terminate.value, 2)).?;
    defer a.free(stop_replay);
    try std.testing.expectEqualStrings(stopped, stop_replay);
}

test "completion persistence failure isolates existing PTYs and rejects new mutations" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "service");
    defer state.deinit();
    var pool = try Pool.init(a, .{});
    defer pool.deinit();
    const unrelated_id = "00000000-0000-4000-8000-000000000088".*;
    try pool.create(unrelated_id, .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "printf BEFORE; while read line; do printf '%s\\n' \"$line\"; done" } });
    const unrelated_pid = pool.find(unrelated_id).?.session.process.pid;
    var service = try Service.init(a, &pool, &state, .{ .server_id = ids.newUUID(), .session_id = ids.newUUID() }, ids.newUUID());
    defer service.deinit();
    const create = try testRequest(&service, a, .@"terminal.create", 'a', "{\"cwd\":\"/\",\"argv\":[\"/bin/sh\",\"-c\",\"read line\"]}");
    defer create.deinit();
    try std.testing.expect(try service.respond(a, create.value, 1) == null);
    const intent = service.pending.items[0].intent;
    // A directory at the private staging-file name deterministically rejects
    // completion persistence without touching the already committed intent.
    try state.dir.makeDir("idempotency.pending");
    const outcome = try testAsync(&service);
    defer a.free(outcome);
    try std.testing.expect(std.mem.indexOf(u8, outcome, "outcome_unknown") != null);
    try std.testing.expect(service.log.poisoned);
    try std.testing.expect(service.persistence_failure != null);
    try std.testing.expectEqual(@as(usize, 0), service.pending.items.len);
    try std.testing.expectEqual(@as(usize, 2), pool.entries.items.len);
    try std.testing.expectEqual(unrelated_pid, pool.find(unrelated_id).?.session.process.pid);
    try std.posix.kill(unrelated_pid, 0);

    const another = try testRequest(&service, a, .@"terminal.create", 'b', "{\"cwd\":\"/\",\"argv\":[\"/bin/sh\",\"-c\",\"exit 0\"]}");
    defer another.deinit();
    const rejected = (try service.respond(a, another.value, 2)).?;
    defer a.free(rejected);
    try std.testing.expect(std.mem.indexOf(u8, rejected, "outcome_unknown") != null);
    try std.testing.expectEqual(@as(usize, 2), pool.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.pending.items.len);
    const list = try testRequest(&service, a, .@"terminal.list", 'c', "{}");
    defer list.deinit();
    const listed = (try service.respond(a, list.value, 2)).?;
    defer a.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "terminals") != null);

    const params = try std.fmt.allocPrint(a, "{{\"terminalID\":\"{s}\"}}", .{unrelated_id});
    defer a.free(params);
    const observe = try testRequest(&service, a, .@"terminal.observe", 'f', params);
    defer observe.deinit();
    const idle_observation = (try service.respond(a, observe.value, 3)).?;
    defer a.free(idle_observation);
    try std.testing.expect(std.mem.indexOf(u8, idle_observation, "\"currentLeaseEpoch\":0") != null);
    const attach = try testRequest(&service, a, .@"terminal.attach", 'd', params);
    defer attach.deinit();
    a.free((try service.respond(a, attach.value, 2)).?);
    const grant = service.lease_states.items[0].state.peek().?;
    const active_observation = (try service.respond(a, observe.value, 3)).?;
    defer a.free(active_observation);
    try std.testing.expect(std.mem.indexOf(u8, active_observation, "\"currentLeaseEpoch\":1") != null);
    try std.testing.expectEqualDeep(grant, service.lease_states.items[0].state.peek().?);
    const input_params = try std.fmt.allocPrint(a, "{{\"terminalID\":\"{s}\",\"action\":\"input\",\"data\":\"QUZURVIK\"}}", .{unrelated_id});
    defer a.free(input_params);
    var input = try testRequest(&service, a, .@"terminal.control", 'e', input_params);
    defer input.deinit();
    input.value.lease = .{ .leaseID = &grant.lease.lease_id, .leaseEpoch = grant.lease.lease_epoch };
    input.value.controlSequence = 1;
    const accepted = (try service.respond(a, input.value, 2)).?;
    defer a.free(accepted);
    try std.testing.expect(std.mem.indexOf(u8, accepted, "accepted") != null);
    var timer = try std.time.Timer.start();
    while (true) {
        pool.tick();
        try service.tick();
        const session = pool.find(unrelated_id).?.session;
        const text = try session.terminal.formatActiveScreen(a, false, 32768);
        const found = std.mem.indexOf(u8, text, "BEFORE") != null and std.mem.indexOf(u8, text, "AFTER") != null;
        a.free(text);
        if (found) break;
        if (timer.read() > 3 * std.time.ns_per_s) return error.TestReplyTimedOut;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(unrelated_pid, pool.find(unrelated_id).?.session.process.pid);
    try std.testing.expect(pool.find(unrelated_id).?.session.exit_status == null);
    service.inputClosed(2);
    const released_observation = (try service.respond(a, observe.value, 3)).?;
    defer a.free(released_observation);
    try std.testing.expect(std.mem.indexOf(u8, released_observation, "\"currentLeaseEpoch\":1") != null);
    try std.testing.expect(service.lease_states.items[0].state.peek() == null);
    try state.dir.deleteDir("idempotency.pending");
    var reopened = try durable.Log.open(a, &state, .{});
    defer reopened.deinit();
    const replay = (try reopened.lookup(intent, service.epoch, @intCast(std.time.milliTimestamp()))).?;
    try std.testing.expectEqual(durable.Decision.outcome_unknown, replay);
}

fn testAttach(service: *Service, a: std.mem.Allocator, terminal_id: ID, generation: u64) !leases.Grant {
    const params = try std.fmt.allocPrint(a, "{{\"terminalID\":\"{s}\"}}", .{terminal_id});
    defer a.free(params);
    const request = try testRequest(service, a, .@"terminal.attach", 'a', params);
    defer request.deinit();
    const response = (try service.respond(a, request.value, generation)).?;
    defer a.free(response);
    if (std.mem.indexOf(u8, response, "\"result\"") == null) return error.TestAttachFailed;
    return (try service.leaseState(terminal_id)).state.peek().?;
}

fn testInput(service: *Service, a: std.mem.Allocator, terminal_id: ID, serial: u8) !std.json.Parsed(Request) {
    const params = try std.fmt.allocPrint(a, "{{\"terminalID\":\"{s}\",\"action\":\"input\",\"data\":\"eA==\"}}", .{terminal_id});
    defer a.free(params);
    return testRequest(service, a, .@"terminal.control", serial, params);
}

test "terminal service connection sequence survives cross terminal and reattachment" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "service");
    defer state.deinit();
    var pool = try Pool.init(a, .{});
    defer pool.deinit();
    var service = try Service.init(a, &pool, &state, .{ .server_id = ids.newUUID(), .session_id = ids.newUUID() }, ids.newUUID());
    defer service.deinit();
    const first_id = ids.uuidText(ids.newUUID());
    const second_id = ids.uuidText(ids.newUUID());
    try pool.create(first_id, .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "read value" } });
    try pool.create(second_id, .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "read value" } });
    const first_grant = try testAttach(&service, a, first_id, 1);
    const second_grant = try testAttach(&service, a, second_id, 1);
    var first = try testInput(&service, a, first_id, '1');
    defer first.deinit();
    first.value.controlSequence = 10;
    first.value.lease = .{ .leaseID = &first_grant.lease.lease_id, .leaseEpoch = first_grant.lease.lease_epoch };
    a.free((try service.respond(a, first.value, 1)).?);
    service.revision = 7;
    const retry_id = ids.uuidText(ids.newUUID());
    const original_id = first.value.requestID;
    first.value.requestID = &retry_id;
    const duplicate = (try service.respond(a, first.value, 1)).?;
    defer a.free(duplicate);
    const decoded = try std.json.parseFromSlice(std.json.Value, a, duplicate, .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings(&retry_id, decoded.value.object.get("requestID").?.string);
    try std.testing.expectEqual(@as(i64, 0), decoded.value.object.get("revision").?.integer);
    first.value.requestID = original_id;
    try std.testing.expectEqual(@as(usize, 1), pool.find(first_id).?.session.pending_input.items.len);

    var second = try testInput(&service, a, second_id, '2');
    defer second.deinit();
    second.value.controlSequence = 10;
    second.value.lease = .{ .leaseID = &second_grant.lease.lease_id, .leaseEpoch = second_grant.lease.lease_epoch };
    const collision = (try service.respond(a, second.value, 1)).?;
    defer a.free(collision);
    try std.testing.expect(std.mem.indexOf(u8, collision, "delivery_unknown") != null);
    try std.testing.expectEqual(@as(usize, 0), pool.find(second_id).?.session.pending_input.items.len);
    second.value.controlSequence = 11;
    a.free((try service.respond(a, second.value, 1)).?);
    try std.testing.expectEqual(@as(usize, 1), pool.find(second_id).?.session.pending_input.items.len);

    const attachment = service.attachments.items[1];
    const release_params = try std.fmt.allocPrint(a, "{{\"attachmentID\":\"{s}\"}}", .{attachment.id});
    defer a.free(release_params);
    const release = try testRequest(&service, a, .@"terminal.release", '3', release_params);
    defer release.deinit();
    a.free((try service.respond(a, release.value, 1)).?);
    const replacement = try testAttach(&service, a, second_id, 1);
    const lost = (try service.respond(a, second.value, 1)).?;
    defer a.free(lost);
    try std.testing.expect(std.mem.indexOf(u8, lost, "lease_lost") != null);
    second.value.lease = .{ .leaseID = &replacement.lease.lease_id, .leaseEpoch = replacement.lease.lease_epoch };
    const reused = (try service.respond(a, second.value, 1)).?;
    defer a.free(reused);
    try std.testing.expect(std.mem.indexOf(u8, reused, "delivery_unknown") != null);
    second.value.controlSequence = 12;
    a.free((try service.respond(a, second.value, 1)).?);
    service.disconnect(1);
    try std.testing.expectEqual(@as(usize, 0), service.control_cursors.items.len);
    const new_generation = try testAttach(&service, a, second_id, 2);
    second.value.lease = .{ .leaseID = &new_generation.lease.lease_id, .leaseEpoch = new_generation.lease.lease_epoch };
    second.value.controlSequence = 0;
    const fresh = (try service.respond(a, second.value, 2)).?;
    defer a.free(fresh);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "accepted") != null);
    try std.testing.expectEqual(@as(usize, 3), pool.find(second_id).?.session.pending_input.items.len);
}

test "a retired terminal keeps its exit visible and is never reported as running" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "service");
    defer state.deinit();
    var pool = try Pool.init(a, .{ .maximum_terminals = 2 });
    defer pool.deinit();
    var service = try Service.init(a, &pool, &state, .{ .server_id = ids.newUUID(), .session_id = ids.newUUID() }, ids.newUUID());
    defer service.deinit();
    const short = try testRequest(&service, a, .@"terminal.create", '1', "{\"cwd\":\"/\",\"argv\":[\"/bin/sh\",\"-c\",\"exit 4\"]}");
    defer short.deinit();
    try std.testing.expect(try service.respond(a, short.value, 1) == null);
    a.free(try testAsync(&service));
    const retired_id = pool.entries.items[0].id;
    var timer = try std.time.Timer.start();
    while (!(pool.find(retired_id).?.session.exit_status != null and pool.find(retired_id).?.session.cleanupComplete() and pool.find(retired_id).?.session.eof)) {
        pool.tick();
        try service.tick();
        if (timer.read() > 5 * std.time.ns_per_s) return error.TestProcessesDidNotExit;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    inline for (.{ '2', '3' }) |serial| {
        const request = try testRequest(&service, a, .@"terminal.create", serial, "{\"cwd\":\"/\",\"argv\":[\"/bin/sh\",\"-c\",\"read line\"]}");
        defer request.deinit();
        try std.testing.expect(try service.respond(a, request.value, 1) == null);
        a.free(try testAsync(&service));
    }
    // The third create had to take the exited terminal's slot; its outcome must
    // survive as an exit summary rather than as a phantom running terminal.
    try std.testing.expect(pool.find(retired_id) == null);
    const list = try testRequest(&service, a, .@"terminal.list", '4', "{}");
    defer list.deinit();
    const listed = (try service.respond(a, list.value, 1)).?;
    defer a.free(listed);
    const decoded = try std.json.parseFromSlice(std.json.Value, a, listed, .{});
    defer decoded.deinit();
    const terminals = decoded.value.object.get("result").?.object.get("terminals").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), terminals.len);
    var found = false;
    for (terminals) |item| {
        if (!std.mem.eql(u8, item.object.get("terminalID").?.string, &retired_id)) continue;
        found = true;
        try std.testing.expectEqualStrings("exited", item.object.get("state").?.string);
        try std.testing.expectEqual(@as(i64, 4), item.object.get("exitCode").?.integer);
        try std.testing.expect(item.object.get("pid") == null);
    }
    try std.testing.expect(found);
    const params = try std.fmt.allocPrint(a, "{{\"terminalID\":\"{s}\"}}", .{retired_id});
    defer a.free(params);
    const attach = try testRequest(&service, a, .@"terminal.attach", '5', params);
    defer attach.deinit();
    const rejected = (try service.respond(a, attach.value, 1)).?;
    defer a.free(rejected);
    try std.testing.expect(std.mem.indexOf(u8, rejected, "terminal_not_found") != null);
}

test "terminal service control cursor capacity stays bounded and disconnect reclaims it" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "service");
    defer state.deinit();
    var pool = try Pool.init(a, .{});
    defer pool.deinit();
    var service = try Service.init(a, &pool, &state, .{ .server_id = ids.newUUID(), .session_id = ids.newUUID() }, ids.newUUID());
    defer service.deinit();
    for (0..64) |generation| _ = try service.controlCursor(generation);
    try std.testing.expectError(error.ResourceLimit, service.controlCursor(64));
    service.disconnect(32);
    _ = try service.controlCursor(64);
    try std.testing.expectEqual(@as(usize, 64), service.control_cursors.items.len);
}

test "completion allocation failure preserves executed process and unresolved intent" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var state = try StateDirectory.acquire(temporary.dir, "session");
    defer state.deinit();
    var pool = try Pool.init(a, .{});
    defer pool.deinit();
    var service = try Service.init(a, &pool, &state, .{ .server_id = ids.newUUID(), .session_id = ids.newUUID() }, ids.newUUID());
    defer service.deinit();
    const request = try testRequest(&service, a, .@"terminal.create", '7', "{\"cwd\":\"/\",\"argv\":[\"/bin/sh\",\"-c\",\"sleep 60\"]}");
    defer request.deinit();
    try std.testing.expect((try service.respond(a, request.value, 1)) == null);
    var timer = try std.time.Timer.start();
    while (pool.entries.items.len == 0 and timer.read() < 3 * std.time.ns_per_s) {
        pool.tick();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
    const pid = pool.entries.items[0].session.process.pid;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    service.allocator = failing.allocator();
    defer service.allocator = a;
    try service.tick();
    service.allocator = a;
    try std.testing.expectEqual(@as(u64, 1), service.completion_encoding_failures);
    const reply = service.takeReply() orelse return error.TestReplyMissing;
    defer a.free(reply.bytes);
    try std.testing.expect(std.mem.indexOf(u8, reply.bytes, "outcome_unknown") != null);
    try std.testing.expectEqual(@as(usize, 0), service.pending.items.len);
    try std.testing.expectEqual(pid, pool.entries.items[0].session.process.pid);
    try std.testing.expect(pool.entries.items[0].session.exit_status == null);
    const decision = try service.log.query(.{ .client_id = try binaryID(request.value.clientID), .request_id = try binaryID(request.value.requestID) }, @intCast(std.time.milliTimestamp()));
    try std.testing.expectEqual(.pending, decision.state);
}
