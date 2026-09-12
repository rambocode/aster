const std = @import("std");
const Session = @import("session.zig").Session;
const protocol = @import("protocol.zig");
const Hello = @import("handshake.zig").Hello;
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("session_pty.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
});

/// P0 integration endpoint. Deliberately advertises probe-only capabilities;
/// production session IDs, leases and full snapshots are not claimed here.
pub fn serve(allocator: std.mem.Allocator, socket_path: [:0]const u8, cwd: [:0]const u8, executable: [:0]const u8, argv: [*:null]const ?[*:0]const u8) !void {
    const parent_path = std.fs.path.dirname(socket_path) orelse return error.InvalidSocketPath;
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    const info = try std.posix.fstat(parent.fd);
    if (info.uid != c.geteuid() or info.mode & 0o077 != 0) return error.UnsafeSocketDirectory;
    var server = try (try std.net.Address.initUnix(socket_path)).listen(.{ .force_nonblocking = true });
    defer server.deinit();
    defer std.fs.cwd().deleteFile(socket_path) catch {};
    if (c.chmod(socket_path, 0o600) != 0) return error.SocketPermissionFailed;
    const env = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", "TERM=xterm-256color" };
    const session = try Session.create(allocator, cwd, executable, argv, &env, 24, 80);
    defer session.destroy();
    // Probe identities remain stable for this process only. Durable service
    // identities are introduced by the production session store, not fabricated.
    const server_id = randomIdentity();
    const epoch = randomIdentity();
    const session_id = randomIdentity();
    const hello: Hello = .{
        .type = .hello,
        .protocolMajor = 1,
        .protocolMinor = 0,
        .serverID = &server_id,
        .serverEpoch = &epoch,
        .sessionID = &session_id,
        .platform = if (builtin.os.tag == .macos)
            (if (builtin.cpu.arch == .aarch64) .@"macos-aarch64" else .@"macos-x86_64")
        else
            (if (builtin.cpu.arch == .aarch64) .@"linux-aarch64" else .@"linux-x86_64"),
        .capabilities = &.{ "p0_active_screen", "snapshot_transaction_v1", "terminal_delta_v1" },
    };
    const hello_json = try std.json.Stringify.valueAlloc(allocator, hello, .{});
    defer allocator.free(hello_json);
    var client: ?Client = null;
    defer if (client) |*value| value.deinit();
    while (true) {
        const accepted = server.accept() catch |err| switch (err) {
            error.WouldBlock => null,
            else => return err,
        };
        if (accepted) |connection| {
            if (client != null or c.session_same_user(connection.stream.handle) != 1) {
                connection.stream.close();
            } else {
                const fd = connection.stream.handle;
                const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
                _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
                client = Client.init(allocator, connection.stream);
                try client.?.enqueue(.control, hello_json);
                client.?.needs_screen = true;
            }
        }
        const changed = try session.tick(20, 65536);
        if (session.eof) std.Thread.sleep(20 * std.time.ns_per_ms);
        if (client) |*value| {
            const action = value.receive(session) catch .disconnect;
            if (action == .terminate) return;
            if (action == .disconnect) {
                value.deinit();
                client = null;
                continue; // The owned Session is intentionally retained.
            }
            if (changed and !value.needs_screen and session.delta_safe and value.last_queued_sequence == session.delta_base) {
                value.enqueueTransaction(session.delta_bytes.items, session.output_sequence, session.delta_base) catch {
                    value.deinit();
                    client = null;
                    continue;
                };
            } else if (changed or value.needs_screen) {
                const captured = session.snapshotForClient(@import("snapshot.zig").maximum_bytes) catch |err| {
                    std.log.err("snapshot capture failed: {s}", .{@errorName(err)});
                    value.deinit();
                    client = null;
                    continue;
                };
                if (captured) |frame| {
                    defer allocator.free(frame);
                    value.enqueueTransaction(frame, session.output_sequence, null) catch {
                        value.deinit();
                        client = null;
                        continue;
                    };
                    value.needs_screen = false;
                }
            }
            value.flush() catch {
                value.deinit();
                client = null;
            };
        }
    }
}

