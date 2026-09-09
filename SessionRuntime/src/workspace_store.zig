const std = @import("std");
const ids = @import("service_identity.zig");
const validID = @import("operation_request.zig").validID;

pub const ID = [36]u8;

/// Structural ceilings for one session. They mirror protocol/operations.json
/// (`maxItems` on workspace/tab arrays and `semanticLimits.maximumPanes` /
/// `maximumLayoutDepth`); the wire schema only bounds one message, so the store
/// enforces the session-wide totals that a sequence of valid requests could
/// otherwise exceed.
pub const limits = struct {
    pub const workspaces: usize = 1024;
    pub const tabs: usize = 128;
    pub const panes: usize = 64;
    pub const depth: usize = 16;
    pub const short_text: usize = 128;
    pub const long_text: usize = 4096;
};

pub const Axis = enum { horizontal, vertical };
pub const Direction = enum { left, right, up, down };

pub const Pane = struct { pane_id: ID, terminal_id: ID, title: ?[]u8 = null };
const Split = struct { axis: Axis, ratio: f64, first: usize, second: usize };
/// `free` is a tombstone: node indices are referenced by parent splits, so a
/// removed node keeps its slot until a later split reuses it. Slots per tab are
/// bounded by 2*panes-1, so tombstones cannot grow without bound.
const Node = union(enum) { free, leaf: Pane, split: Split };

pub const Tab = struct {
    tab_id: ID,
    title: []u8,
    nodes: std.ArrayList(Node) = .empty,
    root: usize = 0,
};

pub const Workspace = struct {
    workspace_id: ID,
    title: []u8,
    cwd: []u8,
    tabs: std.ArrayList(Tab) = .empty,
};

