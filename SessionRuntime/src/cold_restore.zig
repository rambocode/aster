const std = @import("std");
const ids = @import("service_identity.zig");
const store_mod = @import("workspace_store.zig");
const Store = store_mod.Store;
const ID = store_mod.ID;

/// Cold restore: reads a persisted layout and produces a plan of terminals to
/// create. Each plan entry preserves the original paneID but assigns a fresh
/// terminalID. The caller (workspace_service) creates the actual terminals and
/// updates the layout store with the new terminalID mappings.
///
/// The store already loads `layout.json` on startup (see
/// `service_server.zig`); this module only decides *what to do* with that
/// loaded tree — it never touches the filesystem or spawns anything itself.

/// One planned terminal, keyed by its stable paneID. `old_terminal_id` is the
/// identifier that was persisted before the restart; `new_terminal_id` is
/// generated up front so the plan is fully determined before any terminal is
/// actually started, which keeps `applyPlan` a pure, order-independent
/// rewrite of the store.
pub const RestoreEntry = struct {
    pane_id: ID,
    old_terminal_id: ID,
    new_terminal_id: ID,
    workspace_title: []const u8,
    tab_title: []const u8,
    /// Lifecycle of this entry's terminal creation. Set by the caller as it
    /// works the plan; buildPlan only ever produces `.pending` entries.
    status: enum { pending, created, failed, skipped } = .pending,
    new_pid: ?i32 = null,
    failure_reason: ?[]const u8 = null,
};

/// One provider/session reference recorded on a pane (P6.3). Both strings are
/// borrowed from the store's own `Pane.agent_provider` /
/// `Pane.agent_native_session` allocations and are only valid as long as the
/// store outlives them.
pub const AgentRef = struct {
    terminal_id: ID,
    provider: []const u8,
    native_session: []const u8,
};

/// Ordered list of terminals to (re)create for a cold restart. Entries are
/// borrowed views into `store`'s own memory (workspace/tab titles) plus
/// freshly generated terminal IDs, so the plan must not outlive the store it
/// was built from.
pub const RestorePlan = struct {
    entries: std.ArrayList(RestoreEntry) = .empty,

    pub fn deinit(self: *RestorePlan, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.* = undefined;
    }
};

/// Walks every workspace/tab/pane in `store` and records one restore entry
/// per pane, generating a fresh terminalID for each. Order follows the
/// store's own workspace/tab/node order, which is stable for a given
/// layout.json — callers that log or replay the plan can rely on that.
pub fn buildPlan(store: *Store, allocator: std.mem.Allocator) !RestorePlan {
    var plan = RestorePlan{};
    errdefer plan.deinit(allocator);
    for (store.workspaces.items) |*workspace| {
        for (workspace.tabs.items) |*tab| {
            for (tab.nodes.items) |node| {
                if (node != .leaf) continue;
                const pane = node.leaf;
                try plan.entries.append(allocator, .{
                    .pane_id = pane.pane_id,
                    .old_terminal_id = pane.terminal_id,
                    .new_terminal_id = ids.uuidText(ids.newUUID()),
                    .workspace_title = workspace.title,
                    .tab_title = tab.title,
                });
            }
        }
    }
    return plan;
}

/// Rewrites each planned pane's `terminal_id` in `store` to the entry's
/// `new_terminal_id`. A pane the plan references but the store no longer has
/// (closed between `buildPlan` and this call) is silently skipped: the tree
/// itself is the source of truth, and a stale plan entry for a pane that is
/// simply gone is not an error.
pub fn applyPlan(store: *Store, plan: *const RestorePlan) void {
    for (plan.entries.items) |entry| {
        const location = store.findPane(entry.pane_id) orelse continue;
        location.tab.nodes.items[location.node].leaf.terminal_id = entry.new_terminal_id;
    }
}

