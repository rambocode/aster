// Live handoff: transfer PTY ownership, VT state, layout, agent metadata, and
// idempotency log from an old service to a new one without killing terminals.
// The old service serializes state, sends PTY master FDs via SCM_RIGHTS over
// a private Unix socketpair, and waits for takeover confirmation before exiting.

const std = @import("std");
const ids = @import("service_identity.zig");
const Pool = @import("terminal_pool.zig").Pool;
const AgentStore = @import("agent_store.zig").Store;
const workspace_store = @import("workspace_store.zig");
const c = @cImport({
    @cInclude("scm_rights.h");
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
});

/// Maximum time (ns) the old service waits for takeover confirmation.
pub const confirmation_timeout_ns: u64 = 5 * std.time.ns_per_s;

/// Maximum serialized state size (16 MiB). Rejects implausibly large payloads.
const max_state_bytes: usize = 16 * 1024 * 1024;

/// Maximum number of PTY FDs transferred in one SCM_RIGHTS message.
const max_fds: usize = 64;

// ─── Wire types ────────────────────────────────────────────────────────────

/// One terminal entry in the handoff state envelope.
pub const TerminalEntry = struct {
    id: []const u8,
    pid: i32,
    cwd: []const u8,
    history_excluded: bool = false,
};

/// Complete state envelope serialized as JSON.
pub const StateEnvelope = struct {
    version: u32 = 1,
    epoch: []const u8,
    terminals: []const TerminalEntry,
    layout_json: ?[]const u8 = null,
    agents_json: ?[]const u8 = null,
    idempotency_json: ?[]const u8 = null,
};

/// Confirmation message sent back on the private socket.
const Confirmation = struct {
    confirmed: bool,
    new_epoch: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

// ─── Sender (old service) ──────────────────────────────────────────────────

/// Serializes current service state and sends it with PTY FDs to the new
/// service over the given socket. Returns the list of PTY FDs that were
/// sent (caller must NOT close them until confirmation or recovery).
pub fn sendState(
    allocator: std.mem.Allocator,
    socket_fd: std.posix.fd_t,
    pool: *Pool,
    store: *workspace_store.Store,
    agents: *AgentStore,
    epoch: [16]u8,
) ![]std.posix.fd_t {
    // Collect terminal entries and their PTY master FDs.
    var entries: std.ArrayList(TerminalEntry) = .empty;
    defer entries.deinit(allocator);
    var fds: std.ArrayList(std.posix.fd_t) = .empty;
    defer fds.deinit(allocator);

    for (pool.entries.items) |*entry| {
        const master_fd = entry.session.process.master;
        if (master_fd < 0) continue;
        try entries.append(allocator, .{
            .id = &entry.id,
            .pid = entry.session.process.pid,
            .cwd = entry.cwd[0..std.mem.len(@as([*:0]const u8, entry.cwd.ptr))],
            .history_excluded = entry.history_excluded,
        });
        try fds.append(allocator, master_fd);
    }

    if (fds.items.len > max_fds) return error.TooManyTerminals;

    // Serialize layout.
    const layout_json = try store.serializeJson(allocator);
    defer if (layout_json) |lj| allocator.free(lj);

    // Serialize agent store.
    const agents_json = try serializeAgents(allocator, agents);
    defer if (agents_json) |aj| allocator.free(aj);

    // Build envelope.
    const epoch_text = ids.uuidText(epoch);
    const envelope = StateEnvelope{
        .epoch = &epoch_text,
        .terminals = entries.items,
        .layout_json = layout_json,
        .agents_json = agents_json,
    };

    const json = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    defer allocator.free(json);

    if (json.len > max_state_bytes) return error.StateTooLarge;

    // Send length prefix (4 bytes, big-endian) as inline data with FDs.
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(json.len), .big);

    // Send FDs with the length header.
    const send_result = c.aster_scm_send_fds(
        socket_fd,
        @ptrCast(fds.items.ptr),
        @intCast(fds.items.len),
        &header,
        header.len,
    );
    if (send_result < 0) return error.ScmSendFailed;

    // Send the JSON body in a plain write (no more FDs needed).
    var written: usize = 0;
    while (written < json.len) {
        const n = std.posix.write(socket_fd, json[written..]) catch return error.HandoffWriteFailed;
        if (n == 0) return error.HandoffWriteFailed;
        written += n;
    }

    // Return owned FD list so caller can recover them on failure.
    return try allocator.dupe(std.posix.fd_t, fds.items);
}

