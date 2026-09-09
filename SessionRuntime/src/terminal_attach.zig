const std = @import("std");
const transport = @import("service_client.zig");
const protocol = @import("protocol.zig");
const Request = @import("operation_request.zig").Request;
const replies = @import("operation_response.zig");
const ids = @import("service_identity.zig");
const Assembler = @import("snapshot.zig").Assembler;
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
        try parsed.value.negotiateRequired(&.{ "terminal_control", "surface_interest", "health_check" });
        return .{ .allocator = a, .stream = stream, .client_id = client_id, .server = try identity(parsed.value.serverID), .epoch = try identity(parsed.value.serverEpoch), .session = try identity(parsed.value.sessionID) };
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
        // No retry: after any partial write, input delivery is uncertain.
        try transport.writeAll(self.stream, &header, &deadline);
        try transport.writeAll(self.stream, encoded, &deadline);
        while (true) {
            const bytes = try transport.readFrame(a, self.stream, &deadline);
            defer a.free(bytes);
            const tag = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
            defer tag.deinit();
            const kind = try string(tag.value, "type");
            if (std.mem.eql(u8, kind, "event")) {
                try self.event(bytes);
                continue;
            }
            if (std.mem.eql(u8, kind, "error")) {
                const failure = try std.json.parseFromSlice(replies.Failure, a, bytes, .{});
                defer failure.deinit();
                try failure.value.validate(request);
                // Root exit can reject writes before the owned scope and its
                // tail output are drained. Only this validated input failure
                // closes the write side; it is not a terminal.exited event.
                if (operation == .@"terminal.control" and
                    std.mem.eql(u8, failure.value.@"error".code, "terminal_exited") and
                    std.mem.eql(u8, try string(request.params, "action"), "input"))
                {
                    if (self.terminal_id) |bound| {
                        if (std.mem.eql(u8, try string(request.params, "terminalID"), &bound))
                            return error.TerminalInputClosed;
                    }
                }
                // The Zig error name alone loses the server's decision. Report
                // the validated operation, code, message and retry class so a
                // rejected bridge is diagnosable from the caller's stderr.
                reportRejection(operation, failure.value.@"error".code, failure.value.@"error".message, @tagName(failure.value.@"error".retry));
                return error.TerminalRequestRejected;
            }
            const result = try std.json.parseFromSlice(Response, a, bytes, .{ .allocate = .alloc_always });
            errdefer result.deinit();
            try result.value.validate(request);
            return result;
        }
    }
    /// Events share a connection cursor even when their terminal is unrelated.
    /// Validate the envelope before changing either cursor or local ownership.
    fn event(self: *Client, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(replies.Event(std.json.Value), self.allocator, bytes, .{});
        defer parsed.deinit();
        const value = parsed.value;
        try value.validate(value.event, .{ .serverID = &self.server, .serverEpoch = &self.epoch, .sessionID = &self.session }, self.event_sequence, self.event_revision);
        const terminal_id = try identity(try string(value.body, "terminalID"));
        const matching = if (self.terminal_id) |bound| std.mem.eql(u8, &terminal_id, &bound) else false;
        var revoked = false;
        if (std.mem.eql(u8, value.event, "terminal.exited")) {
            // The terminal event body is the protocol's terminal record.
            const cwd = try string(value.body, "cwd");
            if (cwd.len == 0 or cwd.len > 4096 or !std.fs.path.isAbsolute(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidTerminalEvent;
            if (!std.mem.eql(u8, try string(value.body, "state"), "exited")) return error.InvalidTerminalEvent;
        } else if (std.mem.eql(u8, value.event, "lease.revoked")) {
            const lease_id = try identity(try string(value.body, "leaseID"));
            const epoch = try integer(try field(value.body, "leaseEpoch"));
            const reason = try string(value.body, "reason");
            if (reason.len == 0 or reason.len > 4096) return error.InvalidTerminalEvent;
            if (self.lease) |lease| revoked = matching and std.mem.eql(u8, &lease_id, &lease.leaseID) and epoch == lease.leaseEpoch;
        } else return error.UnexpectedControlEvent;
        self.event_sequence = value.sequence;
        self.event_revision = value.revision;
        if (std.mem.eql(u8, value.event, "terminal.exited") and matching) self.exited = true;
        if (revoked) return error.WriterLeaseLost;
    }
    fn readEvent(self: *Client) !void {
        var deadline = try transport.Deadline.init(5000);
        const bytes = try transport.readFrame(self.allocator, self.stream, &deadline);
        defer self.allocator.free(bytes);
        try self.event(bytes);
    }

    fn input(self: *Client, terminal_id: []const u8, bytes: []const u8) !void {
        if (self.input_closed) return;
        var encoded: [5464]u8 = undefined;
        if (bytes.len > 4096) return error.InputTooLarge;
        const data = std.base64.standard.Encoder.encode(&encoded, bytes);
        const result = self.rpc(.@"terminal.control", .{ .terminalID = terminal_id, .action = "input", .data = data }) catch |err| {
            if (err == error.TerminalInputClosed) {
                self.input_closed = true;
                return;
            }
            return err;
        };
        defer result.deinit();
        if (!try boolean(result.value.result, "accepted")) return error.InputRejected;
    }
};

/// Owns only complete, bounded transactions. Raw surface frames carry bytes;
/// their order is supplied to the shared assembler by this single ordered byte stream.
const Receiver = struct {
    allocator: std.mem.Allocator,
    assembler: ?Assembler = null,
    last: ?u64 = null,
    sequence: u64 = 0,
    delta: bool = false,
    discard: bool = false,
    resync: bool = false,
    started: u64 = 0,
    fn deinit(self: *Receiver) void {
        if (self.assembler) |*value| value.deinit();
    }
    fn frame(self: *Receiver, message: protocol.Frame, now: u64) !?[]const u8 {
        if (message.kind == .surface) {
            const current = if (self.assembler) |*value| value else return error.SnapshotRequired;
            try current.append(current.next_index, message.payload);
            return null;
        }
        const Event = struct { type: enum { snapshot_begin, snapshot_end, delta_begin, delta_end }, length: ?usize = null, sha256: ?[]const u8 = null, sequence: ?u64 = null, baseSequence: ?u64 = null };
        const parsed = try std.json.parseFromSlice(Event, self.allocator, message.payload, .{});
        defer parsed.deinit();
        const event = parsed.value;
        switch (event.type) {
            .snapshot_begin, .delta_begin => {
                if (self.assembler != null) return error.OverlappingSnapshot;
                self.sequence = event.sequence orelse return error.MissingSequence;
                self.delta = event.type == .delta_begin;
                self.discard = false;
                if (self.delta) {
                    const base = event.baseSequence orelse return error.MissingSequence;
                    if (self.sequence <= base) return error.InvalidSequence;
                    if (self.last == null or self.last.? != base or self.resync) {
                        self.discard = true;
                        self.resync = true;
                    }
                } else {
                    if (event.baseSequence != null or (self.last != null and self.sequence < self.last.?)) return error.StaleSnapshot;
                }
                const length = event.length orelse return error.MissingLength;
                if (self.delta and length > 65536) return error.DeltaTooLarge;
                const hex = event.sha256 orelse return error.MissingDigest;
                if (hex.len != 64) return error.InvalidDigest;
                var digest: [32]u8 = undefined;
                _ = try std.fmt.hexToBytes(&digest, hex);
                self.assembler = try Assembler.init(self.allocator, length, digest);
                self.started = now;
                return null;
            },
            .snapshot_end, .delta_end => {
                const current = if (self.assembler) |*value| value else return error.UnexpectedTransactionEnd;
                if ((event.type == .delta_end) != self.delta) return error.UnexpectedTransactionEnd;
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
        var client = try Client.connect(a, parent, name, owner.client_id);
        errdefer client.stream.close();
        if (!std.mem.eql(u8, &client.server, &owner.server) or !std.mem.eql(u8, &client.epoch, &owner.epoch) or !std.mem.eql(u8, &client.session, &owner.session)) return error.ServiceReplaced;
        const reply = try client.rpc(.@"surface.subscribe", .{ .attachmentID = &attachment, .geometry = geometry });
        defer reply.deinit();
        if (!std.mem.eql(u8, try string(reply.value.result, "terminalID"), terminal_id)) return error.InvalidSurfaceReply;
        return .{ .client = client, .id = try identity(try string(reply.value.result, "streamID")), .decoder = protocol.Decoder.init(a), .receiver = .{ .allocator = a } };
    }
    fn deinit(self: *Surface) void {
        self.receiver.deinit();
        self.decoder.deinit();
        self.client.stream.close();
    }
};

/// Interactive attach/observe owns two connections and restores the caller's
/// terminal on every return path. Detach releases attachment ownership only.
pub fn run(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, terminal_id: []const u8, read_only: bool) !void {
    return runWithTakeover(a, parent_path, name, terminal_id, read_only, false);
}

pub fn runWithTakeover(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, terminal_id: []const u8, read_only: bool, takeover: bool) !void {
    // A missing control event invalidates both ownership and cached state.
    // Re-enter through the same handshake path once, with fresh connection IDs
    // and leases. Never replay an interrupted request or repeat a takeover.
    var recovering = false;
    while (true) {
        runConnection(a, parent_path, name, terminal_id, read_only, if (recovering) false else takeover) catch |err| {
            if (err != error.SequenceGap or recovering) return err;
            recovering = true;
            if (c.isatty(0) == 1) _ = c.tcflush(0, c.TCIFLUSH);
            continue;
        };
        return;
    }
}

fn runConnection(a: std.mem.Allocator, parent_path: []const u8, name: []const u8, terminal_id: []const u8, read_only: bool, takeover: bool) !void {
    if (read_only and takeover) return error.InvalidTakeoverOption;
    _ = try identity(terminal_id);
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    const stat = try std.posix.fstat(parent.fd);
    if (stat.uid != std.posix.geteuid() or stat.mode & 0o077 != 0) return error.UnsafeStateParent;
    var owner = try Client.connect(a, parent, name, ids.uuidText(ids.newUUID()));
    defer owner.stream.close();
    owner.terminal_id = try identity(terminal_id);
    const attached = if (takeover) blk: {
        const observation = try owner.rpc(.@"terminal.observe", .{ .terminalID = terminal_id });
        defer observation.deinit();
        const expected_epoch = try integer(try field(observation.value.result, "currentLeaseEpoch"));
        const observation_id = try string(observation.value.result, "attachmentID");
        const released = try owner.rpc(.@"terminal.release", .{ .attachmentID = observation_id });
        released.deinit();
        // Preserve the epoch actually observed by this client; a concurrent
        // takeover fails CAS instead of silently overriding its winner.
        break :blk try owner.rpc(.@"terminal.attach", .{ .terminalID = terminal_id, .takeover = true, .expectedLeaseEpoch = expected_epoch });
    } else try owner.rpc(if (read_only) .@"terminal.observe" else .@"terminal.attach", .{ .terminalID = terminal_id });
    defer attached.deinit();
    if (!std.mem.eql(u8, try string(attached.value.result, "terminalID"), terminal_id) or try boolean(attached.value.result, "readOnly") != read_only) return error.InvalidAttachment;
    const attachment = try identity(try string(attached.value.result, "attachmentID"));
    defer {
        if (owner.rpc(.@"terminal.release", .{ .attachmentID = &attachment })) |reply| reply.deinit() else |_| {}
    }
    if (!read_only) {
        const lease = try field(attached.value.result, "lease");
        owner.lease = .{ .leaseID = try identity(try string(lease, "leaseID")), .leaseEpoch = try integer(try field(lease, "leaseEpoch")) };
    }
    const signal_fd = c.session_bridge_signals_start();
    if (signal_fd < 0) return error.SignalSetupFailed;
    defer c.session_bridge_signals_stop();
    var original: c.termios = undefined;
    const has_tty = c.isatty(0) == 1;
    if (has_tty and c.tcgetattr(0, &original) != 0) return error.TerminalModeUnavailable;
    var raw_installed = false;
    defer if (raw_installed) {
        _ = c.tcsetattr(0, c.TCSANOW, &original);
    };
    var geometry = try sourceGeometry(&owner, terminal_id);
    if (!read_only and !owner.exited and !owner.input_closed) if (try localGeometry()) |g| {
        try resize(&owner, terminal_id, g);
        geometry = g;
    };
    var surface = try Surface.init(a, parent, name, &owner, attachment, terminal_id, geometry);
    defer surface.deinit();
    if (has_tty) {
        var raw = original;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return error.TerminalModeUnavailable;
        raw_installed = true;
    }
    const stdout_flags = try std.posix.fcntl(1, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(1, std.posix.F.SETFL, stdout_flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
    defer {
        _ = std.posix.fcntl(1, std.posix.F.SETFL, stdout_flags) catch 0;
    }
    var pending_output: ?[]const u8 = null;
    var output_offset: usize = 0;
    var read_bytes: [8192]u8 = undefined;
    var read_count: usize = 0;
    var read_offset: usize = 0;
    var clock = try std.time.Timer.start();
    var heartbeat: u64 = 0;
    var waiting_since: u64 = 0;
    var prefix: Prefix = .{};
    var requested = false;
    var input_ready = false;
    var resize_pending = false;
    while (true) {
        const now = clock.read() / std.time.ns_per_ms;
        // A window change during recovery is deferred, not lost. Finish the
        // recovery transaction, then obtain a new-size snapshot before input.
        if (resize_pending and pending_output == null and surface.receiver.assembler == null and
            !surface.receiver.resync and surface.receiver.last != null)
        {
            resize_pending = false;
            if (try localGeometry()) |g| if (!std.meta.eql(g, geometry)) {
                const reply = try owner.rpc(.@"surface.unsubscribe", .{ .streamID = &surface.id });
                reply.deinit();
                try resize(&owner, terminal_id, g);
                const replacement = try Surface.init(a, parent, name, &owner, attachment, terminal_id, g);
                surface.deinit();
                surface = replacement;
                geometry = g;
                read_count = 0;
                read_offset = 0;
                waiting_since = now;
                requested = false;
                input_ready = false;
                prefix = .{};
            };
        }
        const input_was_ready = input_ready;
        var stdin_flushed = false;
        if ((surface.receiver.last == null and now - waiting_since >= 30_000) or (surface.receiver.assembler != null and now - surface.receiver.started >= 30_000)) return error.SnapshotTimeout;
        if (now - heartbeat >= 5000) {
            const reply = try owner.rpc(.@"health.check", .{});
            reply.deinit();
            if (!read_only and !owner.exited and !owner.input_closed) try owner.input(terminal_id, "");
            heartbeat = now;
        }
        var fds = [_]std.posix.pollfd{
            .{ .fd = if (pending_output == null) surface.client.stream.handle else -1, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = signal_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = owner.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (pending_output != null) 1 else -1, .events = std.posix.POLL.OUT, .revents = 0 },
        };
        _ = try std.posix.poll(&fds, if (pending_output == null and read_count > read_offset) 0 else 100);
        if (fds[2].revents != 0) {
            const event = c.session_bridge_signals_take();
            if (event != 0 and event != c.SIGWINCH) return error.AttachInterrupted;
            if (event == c.SIGWINCH and !input_ready and !read_only and !owner.exited and !owner.input_closed) resize_pending = true;
            if (event == c.SIGWINCH and input_ready and !read_only and !owner.exited and !owner.input_closed) if (try localGeometry()) |g| {
                const reply = try owner.rpc(.@"surface.unsubscribe", .{ .streamID = &surface.id });
                reply.deinit();
                try resize(&owner, terminal_id, g);
                const replacement = try Surface.init(a, parent, name, &owner, attachment, terminal_id, g);
                pending_output = null;
                read_count = 0;
                read_offset = 0;
                surface.deinit();
                surface = replacement;
                geometry = g;
                waiting_since = now;
                requested = false;
                input_ready = false;
                prefix = .{};
                continue;
            };
        }
        if (fds[3].revents != 0) try owner.readEvent();
        if (pending_output) |output| {
            if (fds[4].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) return error.OutputClosed;
            if (fds[4].revents & std.posix.POLL.OUT != 0) {
                if (!input_ready and has_tty) {
                    // Flush stale keys before publishing the next output bytes,
                    // never after: a user may answer immediately on seeing the
                    // final byte of the restored snapshot.
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
                        // Drop keys typed against stale state, including a
                        // partial detach prefix, before reopening user writes.
                        prefix = .{};
                        input_ready = true;
                    }
                }
            }
        }
        if (pending_output == null and (read_count > read_offset or fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)) {
            if (read_count == read_offset) {
                read_count = surface.client.stream.read(&read_bytes) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return err,
                };
                read_offset = 0;
                if (read_count == 0) {
                    try surface.decoder.finish();
                    if (surface.receiver.assembler != null) return error.IncompleteSnapshot;
                    return;
                }
            }
            while (read_offset < read_count) {
                var consumed: usize = 0;
                const message = try surface.decoder.feed(read_bytes[read_offset..read_count], &consumed);
                read_offset += consumed;
                if (message) |frame| {
                    if (try surface.receiver.frame(frame, now)) |complete| {
                        pending_output = complete;
                        output_offset = 0;
                        requested = false;
                        break;
                    }
                    if (surface.receiver.resync and !requested) {
                        input_ready = false;
                        prefix = .{};
                        const reply = try owner.rpc(.@"surface.snapshot", .{ .streamID = &surface.id });
                        reply.deinit();
                        requested = true;
                    }
                }
            }
        }
        // tcflush above invalidates this turn's stdin readiness. Do not
        // block on a read of the stale poll result after reopening the gate.
        if (!stdin_flushed and fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            var input: [4096]u8 = undefined;
            const count = try std.posix.read(0, &input);
            if (count == 0) return;
            var output: [4097]u8 = undefined;
            const result = prefix.consume(input[0..count], &output);
            if (input_ready and input_was_ready and !read_only and !owner.exited and !owner.input_closed and result.length != 0) {
                try owner.input(terminal_id, output[0..@min(result.length, 4096)]);
                if (result.length > 4096) try owner.input(terminal_id, output[4096..result.length]);
            }
            if (result.detach) return;
        }
    }
}

const Prefix = struct {
    pending: bool = false,
    fn consume(self: *Prefix, input: []const u8, output: []u8) struct { length: usize, detach: bool } {
        var length: usize = 0;
        for (input) |byte| {
            if (self.pending) {
                self.pending = false;
                if (byte == 'q') return .{ .length = length, .detach = true };
                output[length] = 2;
                length += 1;
                if (byte == 2) continue;
            } else if (byte == 2) {
                self.pending = true;
                continue;
            }
            output[length] = byte;
            length += 1;
        }
        return .{ .length = length, .detach = false };
    }
};
/// Print a server rejection to stderr. Best effort and non-fatal: a failure to
/// report must never replace the rejection the caller has to act on. CR+LF is
/// used because the caller's terminal may still be in raw mode at this point.
fn reportRejection(operation: @import("operation_kind.zig").Operation, code: []const u8, message: []const u8, retry: []const u8) void {
    var buffer: [4608]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "aster-session: {s} rejected: code={s} retry={s} message={s}\r\n", .{ @tagName(operation), code, retry, message }) catch return;
    std.fs.File.stderr().writeAll(text) catch {};
}
fn resize(owner: *Client, terminal_id: []const u8, geometry: Geometry) !void {
    const reply = try owner.rpc(.@"terminal.control", .{ .terminalID = terminal_id, .action = "resize", .geometry = geometry });
    defer reply.deinit();
    if (!try boolean(reply.value.result, "accepted")) return error.ResizeRejected;
}
fn localGeometry() !?Geometry {
    if (c.isatty(0) != 1) return null;
    var size: c.winsize = std.mem.zeroes(c.winsize);
    if (c.ioctl(0, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeUnavailable;
    if (size.ws_row == 0 or size.ws_col == 0) return null;
    return .{ .rows = size.ws_row, .columns = size.ws_col, .pixelWidth = if (size.ws_xpixel >= size.ws_col and size.ws_ypixel >= size.ws_row) size.ws_xpixel else 0, .pixelHeight = if (size.ws_xpixel >= size.ws_col and size.ws_ypixel >= size.ws_row) size.ws_ypixel else 0 };
}
fn sourceGeometry(owner: *Client, terminal_id: []const u8) !Geometry {
    const reply = try owner.rpc(.@"terminal.list", .{});
    defer reply.deinit();
    const terminals = try field(reply.value.result, "terminals");
    if (terminals != .array) return error.InvalidTerminalReply;
    for (terminals.array.items) |terminal| if (std.mem.eql(u8, try string(terminal, "terminalID"), terminal_id)) {
        const geometry = try field(terminal, "geometry");
        const parsed = try std.json.parseFromValue(Geometry, owner.allocator, geometry, .{});
        defer parsed.deinit();
        if (parsed.value.rows == 0 or parsed.value.columns == 0) return error.InvalidGeometry;
        return parsed.value;
    };
    return error.TerminalNotFound;
}
fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidTerminalReply;
    return value.object.get(key) orelse error.InvalidTerminalReply;
}
fn string(value: std.json.Value, key: []const u8) ![]const u8 {
    const found = try field(value, key);
    if (found != .string) return error.InvalidTerminalReply;
    return found.string;
}
fn boolean(value: std.json.Value, key: []const u8) !bool {
    const found = try field(value, key);
    if (found != .bool) return error.InvalidTerminalReply;
    return found.bool;
}
fn integer(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else error.InvalidTerminalReply,
        .number_string => |s| std.fmt.parseInt(u64, s, 10),
        else => error.InvalidTerminalReply,
    };
}
fn identity(value: []const u8) !ID {
    if (!@import("operation_request.zig").validID(value)) return error.InvalidIdentity;
    return value[0..36].*;
}

test "terminal attach prefix survives read boundaries and observer detach" {
    var prefix: Prefix = .{};
    var output: [20]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), prefix.consume(&.{2}, &output).length);
    try std.testing.expectEqual(@as(usize, 1), prefix.consume(&.{2}, &output).length);
    try std.testing.expectEqual(@as(u8, 2), output[0]);
    const result = prefix.consume(&.{ 'a', 2, 'q', 'b' }, &output);
    try std.testing.expect(result.detach);
    try std.testing.expectEqualStrings("a", output[0..result.length]);
}

