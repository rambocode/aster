const std = @import("std");
const pool_mod = @import("terminal_pool.zig");
const Pool = pool_mod.Pool;
const Request = @import("operation_request.zig").Request;
const Operation = @import("operation_kind.zig").Operation;
const ids = @import("service_identity.zig");
const durable = @import("idempotency_log.zig");
const replies = @import("operation_response.zig");
const preparation = @import("launch_preparation.zig");
const terminals_mod = @import("terminal_service.zig");
const store_mod = @import("workspace_store.zig");
const screen_history = @import("screen_history.zig");
const Store = store_mod.Store;
const ID = store_mod.ID;

pub const Reply = struct { connection_generation: u64, bytes: []u8 };
/// One broadcast-ready structural event. `body` is the already-encoded schema
/// body; the server wraps it per connection because `sequence` belongs to the
/// receiving control stream, not to the event itself.
pub const Event = struct { name: []const u8, body: []u8, revision: u64 };

const Retry = @TypeOf(@as(replies.Failure, undefined).@"error".retry);

/// What a deferred create commits once its PTY actually exists.
const PendingKind = union(enum) {
    workspace: struct { title: []u8, cwd: []u8 },
    tab: struct { workspace_id: ID, title: []u8 },
    pane: struct { pane_id: ID, direction: store_mod.Direction },
};

const Pending = struct {
    intent: durable.Intent,
    request_id: ID,
    client_id: ID,
    operation: Operation,
    generation: ?u64,
    terminal_id: ID,
    pane_id: ID,
    kind: PendingKind,
    completion: ?pool_mod.Completion = null,
    startup_error: ?anyerror = null,
    response: ?[]u8 = null,
    persisted: bool = false,
    completion_failed: bool = false,
    unknown_response: ?[]u8 = null,
};