/// Walks every pane with an agent binding (P6.3) and returns its
/// provider/native-session reference. Used by the remote-work reconciler to
/// verify each binding still points at a live native session before wiring a
/// restored pane back up to it.
pub fn collectAgentRefs(store: *Store, allocator: std.mem.Allocator) !std.ArrayList(AgentRef) {
    var refs: std.ArrayList(AgentRef) = .empty;
    errdefer refs.deinit(allocator);
    for (store.workspaces.items) |*workspace| {
        for (workspace.tabs.items) |*tab| {
            for (tab.nodes.items) |node| {
                if (node != .leaf) continue;
                const pane = node.leaf;
                const provider = pane.agent_provider orelse continue;
                const native_session = pane.agent_native_session orelse continue;
                try refs.append(allocator, .{
                    .terminal_id = pane.terminal_id,
                    .provider = provider,
                    .native_session = native_session,
                });
            }
        }
    }
    return refs;
}

fn testPane() store_mod.Pane {
    return .{ .pane_id = ids.uuidText(ids.newUUID()), .terminal_id = ids.uuidText(ids.newUUID()) };
}

test "cold restore buildPlan assigns a fresh terminalID per pane" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const workspace = try store.createWorkspace("first", "/tmp", testPane());
    const tab = &workspace.tabs.items[0];
    const root_pane = tab.nodes.items[tab.root].leaf.pane_id;
    _ = try store.splitPane(store.findPane(root_pane).?, .right, testPane());

    var plan = try buildPlan(&store, std.testing.allocator);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.entries.items.len);

    var seen_new_ids: [2]ID = undefined;
    for (plan.entries.items, 0..) |entry, index| {
        // Every entry gets a fresh ID distinct from what was persisted, and
        // still points at a pane that genuinely exists in the store.
        try std.testing.expect(!std.mem.eql(u8, &entry.old_terminal_id, &entry.new_terminal_id));
        try std.testing.expect(store.findPane(entry.pane_id) != null);
        try std.testing.expect(entry.status == .pending);
        seen_new_ids[index] = entry.new_terminal_id;
    }
    // ...and distinct from every other entry's fresh ID.
    try std.testing.expect(!std.mem.eql(u8, &seen_new_ids[0], &seen_new_ids[1]));
}

test "cold restore applyPlan rewrites the store's terminal IDs" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const workspace = try store.createWorkspace("first", "/tmp", testPane());
    const tab = &workspace.tabs.items[0];
    const root_pane = tab.nodes.items[tab.root].leaf.pane_id;
    const added = try store.splitPane(store.findPane(root_pane).?, .right, testPane());
    const added_pane = added.pane_id;

    var plan = try buildPlan(&store, std.testing.allocator);
    defer plan.deinit(std.testing.allocator);
    applyPlan(&store, &plan);

    for (plan.entries.items) |entry| {
        const location = store.findPane(entry.pane_id).?;
        try std.testing.expectEqualSlices(u8, &entry.new_terminal_id, &location.tab.nodes.items[location.node].leaf.terminal_id);
    }
    try std.testing.expect(store.findPane(root_pane) != null and store.findPane(added_pane) != null);
}

test "cold restore agent references survive a persist and load cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pane_id: ID = undefined;
    var expected_terminal_id: ID = undefined;
    {
        var store = Store.init(std.testing.allocator);
        defer store.deinit();
        const workspace = try store.createWorkspace("first", "/tmp", testPane());
        const tab = &workspace.tabs.items[0];
        pane_id = tab.nodes.items[tab.root].leaf.pane_id;
        expected_terminal_id = tab.nodes.items[tab.root].leaf.terminal_id;
        const location = store.findPane(pane_id).?;
        location.tab.nodes.items[location.node].leaf.agent_provider = try store.allocator.dupe(u8, "claudeCode");
        location.tab.nodes.items[location.node].leaf.agent_native_session = try store.allocator.dupe(u8, "sess-001");
        try store.persist(tmp.dir);
    }
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.load(tmp.dir);
    var refs = try collectAgentRefs(&store, std.testing.allocator);
    defer refs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqualSlices(u8, &expected_terminal_id, &refs.items[0].terminal_id);
    try std.testing.expectEqualStrings("claudeCode", refs.items[0].provider);
    try std.testing.expectEqualStrings("sess-001", refs.items[0].native_session);
}
