// 完整 TUI 客户端：在 SSH shell 中运行，连接服务端会话，提供工作区/标签/窗格导航、
// 单终端交互、状态栏、Ctrl+B 前缀分离与字面发送、鼠标和窄屏布局。
const std = @import("std");
const transport = @import("service_client.zig");
const protocol = @import("protocol.zig");
const Request = @import("operation_request.zig").Request;
const replies = @import("operation_response.zig");
const ids = @import("service_identity.zig");
const Assembler = @import("snapshot.zig").Assembler;
const workspace_client = @import("workspace_client.zig");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
    @cInclude("bridge_signals.h");
});
const ID = [36]u8;
const Geometry = struct { rows: u16, columns: u16, pixelWidth: u16 = 0, pixelHeight: u16 = 0 };
const Lease = struct { leaseID: ID, leaseEpoch: u64 };
const Response = replies.Response(std.json.Value);

// ---- layout model ----------------------------------------------------------

/// 扁平化的窗格引用，从 session.snapshot 的工作区→标签→递归分屏树中提取。
const PaneRef = struct {
    pane_id: ID,
    terminal_id: ID,
    workspace_idx: u16,
    tab_idx: u16,
    pane_seq: u16,
};

/// 工作区快照的结构化索引，用于导航和状态栏渲染。
const LayoutIndex = struct {
    panes: std.ArrayList(PaneRef),
    workspace_titles: std.ArrayList([]u8),
    /// 每个工作区的 UUID（与 workspace_titles 同索引），用于 tab.create 等写操作。
    workspace_ids: std.ArrayList(ID),
    tab_titles: std.ArrayList([]u8),
    workspace_starts: std.ArrayList(u32),
    tab_starts: std.ArrayList(u32),
    revision: u64 = 0,

    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) LayoutIndex {
        return .{
            .allocator = a,
            .panes = .empty,
            .workspace_titles = .empty,
            .workspace_ids = .empty,
            .tab_titles = .empty,
            .workspace_starts = .empty,
            .tab_starts = .empty,
        };
    }
    fn deinit(self: *LayoutIndex) void {
        for (self.workspace_titles.items) |title| self.allocator.free(title);
        for (self.tab_titles.items) |title| self.allocator.free(title);
        self.panes.deinit(self.allocator);
        self.workspace_titles.deinit(self.allocator);
        self.workspace_ids.deinit(self.allocator);
        self.tab_titles.deinit(self.allocator);
        self.workspace_starts.deinit(self.allocator);
        self.tab_starts.deinit(self.allocator);
    }
    fn clear(self: *LayoutIndex) void {
        for (self.workspace_titles.items) |title| self.allocator.free(title);
        for (self.tab_titles.items) |title| self.allocator.free(title);
        self.panes.clearRetainingCapacity();
        self.workspace_titles.clearRetainingCapacity();
        self.workspace_ids.clearRetainingCapacity();
        self.tab_titles.clearRetainingCapacity();
        self.workspace_starts.clearRetainingCapacity();
        self.tab_starts.clearRetainingCapacity();
    }

    /// 从 session.snapshot 的 workspaces JSON 数组构建扁平化索引。
    fn build(self: *LayoutIndex, workspaces: std.json.Value, rev: u64) !void {
        self.clear();
        self.revision = rev;
        if (workspaces != .array) return error.InvalidSnapshot;
        var ws_idx: u16 = 0;
        for (workspaces.array.items) |ws| {
            if (ws != .object) return error.InvalidSnapshot;
            const ws_title = str(ws, "title") catch "workspace";
            try self.workspace_titles.append(self.allocator, try self.allocator.dupe(u8, ws_title));
            // 提取工作区 UUID，tab.create 需要它来定位父工作区
            const ws_id_str = str(ws, "workspaceID") catch return error.InvalidSnapshot;
            try self.workspace_ids.append(self.allocator, validID(ws_id_str) orelse return error.InvalidSnapshot);
            try self.workspace_starts.append(self.allocator, @intCast(self.panes.items.len));
            const tabs = ws.object.get("tabs") orelse return error.InvalidSnapshot;
            if (tabs != .array) return error.InvalidSnapshot;
            var tab_idx: u16 = 0;
            for (tabs.array.items) |tab| {
                if (tab != .object) return error.InvalidSnapshot;
                const tab_title = str(tab, "title") catch "tab";
                try self.tab_titles.append(self.allocator, try self.allocator.dupe(u8, tab_title));
                try self.tab_starts.append(self.allocator, @intCast(self.panes.items.len));
                const layout_node = tab.object.get("layout") orelse return error.InvalidSnapshot;
                var pane_seq: u16 = 0;
                try self.collectPanes(layout_node, ws_idx, tab_idx, &pane_seq);
                tab_idx += 1;
            }
            ws_idx += 1;
        }
    }

    fn collectPanes(self: *LayoutIndex, node: std.json.Value, ws_idx: u16, tab_idx: u16, seq: *u16) !void {
        if (node != .object) return error.InvalidSnapshot;
        const kind = str(node, "kind") catch return error.InvalidSnapshot;
        if (std.mem.eql(u8, kind, "leaf")) {
            const pane = node.object.get("pane") orelse return error.InvalidSnapshot;
            if (pane != .object) return error.InvalidSnapshot;
            const pane_id = str(pane, "paneID") catch return error.InvalidSnapshot;
            const terminal_id = str(pane, "terminalID") catch return error.InvalidSnapshot;
            try self.panes.append(self.allocator, .{
                .pane_id = validID(pane_id) orelse return error.InvalidSnapshot,
                .terminal_id = validID(terminal_id) orelse return error.InvalidSnapshot,
                .workspace_idx = ws_idx,
                .tab_idx = tab_idx,
                .pane_seq = seq.*,
            });
            seq.* += 1;
        } else if (std.mem.eql(u8, kind, "split")) {
            const first = node.object.get("first") orelse return error.InvalidSnapshot;
            const second = node.object.get("second") orelse return error.InvalidSnapshot;
            try self.collectPanes(first, ws_idx, tab_idx, seq);
            try self.collectPanes(second, ws_idx, tab_idx, seq);
        }
    }

    fn currentWorkspaceTitle(self: *const LayoutIndex, idx: usize) []const u8 {
        if (idx >= self.panes.items.len) return "?";
        const ws = self.panes.items[idx].workspace_idx;
        return if (ws < self.workspace_titles.items.len) self.workspace_titles.items[ws] else "?";
    }
    fn currentTabTitle(self: *const LayoutIndex, idx: usize) []const u8 {
        if (idx >= self.panes.items.len) return "?";
        const tab = self.panes.items[idx].tab_idx;
        return if (tab < self.tab_titles.items.len) self.tab_titles.items[tab] else "?";
    }
    fn currentPaneLabel(self: *const LayoutIndex, idx: usize) u16 {
        if (idx >= self.panes.items.len) return 0;
        return self.panes.items[idx].pane_seq + 1;
    }
    fn panesInTab(self: *const LayoutIndex, idx: usize) u16 {
        if (idx >= self.panes.items.len) return 0;
        const current = self.panes.items[idx];
        var count: u16 = 0;
        for (self.panes.items) |pane| {
            if (pane.workspace_idx == current.workspace_idx and pane.tab_idx == current.tab_idx)
                count += 1;
        }
        return count;
    }

    /// 返回指定窗格所属工作区的 UUID 文本。
    fn workspaceIDForPane(self: *const LayoutIndex, idx: usize) ?*const ID {
        if (idx >= self.panes.items.len) return null;
        const ws = self.panes.items[idx].workspace_idx;
        return if (ws < self.workspace_ids.items.len) &self.workspace_ids.items[ws] else null;
    }

    /// 切到同工作区下一个标签的第一个窗格。
    fn nextTab(self: *const LayoutIndex, idx: usize) usize {
        if (self.panes.items.len == 0) return 0;
        const current = self.panes.items[idx];
        const next_t = current.tab_idx + 1;
        for (self.panes.items, 0..) |pane, i| {
            if (pane.workspace_idx == current.workspace_idx and pane.tab_idx == next_t) return i;
        }
        for (self.panes.items, 0..) |pane, i| {
            if (pane.workspace_idx == current.workspace_idx and pane.tab_idx == 0) return i;
        }
        return idx;
    }
    /// 切到同工作区上一个标签。
    fn prevTab(self: *const LayoutIndex, idx: usize) usize {
        if (self.panes.items.len == 0) return 0;
        const current = self.panes.items[idx];
        if (current.tab_idx == 0) {
            var max_tab: u16 = 0;
            for (self.panes.items) |pane| {
                if (pane.workspace_idx == current.workspace_idx and pane.tab_idx > max_tab)
                    max_tab = pane.tab_idx;
            }
            for (self.panes.items, 0..) |pane, i| {
                if (pane.workspace_idx == current.workspace_idx and pane.tab_idx == max_tab) return i;
            }
            return idx;
        }
        const prev = current.tab_idx - 1;
        for (self.panes.items, 0..) |pane, i| {
            if (pane.workspace_idx == current.workspace_idx and pane.tab_idx == prev) return i;
        }
        return idx;
    }
    /// 切到下一个窗格（全局循环）。
    fn nextPane(self: *const LayoutIndex, idx: usize) usize {
        if (self.panes.items.len == 0) return 0;
        return if (idx + 1 < self.panes.items.len) idx + 1 else 0;
    }
    /// 切到下一个工作区的第一个窗格。
    fn nextWorkspace(self: *const LayoutIndex, idx: usize) usize {
        if (self.panes.items.len == 0) return 0;
        const current = self.panes.items[idx];
        const next_ws = current.workspace_idx + 1;
        for (self.panes.items, 0..) |pane, i| {
            if (pane.workspace_idx == next_ws) return i;
        }
        for (self.panes.items, 0..) |pane, i| {
            if (pane.workspace_idx == 0) return i;
        }
        return idx;
    }
};