/// Server-side workspace/tab/pane transactions for one session.
///
/// Every structural request carries `expectedRevision`. The check and the
/// revision bump happen together at admission, before any PTY is launched, so
/// two clients submitting against the same revision cannot both be admitted:
/// exactly one proceeds and the other gets `revision_conflict` carrying the
/// current revision. Creates are deferred until the real process exists and the
/// layout is committed to disk, so a failed launch leaves no half-built node.
pub const Service = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    terminals: *terminals_mod.Service,
    pool: *Pool,
    /// Session state directory; owns layout.json. Borrowed, never closed here.
    dir: std.fs.Dir,
    pending: std.ArrayList(Pending) = .empty,
    replies: std.ArrayList(Reply) = .empty,
    events: std.ArrayList(Event) = .empty,
    /// Latched layout-persistence fault. Reads and existing PTYs keep working;
    /// further structural mutation is refused because memory and disk no longer
    /// agree and silently continuing would lose the user's layout on restart.
    persistence_failure: ?anyerror = null,
    /// True once a client has completed a cold restore for this server incarnation.
    /// Prevents duplicate restores from another client or reconnect.
    restore_completed: bool = false,
    /// Terminal IDs created during cold restore; their completions are claimed
    /// silently (no durable log, no client response, no "session started").
    restore_terminal_ids: std.ArrayList(ID) = .empty,
    /// Whether disk screen history is enabled for this session (P6.2, default off).
    screen_history_enabled: bool = false,
    /// Optional reference to the shared screen history writer (set by service_server).
    /// Used during cold restore to check for persisted screen data.
    screen_history_writer: ?*screen_history.Writer = null,

    pub fn init(allocator: std.mem.Allocator, store: *Store, terminals: *terminals_mod.Service, pool: *Pool, dir: std.fs.Dir) !Service {
        var self = Service{ .allocator = allocator, .store = store, .terminals = terminals, .pool = pool, .dir = dir };
        errdefer self.deinit();
        try self.pending.ensureTotalCapacity(allocator, 64);
        try self.replies.ensureTotalCapacity(allocator, 64);
        try self.events.ensureTotalCapacity(allocator, 256);
        try self.restore_terminal_ids.ensureTotalCapacity(allocator, 64);
        return self;
    }

    pub fn deinit(self: *Service) void {
        for (self.pending.items) |*item| self.releasePending(item);
        for (self.replies.items) |item| self.allocator.free(item.bytes);
        for (self.events.items) |item| self.allocator.free(item.body);
        self.pending.deinit(self.allocator);
        self.replies.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.restore_terminal_ids.deinit(self.allocator);
        self.* = undefined;
    }

    fn releasePending(self: *Service, item: *Pending) void {
        switch (item.kind) {
            .workspace => |value| {
                self.allocator.free(value.title);
                self.allocator.free(value.cwd);
            },
            .tab => |value| self.allocator.free(value.title),
            .pane => {},
        }
        if (item.response) |bytes| self.allocator.free(bytes);
        if (item.unknown_response) |bytes| self.allocator.free(bytes);
    }

    /// Claims a pool completion belonging to a deferred structural create.
    /// Called from the terminal domain's completion drain; returning false lets
    /// the terminal domain report an unowned completion as it always has.
    pub fn claimCompletion(context: *anyopaque, completion: pool_mod.Completion) bool {
        const self: *Service = @ptrCast(@alignCast(context));
        for (self.pending.items) |*item| {
            if (!std.mem.eql(u8, &item.terminal_id, &completion.id)) continue;
            item.completion = completion;
            return true;
        }
        // Also claim completions for cold-restore terminals (P6.1).
        for (self.restore_terminal_ids.items, 0..) |*rid, i| {
            if (std.mem.eql(u8, rid, &completion.id)) {
                _ = self.restore_terminal_ids.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn hook(self: *Service) terminals_mod.StructureHook {
        return .{ .context = self, .claim = claimCompletion };
    }

    fn target(self: *Service) @TypeOf(@as(Request, undefined).target) {
        return self.terminals.target();
    }

    fn success(self: *Service, allocator: std.mem.Allocator, request: Request, result: anytype) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, replies.Response(@TypeOf(result)){
            .type = "response",
            .requestID = request.requestID,
            .scope = request.scope,
            .operation = request.operation,
            .target = self.target(),
            .revision = self.store.revision,
            .result = result,
        }, .{ .emit_null_optional_fields = false });
    }

    fn failure(self: *Service, a: std.mem.Allocator, r: Request, code: []const u8, retry: Retry) ![]u8 {
        // revision_conflict is the only failure that carries authoritative
        // state: the loser needs the current revision to retry immediately.
        const conflict = std.mem.eql(u8, code, "revision_conflict");
        return std.json.Stringify.valueAlloc(a, replies.Failure{
            .type = "error",
            .requestID = r.requestID,
            .operation = @tagName(r.operation),
            .scope = r.scope,
            .target = if (conflict) self.target() else null,
            .currentRevision = if (conflict) self.store.revision else null,
            .@"error" = .{ .code = code, .message = code, .retry = retry },
        }, .{ .emit_null_optional_fields = false });
    }

    pub fn respond(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) !?[]u8 {
        return self.dispatch(a, r, generation) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try self.failure(a, r, errorCode(err), errorRetry(err)),
        };
    }

    fn dispatch(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) !?[]u8 {
        return switch (r.operation) {
            .@"session.snapshot" => try self.snapshot(a, r),
            .@"session.restore" => try self.restore(a, r),
            .@"session.settings.get" => try self.settingsGet(a, r),
            .@"session.settings.update" => try self.settingsUpdate(a, r),
            .@"workspace.list" => try self.list(a, r),
            .@"workspace.create", .@"tab.create", .@"pane.split" => try self.beginCreate(a, r, generation),
            .@"workspace.update", .@"workspace.close", .@"tab.update", .@"tab.close", .@"pane.update", .@"pane.close" => try self.mutate(a, r),
            else => error.MissingCapability,
        };
    }

    // ---- reads ---------------------------------------------------------

    fn snapshot(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{});
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var running: [64]terminals_mod.Terminal = undefined;
        for (self.pool.entries.items, 0..) |*entry, index| running[index] = terminals_mod.terminal(entry);
        return self.success(a, r, .{
            .workspaces = try self.store.workspacesValue(arena.allocator()),
            .terminals = running[0..self.pool.entries.items.len],
        });
    }

    fn list(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{});
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        return self.success(a, r, .{ .workspaces = try self.store.workspacesValue(arena.allocator()) });
    }

    // ---- deferred creates ----------------------------------------------

    fn beginCreate(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) !?[]u8 {
        if (self.terminals.log.poisoned) return error.LogRequiresReopen;
        if (self.persistence_failure != null) return error.LayoutPersistenceFailed;
        const timestamp = r.createdAtUnixMs orelse return error.InvalidRequest;
        const intent = durable.Intent{
            .key = .{ .client_id = try binaryID(r.clientID), .request_id = try binaryID(r.requestID) },
            .fingerprint = try fingerprint(a, r),
            .epoch = self.terminals.epoch,
            .created_ms = timestamp,
            .operation = r.operation,
        };
        const wall: u64 = @intCast(@max(0, std.time.milliTimestamp()));
        if (try self.terminals.log.lookup(intent, self.terminals.epoch, wall)) |decision| return try self.replay(a, r, decision);
        if (self.pending.items.len >= 32) return error.ResourceLimit;

        // Parse and validate everything, including the structural parent and the
        // execution-machine cwd, before the durable reservation. A rejected
        // request must not consume a revision or an idempotency slot.
        var kind: PendingKind = undefined;
        var spec_value: std.json.Value = undefined;
        switch (r.operation) {
            .@"workspace.create" => {
                try only(r.params, &.{ "title", "terminal" });
                const title = try shortParam(r.params, "title");
                spec_value = r.params.object.get("terminal") orelse return error.InvalidRequest;
                const cwd = try pathParam(spec_value, "cwd");
                if (self.store.workspaces.items.len >= store_mod.limits.workspaces) return error.ResourceLimit;
                kind = .{ .workspace = .{ .title = try self.allocator.dupe(u8, title), .cwd = try self.allocator.dupe(u8, cwd) } };
            },
            .@"tab.create" => {
                try only(r.params, &.{ "workspaceID", "title", "terminal" });
                const workspace_id = try idParam(r.params, "workspaceID");
                const title = try shortParam(r.params, "title");
                spec_value = r.params.object.get("terminal") orelse return error.InvalidRequest;
                if (self.store.findWorkspace(workspace_id) == null) return error.WorkspaceNotFound;
                kind = .{ .tab = .{ .workspace_id = workspace_id, .title = try self.allocator.dupe(u8, title) } };
            },
            else => {
                try only(r.params, &.{ "paneID", "direction", "terminal" });
                const pane_id = try idParam(r.params, "paneID");
                const direction = std.meta.stringToEnum(store_mod.Direction, try stringParam(r.params, "direction")) orelse return error.InvalidRequest;
                spec_value = r.params.object.get("terminal") orelse return error.InvalidRequest;
                if (self.store.findPane(pane_id) == null) return error.PaneNotFound;
                kind = .{ .pane = .{ .pane_id = pane_id, .direction = direction } };
            },
        }
        errdefer switch (kind) {
            .workspace => |value| {
                self.allocator.free(value.title);
                self.allocator.free(value.cwd);
            },
            .tab => |value| self.allocator.free(value.title),
            .pane => {},
        };
        if (self.store.paneCount() >= store_mod.limits.panes or self.store.tabCount() >= store_mod.limits.tabs) return error.ResourceLimit;
        try self.checkRevision(r);
        var prepared = try prepareLaunch(a, spec_value);
        defer prepared.deinit();

        const terminal_id = ids.uuidText(ids.newUUID());
        const unknown_response = try self.failure(self.allocator, r, "outcome_unknown", .after_query);
        errdefer self.allocator.free(unknown_response);
        var reserved = intent;
        reserved.terminal_id = try binaryID(&terminal_id);
        const decision = try self.terminals.log.reserve(reserved, self.terminals.epoch, wall);
        if (decision != .reserved) {
            const response = try self.replay(a, r, decision);
            self.allocator.free(unknown_response);
            return response;
        }
        // Consume the revision now. Admission, not completion, is what a
        // competing client must lose against; otherwise two same-revision
        // submissions would both launch and both commit.
        self.store.revision +|= 1;
        self.pending.appendAssumeCapacity(.{
            .intent = reserved,
            .request_id = try textID(r.requestID),
            .client_id = try textID(r.clientID),
            .operation = r.operation,
            .generation = generation,
            .terminal_id = terminal_id,
            .pane_id = ids.uuidText(ids.newUUID()),
            .kind = kind,
            .unknown_response = unknown_response,
        });
        const item = &self.pending.items[self.pending.items.len - 1];
        self.pool.beginCreate(terminal_id, prepared.asLaunch()) catch |err| {
            item.startup_error = err;
        };
        return null;
    }

    fn replay(self: *Service, a: std.mem.Allocator, r: Request, decision: durable.Decision) ![]u8 {
        return switch (decision) {
            .conflict => self.failure(a, r, "invalid_request", .never),
            .request_expired => self.failure(a, r, "request_expired", .after_query),
            .outcome_unknown => self.failure(a, r, "outcome_unknown", .after_query),
            .reserved => error.InvalidRequest,
            // A structural replay describes resources this incarnation may no
            // longer own. Report the recorded outcome verbatim rather than
            // re-asserting liveness; the client reconciles with session.snapshot.
            .replay => |old| a.dupe(u8, old.response),
        };
    }

    fn checkRevision(self: *Service, r: Request) !void {
        const expected = r.expectedRevision orelse return error.InvalidRequest;
        if (expected != self.store.revision) return error.RevisionConflict;
    }

    // ---- synchronous structural mutations -------------------------------

    fn mutate(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        if (self.terminals.log.poisoned) return error.LogRequiresReopen;
        if (self.persistence_failure != null) return error.LayoutPersistenceFailed;
        const timestamp = r.createdAtUnixMs orelse return error.InvalidRequest;
        const intent = durable.Intent{
            .key = .{ .client_id = try binaryID(r.clientID), .request_id = try binaryID(r.requestID) },
            .fingerprint = try fingerprint(a, r),
            .epoch = self.terminals.epoch,
            .created_ms = timestamp,
            .operation = r.operation,
        };
        const wall: u64 = @intCast(@max(0, std.time.milliTimestamp()));
        if (try self.terminals.log.lookup(intent, self.terminals.epoch, wall)) |decision| return try self.replay(a, r, decision);
        try self.checkRevision(r);
        const decision = try self.terminals.log.reserve(intent, self.terminals.epoch, wall);
        if (decision != .reserved) return try self.replay(a, r, decision);
        const before = self.store.revision;
        const response = self.apply(a, r) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A failure after the revision moved already changed observable
            // state, so the intent stays unresolved and a retry reports
            // uncertainty. A failure before it never happened at all, and is
            // recorded so the retry replays the same deterministic answer.
            else => if (self.store.revision != before)
                return try self.failure(a, r, "outcome_unknown", .after_query)
            else
                try self.failure(a, r, errorCode(err), errorRetry(err)),
        };
        self.terminals.log.complete(intent.key, intent.fingerprint, response) catch |err| {
            // The structure already changed and was committed to disk. Keep the
            // intent unresolved so a retry reports uncertainty instead of
            // repeating the mutation, and stop accepting further mutations.
            self.terminals.log.poisoned = true;
            self.persistence_failure = self.persistence_failure orelse err;
            // Free first: the fallback encoding must not risk a double free if
            // it also fails.
            a.free(response);
            return self.failure(a, r, "outcome_unknown", .after_query);
        };
        return response;
    }

    /// Performs one structural change: bump revision, edit the tree, commit
    /// layout.json, then end any orphaned terminals and queue the events.
    /// Terminals are ended only after the layout commit so a persistence failure
    /// cannot destroy processes the recorded layout still references.
    fn apply(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        var doomed: std.ArrayList(ID) = .empty;
        defer doomed.deinit(self.allocator);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temporary = arena.allocator();
        var event_name: []const u8 = undefined;
        var event_body: std.json.Value = undefined;
        var result: std.json.Value = undefined;

        switch (r.operation) {
            .@"workspace.update" => {
                try only(r.params, &.{ "workspaceID", "title" });
                const workspace = self.store.findWorkspace(try idParam(r.params, "workspaceID")) orelse return error.WorkspaceNotFound;
                if (r.params.object.get("title")) |_| try self.store.updateWorkspaceTitle(workspace, try shortParam(r.params, "title"));
                self.store.revision +|= 1;
                try self.commitLayout();
                result = try self.store.workspaceValue(temporary, workspace);
                event_name = "workspace.changed";
                event_body = result;
            },
            .@"workspace.close" => {
                try only(r.params, &.{"workspaceID"});
                const workspace_id = try idParam(r.params, "workspaceID");
                const workspace = self.store.findWorkspace(workspace_id) orelse return error.WorkspaceNotFound;
                try self.store.collectWorkspaceTerminals(workspace, &doomed);
                self.store.revision +|= 1;
                self.store.closeWorkspace(workspace);
                try self.commitLayout();
                result = try boolean(temporary, "closed");
                // A closed workspace is reported as itself with no tabs: the
                // schema has no removal variant and an empty tab list is the
                // only shape that names the workspace that went away.
                event_name = "workspace.changed";
                event_body = try emptyWorkspace(temporary, workspace_id);
            },
            .@"tab.update" => {
                try only(r.params, &.{ "tabID", "title", "layout" });
                const location = self.store.findTab(try idParam(r.params, "tabID")) orelse return error.TabNotFound;
                if (r.params.object.get("title")) |_| try self.store.updateTabTitle(location.tab, try shortParam(r.params, "title"));
                if (r.params.object.get("layout")) |layout| try self.store.replaceLayout(location.tab, layout);
                self.store.revision +|= 1;
                try self.commitLayout();
                result = try self.store.tabValue(temporary, location.tab);
                event_name = "tab.changed";
                event_body = result;
            },
            .@"tab.close" => {
                try only(r.params, &.{"tabID"});
                const location = self.store.findTab(try idParam(r.params, "tabID")) orelse return error.TabNotFound;
                try self.store.collectTabTerminals(location.tab, &doomed);
                const workspace_id = location.workspace.workspace_id;
                const last = location.workspace.tabs.items.len == 1;
                self.store.revision +|= 1;
                self.store.closeTab(location.workspace, location.tab);
                if (last) self.store.closeWorkspace(location.workspace);
                try self.commitLayout();
                result = try boolean(temporary, "closed");
                event_name = "workspace.changed";
                event_body = if (last) try emptyWorkspace(temporary, workspace_id) else try self.store.workspaceValue(temporary, self.store.findWorkspace(workspace_id).?);
            },
            .@"pane.update" => {
                try only(r.params, &.{ "paneID", "title" });
                const location = self.store.findPane(try idParam(r.params, "paneID")) orelse return error.PaneNotFound;
                try self.store.updatePaneTitle(location, try stringParam(r.params, "title"));
                self.store.revision +|= 1;
                try self.commitLayout();
                result = try self.store.paneValue(temporary, location.tab.nodes.items[location.node].leaf);
                event_name = "pane.changed";
                event_body = result;
            },
            else => {
                try only(r.params, &.{"paneID"});
                const location = self.store.findPane(try idParam(r.params, "paneID")) orelse return error.PaneNotFound;
                try doomed.append(self.allocator, location.tab.nodes.items[location.node].leaf.terminal_id);
                const workspace_id = location.workspace.workspace_id;
                const tab_id = location.tab.tab_id;
                self.store.revision +|= 1;
                const removal = self.store.closePane(location);
                try self.commitLayout();
                result = try boolean(temporary, "closed");
                switch (removal) {
                    .pane_only => {
                        event_name = "tab.changed";
                        event_body = try self.store.tabValue(temporary, self.store.findTab(tab_id).?.tab);
                    },
                    .tab_closed => {
                        event_name = "workspace.changed";
                        event_body = try self.store.workspaceValue(temporary, self.store.findWorkspace(workspace_id).?);
                    },
                    .workspace_closed => {
                        event_name = "workspace.changed";
                        event_body = try emptyWorkspace(temporary, workspace_id);
                    },
                }
            },
        }
        const response = try self.success(a, r, result);
        errdefer a.free(response);
        try self.queueEvent(event_name, event_body);
        for (doomed.items) |terminal_id| self.pool.terminate(terminal_id, 1000) catch {};
        return response;
    }

    fn commitLayout(self: *Service) !void {
        self.store.persist(self.dir) catch |err| {
            self.persistence_failure = err;
            return error.LayoutPersistenceFailed;
        };
    }

    /// Sync agent bindings from agent_store to layout panes, then persist.
    /// Called from the service main loop. Checks each pane for stale bindings.
    pub fn maybeSyncAgentBindings(self: *Service) void {
        var dirty = false;
        for (self.store.workspaces.items) |*workspace| {
            for (workspace.tabs.items) |*tab| {
                for (tab.nodes.items) |*node| {
                    if (node.* != .leaf) continue;
                    const pane = &node.leaf;
                    if (self.terminals.getAgentBinding(pane.terminal_id)) |binding| {
                        if (pane.agent_provider == null or !std.mem.eql(u8, pane.agent_provider.?, binding.provider)) {
                            if (pane.agent_provider) |old| self.allocator.free(old);
                            pane.agent_provider = self.allocator.dupe(u8, binding.provider) catch null;
                            dirty = true;
                        }
                        if (binding.native_session) |ns| {
                            if (pane.agent_native_session == null or !std.mem.eql(u8, pane.agent_native_session.?, ns)) {
                                if (pane.agent_native_session) |old| self.allocator.free(old);
                                pane.agent_native_session = self.allocator.dupe(u8, ns) catch null;
                                dirty = true;
                            }
                        }
                    }
                }
            }
        }
        if (dirty) {
            self.store.persist(self.dir) catch |err| {
                self.persistence_failure = self.persistence_failure orelse err;
            };
        }
    }


    fn queueEvent(self: *Service, name: []const u8, body: std.json.Value) !void {
        if (self.events.items.len >= 256) return error.ResourceLimit;
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, body, .{});
        self.events.appendAssumeCapacity(.{ .name = name, .body = bytes, .revision = self.store.revision });
    }

    // ---- completion of deferred creates ---------------------------------

    pub fn tick(self: *Service) !void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const item = &self.pending.items[index];
            if (item.response == null) {
                if (item.startup_error == null and item.completion == null) {
                    index += 1;
                    continue;
                }
                self.finish(item);
            }
            if (!item.persisted and !item.completion_failed) {
                if (self.terminals.log.complete(item.intent.key, item.intent.fingerprint, item.response.?)) |_| {
                    item.persisted = true;
                } else |err| {
                    self.terminals.log.poisoned = true;
                    self.persistence_failure = self.persistence_failure orelse err;
                    self.allocator.free(item.response.?);
                    item.response = item.unknown_response.?;
                    item.unknown_response = null;
                    item.completion_failed = true;
                }
            }
            if (item.generation) |generation| {
                if (self.replies.items.len >= 64) {
                    index += 1;
                    continue;
                }
                self.replies.appendAssumeCapacity(.{ .connection_generation = generation, .bytes = item.response.? });
                item.response = null;
            } else {
                self.allocator.free(item.response.?);
                item.response = null;
            }
            self.releasePending(item);
            _ = self.pending.orderedRemove(index);
        }
    }

    /// Commits or rejects one finished create. The structural node is inserted
    /// only for a real, running PTY, so a launch failure leaves nothing behind.
    fn finish(self: *Service, item: *Pending) void {
        const request = Request{
            .type = "request",
            .requestID = &item.request_id,
            .clientID = &item.client_id,
            .scope = .session,
            .operation = item.operation,
            .target = self.target(),
            .params = .{ .object = std.json.ObjectMap.init(self.allocator) },
        };
        if (item.startup_error) |err| {
            item.response = self.encoded(item, self.failure(self.allocator, request, errorCode(err), errorRetry(err)));
            return;
        }
        switch (item.completion.?.result) {
            .failed => |value| {
                item.response = self.encoded(item, self.failure(self.allocator, request, errorCode(value.reason), errorRetry(value.reason)));
                return;
            },
            .cancelled => {
                item.response = self.encoded(item, self.failure(self.allocator, request, "service_stopping", .after_reconnect));
                return;
            },
            .created => {},
        }
        item.response = self.encoded(item, self.commitCreate(item, request));
    }

    fn commitCreate(self: *Service, item: *Pending, request: Request) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        const pane = store_mod.Pane{ .pane_id = item.pane_id, .terminal_id = item.terminal_id };
        var result: std.json.Value = undefined;
        var event_name: []const u8 = undefined;
        var event_body: std.json.Value = undefined;
        switch (item.kind) {
            .workspace => |value| {
                const workspace = try self.store.createWorkspace(value.title, value.cwd, pane);
                try self.commitLayout();
                result = try self.store.workspaceValue(temporary, workspace);
                event_name = "workspace.changed";
                event_body = result;
            },
            .tab => |value| {
                const workspace = self.store.findWorkspace(value.workspace_id) orelse return error.WorkspaceNotFound;
                const tab = try self.store.createTab(workspace, value.title, pane);
                try self.commitLayout();
                result = try self.store.tabValue(temporary, tab);
                event_name = "tab.changed";
                event_body = result;
            },
            .pane => |value| {
                const location = self.store.findPane(value.pane_id) orelse return error.PaneNotFound;
                const tab_id = location.tab.tab_id;
                _ = try self.store.splitPane(location, value.direction, pane);
                try self.commitLayout();
                var object = std.json.ObjectMap.init(temporary);
                try object.put("pane", try self.store.paneValue(temporary, pane));
                try object.put("terminal", try terminalValue(temporary, terminals_mod.terminal(self.pool.find(item.terminal_id).?)));
                result = .{ .object = object };
                event_name = "tab.changed";
                event_body = try self.store.tabValue(temporary, self.store.findTab(tab_id).?.tab);
            },
        }
        const response = try self.success(self.allocator, request, result);
        errdefer self.allocator.free(response);
        try self.queueEvent("terminal.created", try terminalValue(temporary, terminals_mod.terminal(self.pool.find(item.terminal_id).?)));
        try self.queueEvent(event_name, event_body);
        return response;
    }

    /// A commit or encoding failure cannot unwind a process that already exists.
    /// Fall back to the uncertainty reply reserved before the launch.
    fn encoded(_: *Service, item: *Pending, result: anyerror![]u8) []u8 {
        return result catch {
            item.completion_failed = true;
            const reply = item.unknown_response.?;
            item.unknown_response = null;
            return reply;
        };
    }

    // ---- cold restore (P6.1/P6.4) ----------------------------------------

    /// Handles session.restore: for each stale pane in the persisted layout,
    /// assigns a new terminal ID and enqueues a deferred create. The response
    /// is returned immediately with the old→new mapping; the actual terminals
    /// start asynchronously and completions are claimed by this service's
    /// structure hook. Prevents duplicate restore across clients.
    fn restore(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{ "geometry", "theme", "force", "paneID" });
        // `force`：用户显式点「重新启动 Shell」时绕过"每次冷启动只恢复一次"的守卫——
        // 已退出的终端已从活动池退休，等同失效，可以被替换成新 Shell（或 Agent 原生恢复）。
        // `paneID`：只恢复这一个窗格，不把会话里其它已退出的窗格一起拉起来。
        const force = if (r.params.object.get("force")) |v| (v == .bool and v.bool) else false;
        var only_pane: ?[36]u8 = null;
        if (r.params.object.get("paneID")) |_| only_pane = try idParam(r.params, "paneID");
        if (self.restore_completed and !force) {
            return self.success(a, r, .{ .entries = &[0]std.json.Value{}, .alreadyRestored = true });
        }
        // Parse client-provided geometry for new terminal creation
        const geometry_value = r.params.object.get("geometry") orelse return error.InvalidRequest;
        const parsed_geo = std.json.parseFromValue(struct { rows: u16, columns: u16, pixelWidth: u16 = 0, pixelHeight: u16 = 0 }, a, geometry_value, .{}) catch return error.InvalidRequest;
        defer parsed_geo.deinit();
        const geometry = @import("geometry.zig").Geometry{
            .rows = parsed_geo.value.rows, .columns = parsed_geo.value.columns,
            .pixel_width = parsed_geo.value.pixelWidth, .pixel_height = parsed_geo.value.pixelHeight,
        };
        try geometry.validate();

        // Collect stale panes and build restore entries
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temporary = arena.allocator();
        var entries = std.json.Array.init(temporary);

        for (self.store.workspaces.items) |*workspace| {
            for (workspace.tabs.items) |*tab| {
                try self.collectRestorePanes(temporary, tab, tab.root, workspace.cwd, geometry, only_pane, &entries);
            }
        }

        // Persist the updated layout with new terminal IDs
        if (entries.items.len > 0) {
            try self.commitLayout();
        }
        self.restore_completed = true;
        return self.success(a, r, .{ .entries = entries.items, .alreadyRestored = false });
    }

    /// Walk layout nodes, assign new terminal IDs to stale panes, and enqueue
    /// each as a workspace-service Pending (so structure_hook claims the
    /// completion). Agent references produce resume argv instead of /bin/sh.
    fn collectRestorePanes(self: *Service, arena: std.mem.Allocator, tab: *store_mod.Tab, index: usize, cwd: []const u8, geometry: @import("geometry.zig").Geometry, only_pane: ?[36]u8, entries: *std.json.Array) !void {
        if (index >= tab.nodes.items.len) return;
        switch (tab.nodes.items[index]) {
            .leaf => |*pane| {
                if (only_pane) |wanted| if (!std.mem.eql(u8, &wanted, &pane.pane_id)) return;
                const old_terminal_id = pane.terminal_id;
                // Skip terminals that are already running (detach-reattach)
                if (self.pool.find(old_terminal_id) != null) return;
                // Assign new terminal ID
                const new_terminal_id = ids.uuidText(ids.newUUID());
                // Determine restore path and argv — check screen history first:
                // if history data exists for this terminal and no agent binding,
                // use history_replay instead of starting a fresh shell.
                var path: []const u8 = "new_shell";
                var history_captured_at_ms: ?u64 = null;
                if (self.screen_history_writer) |hw| {
                    history_captured_at_ms = readHistoryCapturedAt(hw, old_terminal_id);
                }
                var agent_provider: ?[]const u8 = null;
                var agent_session: ?[]const u8 = null;
                // Build the terminal spec for pool.beginCreate
                const spec_cwd = try self.allocator.dupeZ(u8, cwd);
                errdefer self.allocator.free(spec_cwd);
                // 冷恢复的新 Shell 必须是用户的登录交互 Shell，与客户端新建标签一致
                // （ManagedTerminalLaunchSpec.remoteArgv）：裸 /bin/sh 没有 PATH、提示符和
                // rc 文件，用户看到的是 `grok: not found` 这种"坏掉的终端"。
                var default_argv = [_][]const u8{ "/bin/sh", "-lc", "exec \"${SHELL:-/bin/sh}\" -l -i" };
                var actual_argv: []const []const u8 = &default_argv;
                var restore_argv_buf: [8][]const u8 = undefined;
                if (pane.agent_provider) |provider| {
                    if (pane.agent_native_session) |session| {
                        if (buildAgentRestoreArgv(provider, session, &restore_argv_buf)) |restore_argv| {
                            actual_argv = restore_argv;
                            path = "agent_restore";
                            agent_provider = provider;
                            agent_session = session;
                        }
                    }
                }
                // Resolve argv[0] to an absolute path (pool requires it).
                if (!std.fs.path.isAbsolute(actual_argv[0])) {
                    const default_path = "/usr/local/bin:/usr/bin:/bin";
                    const path_env = std.posix.getenv("PATH") orelse default_path;
                    if (preparation.resolveExecutable(arena, cwd, actual_argv[0], path_env)) |resolved| {
                        restore_argv_buf[0] = resolved;
                        actual_argv = restore_argv_buf[0..actual_argv.len];
                    } else |_| {
                        // CLI not found; fall back to new shell
                        path = "new_shell";
                        agent_provider = null;
                        agent_session = null;
                        actual_argv = &default_argv;
                    }
                }
                // If no agent binding but history exists, mark as history_replay.
                if (std.mem.eql(u8, path, "new_shell") and history_captured_at_ms != null) {
                    path = "history_replay";
                }
                // Use pool.beginCreate for the actual terminal spawn
                self.pool.beginCreate(new_terminal_id, .{
                    .cwd = cwd, .argv = actual_argv, .geometry = geometry,
                }) catch |err| {
                    self.allocator.free(spec_cwd);
                    // Record failure entry
                    var entry = std.json.ObjectMap.init(arena);
                    entry.put("paneID", .{ .string = arena.dupe(u8, &pane.pane_id) catch return err }) catch return err;
                    entry.put("oldTerminalID", .{ .string = arena.dupe(u8, &old_terminal_id) catch return err }) catch return err;
                    entry.put("newTerminalID", .{ .string = arena.dupe(u8, &new_terminal_id) catch return err }) catch return err;
                    entry.put("path", .{ .string = "failed" }) catch return err;
                    entry.put("failureReason", .{ .string = @errorName(err) }) catch return err;
                    entries.append(.{ .object = entry }) catch return err;
                    return;
                };
                self.allocator.free(spec_cwd);
                // Register in terminal_service so tick() claims the completion
                try self.restore_terminal_ids.append(self.allocator, new_terminal_id);
                // Update the store with the new terminal ID
                pane.terminal_id = new_terminal_id;
                // Build the restore entry for the response
                var entry = std.json.ObjectMap.init(arena);
                try entry.put("paneID", .{ .string = try arena.dupe(u8, &pane.pane_id) });
                try entry.put("oldTerminalID", .{ .string = try arena.dupe(u8, &old_terminal_id) });
                try entry.put("newTerminalID", .{ .string = try arena.dupe(u8, &new_terminal_id) });
                try entry.put("path", .{ .string = path });
                if (agent_provider) |p| try entry.put("agentProvider", .{ .string = try arena.dupe(u8, p) });
                if (agent_session) |s| try entry.put("agentNativeSession", .{ .string = try arena.dupe(u8, s) });
                if (history_captured_at_ms) |ts| try entry.put("capturedAtMs", .{ .integer = @intCast(ts) });
                try entries.append(.{ .object = entry });
            },
            .split => |split| {
                try self.collectRestorePanes(arena, tab, split.first, cwd, geometry, only_pane, entries);
                try self.collectRestorePanes(arena, tab, split.second, cwd, geometry, only_pane, entries);
            },
            .free => {},
        }
    }


    /// Read the captured_at_ms timestamp from a terminal's screen history file.
    /// Opens history/ under the writer's state directory and parses the file
    /// header directly. Returns null if the file is missing or corrupted.
    fn readHistoryCapturedAt(writer: *screen_history.Writer, terminal_id: [36]u8) ?u64 {
        var dir = writer.dir.openDir("history", .{}) catch return null;
        defer dir.close();
        const header_len = 4 + 1 + 8 + 4; // magic(4) + version(1) + captured_at_ms(8) + data_len(4)
        var name_buf: [36 + 5]u8 = undefined;
        @memcpy(name_buf[0..36], &terminal_id);
        @memcpy(name_buf[36..], ".hist");
        const fd = std.posix.openat(dir.fd, &name_buf, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch return null;
        var file = std.fs.File{ .handle = fd };
        defer file.close();
        var header: [header_len]u8 = undefined;
        const n = file.readAll(&header) catch return null;
        if (n < header_len) return null;
        if (!std.mem.eql(u8, header[0..4], "ASTH") or header[4] != 1) return null;
        return std.mem.readInt(u64, header[5..13], .little);
    }

    // ---- session settings (P6.2) ------------------------------------------

    /// Returns current session settings including screen history toggle.
    fn settingsGet(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{});
        return self.success(a, r, .{
            .paneHistory = self.store.screen_history_enabled,
            .resumeAgentsOnRestore = true,
        });
    }

    /// Updates session settings. Currently supports screen history toggle.
    fn settingsUpdate(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try self.checkRevision(r);
        if (r.params.object.get("paneHistory")) |value| {
            if (value != .bool) return error.InvalidRequest;
            self.store.screen_history_enabled = value.bool;
        }
        self.store.revision +|= 1;
        try self.commitLayout();
        return self.success(a, r, .{
            .paneHistory = self.store.screen_history_enabled,
            .resumeAgentsOnRestore = true,
        });
    }

    pub fn takeReply(self: *Service) ?Reply {
        return if (self.replies.items.len == 0) null else self.replies.orderedRemove(0);
    }

    pub fn takeEvent(self: *Service) ?Event {
        return if (self.events.items.len == 0) null else self.events.orderedRemove(0);
    }

    /// Losing a connection discards delivery rights only. An accepted structural
    /// mutation keeps running and still commits.
    pub fn disconnect(self: *Service, generation: u64) void {
        for (self.pending.items) |*item| if (item.generation == generation) {
            item.generation = null;
        };
        var index: usize = 0;
        while (index < self.replies.items.len) {
            if (self.replies.items[index].connection_generation != generation) {
                index += 1;
                continue;
            }
            self.allocator.free(self.replies.orderedRemove(index).bytes);
        }
    }
};