/// Authoritative workspace/tab/pane tree of one session plus its monotonic
/// revision. Every structural change is committed through this object so the
/// revision, the in-memory tree and `layout.json` stay in agreement. The store
/// never starts or stops a process; the caller pairs each commit with the
/// matching terminal lifecycle action.
pub const Store = struct {
    allocator: std.mem.Allocator,
    workspaces: std.ArrayList(Workspace) = .empty,
    /// Layout revision: the optimistic-concurrency token for structural
    /// transactions (`workspace.*`, `tab.*`, `pane.*`). Monotonic, never
    /// rewound. The terminal domain only *reads* it: terminal lifecycle
    /// (create / terminate / exit) is not a layout edit and must not advance it,
    /// otherwise an unrelated terminal being reaped inside a client's
    /// read/submit window turns a legal transaction into a false
    /// `revision_conflict`. A structural request that also creates a terminal
    /// advances it exactly once, at admission.
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.workspaces.items) |*workspace| self.freeWorkspace(workspace);
        self.workspaces.deinit(self.allocator);
        self.* = undefined;
    }

    fn freeWorkspace(self: *Store, workspace: *Workspace) void {
        for (workspace.tabs.items) |*tab| self.freeTab(tab);
        workspace.tabs.deinit(self.allocator);
        self.allocator.free(workspace.title);
        self.allocator.free(workspace.cwd);
    }

    fn freeTab(self: *Store, tab: *Tab) void {
        for (tab.nodes.items) |node| if (node == .leaf) {
            if (node.leaf.title) |title| self.allocator.free(title);
        };
        tab.nodes.deinit(self.allocator);
        self.allocator.free(tab.title);
    }

    // ---- lookups -------------------------------------------------------

    pub fn findWorkspace(self: *Store, id: ID) ?*Workspace {
        for (self.workspaces.items) |*workspace| {
            if (std.mem.eql(u8, &workspace.workspace_id, &id)) return workspace;
        }
        return null;
    }

    pub const TabLocation = struct { workspace: *Workspace, tab: *Tab };
    pub fn findTab(self: *Store, id: ID) ?TabLocation {
        for (self.workspaces.items) |*workspace| {
            for (workspace.tabs.items) |*tab| {
                if (std.mem.eql(u8, &tab.tab_id, &id)) return .{ .workspace = workspace, .tab = tab };
            }
        }
        return null;
    }

    pub const PaneLocation = struct { workspace: *Workspace, tab: *Tab, node: usize };
    pub fn findPane(self: *Store, id: ID) ?PaneLocation {
        for (self.workspaces.items) |*workspace| {
            for (workspace.tabs.items) |*tab| {
                for (tab.nodes.items, 0..) |node, index| {
                    if (node == .leaf and std.mem.eql(u8, &node.leaf.pane_id, &id))
                        return .{ .workspace = workspace, .tab = tab, .node = index };
                }
            }
        }
        return null;
    }

    pub fn tabCount(self: *const Store) usize {
        var total: usize = 0;
        for (self.workspaces.items) |workspace| total += workspace.tabs.items.len;
        return total;
    }

    pub fn paneCount(self: *const Store) usize {
        var total: usize = 0;
        for (self.workspaces.items) |workspace| {
            for (workspace.tabs.items) |tab| {
                for (tab.nodes.items) |node| if (node == .leaf) {
                    total += 1;
                };
            }
        }
        return total;
    }

    // ---- mutations -----------------------------------------------------

    /// Creates a workspace holding one tab with a single leaf pane. Every
    /// allocation happens before the workspace list is touched, so a failure
    /// cannot leave a half-built workspace behind.
    pub fn createWorkspace(self: *Store, title: []const u8, cwd: []const u8, pane: Pane) !*Workspace {
        if (self.workspaces.items.len >= limits.workspaces) return error.ResourceLimit;
        if (self.tabCount() >= limits.tabs or self.paneCount() >= limits.panes) return error.ResourceLimit;
        try checkShort(title);
        try checkPath(cwd);
        var workspace = Workspace{
            .workspace_id = ids.uuidText(ids.newUUID()),
            .title = try self.allocator.dupe(u8, title),
            .cwd = undefined,
        };
        errdefer self.freeWorkspace(&workspace);
        workspace.cwd = try self.allocator.dupe(u8, cwd);
        _ = try self.createTab(&workspace, title, pane);
        try self.workspaces.append(self.allocator, workspace);
        return &self.workspaces.items[self.workspaces.items.len - 1];
    }

    pub fn createTab(self: *Store, workspace: *Workspace, title: []const u8, pane: Pane) !*Tab {
        if (workspace.tabs.items.len >= limits.tabs or self.tabCount() >= limits.tabs) return error.ResourceLimit;
        if (self.paneCount() >= limits.panes) return error.ResourceLimit;
        try checkShort(title);
        // Reserve the tab slot first: after the title/node allocations succeed
        // the append must not be able to fail and orphan them.
        try workspace.tabs.ensureUnusedCapacity(self.allocator, 1);
        var tab = Tab{ .tab_id = ids.uuidText(ids.newUUID()), .title = try self.allocator.dupe(u8, title) };
        errdefer self.freeTab(&tab);
        try tab.nodes.append(self.allocator, .{ .leaf = pane });
        tab.root = 0;
        workspace.tabs.appendAssumeCapacity(tab);
        return &workspace.tabs.items[workspace.tabs.items.len - 1];
    }

    /// Replaces the target leaf with a split holding the old leaf and the new
    /// pane. The direction decides both the axis and which side is `first`.
    pub fn splitPane(self: *Store, location: PaneLocation, direction: Direction, pane: Pane) !*Pane {
        if (self.paneCount() >= limits.panes) return error.ResourceLimit;
        const tab = location.tab;
        const depth = (try self.nodeDepth(tab, tab.root, location.node, 0)) orelse return error.PaneNotFound;
        if (depth + 1 > limits.depth) return error.ResourceLimit;
        // Reserve BOTH slots in one pass before mutating anything. Reserving
        // them one at a time would hand out the same tombstone twice, because a
        // reserved-but-still-empty slot is indistinguishable from a free one.
        var slots: [2]usize = undefined;
        try self.reserveNodes(tab, &slots);
        const existing = slots[0];
        const added = slots[1];
        tab.nodes.items[existing] = tab.nodes.items[location.node];
        tab.nodes.items[added] = .{ .leaf = pane };
        const axis: Axis = switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
        const inserted_first = direction == .left or direction == .up;
        tab.nodes.items[location.node] = .{ .split = .{
            .axis = axis,
            .ratio = 0.5,
            .first = if (inserted_first) added else existing,
            .second = if (inserted_first) existing else added,
        } };
        return &tab.nodes.items[added].leaf;
    }

    fn reserveNodes(self: *Store, tab: *Tab, out: *[2]usize) !void {
        var found: usize = 0;
        for (tab.nodes.items, 0..) |node, index| {
            if (node != .free) continue;
            out[found] = index;
            found += 1;
            if (found == out.len) return;
        }
        while (found < out.len) {
            if (tab.nodes.items.len >= 2 * limits.panes) return error.ResourceLimit;
            try tab.nodes.append(self.allocator, .free);
            out[found] = tab.nodes.items.len - 1;
            found += 1;
        }
    }

    /// Depth of `wanted` below `current`; null when it is not in that subtree.
    /// Only a genuinely malformed tree can exceed the schema depth here, so the
    /// guard reports corruption instead of silently truncating the walk.
    fn nodeDepth(self: *Store, tab: *Tab, current: usize, wanted: usize, depth: usize) anyerror!?usize {
        if (depth > limits.depth) return error.CorruptLayout;
        if (current == wanted) return depth;
        return switch (tab.nodes.items[current]) {
            .split => |split| (try self.nodeDepth(tab, split.first, wanted, depth + 1)) orelse
                try self.nodeDepth(tab, split.second, wanted, depth + 1),
            else => null,
        };
    }

    pub fn updateWorkspaceTitle(self: *Store, workspace: *Workspace, title: []const u8) !void {
        try checkShort(title);
        const owned = try self.allocator.dupe(u8, title);
        self.allocator.free(workspace.title);
        workspace.title = owned;
    }

    pub fn updateTabTitle(self: *Store, tab: *Tab, title: []const u8) !void {
        try checkShort(title);
        const owned = try self.allocator.dupe(u8, title);
        self.allocator.free(tab.title);
        tab.title = owned;
    }

    pub fn updatePaneTitle(self: *Store, location: PaneLocation, title: []const u8) !void {
        if (title.len > limits.long_text or hasControl(title)) return error.InvalidRequest;
        const owned = try self.allocator.dupe(u8, title);
        const pane = &location.tab.nodes.items[location.node].leaf;
        if (pane.title) |old| self.allocator.free(old);
        pane.title = owned;
    }

    /// Collects the terminal IDs a close would orphan without mutating; the
    /// caller persists first and only then ends the processes.
    pub fn collectWorkspaceTerminals(self: *Store, workspace: *const Workspace, out: *std.ArrayList(ID)) !void {
        for (workspace.tabs.items) |tab| try self.collectTabTerminals(&tab, out);
    }

    pub fn collectTabTerminals(self: *Store, tab: *const Tab, out: *std.ArrayList(ID)) !void {
        for (tab.nodes.items) |node| if (node == .leaf) {
            try out.append(self.allocator, node.leaf.terminal_id);
        };
    }

    pub fn closeWorkspace(self: *Store, workspace: *Workspace) void {
        const index = (@intFromPtr(workspace) - @intFromPtr(self.workspaces.items.ptr)) / @sizeOf(Workspace);
        var removed = self.workspaces.orderedRemove(index);
        self.freeWorkspace(&removed);
    }

    pub fn closeTab(self: *Store, workspace: *Workspace, tab: *Tab) void {
        const index = (@intFromPtr(tab) - @intFromPtr(workspace.tabs.items.ptr)) / @sizeOf(Tab);
        var removed = workspace.tabs.orderedRemove(index);
        self.freeTab(&removed);
    }

    pub const PaneRemoval = enum { pane_only, tab_closed, workspace_closed };

    /// Removes one leaf; its sibling takes the parent split's slot. Removing the
    /// last pane of a tab closes the tab, and the last tab closes the workspace,
    /// so the tree never keeps an empty container the schema cannot express.
    pub fn closePane(self: *Store, location: PaneLocation) PaneRemoval {
        const tab = location.tab;
        if (tab.root == location.node) {
            self.releaseNode(tab, location.node);
            if (location.workspace.tabs.items.len == 1) {
                self.closeWorkspace(location.workspace);
                return .workspace_closed;
            }
            self.closeTab(location.workspace, tab);
            return .tab_closed;
        }
        const parent = self.findParent(tab, tab.root, location.node).?;
        const split = tab.nodes.items[parent].split;
        const sibling = if (split.first == location.node) split.second else split.first;
        self.releaseNode(tab, location.node);
        tab.nodes.items[parent] = tab.nodes.items[sibling];
        tab.nodes.items[sibling] = .free;
        return .pane_only;
    }

    fn releaseNode(self: *Store, tab: *Tab, index: usize) void {
        if (tab.nodes.items[index] == .leaf) {
            if (tab.nodes.items[index].leaf.title) |title| self.allocator.free(title);
        }
        tab.nodes.items[index] = .free;
    }

    fn findParent(self: *Store, tab: *Tab, current: usize, wanted: usize) ?usize {
        return switch (tab.nodes.items[current]) {
            .split => |split| {
                if (split.first == wanted or split.second == wanted) return current;
                return self.findParent(tab, split.first, wanted) orelse self.findParent(tab, split.second, wanted);
            },
            else => null,
        };
    }

    /// Applies a client-supplied `layout16` tree to an existing tab. Only the
    /// arrangement and ratios may change: the new tree must contain exactly the
    /// tab's current panes, once each, with their existing terminal binding.
    /// This keeps layout editing from smuggling in resource creation or theft.
    pub fn replaceLayout(self: *Store, tab: *Tab, value: std.json.Value) !void {
        var replacement = Tab{ .tab_id = tab.tab_id, .title = tab.title };
        errdefer replacement.nodes.deinit(self.allocator);
        replacement.root = try self.buildLayout(&replacement, value, 0);
        // Ownership check: same pane set, same terminals, no duplicates.
        var seen: usize = 0;
        for (replacement.nodes.items) |node| if (node == .leaf) {
            seen += 1;
            var matched = false;
            for (tab.nodes.items) |existing| {
                if (existing != .leaf) continue;
                if (!std.mem.eql(u8, &existing.leaf.pane_id, &node.leaf.pane_id)) continue;
                if (!std.mem.eql(u8, &existing.leaf.terminal_id, &node.leaf.terminal_id)) return error.InvalidRequest;
                matched = true;
                break;
            }
            if (!matched) return error.PaneNotFound;
        };
        var duplicates: usize = 0;
        for (replacement.nodes.items, 0..) |node, index| {
            if (node != .leaf) continue;
            for (replacement.nodes.items[0..index]) |earlier| {
                if (earlier == .leaf and std.mem.eql(u8, &earlier.leaf.pane_id, &node.leaf.pane_id)) duplicates += 1;
            }
        }
        var current: usize = 0;
        for (tab.nodes.items) |node| if (node == .leaf) {
            current += 1;
        };
        if (duplicates != 0 or seen != current) return error.InvalidRequest;
        // Carry the server-owned pane titles across; the layout wire form may
        // omit them and must never be able to clear them implicitly.
        for (replacement.nodes.items) |*node| {
            if (node.* != .leaf) continue;
            for (tab.nodes.items) |existing| {
                if (existing != .leaf or !std.mem.eql(u8, &existing.leaf.pane_id, &node.leaf.pane_id)) continue;
                node.leaf.title = existing.leaf.title;
            }
        }
        tab.nodes.deinit(self.allocator);
        tab.nodes = replacement.nodes;
        tab.root = replacement.root;
    }

    fn buildLayout(self: *Store, tab: *Tab, value: std.json.Value, depth: usize) anyerror!usize {
        if (depth >= limits.depth) return error.ResourceLimit;
        if (value != .object) return error.InvalidRequest;
        const kind = value.object.get("kind") orelse return error.InvalidRequest;
        if (kind != .string) return error.InvalidRequest;
        if (std.mem.eql(u8, kind.string, "leaf")) {
            const pane = value.object.get("pane") orelse return error.InvalidRequest;
            if (pane != .object) return error.InvalidRequest;
            const index = tab.nodes.items.len;
            if (index >= 2 * limits.panes) return error.ResourceLimit;
            try tab.nodes.append(self.allocator, .{ .leaf = .{
                .pane_id = try readID(pane, "paneID"),
                .terminal_id = try readID(pane, "terminalID"),
            } });
            return index;
        }
        if (!std.mem.eql(u8, kind.string, "split")) return error.InvalidRequest;
        const axis_value = value.object.get("axis") orelse return error.InvalidRequest;
        if (axis_value != .string) return error.InvalidRequest;
        const axis = std.meta.stringToEnum(Axis, axis_value.string) orelse return error.InvalidRequest;
        const ratio = switch (value.object.get("ratio") orelse return error.InvalidRequest) {
            .float => |number| number,
            .integer => |number| @as(f64, @floatFromInt(number)),
            else => return error.InvalidRequest,
        };
        if (!(ratio > 0 and ratio < 1)) return error.InvalidRequest;
        const index = tab.nodes.items.len;
        if (index >= 2 * limits.panes) return error.ResourceLimit;
        try tab.nodes.append(self.allocator, .free);
        const first = try self.buildLayout(tab, value.object.get("first") orelse return error.InvalidRequest, depth + 1);
        const second = try self.buildLayout(tab, value.object.get("second") orelse return error.InvalidRequest, depth + 1);
        tab.nodes.items[index] = .{ .split = .{ .axis = axis, .ratio = ratio, .first = first, .second = second } };
        return index;
    }

    // ---- wire encoding -------------------------------------------------

    /// Produces the exact `#/$defs/workspace` shape. The same encoding is used
    /// for RPC results, events and `layout.json`, so a persisted layout is
    /// always something the protocol schema already accepts.
    pub fn workspaceValue(self: *Store, arena: std.mem.Allocator, workspace: *const Workspace) !std.json.Value {
        var object = std.json.ObjectMap.init(arena);
        try object.put("workspaceID", .{ .string = try arena.dupe(u8, &workspace.workspace_id) });
        try object.put("title", .{ .string = try arena.dupe(u8, workspace.title) });
        try object.put("cwd", .{ .string = try arena.dupe(u8, workspace.cwd) });
        var tabs = std.json.Array.init(arena);
        for (workspace.tabs.items) |*tab| try tabs.append(try self.tabValue(arena, tab));
        try object.put("tabs", .{ .array = tabs });
        return .{ .object = object };
    }

    pub fn tabValue(self: *Store, arena: std.mem.Allocator, tab: *const Tab) !std.json.Value {
        var object = std.json.ObjectMap.init(arena);
        try object.put("tabID", .{ .string = try arena.dupe(u8, &tab.tab_id) });
        try object.put("title", .{ .string = try arena.dupe(u8, tab.title) });
        try object.put("layout", try self.layoutValue(arena, tab, tab.root, 0));
        return .{ .object = object };
    }

    pub fn paneValue(_: *Store, arena: std.mem.Allocator, pane: Pane) !std.json.Value {
        var object = std.json.ObjectMap.init(arena);
        try object.put("paneID", .{ .string = try arena.dupe(u8, &pane.pane_id) });
        try object.put("terminalID", .{ .string = try arena.dupe(u8, &pane.terminal_id) });
        if (pane.title) |title| try object.put("title", .{ .string = try arena.dupe(u8, title) });
        return .{ .object = object };
    }

    fn layoutValue(self: *Store, arena: std.mem.Allocator, tab: *const Tab, index: usize, depth: usize) anyerror!std.json.Value {
        if (depth > limits.depth) return error.CorruptLayout;
        var object = std.json.ObjectMap.init(arena);
        switch (tab.nodes.items[index]) {
            .leaf => |pane| {
                try object.put("kind", .{ .string = "leaf" });
                try object.put("pane", try self.paneValue(arena, pane));
            },
            .split => |split| {
                try object.put("kind", .{ .string = "split" });
                try object.put("axis", .{ .string = @tagName(split.axis) });
                try object.put("ratio", .{ .float = split.ratio });
                try object.put("first", try self.layoutValue(arena, tab, split.first, depth + 1));
                try object.put("second", try self.layoutValue(arena, tab, split.second, depth + 1));
            },
            .free => return error.CorruptLayout,
        }
        return .{ .object = object };
    }

    pub fn workspacesValue(self: *Store, arena: std.mem.Allocator) !std.json.Value {
        var array = std.json.Array.init(arena);
        for (self.workspaces.items) |*workspace| try array.append(try self.workspaceValue(arena, workspace));
        return .{ .array = array };
    }

    // ---- persistence ---------------------------------------------------

    const file_name = "layout.json";
    const staging_name = "layout.pending";

    /// Reads the committed layout. A missing file is an empty session; a damaged
    /// one is an explicit error with the original file left untouched, because
    /// silently starting empty would look like the user's work simply vanished.
    pub fn load(self: *Store, dir: std.fs.Dir) !void {
        const fd = std.posix.openat(dir.fd, file_name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        var file = std.fs.File{ .handle = fd };
        defer file.close();
        const info = try std.posix.fstat(fd);
        if (!std.posix.S.ISREG(info.mode) or info.uid != std.posix.geteuid() or info.mode & 0o777 != 0o600 or info.nlink != 1)
            return error.UnsafeLayoutFile;
        const bytes = file.readToEndAlloc(self.allocator, 8 * 1024 * 1024) catch return error.CorruptLayout;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.CorruptLayout;
        defer parsed.deinit();
        self.decode(parsed.value) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.CorruptLayout,
        };
    }

    fn decode(self: *Store, value: std.json.Value) !void {
        if (value != .object) return error.CorruptLayout;
        const version = value.object.get("version") orelse return error.CorruptLayout;
        if (version != .integer or version.integer != 1) return error.CorruptLayout;
        const revision = value.object.get("revision") orelse return error.CorruptLayout;
        if (revision != .integer or revision.integer < 0) return error.CorruptLayout;
        const list = value.object.get("workspaces") orelse return error.CorruptLayout;
        if (list != .array or list.array.items.len > limits.workspaces) return error.CorruptLayout;
        errdefer {
            for (self.workspaces.items) |*workspace| self.freeWorkspace(workspace);
            self.workspaces.clearRetainingCapacity();
        }
        for (list.array.items) |item| {
            if (item != .object) return error.CorruptLayout;
            const title = try readString(item, "title", limits.short_text);
            const cwd = try readString(item, "cwd", limits.long_text);
            var workspace = Workspace{
                .workspace_id = try readID(item, "workspaceID"),
                .title = try self.allocator.dupe(u8, title),
                .cwd = try self.allocator.dupe(u8, cwd),
            };
            errdefer self.freeWorkspace(&workspace);
            const tabs = item.object.get("tabs") orelse return error.CorruptLayout;
            if (tabs != .array or tabs.array.items.len > limits.tabs) return error.CorruptLayout;
            for (tabs.array.items) |tab_value| {
                if (tab_value != .object) return error.CorruptLayout;
                var tab = Tab{
                    .tab_id = try readID(tab_value, "tabID"),
                    .title = try self.allocator.dupe(u8, try readString(tab_value, "title", limits.long_text)),
                };
                errdefer self.freeTab(&tab);
                tab.root = try self.buildLayout(&tab, tab_value.object.get("layout") orelse return error.CorruptLayout, 0);
                try workspace.tabs.append(self.allocator, tab);
            }
            try self.workspaces.append(self.allocator, workspace);
        }
        if (self.paneCount() > limits.panes or self.tabCount() > limits.tabs) return error.CorruptLayout;
        self.revision = @intCast(revision.integer);
    }

    /// Atomic commit: private staging file, fsync, rename, directory fsync. A
    /// failure leaves the previously committed layout readable.
    pub fn persist(self: *Store, dir: std.fs.Dir) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        var object = std.json.ObjectMap.init(temporary);
        try object.put("version", .{ .integer = 1 });
        try object.put("revision", .{ .integer = @intCast(self.revision) });
        try object.put("workspaces", try self.workspacesValue(temporary));
        const bytes = try std.json.Stringify.valueAlloc(temporary, std.json.Value{ .object = object }, .{});
        dir.deleteFile(staging_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const fd = try std.posix.openat(dir.fd, staging_name, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0o600);
        var file = std.fs.File{ .handle = fd };
        {
            defer file.close();
            try file.writeAll(bytes);
            try file.sync();
        }
        try dir.rename(staging_name, file_name);
        try std.posix.fsync(dir.fd);
    }
};