// ---- control connection ----------------------------------------------------

/// 控制连接：RPC + 事件处理。与 terminal_attach.zig 的 Client 结构对齐。
const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    client_id: ID,
    server: ID,
    epoch: ID,
    session: ID,
    lease: ?Lease = null,
    sequence: u64 = 0,
    terminal_id: ?ID = null,
    exited: bool = false,
    input_closed: bool = false,
    event_sequence: u64 = 0,
    event_revision: ?u64 = null,

    fn connect(a: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, client_id: ID) !Client {
        var deadline = try transport.Deadline.init(5000);
        const stream = try transport.connect(parent, name, &deadline);
        errdefer stream.close();
        const bytes = try transport.readFrame(a, stream, &deadline);
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(@import("handshake.zig").Hello, a, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try parsed.value.negotiateRequired(&.{ "terminal_control", "surface_interest", "health_check", "session_snapshot" });
        return .{ .allocator = a, .stream = stream, .client_id = client_id, .server = validID(parsed.value.serverID) orelse return error.InvalidHandshake, .epoch = validID(parsed.value.serverEpoch) orelse return error.InvalidHandshake, .session = validID(parsed.value.sessionID) orelse return error.InvalidHandshake };
    }

    fn rpc(self: *Client, operation: @import("operation_kind.zig").Operation, params: anytype) !std.json.Parsed(Response) {
        const a = self.allocator;
        const encoded_params = if (@typeInfo(@TypeOf(params)) == .@"struct" and @typeInfo(@TypeOf(params)).@"struct".fields.len == 0) try a.dupe(u8, "{}") else try std.json.Stringify.valueAlloc(a, params, .{});
        defer a.free(encoded_params);
        const parsed_params = try std.json.parseFromSlice(std.json.Value, a, encoded_params, .{});
        defer parsed_params.deinit();
        const request_id = ids.uuidText(ids.newUUID());
        var request = Request{ .type = "request", .requestID = &request_id, .clientID = &self.client_id, .scope = .session, .operation = operation, .target = .{ .serverID = &self.server, .serverEpoch = &self.epoch, .sessionID = &self.session }, .params = parsed_params.value };
        if (operation == .@"terminal.control") {
            const lease = if (self.lease) |*value| value else return error.WriterLeaseRequired;
            if (self.sequence == std.math.maxInt(u64)) return error.ControlSequenceExhausted;
            self.sequence += 1;
            request.lease = .{ .leaseID = &lease.leaseID, .leaseEpoch = lease.leaseEpoch };
            request.controlSequence = self.sequence;
        }
        try request.validateEnvelope();
        const encoded = try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false });
        defer a.free(encoded);
        if (encoded.len > protocol.maximum_control_bytes) return error.RequestTooLarge;
        var deadline = try transport.Deadline.init(5000);
        var header: [5]u8 = undefined;
        header[0] = 1;
        std.mem.writeInt(u32, header[1..], @intCast(encoded.len), .big);
        try transport.writeAll(self.stream, &header, &deadline);
        try transport.writeAll(self.stream, encoded, &deadline);
        while (true) {
            const bytes = try transport.readFrame(a, self.stream, &deadline);
            defer a.free(bytes);
            const tag = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
            defer tag.deinit();
            const kind_str = str(tag.value, "type") catch return error.InvalidReply;
            if (std.mem.eql(u8, kind_str, "event")) {
                self.handleEvent(bytes) catch {};
                continue;
            }
            if (std.mem.eql(u8, kind_str, "error")) {
                const failure = try std.json.parseFromSlice(replies.Failure, a, bytes, .{});
                defer failure.deinit();
                try failure.value.validate(request);
                if (operation == .@"terminal.control") {
                    if (std.mem.eql(u8, failure.value.@"error".code, "terminal_exited")) {
                        const act = str(request.params, "action") catch "";
                        if (std.mem.eql(u8, act, "input")) {
                            if (self.terminal_id) |bound| {
                                const tid = str(request.params, "terminalID") catch "";
                                if (std.mem.eql(u8, tid, &bound))
                                    return error.TerminalInputClosed;
                            }
                        }
                    }
                }
                return error.TerminalRequestRejected;
            }
            const result = try std.json.parseFromSlice(Response, a, bytes, .{ .allocate = .alloc_always });
            errdefer result.deinit();
            try result.value.validate(request);
            return result;
        }
    }

    fn handleEvent(self: *Client, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(replies.Event(std.json.Value), self.allocator, bytes, .{});
        defer parsed.deinit();
        const value = parsed.value;
        try value.validate(value.event, .{ .serverID = &self.server, .serverEpoch = &self.epoch, .sessionID = &self.session }, self.event_sequence, self.event_revision);
        self.event_sequence = value.sequence;
        self.event_revision = value.revision;
        if (std.mem.eql(u8, value.event, "terminal.exited")) {
            const tid = str(value.body, "terminalID") catch return;
            if (self.terminal_id) |bound| {
                if (std.mem.eql(u8, tid, &bound)) self.exited = true;
            }
        } else if (std.mem.eql(u8, value.event, "lease.revoked")) {
            const lid = validID(str(value.body, "leaseID") catch return) orelse return;
            const ep = integer(fld(value.body, "leaseEpoch") catch return) catch return;
            if (self.lease) |lease| {
                if (self.terminal_id) |bound| {
                    const tid = str(value.body, "terminalID") catch return;
                    if (std.mem.eql(u8, tid, &bound) and std.mem.eql(u8, &lid, &lease.leaseID) and ep == lease.leaseEpoch)
                        self.lease = null;
                }
            }
        }
    }

    fn input(self: *Client, terminal_id: []const u8, data: []const u8) !void {
        const reply = try self.rpc(.@"terminal.control", .{ .terminalID = terminal_id, .action = "input", .data = data });
        reply.deinit();
    }
};