fn emptyWorkspace(arena: std.mem.Allocator, id: ID) !std.json.Value {
    var object = std.json.ObjectMap.init(arena);
    try object.put("workspaceID", .{ .string = try arena.dupe(u8, &id) });
    try object.put("title", .{ .string = "" });
    try object.put("cwd", .{ .string = "/" });
    try object.put("tabs", .{ .array = std.json.Array.init(arena) });
    return .{ .object = object };
}

fn boolean(arena: std.mem.Allocator, key: []const u8) !std.json.Value {
    var object = std.json.ObjectMap.init(arena);
    try object.put(key, .{ .bool = true });
    return .{ .object = object };
}

fn terminalValue(arena: std.mem.Allocator, value: terminals_mod.Terminal) !std.json.Value {
    const bytes = try std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    return parsed;
}

/// Build provider-specific resume argv (P6.3). Returns null if provider unknown.
fn buildAgentRestoreArgv(provider: []const u8, session: []const u8, buf: *[8][]const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, provider, "grokBuild")) {
        buf[0] = "grok"; buf[1] = "--resume"; buf[2] = session;
        return buf[0..3];
    } else if (std.mem.eql(u8, provider, "claudeCode")) {
        buf[0] = "claude"; buf[1] = "--resume"; buf[2] = session;
        return buf[0..3];
    } else if (std.mem.eql(u8, provider, "codex")) {
        buf[0] = "codex"; buf[1] = "--resume"; buf[2] = session;
        return buf[0..3];
    } else if (std.mem.eql(u8, provider, "openCode")) {
        buf[0] = "opencode"; buf[1] = "--resume"; buf[2] = session;
        return buf[0..3];
    } else if (std.mem.eql(u8, provider, "kimiCode")) {
        buf[0] = "kimi"; buf[1] = "--resume"; buf[2] = session;
        return buf[0..3];
    } else if (std.mem.eql(u8, provider, "pi")) {
        buf[0] = "pi"; buf[1] = "--resume"; buf[2] = session;
        return buf[0..3];
    } else if (std.mem.eql(u8, provider, "omp")) {
        buf[0] = "omp"; buf[1] = "--resume"; buf[2] = session;
        return buf[0..3];
    } else if (std.mem.eql(u8, provider, "cursorCLI")) {
        buf[0] = "agent"; buf[1] = "--resume"; buf[2] = session;
        return buf[0..3];
    }
    return null;
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.RevisionConflict => "revision_conflict",
        error.WorkspaceNotFound => "workspace_not_found",
        error.TabNotFound => "tab_not_found",
        error.MissingCapability => "missing_capability",
        error.LogRequiresReopen, error.LayoutPersistenceFailed, error.CorruptLayout => "outcome_unknown",
        error.InvalidTerminalDirectory, error.WorkingDirectoryUnavailable => "cwd_unavailable",
        error.ExecutableUnavailable => "executable_unavailable",
        error.ResourceLimit, error.TerminalLimitReached, error.CreationCompletionBackpressure, error.LogCapacity, error.TerminalGeometryLimit => "resource_limit",
        error.RestoreAlreadyCompleted => "restore_already_completed",
        error.PaneNotFound, error.InvalidRequest, error.InvalidTerminalArguments, error.InvalidTerminalEnvironment, error.DuplicateEnvironmentName, error.FutureRequest, error.InvalidDimensions, error.InvalidPixelDimensions, error.UnsafeLayoutFile => "invalid_request",
        else => "internal_error",
    };
}

