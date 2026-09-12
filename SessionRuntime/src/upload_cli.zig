//! CLI entry point for uploading image data to a remote session via stdin.
//!
//! Reads up to 20 MiB from stdin, computes SHA-256, connects to the session
//! control socket, and performs the upload.begin / upload.chunk / upload.commit
//! RPC sequence. Prints the resulting server-side path as JSON to stdout.
const std = @import("std");
const transport = @import("service_client.zig");
const handshake = @import("handshake.zig");
const identity = @import("service_identity.zig");
const requests = @import("operation_request.zig");
const replies = @import("operation_response.zig");
const control = @import("service_control.zig");
const protocol = @import("protocol.zig");

/// Maximum upload size: 20 MiB.
const max_size: usize = 20 * 1024 * 1024;
/// Raw chunk size before base64 encoding: 192 KB -> ~256 KB base64.
const raw_chunk_size: usize = 192 * 1024;
/// RPC timeout for each round trip.
const rpc_timeout_ms: u32 = 30_000;

/// Run the upload flow: read stdin, hash, connect, RPC begin/chunk/commit.
pub fn run(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, terminal_id: []const u8, content_type: []const u8) !void {
    // Read all image data from stdin (up to 20 MiB).
    const stdin = std.fs.File.stdin();
    const data = try stdin.readToEndAlloc(allocator, max_size);
    defer allocator.free(data);
    if (data.len == 0) return error.EmptyInput;

    // Compute SHA-256 digest.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = "0123456789abcdef";
    var sha_hex: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        sha_hex[i * 2] = hex[byte >> 4];
        sha_hex[i * 2 + 1] = hex[byte & 15];
    }

    // Connect to the session control socket.
    var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
    defer parent.close();
    const info = try std.posix.fstat(parent.fd);
    if (info.uid != std.posix.geteuid() or info.mode & 0o077 != 0) return error.UnsafeStateParent;
    var deadline = try transport.Deadline.init(rpc_timeout_ms);
    const stream = try transport.connect(parent, name, &deadline);
    defer stream.close();

    // Read and validate hello.
    const hello_bytes = try transport.readFrame(allocator, stream, &deadline);
    defer allocator.free(hello_bytes);
    const hello = try std.json.parseFromSlice(handshake.Hello, allocator, hello_bytes, .{ .ignore_unknown_fields = true });
    defer hello.deinit();
    try hello.value.negotiateRequired(&.{"image_upload"});

    const client_id = identity.uuidText(identity.newUUID());

    // RPC helper: send a request and read back the response.
    const Ctx = struct {
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        hello: handshake.Hello,
        client_id: [36]u8,

        /// Send one RPC request and return the response bytes (caller-owned).
        fn rpc(self: @This(), operation: @import("operation_kind.zig").Operation, params: std.json.Value) ![]u8 {
            const request_id = identity.uuidText(identity.newUUID());
            const request = requests.Request{
                .type = "request",
                .requestID = &request_id,
                .clientID = &self.client_id,
                .scope = .session,
                .operation = operation,
                .target = .{
                    .serverID = self.hello.serverID,
                    .serverEpoch = self.hello.serverEpoch,
                    .sessionID = self.hello.sessionID,
                },
                .params = params,
            };
            const encoded = try std.json.Stringify.valueAlloc(self.allocator, request, .{ .emit_null_optional_fields = false });
            defer self.allocator.free(encoded);
            if (encoded.len > protocol.maximum_control_bytes) return error.RequestTooLarge;
            var header: [5]u8 = undefined;
            header[0] = 1;
            std.mem.writeInt(u32, header[1..5], @intCast(encoded.len), .big);
            var dl = transport.Deadline.init(rpc_timeout_ms) catch return error.ServiceTimedOut;
            try transport.writeAll(self.stream, &header, &dl);
            try transport.writeAll(self.stream, encoded, &dl);
            return try transport.readReply(self.allocator, self.stream, &dl, request.target.?);
        }
    };
    const ctx = Ctx{
        .allocator = allocator,
        .stream = stream,
        .hello = hello.value,
        .client_id = client_id,
    };

    // Build params map for upload.begin.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var begin_params = std.json.ObjectMap.init(aa);
    try begin_params.put("terminalID", .{ .string = terminal_id });
    try begin_params.put("contentType", .{ .string = content_type });
    try begin_params.put("size", .{ .integer = @intCast(data.len) });
    try begin_params.put("sha256", .{ .string = &sha_hex });

    const begin_resp = try ctx.rpc(.@"upload.begin", .{ .object = begin_params });
    defer allocator.free(begin_resp);

    // Parse uploadID from the begin response.
    const begin_parsed = try std.json.parseFromSlice(struct { result: struct { uploadID: []const u8 } }, aa, begin_resp, .{ .ignore_unknown_fields = true });
    const upload_id = begin_parsed.value.result.uploadID;

    // Send data in chunks (192KB raw = ~256KB base64).
    var offset: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + raw_chunk_size, data.len);
        const chunk = data[offset..end];

        // Base64-encode the chunk.
        const b64_len = std.base64.standard.Encoder.calcSize(chunk.len);
        const b64_buf = try allocator.alloc(u8, b64_len);
        defer allocator.free(b64_buf);
        _ = std.base64.standard.Encoder.encode(b64_buf, chunk);

        var chunk_params = std.json.ObjectMap.init(aa);
        try chunk_params.put("uploadID", .{ .string = upload_id });
        try chunk_params.put("data", .{ .string = b64_buf });

        const chunk_resp = try ctx.rpc(.@"upload.chunk", .{ .object = chunk_params });
        allocator.free(chunk_resp);

        offset = end;
    }

    // Commit with SHA-256 verification.
    var commit_params = std.json.ObjectMap.init(aa);
    try commit_params.put("uploadID", .{ .string = upload_id });
    try commit_params.put("sha256", .{ .string = &sha_hex });

    const commit_resp = try ctx.rpc(.@"upload.commit", .{ .object = commit_params });
    defer allocator.free(commit_resp);

    // Parse the path from commit response and output as JSON.
    const commit_parsed = try std.json.parseFromSlice(struct { result: struct { path: []const u8 } }, aa, commit_resp, .{ .ignore_unknown_fields = true });
    const path = commit_parsed.value.result.path;

    const output = try std.json.Stringify.valueAlloc(allocator, .{ .path = path }, .{});
    defer allocator.free(output);
    try std.fs.File.stdout().writeAll(output);
    try std.fs.File.stdout().writeAll("\n");
}
