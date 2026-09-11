/// 会话级 Agent 状态内存存储。每个终端至多关联一条 Agent 记录，
/// 全局上限 1024 条（与协议 maxItems 一致）。
const std = @import("std");
const validID = @import("operation_request.zig").validID;

pub const ID = [36]u8;

/// 协议定义的 Agent 运行状态
pub const State = enum {
    idle,
    working,
    blocked,
    done,
    unknown,

    /// 从字符串解析状态枚举
    pub fn fromString(text: []const u8) ?State {
        return std.meta.stringToEnum(State, text);
    }
};

/// 单条 Agent 状态记录
pub const Agent = struct {
    terminal_id: ID,
    provider: []u8,
    state: State,
    name: ?[]u8 = null,
    native_session: ?[]u8 = null,
    source: ?[]u8 = null,
    unread: bool = false,
    /// 单调递增序号，用于列表排序
    sequence: u64 = 0,
};

/// 协议上限
const max_entries: usize = 1024;
const max_short: usize = 128;
const max_long: usize = 4096;

/// 有界内存 Agent 状态存储。所有变更返回一个标志位，调用方据此决定是否
/// 广播 agent.changed 事件。
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Agent) = .empty,
    next_sequence: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*entry| self.freeAgent(entry);
        self.entries.deinit(self.allocator);
    }

    fn freeAgent(self: *Store, agent: *Agent) void {
        self.allocator.free(agent.provider);
        if (agent.name) |n| self.allocator.free(n);
        if (agent.native_session) |ns| self.allocator.free(ns);
        if (agent.source) |s| self.allocator.free(s);
    }

    /// 客户端上报 Agent 状态。返回 true 表示已接受，false 表示拒绝。
    /// 拒绝原因：terminalID 无效、provider 不匹配已有记录、字段超长、容量满。
    pub fn report(self: *Store, terminal_id: ID, provider: []const u8, state: State, name_opt: ?[]const u8, native_session_opt: ?[]const u8, source_opt: ?[]const u8) !bool {
        // 字段长度校验
        if (provider.len == 0 or provider.len > max_short) return false;
        if (name_opt) |n| if (n.len > max_short or hasControl(n)) return false;
        if (native_session_opt) |ns| if (ns.len > max_long) return false;
        if (source_opt) |s| if (s.len > max_short or hasControl(s)) return false;
        if (hasControl(provider)) return false;

        // 查找已有记录
        for (self.entries.items) |*existing| {
            if (!std.mem.eql(u8, &existing.terminal_id, &terminal_id)) continue;
            // provider 不匹配则视为过期上报，拒绝
            if (!std.mem.eql(u8, existing.provider, provider)) return false;
            // working -> idle/done 的转换表示完成，标记 unread
            const was_working = existing.state == .working;
            const now_settled = state == .idle or state == .done;
            // 更新可变字段
            existing.state = state;
            if (was_working and now_settled) existing.unread = true;
            try self.updateOptional(&existing.name, name_opt);
            try self.updateOptional(&existing.native_session, native_session_opt);
            try self.updateOptional(&existing.source, source_opt);
            existing.sequence = self.next_sequence;
            self.next_sequence +|= 1;
            return true;
        }

        // 新记录
        if (self.entries.items.len >= max_entries) return false;
        var agent = Agent{
            .terminal_id = terminal_id,
            .provider = try self.allocator.dupe(u8, provider),
            .state = state,
            .sequence = self.next_sequence,
        };
        errdefer self.freeAgent(&agent);
        if (name_opt) |n| agent.name = try self.allocator.dupe(u8, n);
        if (native_session_opt) |ns| agent.native_session = try self.allocator.dupe(u8, ns);
        if (source_opt) |s| agent.source = try self.allocator.dupe(u8, s);
        try self.entries.append(self.allocator, agent);
        self.next_sequence +|= 1;
        return true;
    }

    /// 按 sequence 排序返回所有 Agent 记录
    pub fn list(self: *const Store) []const Agent {
        return self.entries.items;
    }

    /// 按 terminalID 查找单条记录
    pub fn get(self: *const Store, terminal_id: ID) ?*const Agent {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.terminal_id, &terminal_id)) return entry;
        }
        return null;
    }

    /// explain 等价于 get，协议语义一致
    pub fn explain(self: *const Store, terminal_id: ID) ?*const Agent {
        return self.get(terminal_id);
    }

    /// 重命名 Agent。返回 true 表示成功。
    pub fn rename(self: *Store, terminal_id: ID, new_name: []const u8) !bool {
        if (new_name.len == 0 or new_name.len > max_short or hasControl(new_name)) return false;
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, &entry.terminal_id, &terminal_id)) continue;
            const owned = try self.allocator.dupe(u8, new_name);
            if (entry.name) |old| self.allocator.free(old);
            entry.name = owned;
            entry.sequence = self.next_sequence;
            self.next_sequence +|= 1;
            return true;
        }
        return false;
    }

    /// 标记完成已读。返回 true 表示成功。
    pub fn acknowledge(self: *Store, terminal_id: ID) bool {
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, &entry.terminal_id, &terminal_id)) continue;
            entry.unread = false;
            return true;
        }
        return false;
    }

    /// 终端退出时清理其 Agent 记录
    pub fn removeTerminal(self: *Store, terminal_id: ID) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (std.mem.eql(u8, &self.entries.items[index].terminal_id, &terminal_id)) {
                var removed = self.entries.orderedRemove(index);
                self.freeAgent(&removed);
            } else {
                index += 1;
            }
        }
    }

    fn updateOptional(self: *Store, field: *?[]u8, value: ?[]const u8) !void {
        if (value) |v| {
            const owned = try self.allocator.dupe(u8, v);
            if (field.*) |old| self.allocator.free(old);
            field.* = owned;
        }
    }
};