/// Waits for takeover confirmation from the new service. Returns true if
/// confirmed, false on timeout or explicit rejection.
pub fn awaitConfirmation(socket_fd: std.posix.fd_t, timeout_ns: u64) !bool {
    // Poll with timeout.
    const timeout_ms: i32 = @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(i32)));
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = socket_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const poll_result = try std.posix.poll(&poll_fds, timeout_ms);
    if (poll_result == 0) return false; // Timeout.

    var buf: [4096]u8 = undefined;
    const n = std.posix.read(socket_fd, &buf) catch return false;
    if (n == 0) return false;

    const parsed = std.json.parseFromSlice(Confirmation, std.heap.page_allocator, buf[0..n], .{}) catch return false;
    defer parsed.deinit();
    return parsed.value.confirmed;
}

// ─── Receiver (new service) ────────────────────────────────────────────────

/// Result of receiving handoff state from the old service.
pub const ReceivedState = struct {
    allocator: std.mem.Allocator,
    envelope: std.json.Parsed(StateEnvelope),
    fds: []std.posix.fd_t,

    /// Releases all resources. Caller must have adopted or closed FDs first.
    pub fn deinit(self: *ReceivedState) void {
        self.allocator.free(self.fds);
        self.envelope.deinit();
        self.* = undefined;
    }
};

/// Receives FDs and state envelope from the old service over the private
/// socket. The caller must verify FD validity and process liveness before
/// sending confirmation.
pub fn receiveState(allocator: std.mem.Allocator, socket_fd: std.posix.fd_t) !ReceivedState {
    // Receive FDs + length header.
    var fds_buf: [max_fds]c_int = undefined;
    var header: [4]u8 = undefined;
    var header_len: usize = header.len;

    const fd_count = c.aster_scm_recv_fds(
        socket_fd,
        &fds_buf,
        max_fds,
        &header,
        &header_len,
    );
    if (fd_count < 0) return error.ScmRecvFailed;
    if (header_len < 4) return error.HandoffHeaderTruncated;

    const json_len = std.mem.readInt(u32, &header, .big);
    if (json_len == 0 or json_len > max_state_bytes) return error.HandoffStateTooLarge;

    // Read the JSON body.
    const json_buf = try allocator.alloc(u8, json_len);
    defer allocator.free(json_buf);
    var total: usize = 0;
    while (total < json_len) {
        const n = std.posix.read(socket_fd, json_buf[total..]) catch return error.HandoffReadFailed;
        if (n == 0) return error.HandoffReadFailed;
        total += n;
    }

    // Parse envelope.
    const parsed = std.json.parseFromSlice(StateEnvelope, allocator, json_buf[0..json_len], .{
        .allocate = .alloc_always,
    }) catch return error.HandoffStateInvalid;
    errdefer parsed.deinit();

    // Copy FDs into Zig-owned slice.
    const fd_slice = try allocator.alloc(std.posix.fd_t, @intCast(fd_count));
    errdefer allocator.free(fd_slice);
    for (0..@intCast(fd_count)) |i| {
        fd_slice[i] = fds_buf[i];
    }

    return .{
        .allocator = allocator,
        .envelope = parsed,
        .fds = fd_slice,
    };
}

/// Sends takeover confirmation to the old service.
pub fn sendConfirmation(socket_fd: std.posix.fd_t, confirmed: bool, new_epoch: ?[16]u8) !void {
    var epoch_text_buf: [36]u8 = undefined;
    const epoch_text: ?[]const u8 = if (new_epoch) |e| blk: {
        epoch_text_buf = ids.uuidText(e);
        break :blk &epoch_text_buf;
    } else null;

    const confirmation = Confirmation{
        .confirmed = confirmed,
        .new_epoch = epoch_text,
        .message = if (confirmed) "takeover successful" else "takeover rejected",
    };
    const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, confirmation, .{});
    defer std.heap.page_allocator.free(json);

    _ = std.posix.write(socket_fd, json) catch return error.HandoffConfirmationFailed;
}

/// Verifies that received PTY FDs are readable and their processes are alive.
/// Returns the number of valid FDs, or an error if none are usable.
pub fn verifyReceivedState(state: *const ReceivedState) !usize {
    const envelope = state.envelope.value;
    if (state.fds.len != envelope.terminals.len) return error.HandoffFdCountMismatch;

    var valid: usize = 0;
    for (state.fds, envelope.terminals) |fd, terminal| {
        // Check FD is valid with a zero-timeout poll.
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN | std.posix.POLL.OUT,
            .revents = 0,
        }};
        const poll_result = std.posix.poll(&poll_fds, 0) catch continue;
        _ = poll_result;

        // Check process liveness with kill(pid, 0).
        if (terminal.pid > 0) {
            std.posix.kill(terminal.pid, 0) catch continue;
        }
        valid += 1;
    }

    if (valid == 0 and envelope.terminals.len > 0) return error.HandoffNoValidTerminals;
    return valid;
}