const Action = enum { keep, disconnect, terminate };
const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    decoder: protocol.Decoder,
    queue: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    needs_screen: bool = true,
    last_queued_sequence: ?u64 = null,

    fn init(allocator: std.mem.Allocator, stream: std.net.Stream) Client {
        return .{ .allocator = allocator, .stream = stream, .decoder = protocol.Decoder.init(allocator) };
    }
    fn deinit(self: *Client) void {
        self.stream.close();
        self.decoder.deinit();
        self.queue.deinit(self.allocator);
    }
    fn enqueue(self: *Client, kind: protocol.Kind, bytes: []const u8) !void {
        if (self.queue.items.len - self.sent + bytes.len + 5 > 8 * 1024 * 1024) return error.SlowConsumer;
        if (self.sent != 0) {
            const remaining = self.queue.items.len - self.sent;
            std.mem.copyForwards(u8, self.queue.items[0..remaining], self.queue.items[self.sent..]);
            self.queue.shrinkRetainingCapacity(remaining);
            self.sent = 0;
        }
        var header: [5]u8 = undefined;
        header[0] = @intFromEnum(kind);
        std.mem.writeInt(u32, header[1..5], @intCast(bytes.len), .big);
        try self.queue.appendSlice(self.allocator, &header);
        try self.queue.appendSlice(self.allocator, bytes);
    }
    fn enqueueTransaction(self: *Client, bytes: []const u8, sequence: u64, base: ?u64) !void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const begin = try std.json.Stringify.valueAlloc(self.allocator, .{
            .type = if (base == null) "snapshot_begin" else "delta_begin",
            .length = bytes.len,
            .sha256 = @as([]const u8, &hex),
            .sequence = sequence,
            .baseSequence = base,
        }, .{});
        defer self.allocator.free(begin);
        try self.enqueue(.control, begin);
        var offset: usize = 0;
        var index: u32 = 0;
        while (offset < bytes.len) {
            const count = @min(bytes.len - offset, protocol.maximum_surface_bytes - 4);
            const chunk = try self.allocator.alloc(u8, count + 4);
            defer self.allocator.free(chunk);
            std.mem.writeInt(u32, chunk[0..4], index, .big);
            @memcpy(chunk[4..], bytes[offset..][0..count]);
            try self.enqueue(.surface, chunk);
            offset += count;
            index += 1;
        }
        try self.enqueue(.control, if (base == null) "{\"type\":\"snapshot_end\"}" else "{\"type\":\"delta_end\"}");
        self.last_queued_sequence = sequence;
    }

    fn flush(self: *Client) !void {
        if (self.sent == self.queue.items.len) return;
        const n = self.stream.write(self.queue.items[self.sent..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        self.sent += n;
        if (self.sent == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.sent = 0;
        }
    }
    fn receive(self: *Client, session: *Session) !Action {
        var bytes: [8192]u8 = undefined;
        const count = self.stream.read(&bytes) catch |err| switch (err) {
            error.WouldBlock => return .keep,
            else => return err,
        };
        if (count == 0) return .disconnect;
        var offset: usize = 0;
        while (offset < count) {
            var consumed: usize = 0;
            const frame = try self.decoder.feed(bytes[offset..count], &consumed);
            offset += consumed;
            if (frame) |message| {
                if (message.kind != .control) return error.InvalidMessage;
                const parsed = try std.json.parseFromSlice(Request, self.allocator, message.payload, .{});
                defer parsed.deinit();
                const request = parsed.value;
                switch (request.op) {
                    .input => {
                        if (request.data) |encoded| {
                            if (request.text != null) return error.AmbiguousInput;
                            const decoder = std.base64.standard.Decoder;
                            const length = try decoder.calcSizeForSlice(encoded);
                            if (length > Session.input_limit) return error.InputQueueFull;
                            const decoded = try self.allocator.alloc(u8, length);
                            defer self.allocator.free(decoded);
                            try decoder.decode(decoded, encoded);
                            try session.send(decoded);
                        } else try session.send(request.text orelse return error.MissingInput);
                    },
                    .resize => {
                        try session.resizeGeometry(.{
                            .rows = request.rows orelse return error.MissingRows,
                            .columns = request.cols orelse return error.MissingColumns,
                            .pixel_width = request.pixelWidth orelse 0,
                            .pixel_height = request.pixelHeight orelse 0,
                        });
                        self.needs_screen = true;
                    },
                    .snapshot => self.needs_screen = true,
                    .release => return .disconnect,
                    .terminate => return .terminate,
                }
            }
        }
        return .keep;
    }
};
const Request = struct {
    op: enum { input, resize, snapshot, release, terminate },
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    rows: ?u16 = null,
    cols: ?u16 = null,
    pixelWidth: ?u16 = null,
    pixelHeight: ?u16 = null,
};

fn randomIdentity() [36]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    const hex = "0123456789abcdef";
    var result: [36]u8 = undefined;
    var offset: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            result[offset] = '-';
            offset += 1;
        }
        result[offset] = hex[byte >> 4];
        result[offset + 1] = hex[byte & 15];
        offset += 2;
    }
    return result;
}