// ---- surface connection ----------------------------------------------------

const Receiver = struct {
    allocator: std.mem.Allocator,
    assembler: ?Assembler = null,
    last: ?u64 = null,
    sequence: u64 = 0,
    delta: bool = false,
    discard: bool = false,
    resync: bool = false,

    fn deinit(self: *Receiver) void {
        if (self.assembler) |*asm_| asm_.deinit();
    }
    fn frame(self: *Receiver, msg: protocol.Frame, now: u64) !?[]const u8 {
        _ = now;
        if (msg.kind == .surface) {
            if (self.assembler) |*asm_| { try asm_.append(asm_.next_index, msg.payload); } else return error.SnapshotRequired;
            return null;
        }
        const Event = struct {
            type: enum { snapshot_begin, snapshot_end, delta_begin, delta_end },
            length: ?usize = null,
            sha256: ?[]const u8 = null,
            sequence: ?u64 = null,
            baseSequence: ?u64 = null,
        };
        const parsed = try std.json.parseFromSlice(Event, self.allocator, msg.payload, .{});
        defer parsed.deinit();
        switch (parsed.value.type) {
            .snapshot_begin, .delta_begin => {
                if (self.assembler != null) return error.OverlappingSnapshot;
                self.sequence = parsed.value.sequence orelse return error.MissingSequence;
                self.delta = parsed.value.type == .delta_begin;
                self.discard = false;
                if (self.delta) {
                    const base = parsed.value.baseSequence orelse return error.MissingSequence;
                    if (self.sequence <= base) return error.InvalidSequence;
                    if (self.last == null or self.last.? != base or self.resync) {
                        self.discard = true;
                        self.resync = true;
                    }
                } else {
                    if (parsed.value.baseSequence != null or (self.last != null and self.sequence < self.last.?)) return error.StaleSnapshot;
                }
                const length = parsed.value.length orelse return error.MissingLength;
                if (self.delta and length > 65536) return error.DeltaTooLarge;
                const hex = parsed.value.sha256 orelse return error.MissingDigest;
                if (hex.len != 64) return error.InvalidDigest;
                var digest: [32]u8 = undefined;
                _ = try std.fmt.hexToBytes(&digest, hex);
                self.assembler = try Assembler.init(self.allocator, length, digest);
                return null;
            },
            .snapshot_end, .delta_end => {
                const current = if (self.assembler) |*asm_| asm_ else return error.UnexpectedTransactionEnd;
                if ((parsed.value.type == .delta_end) != self.delta) return error.UnexpectedTransactionEnd;
                const bytes = try current.finish();
                if (self.discard) {
                    self.release();
                    return null;
                }
                if (self.delta) {
                    var filter: @import("delta_filter.zig").Filter = .{};
                    if (!filter.consume(bytes)) return error.UnsafeDelta;
                }
                self.last = self.sequence;
                self.resync = false;
                return bytes;
            },
        }
    }
    fn release(self: *Receiver) void {
        self.assembler.?.deinit();
        self.assembler = null;
    }
};