test "terminal attach only exposes verified complete transactions and requests gaps" {
    const a = std.testing.allocator;
    var receiver = Receiver{ .allocator = a };
    defer receiver.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &digest, .{});
    const begin = try std.fmt.allocPrint(a, "{{\"type\":\"snapshot_begin\",\"length\":3,\"sha256\":\"{s}\",\"sequence\":5}}", .{std.fmt.bytesToHex(digest, .lower)});
    defer a.free(begin);
    try std.testing.expect(try receiver.frame(.{ .kind = .control, .payload = begin }, 0) == null);
    try std.testing.expect(try receiver.frame(.{ .kind = .surface, .payload = "abc" }, 1) == null);
    try std.testing.expectEqualStrings("abc", (try receiver.frame(.{ .kind = .control, .payload = "{\"type\":\"snapshot_end\"}" }, 2)).?);
    receiver.release();
    const gap = try std.fmt.allocPrint(a, "{{\"type\":\"delta_begin\",\"length\":3,\"sha256\":\"{s}\",\"sequence\":7,\"baseSequence\":6}}", .{std.fmt.bytesToHex(digest, .lower)});
    defer a.free(gap);
    _ = try receiver.frame(.{ .kind = .control, .payload = gap }, 3);
    try std.testing.expect(receiver.resync);
    _ = try receiver.frame(.{ .kind = .surface, .payload = "abc" }, 4);
    try std.testing.expect(try receiver.frame(.{ .kind = .control, .payload = "{\"type\":\"delta_end\"}" }, 5) == null);
    try std.testing.expectEqual(@as(?u64, 5), receiver.last);
}