fn hasControl(text: []const u8) bool {
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

// ---- tests ----

test "agent store report, list, rename, acknowledge and cleanup" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();

    const tid = "00000000-0000-4000-8000-000000000001".*;
    // 首次上报
    try std.testing.expect(try store.report(tid, "claude", .working, "my-agent", null, "hook"));
    try std.testing.expectEqual(@as(usize, 1), store.list().len);
    const agent = store.get(tid).?;
    try std.testing.expectEqualStrings("claude", agent.provider);
    try std.testing.expect(agent.state == .working);
    try std.testing.expect(!agent.unread);

    // working -> idle 触发 unread
    try std.testing.expect(try store.report(tid, "claude", .idle, null, null, null));
    try std.testing.expect(store.get(tid).?.unread);
    try std.testing.expect(store.get(tid).?.state == .idle);

    // acknowledge 清除 unread
    try std.testing.expect(store.acknowledge(tid));
    try std.testing.expect(!store.get(tid).?.unread);

    // provider 不匹配被拒绝
    try std.testing.expect(!try store.report(tid, "codex", .working, null, null, null));

    // rename
    try std.testing.expect(try store.rename(tid, "new-name"));
    try std.testing.expectEqualStrings("new-name", store.get(tid).?.name.?);

    // explain 等价于 get
    try std.testing.expect(store.explain(tid) != null);

    // removeTerminal 清理
    store.removeTerminal(tid);
    try std.testing.expectEqual(@as(usize, 0), store.list().len);
    try std.testing.expect(!store.acknowledge(tid));
}

test "agent store rejects oversized fields" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    const tid = "00000000-0000-4000-8000-000000000002".*;
    // 空 provider
    try std.testing.expect(!try store.report(tid, "", .idle, null, null, null));
    // provider 超长
    const long = "a" ** 129;
    try std.testing.expect(!try store.report(tid, long, .idle, null, null, null));
    // name 带控制字符
    try std.testing.expect(!try store.report(tid, "ok", .idle, "bad\x00name", null, null));
}