const Surface = struct {
    client: Client,
    id: ID,
    decoder: protocol.Decoder,
    receiver: Receiver,
    fn init(a: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, owner: *Client, attachment: ID, terminal_id: []const u8, geometry: Geometry) !Surface {
        var sclient = try Client.connect(a, parent, name, owner.client_id);
        errdefer sclient.stream.close();
        if (!std.mem.eql(u8, &sclient.server, &owner.server) or !std.mem.eql(u8, &sclient.epoch, &owner.epoch) or !std.mem.eql(u8, &sclient.session, &owner.session)) return error.ServiceReplaced;
        const reply = try sclient.rpc(.@"surface.subscribe", .{ .attachmentID = &attachment, .geometry = geometry });
        defer reply.deinit();
        if (!std.mem.eql(u8, str(reply.value.result, "terminalID") catch return error.InvalidSurfaceReply, terminal_id)) return error.InvalidSurfaceReply;
        return .{ .client = sclient, .id = validID(str(reply.value.result, "streamID") catch return error.InvalidSurfaceReply) orelse return error.InvalidSurfaceReply, .decoder = protocol.Decoder.init(a), .receiver = .{ .allocator = a } };
    }
    fn deinit(self: *Surface) void {
        self.receiver.deinit();
        self.decoder.deinit();
        self.client.stream.close();
    }
};

// ---- Ctrl+B prefix ---------------------------------------------------------

const PrefixAction = enum { none, detach, next_tab, prev_tab, next_pane, next_workspace, create_tab, split_h, split_v, close_pane, help };

/// 可配置前缀键的 TUI 快捷键处理器。
/// 默认 Ctrl+B（byte 2）；keybindingsMode=server 时可从 config 读取自定义前缀。
const TuiPrefix = struct {
    pending: bool = false,
    /// 前缀字节：默认 Ctrl+B = 0x02；服务端配置可改成其他控制字符（如 Ctrl+A = 0x01）。
    prefix_byte: u8 = 2,

    fn consume(self: *TuiPrefix, in: []const u8, out: []u8) struct { length: usize, action: PrefixAction } {
        var length: usize = 0;
        for (in) |byte| {
            if (self.pending) {
                self.pending = false;
                switch (byte) {
                    'q', 'd' => return .{ .length = length, .action = .detach },
                    'n' => return .{ .length = length, .action = .next_tab },
                    'p' => return .{ .length = length, .action = .prev_tab },
                    'o' => return .{ .length = length, .action = .next_pane },
                    'w' => return .{ .length = length, .action = .next_workspace },
                    'c' => return .{ .length = length, .action = .create_tab },
                    '%', '|' => return .{ .length = length, .action = .split_h },
                    '"', '-' => return .{ .length = length, .action = .split_v },
                    'x' => return .{ .length = length, .action = .close_pane },
                    '?' => return .{ .length = length, .action = .help },
                    else => |b| {
                        // 双击前缀键发送字面值
                        if (b == self.prefix_byte) { out[length] = self.prefix_byte; length += 1; continue; }
                        out[length] = self.prefix_byte; length += 1;
                    },
                }
            } else if (byte == self.prefix_byte) { self.pending = true; continue; }
            out[length] = byte;
            length += 1;
        }
        return .{ .length = length, .action = .none };
    }
};

// ---- status bar ------------------------------------------------------------

/// 在终端最后一行画反色状态栏。
fn drawStatusBar(cols: u16, rows: u16, layout: *const LayoutIndex, pane_idx: usize, mode_text: ?[]const u8, prefix_byte: u8) void {
    var buffer: [512]u8 = undefined;
    const ws_title = layout.currentWorkspaceTitle(pane_idx);
    const tab_title = layout.currentTabTitle(pane_idx);
    const pane_label = layout.currentPaneLabel(pane_idx);
    const pane_total = layout.panesInTab(pane_idx);
    // 把前缀字节表示为 ^X 形式（如 ^B、^A）
    const prefix_char: u8 = prefix_byte + 'A' - 1;
    const content = if (mode_text) |mode|
        std.fmt.bufPrint(&buffer, " {s} > {s} [{d}/{d}] {s}", .{ ws_title, tab_title, pane_label, pane_total, mode }) catch " ? "
    else if (cols < 50)
        std.fmt.bufPrint(&buffer, " {s} [{d}/{d}] ^{c}q=quit", .{ tab_title, pane_label, pane_total, prefix_char }) catch " ? "
    else
        std.fmt.bufPrint(&buffer, " {s} > {s} [{d}/{d}]  ^{c}?=help ^{c}q=detach", .{ ws_title, tab_title, pane_label, pane_total, prefix_char, prefix_char }) catch " ? ";
    const max: usize = @min(cols, buffer.len);
    const display = if (content.len > max) content[0..max] else content;
    var out: [1024]u8 = undefined;
    const rendered = std.fmt.bufPrint(&out, "\x1b7\x1b[{d};1H\x1b[7m\x1b[2K{s}\x1b[0m\x1b8", .{ rows, display }) catch return;
    std.fs.File.stdout().writeAll(rendered) catch {};
}

fn drawHelp(cols: u16, rows: u16) void {
    _ = cols;
    const lines = [_][]const u8{
        "  Aster TUI keybindings (Ctrl+B prefix)  ",
        "  q/d    detach                           ",
        "  n/p    next/prev tab                    ",
        "  o      next pane                        ",
        "  w      next workspace                   ",
        "  c      create tab   %  split h          ",
        "  \"      split v      x  close pane       ",
        "  Ctrl+B send literal    ?  this help     ",
        "  Press any key to dismiss                ",
    };
    const start_row: u16 = if (rows > lines.len + 2) @intCast((rows - lines.len) / 2) else 1;
    for (lines, 0..) |line, i| {
        var out: [256]u8 = undefined;
        const row = start_row + @as(u16, @intCast(i));
        const rendered = std.fmt.bufPrint(&out, "\x1b7\x1b[{d};3H\x1b[7m{s}\x1b[0m\x1b8", .{ row, line }) catch continue;
        std.fs.File.stdout().writeAll(rendered) catch {};
    }
}