fn checkShort(text: []const u8) !void {
    if (text.len == 0 or text.len > limits.short_text or hasControl(text)) return error.InvalidRequest;
}

fn checkPath(text: []const u8) !void {
    if (text.len == 0 or text.len > limits.long_text or !std.fs.path.isAbsolute(text) or hasControl(text)) return error.InvalidRequest;
}

fn hasControl(text: []const u8) bool {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

fn readString(value: std.json.Value, key: []const u8, maximum: usize) ![]const u8 {
    const item = value.object.get(key) orelse return error.CorruptLayout;
    if (item != .string or item.string.len == 0 or item.string.len > maximum) return error.CorruptLayout;
    return item.string;
}

fn readID(value: std.json.Value, key: []const u8) !ID {
    const item = value.object.get(key) orelse return error.InvalidRequest;
    if (item != .string or !validID(item.string)) return error.InvalidRequest;
    return item.string[0..36].*;
}

fn testPane() Pane {
    return .{ .pane_id = ids.uuidText(ids.newUUID()), .terminal_id = ids.uuidText(ids.newUUID()) };
}

test "workspace store splits close and collapse empty containers" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const workspace = try store.createWorkspace("first", "/tmp", testPane());
    const tab = &workspace.tabs.items[0];
    const root_pane = tab.nodes.items[tab.root].leaf.pane_id;
    const added = try store.splitPane(store.findPane(root_pane).?, .right, testPane());
    const added_id = added.pane_id;
    try std.testing.expectEqual(@as(usize, 2), store.paneCount());
    try std.testing.expect(!std.mem.eql(u8, &added_id, &root_pane));
    try std.testing.expect(store.findPane(added_id) != null and store.findPane(root_pane) != null);
    try std.testing.expectEqual(Store.PaneRemoval.pane_only, store.closePane(store.findPane(added_id).?));
    try std.testing.expectEqual(@as(usize, 1), store.paneCount());
    try std.testing.expect(store.findPane(root_pane) != null);
    try std.testing.expectEqual(Store.PaneRemoval.workspace_closed, store.closePane(store.findPane(root_pane).?));
    try std.testing.expectEqual(@as(usize, 0), store.workspaces.items.len);
}