// ─── Orchestration (old service) ───────────────────────────────────────────

/// Performs the full old-service side of a live handoff: creates a socketpair,
/// forks the new binary, sends state, waits for confirmation. Returns true if
/// handoff succeeded and old service should exit; false if it should recover.
pub fn performHandoff(
    allocator: std.mem.Allocator,
    pool: *Pool,
    store: *workspace_store.Store,
    agents: *AgentStore,
    epoch: [16]u8,
    new_binary_path: []const u8,
    state_parent_path: []const u8,
    session_name: []const u8,
) !bool {
    // Create socketpair for private communication.
    var pair: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) < 0)
        return error.HandoffSocketpairFailed;

    const parent_fd = pair[0];
    const child_fd = pair[1];
    defer std.posix.close(parent_fd);

    // Fork the new binary with --takeover-fd pointing to child_fd.
    // Allocate null-terminated strings for execv; freed after fork in parent.
    const binary_z = try allocator.dupeZ(u8, new_binary_path);
    defer allocator.free(binary_z);
    const parent_z = try allocator.dupeZ(u8, state_parent_path);
    defer allocator.free(parent_z);
    const name_z = try allocator.dupeZ(u8, session_name);
    defer allocator.free(name_z);
    var child_fd_buf: [16]u8 = undefined;
    const fd_len = (std.fmt.bufPrint(&child_fd_buf, "{d}", .{child_fd}) catch unreachable).len;
    child_fd_buf[fd_len] = 0;
    const fd_z: [*:0]const u8 = @ptrCast(child_fd_buf[0..fd_len :0]);

    const argv = [_:null]?[*:0]const u8{
        binary_z.ptr,
        "server",
        "serve",
        parent_z.ptr,
        name_z.ptr,
        "--takeover-fd",
        fd_z,
    };

    const pid = c.fork();
    if (pid < 0) {
        std.posix.close(child_fd);
        return error.HandoffForkFailed;
    }

    if (pid == 0) {
        // Child: close parent end, exec new binary. FD_CLOEXEC is NOT set
        // on child_fd so it survives exec.
        _ = c.close(parent_fd);
        _ = c.execv(argv[0].?, @ptrCast(&argv));
        // exec failed
        std.process.exit(127);
    }

    // Parent: close child end, send state.
    std.posix.close(child_fd);

    const sent_fds = sendState(allocator, parent_fd, pool, store, agents, epoch) catch |err| {
        // Handoff send failed; kill child and recover.
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
        return err;
    };
    defer allocator.free(sent_fds);

    // Wait for confirmation from new service.
    const confirmed = awaitConfirmation(parent_fd, confirmation_timeout_ns) catch false;

    if (!confirmed) {
        // Handoff rejected or timed out; kill child and recover.
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
        return false;
    }

    // Takeover confirmed. Close our copies of PTY FDs so only the new
    // service owns them. Do NOT reap the child — it's the new service.
    for (sent_fds) |fd| {
        std.posix.close(fd);
    }

    return true;
}

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Serializes the agent store to JSON for the handoff envelope.
fn serializeAgents(allocator: std.mem.Allocator, agents: *AgentStore) !?[]u8 {
    if (agents.entries.items.len == 0) return null;
    // Build a JSON array of agent records using an arena for temporaries.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp = arena.allocator();
    var array = std.json.Array.init(tmp);
    for (agents.entries.items) |*agent| {
        var obj = std.json.ObjectMap.init(tmp);
        try obj.put("terminalID", .{ .string = &agent.terminal_id });
        try obj.put("provider", .{ .string = agent.provider });
        try obj.put("state", .{ .string = @tagName(agent.state) });
        if (agent.name) |n| try obj.put("name", .{ .string = n });
        if (agent.native_session) |ns| try obj.put("nativeSession", .{ .string = ns });
        if (agent.source) |s| try obj.put("source", .{ .string = s });
        try array.append(.{ .object = obj });
    }
    return try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = array }, .{});
}

test "state envelope round-trips through JSON" {
    const allocator = std.testing.allocator;
    const epoch = ids.uuidText(ids.newUUID());
    const entry = TerminalEntry{
        .id = "00000000-0000-4000-8000-000000000001",
        .pid = 42,
        .cwd = "/tmp",
    };
    const envelope = StateEnvelope{
        .epoch = &epoch,
        .terminals = &.{entry},
        .layout_json = "{\"test\":true}",
    };
    const json = try std.json.Stringify.valueAlloc(allocator, envelope, .{});
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(StateEnvelope, allocator, json, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.terminals.len);
    try std.testing.expectEqual(@as(i32, 42), parsed.value.terminals[0].pid);
    try std.testing.expectEqualStrings("/tmp", parsed.value.terminals[0].cwd);
}