// ---- public entry point ----------------------------------------------------

pub const Mode = enum { interactive, observe };

/// TUI 主入口：连接到会话服务，全屏交互，Ctrl+B q 分离后宿主终端恢复正常。
pub fn run(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, mode: Mode) !void {
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    const stat = try std.posix.fstat(parent.fd);
    if (stat.uid != std.posix.geteuid() or stat.mode & 0o077 != 0) return error.UnsafeStateParent;

    const signal_fd = c.session_bridge_signals_start();
    if (signal_fd < 0) return error.SignalSetupFailed;
    defer c.session_bridge_signals_stop();

    var original: c.termios = undefined;
    const has_tty = c.isatty(0) == 1;
    if (has_tty and c.tcgetattr(0, &original) != 0) return error.TerminalModeUnavailable;
    var raw_installed = false;
    defer if (raw_installed) {
        // 退出 alternate screen + 重置 scroll region + 显示光标 + 恢复终端属性
        std.fs.File.stdout().writeAll("\x1b[r\x1b[?1049l\x1b[?25h") catch {};
        _ = c.tcsetattr(0, c.TCSANOW, &original);
    };

    var owner = try Client.connect(a, parent, name, ids.uuidText(ids.newUUID()));
    defer owner.stream.close();

    // 获取布局快照
    const snapshot_reply = try owner.rpc(.@"session.snapshot", .{});
    defer snapshot_reply.deinit();
    var layout = LayoutIndex.init(a);
    defer layout.deinit();
    const workspaces = fld(snapshot_reply.value.result, "workspaces") catch return error.InvalidSnapshot;
    const rev = snapshot_reply.value.revision orelse 0;
    try layout.build(workspaces, rev);
    if (layout.panes.items.len == 0) {
        std.fs.File.stderr().writeAll("aster-session: session has no terminals\r\n") catch {};
        return;
    }

    // 终端尺寸（留 1 行给状态栏）
    var term_rows: u16 = 24;
    var term_cols: u16 = 80;
    if (has_tty) {
        var size: c.winsize = std.mem.zeroes(c.winsize);
        if (c.ioctl(0, c.TIOCGWINSZ, &size) == 0 and size.ws_row > 0 and size.ws_col > 0) {
            term_rows = size.ws_row;
            term_cols = size.ws_col;
        }
    }
    var inner_rows = if (term_rows > 2) term_rows - 1 else term_rows;

    // 附加到第一个窗格
    var pane_idx: usize = 0;
    const read_only = mode == .observe;
    owner.terminal_id = layout.panes.items[0].terminal_id;
    const attached = try owner.rpc(if (read_only) .@"terminal.observe" else .@"terminal.attach", .{ .terminalID = &layout.panes.items[0].terminal_id });
    defer attached.deinit();
    var current_attachment = validID(str(attached.value.result, "attachmentID") catch return error.InvalidAttachment) orelse return error.InvalidAttachment;
    defer {
        if (owner.rpc(.@"terminal.release", .{ .attachmentID = &current_attachment })) |r| r.deinit() else |_| {}
    }
    if (!read_only) {
        if (attached.value.result.object.get("lease")) |lease| {
            owner.lease = .{
                .leaseID = validID(str(lease, "leaseID") catch return error.InvalidAttachment) orelse return error.InvalidAttachment,
                .leaseEpoch = integer(fld(lease, "leaseEpoch") catch return error.InvalidAttachment) catch return error.InvalidAttachment,
            };
        }
    }

    // resize 到内部尺寸
    var geo = Geometry{ .rows = inner_rows, .columns = term_cols };
    if (!read_only and !owner.exited) {
        const r = owner.rpc(.@"terminal.control", .{ .terminalID = &layout.panes.items[0].terminal_id, .action = "resize", .geometry = geo }) catch null;
        if (r) |rr| rr.deinit();
    }

    // 画面订阅
    var surface = try Surface.init(a, parent, name, &owner, current_attachment, &layout.panes.items[0].terminal_id, geo);
    defer surface.deinit();

    // 进入 raw mode + alternate screen
    if (has_tty) {
        var raw = original;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return error.TerminalModeUnavailable;
        raw_installed = true;
    }
    std.fs.File.stdout().writeAll("\x1b[?1049h") catch {};
    {
        var buf: [32]u8 = undefined;
        const sr = std.fmt.bufPrint(&buf, "\x1b[1;{d}r\x1b[H", .{inner_rows}) catch "\x1b[r\x1b[H";
        std.fs.File.stdout().writeAll(sr) catch {};
    }
    const stdout_flags = try std.posix.fcntl(1, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(1, std.posix.F.SETFL, stdout_flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
    defer { _ = std.posix.fcntl(1, std.posix.F.SETFL, stdout_flags) catch 0; }

    // 查询服务端配置以确定快捷键模式和前缀字节
    var prefix = TuiPrefix{};
    {
        const config_reply = owner.rpc(.@"config.get", .{}) catch null;
        defer if (config_reply) |r| r.deinit();
        if (config_reply) |cr| {
            if (cr.value.result.object.get("keybindingsMode")) |mode_val| {
                if (mode_val == .string and std.mem.eql(u8, mode_val.string, "server")) {
                    // keybindingsMode=server：使用服务端配置的前缀键
                    if (cr.value.result.object.get("detachPrefix")) |dp| {
                        if (dp == .integer and dp.integer >= 1 and dp.integer <= 26) {
                            prefix.prefix_byte = @intCast(dp.integer);
                        }
                    }
                }
            }
        }
    }

    drawStatusBar(term_cols, term_rows, &layout, pane_idx, if (read_only) "OBSERVE" else null, prefix.prefix_byte);

    // ---- 主循环 ----
    var pending_output: ?[]const u8 = null;
    var output_offset: usize = 0;
    var read_bytes: [8192]u8 = undefined;
    var read_count: usize = 0;
    var read_offset: usize = 0;
    var input_ready = false;
    var showing_help = false;
    var resize_pending = false;
    var requested = false;

    while (true) {
        var stdin_flushed = false;
        var fds = [_]std.posix.pollfd{
            .{ .fd = surface.client.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (input_ready or showing_help) 0 else -1, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = owner.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (pending_output != null) 1 else -1, .events = std.posix.POLL.OUT, .revents = 0 },
        };
        _ = try std.posix.poll(&fds, if (pending_output == null and read_count <= read_offset) 100 else 0);

        // 信号
        if (fds[2].revents & std.posix.POLL.IN != 0) {
            const event = c.session_bridge_signals_take();
            if (event != 0 and event != c.SIGWINCH) return;
            if (event == c.SIGWINCH) resize_pending = true;
        }

        // resize
        if (resize_pending and input_ready) {
            resize_pending = false;
            if (has_tty) {
                var size: c.winsize = std.mem.zeroes(c.winsize);
                if (c.ioctl(0, c.TIOCGWINSZ, &size) == 0 and size.ws_row > 0 and size.ws_col > 0) {
                    term_rows = size.ws_row;
                    term_cols = size.ws_col;
                    inner_rows = if (term_rows > 2) term_rows - 1 else term_rows;
                    geo = .{ .rows = inner_rows, .columns = term_cols };
                    {
                        var buf: [32]u8 = undefined;
                        const sr = std.fmt.bufPrint(&buf, "\x1b[1;{d}r\x1b[H", .{inner_rows}) catch "\x1b[r\x1b[H";
                        std.fs.File.stdout().writeAll(sr) catch {};
                    }
                    if (!read_only and !owner.exited and !owner.input_closed) {
                        const unsub = owner.rpc(.@"surface.unsubscribe", .{ .streamID = &surface.id }) catch null;
                        if (unsub) |u| u.deinit();
                        const ctrl = owner.rpc(.@"terminal.control", .{ .terminalID = &layout.panes.items[pane_idx].terminal_id, .action = "resize", .geometry = geo }) catch null;
                        if (ctrl) |cc| cc.deinit();
                        const replacement = Surface.init(a, parent, name, &owner, current_attachment, &layout.panes.items[pane_idx].terminal_id, geo) catch continue;
                        pending_output = null;
                        read_count = 0;
                        read_offset = 0;
                        surface.deinit();
                        surface = replacement;
                        input_ready = false;
                        prefix = TuiPrefix{};
                        requested = false;
                    }
                    drawStatusBar(term_cols, term_rows, &layout, pane_idx, if (read_only) "OBSERVE" else null, prefix.prefix_byte);
                }
            }
        }

        // 控制事件
        if (fds[3].revents & std.posix.POLL.IN != 0) {
            var deadline = try transport.Deadline.init(100);
            if (transport.readFrame(a, owner.stream, &deadline)) |bytes| {
                defer a.free(bytes);
                owner.handleEvent(bytes) catch {};
            } else |_| {}
        }

        // 输出画面
        if (pending_output) |output| {
            if (fds[4].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) return;
            if (fds[4].revents & std.posix.POLL.OUT != 0) {
                if (!input_ready and has_tty) {
                    _ = c.tcflush(0, c.TCIFLUSH);
                    stdin_flushed = true;
                }
                const written = std.posix.write(1, output[output_offset..@min(output.len, output_offset + 16384)]) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                output_offset += written;
                if (output_offset == output.len) {
                    pending_output = null;
                    surface.receiver.release();
                    if (!surface.receiver.resync and !input_ready) {
                        prefix = TuiPrefix{};
                        input_ready = true;
                    }
                    drawStatusBar(term_cols, term_rows, &layout, pane_idx, if (read_only) "OBSERVE" else null, prefix.prefix_byte);
                }
            }
        }

        // 读取画面
        if (pending_output == null and (read_count > read_offset or fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)) {
            if (read_count == read_offset) {
                read_count = surface.client.stream.read(&read_bytes) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return err,
                };
                read_offset = 0;
                if (read_count == 0) {
                    try surface.decoder.finish();
                    return;
                }
            }
            while (read_offset < read_count) {
                var consumed: usize = 0;
                const message = try surface.decoder.feed(read_bytes[read_offset..read_count], &consumed);
                read_offset += consumed;
                if (message) |frm| {
                    const now: u64 = @intCast(@max(0, std.time.milliTimestamp()));
                    if (try surface.receiver.frame(frm, now)) |complete| {
                        pending_output = complete;
                        output_offset = 0;
                        requested = false;
                        break;
                    }
                    if (surface.receiver.resync and !requested) {
                        input_ready = false;
                        prefix = TuiPrefix{};
                        const snap_req = owner.rpc(.@"surface.snapshot", .{ .streamID = &surface.id }) catch continue;
                        snap_req.deinit();
                        requested = true;
                    }
                }
            }
        }

        // 输入
        if (!stdin_flushed and fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            var in_buf: [4096]u8 = undefined;
            const count = try std.posix.read(0, &in_buf);
            if (count == 0) return;

            if (showing_help) {
                showing_help = false;
                if (!requested) {
                    const snap_req = owner.rpc(.@"surface.snapshot", .{ .streamID = &surface.id }) catch continue;
                    snap_req.deinit();
                    requested = true;
                    input_ready = false;
                }
                continue;
            }

            var out_buf: [4097]u8 = undefined;
            const result = prefix.consume(in_buf[0..count], &out_buf);

            switch (result.action) {
                .detach => return,
                .next_tab, .prev_tab, .next_pane, .next_workspace => {
                    const new_idx = switch (result.action) {
                        .next_tab => layout.nextTab(pane_idx),
                        .prev_tab => layout.prevTab(pane_idx),
                        .next_pane => layout.nextPane(pane_idx),
                        .next_workspace => layout.nextWorkspace(pane_idx),
                        else => pane_idx,
                    };
                    if (new_idx != pane_idx) {
                        switchPane(a, &owner, &surface, &current_attachment, parent, name, &layout, &pane_idx, new_idx, read_only, inner_rows, term_cols) catch {};
                        pending_output = null;
                        read_count = 0;
                        read_offset = 0;
                        input_ready = false;
                        prefix = TuiPrefix{};
                        requested = false;
                        drawStatusBar(term_cols, term_rows, &layout, pane_idx, if (read_only) "OBSERVE" else null, prefix.prefix_byte);
                    }
                },
                .create_tab => {
                    if (!read_only) {
                        createTab(a, parent_path, name, &layout, pane_idx) catch |err| {
                            var ebuf: [64]u8 = undefined;
                            const ename = @errorName(err);
                            const msg = std.fmt.bufPrint(&ebuf, "tab.create: {s}" ++ "\n", .{ename}) catch "tab.create err\n";
                            std.fs.File.stderr().writeAll(msg) catch {};
                        };
                        refreshLayout(a, &owner, &layout) catch {};
                        drawStatusBar(term_cols, term_rows, &layout, pane_idx, null, prefix.prefix_byte);
                    }
                },
                .split_h, .split_v => {
                    if (!read_only and pane_idx < layout.panes.items.len) {
                        const dir: []const u8 = if (result.action == .split_h) "right" else "down";
                        splitPane(a, parent_path, name, &layout, pane_idx, dir) catch |err| {
                            var ebuf: [64]u8 = undefined;
                            const ename = @errorName(err);
                            const msg = std.fmt.bufPrint(&ebuf, "split: {s}" ++ "\n", .{ename}) catch "split err\n";
                            std.fs.File.stderr().writeAll(msg) catch {};
                        };
                        refreshLayout(a, &owner, &layout) catch {};
                        drawStatusBar(term_cols, term_rows, &layout, pane_idx, null, prefix.prefix_byte);
                    }
                },
                .close_pane => {
                    if (!read_only and pane_idx < layout.panes.items.len) {
                        closePane(a, parent_path, name, &layout, pane_idx) catch {};
                        refreshLayout(a, &owner, &layout) catch {};
                        if (layout.panes.items.len == 0) return;
                        if (pane_idx >= layout.panes.items.len) pane_idx = layout.panes.items.len - 1;
                        switchPane(a, &owner, &surface, &current_attachment, parent, name, &layout, &pane_idx, pane_idx, read_only, inner_rows, term_cols) catch {};
                        pending_output = null;
                        read_count = 0;
                        read_offset = 0;
                        input_ready = false;
                        prefix = TuiPrefix{};
                        requested = false;
                        drawStatusBar(term_cols, term_rows, &layout, pane_idx, null, prefix.prefix_byte);
                    }
                },
                .help => { showing_help = true; drawHelp(term_cols, term_rows); },
                .none => {},
            }

            if (result.action == .none and input_ready and !read_only and !owner.exited and !owner.input_closed and result.length > 0)
                owner.input(&layout.panes.items[pane_idx].terminal_id, out_buf[0..@min(result.length, 4096)]) catch {};
        }
    }
}

// ---- pane switching --------------------------------------------------------

/// 释放旧附加、附加新终端、订阅新画面。
fn switchPane(a: std.mem.Allocator, owner: *Client, surface: *Surface, current_attachment: *ID, parent: std.fs.Dir, name: []const u8, layout: *LayoutIndex, pane_idx: *usize, new_idx: usize, read_only: bool, inner_rows: u16, cols: u16) !void {
    const rel = owner.rpc(.@"terminal.release", .{ .attachmentID = current_attachment }) catch null;
    if (rel) |r| r.deinit();
    owner.lease = null;
    const unsub = owner.rpc(.@"surface.unsubscribe", .{ .streamID = &surface.id }) catch null;
    if (unsub) |u| u.deinit();

    pane_idx.* = new_idx;
    const pane = layout.panes.items[new_idx];
    owner.terminal_id = pane.terminal_id;
    owner.exited = false;
    owner.input_closed = false;

    const attached = try owner.rpc(if (read_only) .@"terminal.observe" else .@"terminal.attach", .{ .terminalID = &pane.terminal_id });
    defer attached.deinit();
    current_attachment.* = validID(str(attached.value.result, "attachmentID") catch return error.InvalidAttachment) orelse return error.InvalidAttachment;
    if (!read_only) {
        if (attached.value.result.object.get("lease")) |lease| {
            owner.lease = .{
                .leaseID = validID(str(lease, "leaseID") catch return error.InvalidAttachment) orelse return error.InvalidAttachment,
                .leaseEpoch = integer(fld(lease, "leaseEpoch") catch return error.InvalidAttachment) catch return error.InvalidAttachment,
            };
            owner.sequence = 0;
        }
    }
    const geo = Geometry{ .rows = inner_rows, .columns = cols };
    if (!read_only and !owner.exited) {
        const r = owner.rpc(.@"terminal.control", .{ .terminalID = &pane.terminal_id, .action = "resize", .geometry = geo }) catch null;
        if (r) |rr| rr.deinit();
    }
    const replacement = try Surface.init(a, parent, name, owner, current_attachment.*, &pane.terminal_id, geo);
    surface.deinit();
    surface.* = replacement;
}

fn refreshLayout(_: std.mem.Allocator, owner: *Client, layout: *LayoutIndex) !void {
    const reply = try owner.rpc(.@"session.snapshot", .{});
    defer reply.deinit();
    const ws = fld(reply.value.result, "workspaces") catch return error.InvalidSnapshot;
    const rev = reply.value.revision orelse 0;
    try layout.build(ws, rev);
}

/// 在当前工作区创建新标签（从 LayoutIndex 获取 workspaceID）。
fn createTab(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, layout: *LayoutIndex, pane_idx: usize) !void {
    if (pane_idx >= layout.panes.items.len) return;
    const ws_id = layout.workspaceIDForPane(pane_idx) orelse return error.InvalidSnapshot;
    const result = try workspace_client.execute(a, parent_path, name, .{
        .tab_create = .{
            .workspace_id = ws_id,  // *const [36]u8 自动解引用为 []const u8
            .title = "tab",
            .spec = .{ .cwd = "/tmp", .argv = &.{"/bin/sh"} },
            .revision = layout.revision,
        },
    }, 5000);
    defer a.free(result.bytes);
}

fn splitPane(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, layout: *LayoutIndex, pane_idx: usize, direction: []const u8) !void {
    if (pane_idx >= layout.panes.items.len) return;
    const pane = layout.panes.items[pane_idx];
    const result = try workspace_client.execute(a, parent_path, name, .{
        .pane_split = .{
            .pane_id = &pane.pane_id,
            .direction = direction,
            .spec = .{ .cwd = "/tmp", .argv = &.{"/bin/sh"} },
            .revision = layout.revision,
        },
    }, 5000);
    defer a.free(result.bytes);
}

fn closePane(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, layout: *LayoutIndex, pane_idx: usize) !void {
    if (pane_idx >= layout.panes.items.len) return;
    const pane = layout.panes.items[pane_idx];
    const result = try workspace_client.execute(a, parent_path, name, .{
        .pane_close = .{
            .pane_id = &pane.pane_id,
            .revision = layout.revision,
        },
    }, 5000);
    defer a.free(result.bytes);
}

// ---- JSON helpers ----------------------------------------------------------

fn str(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidReply;
    const found = value.object.get(key) orelse return error.InvalidReply;
    if (found != .string) return error.InvalidReply;
    return found.string;
}
fn fld(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidReply;
    return value.object.get(key) orelse error.InvalidReply;
}
fn integer(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else error.InvalidReply,
        .number_string => |s| std.fmt.parseInt(u64, s, 10),
        else => error.InvalidReply,
    };
}
fn validID(s: []const u8) ?ID {
    if (!@import("operation_request.zig").validID(s)) return null;
    return s[0..36].*;
}