// Pins the ownership rule for the layout revision: the store holds the
// counter, but only the transaction layer advances it. Tree edits and terminal
// bookkeeping (collecting doomed terminal IDs for the pool to reap) leave it
// untouched, which is what keeps a terminal exit from producing a false
// `revision_conflict` for an unrelated layout transaction.
test "workspace store revision advances only when a caller commits a transaction" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const workspace = try store.createWorkspace("first", "/tmp", testPane());
    // Structural creates and edits are inert until the transaction bumps.
    try std.testing.expectEqual(@as(u64, 0), store.revision);
    const tab = &workspace.tabs.items[0];
    const root_pane = tab.nodes.items[tab.root].leaf.pane_id;
    _ = try store.splitPane(store.findPane(root_pane).?, .right, testPane());
    try store.updateWorkspaceTitle(workspace, "renamed");
    try std.testing.expectEqual(@as(u64, 0), store.revision);

    // One transaction, one bump — even though it also created a terminal.
    store.revision +|= 1;
    try std.testing.expectEqual(@as(u64, 1), store.revision);

    // Terminal reaping never touches the counter: collecting the terminals a
    // close orphans is pure bookkeeping for the pool, not a layout revision.
    var doomed: std.ArrayList(ID) = .empty;
    defer doomed.deinit(std.testing.allocator);
    try store.collectWorkspaceTerminals(workspace, &doomed);
    try std.testing.expectEqual(@as(usize, 2), doomed.items.len);
    try std.testing.expectEqual(@as(u64, 1), store.revision);
    store.closeWorkspace(workspace);
    try std.testing.expectEqual(@as(u64, 1), store.revision);
}