fn errorRetry(err: anyerror) Retry {
    return switch (err) {
        error.RevisionConflict, error.LogRequiresReopen, error.LayoutPersistenceFailed, error.CorruptLayout => .after_query,
        error.ResourceLimit, error.LogCapacity => .backoff,
        else => .never,
    };
}

// ---- shared parameter helpers ------------------------------------------

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

fn shortParam(value: std.json.Value, name: []const u8) ![]const u8 {
    const text = try stringParam(value, name);
    if (text.len == 0 or text.len > store_mod.limits.short_text) return error.InvalidRequest;
    return text;
}

fn pathParam(value: std.json.Value, name: []const u8) ![]const u8 {
    const text = try stringParam(value, name);
    if (text.len == 0 or text.len > store_mod.limits.long_text or !std.fs.path.isAbsolute(text)) return error.InvalidRequest;
    return text;
}

fn textID(value: []const u8) !ID {
    if (!@import("operation_request.zig").validID(value)) return error.InvalidRequest;
    return value[0..36].*;
}

fn idParam(value: std.json.Value, name: []const u8) !ID {
    return textID(try stringParam(value, name));
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
            var result = std.json.Array.init(a);
            for (array.items) |item| try result.append(try canonical(a, item));
            return .{ .array = result };
        },
        else => return value,
    }
}