// ---- tests -----------------------------------------------------------------

test "tui prefix detach and literal" {
    var p = TuiPrefix{};
    var out: [20]u8 = undefined;
    const r1 = p.consume(&.{ 2, 'q' }, &out);
    try std.testing.expect(r1.action == .detach);
    try std.testing.expectEqual(@as(usize, 0), r1.length);
    const r2 = p.consume(&.{ 2, 2 }, &out);
    try std.testing.expect(r2.action == .none);
    try std.testing.expectEqual(@as(usize, 1), r2.length);
    try std.testing.expectEqual(@as(u8, 2), out[0]);
}

test "tui prefix navigation keys" {
    var p = TuiPrefix{};
    var out: [20]u8 = undefined;
    try std.testing.expect(p.consume(&.{ 2, 'n' }, &out).action == .next_tab);
    try std.testing.expect(p.consume(&.{ 2, 'p' }, &out).action == .prev_tab);
    try std.testing.expect(p.consume(&.{ 2, 'o' }, &out).action == .next_pane);
    try std.testing.expect(p.consume(&.{ 2, 'w' }, &out).action == .next_workspace);
    try std.testing.expect(p.consume(&.{ 2, '?' }, &out).action == .help);
}

test "tui prefix split across read boundaries" {
    var p = TuiPrefix{};
    var out: [20]u8 = undefined;
    const r1 = p.consume(&.{2}, &out);
    try std.testing.expect(r1.action == .none);
    try std.testing.expectEqual(@as(usize, 0), r1.length);
    const r2 = p.consume(&.{'q'}, &out);
    try std.testing.expect(r2.action == .detach);
}