test "terminal attach rejects corrupt payload without exposing terminal bytes" {
    var receiver = Receiver{ .allocator = std.testing.allocator };
    defer receiver.deinit();
    _ = try receiver.frame(.{ .kind = .control, .payload = "{\"type\":\"snapshot_begin\",\"length\":3,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"sequence\":1}" }, 0);
    _ = try receiver.frame(.{ .kind = .surface, .payload = "abc" }, 1);
    try std.testing.expectError(error.SnapshotIntegrityFailure, receiver.frame(.{ .kind = .control, .payload = "{\"type\":\"snapshot_end\"}" }, 2));
    try std.testing.expect(receiver.last == null);
}

test "terminal attach run rejects invalid identity before connecting" {
    try std.testing.expectError(error.InvalidIdentity, run(std.testing.allocator, "/", "unused", "invalid", true));
}

fn eventTestClient() Client {
    const first = "00000000-0000-4000-8000-000000000001".*;
    return .{ .allocator = std.testing.allocator, .stream = undefined, .client_id = first, .server = first, .epoch = first, .session = first, .terminal_id = first, .lease = .{ .leaseID = first, .leaseEpoch = 4 } };
}
fn testEvent(client: *Client, event_name: []const u8, sequence: u64, body: anytype, epoch: []const u8) !void {
    const bytes = try std.json.Stringify.valueAlloc(client.allocator, .{ .type = "event", .event = event_name, .eventID = &client.client_id, .target = .{ .serverID = &client.server, .serverEpoch = epoch, .sessionID = &client.session }, .sequence = sequence, .revision = 0, .body = body }, .{});
    defer client.allocator.free(bytes);
    try client.event(bytes);
}
test "terminal attach exit events preserve unrelated cursors and reject wrong targets gaps" {
    var client = eventTestClient();
    const other = "00000000-0000-4000-8000-000000000002";
    try testEvent(&client, "terminal.exited", 1, .{ .terminalID = other, .cwd = "/tmp", .state = "exited", .exitCode = 0 }, &client.epoch);
    try std.testing.expect(!client.exited);
    try std.testing.expectEqual(@as(u64, 1), client.event_sequence);
    const body = .{ .terminalID = &client.client_id, .cwd = "/tmp", .state = "exited", .exitCode = 0 };
    try std.testing.expectError(error.TargetMismatch, testEvent(&client, "terminal.exited", 2, body, other));
    try std.testing.expectError(error.SequenceGap, testEvent(&client, "terminal.exited", 3, body, &client.epoch));
    try std.testing.expect(!client.exited);
    try testEvent(&client, "terminal.exited", 2, body, &client.epoch);
    try std.testing.expect(client.exited);
}
test "terminal attach only matching lease revocation stops its writer" {
    var client = eventTestClient();
    const other = "00000000-0000-4000-8000-000000000002";
    try testEvent(&client, "lease.revoked", 1, .{ .terminalID = other, .leaseID = &client.client_id, .leaseEpoch = 4, .reason = "takeover" }, &client.epoch);
    try testEvent(&client, "lease.revoked", 2, .{ .terminalID = &client.client_id, .leaseID = &client.client_id, .leaseEpoch = 3, .reason = "takeover" }, &client.epoch);
    try std.testing.expectError(error.WriterLeaseLost, testEvent(&client, "lease.revoked", 3, .{ .terminalID = &client.client_id, .leaseID = &client.client_id, .leaseEpoch = 4, .reason = "takeover" }, &client.epoch));
    try std.testing.expectEqual(@as(u64, 3), client.event_sequence);
}