test "workspace store rejects layout replacement that invents or drops panes" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const workspace = try store.createWorkspace("first", "/tmp", testPane());
    const tab = &workspace.tabs.items[0];
    const pane = tab.nodes.items[tab.root].leaf;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const foreign = try std.fmt.allocPrint(arena.allocator(),
        "{{\"kind\":\"leaf\",\"pane\":{{\"paneID\":\"{s}\",\"terminalID\":\"{s}\"}}}}",
        .{ ids.uuidText(ids.newUUID()), pane.terminal_id });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, foreign, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.PaneNotFound, store.replaceLayout(tab, parsed.value));
    try std.testing.expectEqual(@as(usize, 1), store.paneCount());
}

test "workspace store persists atomically and refuses corrupt layout files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = Store.init(std.testing.allocator);
        defer store.deinit();
        _ = try store.createWorkspace("first", "/tmp", testPane());
        store.revision = 5;
        try store.persist(tmp.dir);
    }
    {
        var store = Store.init(std.testing.allocator);
        defer store.deinit();
        try store.load(tmp.dir);
        try std.testing.expectEqual(@as(u64, 5), store.revision);
        try std.testing.expectEqual(@as(usize, 1), store.workspaces.items.len);
        try std.testing.expectEqualStrings("first", store.workspaces.items[0].title);
    }
    const original = try tmp.dir.readFileAlloc(std.testing.allocator, "layout.json", 65536);
    defer std.testing.allocator.free(original);
    var damaged = try tmp.dir.createFile("layout.json", .{ .truncate = true, .mode = 0o600 });
    try damaged.writeAll(original[0 .. original.len / 2]);
    damaged.close();
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.CorruptLayout, store.load(tmp.dir));
    const preserved = try tmp.dir.readFileAlloc(std.testing.allocator, "layout.json", 65536);
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqual(original.len / 2, preserved.len);
}