test "tui prefix custom prefix byte (Ctrl+A)" {
    // keybindingsMode=server 可将前缀改成 Ctrl+A（byte 1）
    var p = TuiPrefix{ .prefix_byte = 1 };
    var out: [20]u8 = undefined;
    // Ctrl+A q 应分离
    const r1 = p.consume(&.{ 1, 'q' }, &out);
    try std.testing.expect(r1.action == .detach);
    try std.testing.expectEqual(@as(usize, 0), r1.length);
    // Ctrl+B 不再触发前缀，直接透传
    const r2 = p.consume(&.{ 2, 'q' }, &out);
    try std.testing.expect(r2.action == .none);
    try std.testing.expectEqual(@as(usize, 2), r2.length);
    // 双击 Ctrl+A 发送字面 Ctrl+A
    const r3 = p.consume(&.{ 1, 1 }, &out);
    try std.testing.expect(r3.action == .none);
    try std.testing.expectEqual(@as(usize, 1), r3.length);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
}

test "layout index builds from snapshot JSON" {
    const a = std.testing.allocator;
    const json =
        \\[{
        \\  "workspaceID": "00000000-0000-4000-8000-000000000001",
        \\  "title": "ws1",
        \\  "cwd": "/tmp",
        \\  "tabs": [{
        \\    "tabID": "00000000-0000-4000-8000-000000000002",
        \\    "title": "tab1",
        \\    "layout": {
        \\      "kind": "split",
        \\      "axis": "horizontal",
        \\      "ratio": 0.5,
        \\      "first": {
        \\        "kind": "leaf",
        \\        "pane": {
        \\          "paneID": "00000000-0000-4000-8000-000000000003",
        \\          "terminalID": "00000000-0000-4000-8000-000000000004"
        \\        }
        \\      },
        \\      "second": {
        \\        "kind": "leaf",
        \\        "pane": {
        \\          "paneID": "00000000-0000-4000-8000-000000000005",
        \\          "terminalID": "00000000-0000-4000-8000-000000000006"
        \\        }
        \\      }
        \\    }
        \\  }]
        \\}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var idx = LayoutIndex.init(a);
    defer idx.deinit();
    try idx.build(parsed.value, 1);
    try std.testing.expectEqual(@as(usize, 2), idx.panes.items.len);
    try std.testing.expectEqual(@as(u16, 0), idx.panes.items[0].workspace_idx);
    try std.testing.expectEqual(@as(u16, 0), idx.panes.items[0].pane_seq);
    try std.testing.expectEqual(@as(u16, 1), idx.panes.items[1].pane_seq);
    try std.testing.expectEqualStrings("ws1", idx.currentWorkspaceTitle(0));
    try std.testing.expectEqualStrings("tab1", idx.currentTabTitle(0));
    try std.testing.expectEqual(@as(u16, 1), idx.currentPaneLabel(0));
    try std.testing.expectEqual(@as(u16, 2), idx.panesInTab(0));
    // 验证 workspaceID 被正确提取
    try std.testing.expectEqual(@as(usize, 1), idx.workspace_ids.items.len);
    const ws_id = idx.workspaceIDForPane(0).?;
    try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000001", ws_id);
}