fn fingerprint(a: std.mem.Allocator, r: Request) ![32]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), .{
        .operation = r.operation,
        .params = try canonical(arena.allocator(), r.params),
        .created = r.createdAtUnixMs,
        .revision = r.expectedRevision,
    }, .{});
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

/// Same launch contract as terminal.create: the execution machine resolves the
/// executable, merges its own environment and validates the directory. A
/// missing directory fails here, before any structure is reserved.
fn prepareLaunch(a: std.mem.Allocator, params: std.json.Value) !preparation.Prepared {
    try only(params, &.{ "cwd", "argv", "environment", "geometry" });
    const cwd = try stringParam(params, "cwd");
    const argv_value = params.object.get("argv") orelse return error.InvalidRequest;
    if (argv_value != .array or argv_value.array.items.len == 0 or argv_value.array.items.len > 128) return error.InvalidRequest;
    var argv: [128][]const u8 = undefined;
    for (argv_value.array.items, 0..) |value, index| {
        if (value != .string) return error.InvalidRequest;
        argv[index] = value.string;
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
    const geometry = if (params.object.get("geometry")) |value| blk: {
        const parsed = std.json.parseFromValue(struct { rows: u16, columns: u16, pixelWidth: u16 = 0, pixelHeight: u16 = 0 }, a, value, .{}) catch return error.InvalidRequest;
        defer parsed.deinit();
        const result = @import("geometry.zig").Geometry{ .rows = parsed.value.rows, .columns = parsed.value.columns, .pixel_width = parsed.value.pixelWidth, .pixel_height = parsed.value.pixelHeight };
        try result.validate();
        break :blk result;
    } else @import("geometry.zig").Geometry{ .rows = 24, .columns = 80 };
    return preparation.prepare(a, .{ .cwd = cwd, .argv = argv[0..argv_value.array.items.len], .environment = env.items, .geometry = geometry }, inherited.items);
}
