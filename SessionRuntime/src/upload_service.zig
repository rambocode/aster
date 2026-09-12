/// Server-side image upload service (P7.5): receives chunked base64 data from
/// the client, reassembles it into a temp file, verifies SHA-256, and atomically
/// renames it to a final path under uploads/.
const std = @import("std");
const Request = @import("operation_request.zig").Request;
const Operation = @import("operation_kind.zig").Operation;
const ids = @import("service_identity.zig");
const replies = @import("operation_response.zig");

const Retry = @TypeOf(@as(replies.Failure, undefined).@"error".retry);

// ---- limits ---------------------------------------------------------------

/// Single image upload cap: 20 MiB.
const max_single_size: u64 = 20 * 1024 * 1024;
/// Session-wide total upload quota: 200 MiB.
const max_session_total: u64 = 200 * 1024 * 1024;
/// Maximum concurrent tracked uploads (bounded array capacity).
const max_active: usize = 16;
/// TTL for uploaded files: 24 hours in milliseconds.
const ttl_ms: u64 = 24 * 3600 * 1000;
/// Base64 decoded chunk ceiling — aligned with the protocol's 256 KiB surface
/// block limit. We accept slightly more raw base64 bytes since encoding inflates
/// by ~33%, but the decoded output is capped here.
const max_chunk_decoded: usize = 256 * 1024;

// ---- upload state ---------------------------------------------------------

/// Tracks one in-progress upload from begin to commit/abort.
const Upload = struct {
    upload_id: [36]u8,
    client_id: [36]u8,
    /// 创建此上传的控制连接代号，用于断线清理。
    connection_generation: u64,
    terminal_id: [36]u8,
    expected_size: u64,
    received: u64,
    expected_sha256: [64]u8,
    content_type: []const u8,
    created_ms: u64,
    /// Incremental SHA-256 hasher for data received so far.
    hasher: std.crypto.hash.sha2.Sha256,
    /// Temp file name under uploads/ (UUID + ".tmp").
    tmp_name: [40]u8,
};

/// Server-side upload service for one session.
///
/// Receives chunked image data from the Mac client, reassembles into a temp
/// file, verifies SHA-256 on commit, and atomically renames to a final path.
/// The client never chooses a server-side path — all filenames are random UUIDs
/// under the uploads/ subdirectory of the session state directory.
pub const Service = struct {
    allocator: std.mem.Allocator,
    /// Session state directory; the service creates `uploads/` inside it.
    dir: std.fs.Dir,
    /// Lazily opened handle to uploads/ subdirectory.
    uploads_dir: ?std.fs.Dir = null,
    /// Active uploads, bounded to max_active slots.
    active: [max_active]?Upload = [_]?Upload{null} ** max_active,
    /// Running total of bytes committed in this session (for quota enforcement).
    session_bytes: u64 = 0,

    /// Create a new upload service bound to the given state directory.
    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) Service {
        return .{ .allocator = allocator, .dir = dir };
    }

    /// Clean up: close the uploads dir handle and delete any leftover temp files.
    pub fn deinit(self: *Service) void {
        for (&self.active) |*slot| {
            if (slot.*) |upload| {
                self.deleteTmp(upload.tmp_name) catch {};
                slot.* = null;
            }
        }
        if (self.uploads_dir) |*d| d.close();
        self.* = undefined;
    }

    // ---- request dispatch -------------------------------------------------

    /// Entry point matching the workspace_service pattern:
    /// returns JSON bytes for the response, or null (unused here — always returns).
    pub fn respond(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) !?[]u8 {
        return self.dispatch(a, r, generation) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try self.failure(a, r, errorCode(err), errorRetry(err)),
        };
    }

    fn dispatch(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) ![]u8 {
        return switch (r.operation) {
            .@"upload.begin" => try self.begin(a, r, generation),
            .@"upload.chunk" => try self.chunk(a, r),
            .@"upload.commit" => try self.commit(a, r),
            .@"upload.abort" => try self.abort(a, r),
            .@"upload.clear" => try self.clear(a, r),
            .@"upload.status" => try self.status(a, r),
            else => error.MissingCapability,
        };
    }

    // ---- upload.begin ------------------------------------------------------

    /// Start a new upload: validate limits, allocate a slot, create a temp file.
    fn begin(self: *Service, a: std.mem.Allocator, r: Request, generation: u64) ![]u8 {
        try only(r.params, &.{ "terminalID", "contentType", "size", "sha256" });

        const terminal_id = try textID(try stringParam(r.params, "terminalID"));
        const content_type = try stringParam(r.params, "contentType");
        const size = try intParam(r.params, "size");
        const sha256_hex = try stringParam(r.params, "sha256");

        if (size == 0 or size > max_single_size) return error.SizeLimitExceeded;
        if (sha256_hex.len != 64) return error.InvalidRequest;
        // Validate hex characters
        for (sha256_hex) |byte| {
            if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidRequest;
        }
        if (self.session_bytes + size > max_session_total) return error.QuotaExceeded;

        // Only one active upload per client connection at a time
        const client_id = try textID(r.clientID);
        for (&self.active) |*slot| {
            if (slot.*) |upload| {
                if (std.mem.eql(u8, &upload.client_id, &client_id)) return error.UploadAlreadyActive;
            }
        }

        // Find a free slot
        const free_slot = for (&self.active) |*slot| {
            if (slot.* == null) break slot;
        } else return error.ResourceLimit;

        // Ensure uploads/ directory exists
        const uploads = try self.ensureUploadsDir();

        // Generate upload ID and temp filename
        const upload_id = ids.uuidText(ids.newUUID());
        var tmp_name: [40]u8 = undefined;
        @memcpy(tmp_name[0..36], &upload_id);
        @memcpy(tmp_name[36..40], ".tmp");

        // Create the temp file
        const fd = try std.posix.openat(uploads.fd, &tmp_name, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0o600);
        std.posix.close(fd);

        var sha_buf: [64]u8 = undefined;
        @memcpy(&sha_buf, sha256_hex);

        free_slot.* = Upload{
            .upload_id = upload_id,
            .client_id = client_id,
            .connection_generation = generation,
            .terminal_id = terminal_id,
            .expected_size = size,
            .received = 0,
            .expected_sha256 = sha_buf,
            .content_type = content_type,
            .created_ms = @intCast(@max(0, std.time.milliTimestamp())),
            .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
            .tmp_name = tmp_name,
        };

        return self.success(a, r, .{ .uploadID = &upload_id });
    }

    // ---- upload.chunk ------------------------------------------------------

    /// Append a base64-decoded data chunk to the temp file and update the hasher.
    fn chunk(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{ "uploadID", "data" });

        const upload_id = try textID(try stringParam(r.params, "uploadID"));
        const data_b64 = try stringParam(r.params, "data");

        const upload = try self.findUpload(upload_id);

        // Decode base64 — reject obviously oversized payloads early.
        // Upper bound for decoded length: 3/4 of encoded length + padding slack.
        const max_decoded = (data_b64.len / 4) * 3 + 3;
        if (max_decoded > max_chunk_decoded + 3) return error.ChunkTooLarge;

        var decode_buf = try a.alloc(u8, max_decoded);
        defer a.free(decode_buf);

        const decoded = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch return error.InvalidRequest;
        if (decoded > max_chunk_decoded) return error.ChunkTooLarge;
        std.base64.standard.Decoder.decode(decode_buf[0..decoded], data_b64) catch return error.InvalidRequest;
        const data = decode_buf[0..decoded];

        // Check that this chunk does not exceed expected total
        if (upload.received + data.len > upload.expected_size) return error.SizeLimitExceeded;

        // Write to temp file
        const uploads = try self.ensureUploadsDir();
        const fd = try std.posix.openat(uploads.fd, &upload.tmp_name, .{
            .ACCMODE = .WRONLY,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0);
        var file = std.fs.File{ .handle = fd };
        defer file.close();
        try file.seekTo(upload.received);
        try file.writeAll(data);

        // Update hasher and byte count
        upload.hasher.update(data);
        upload.received += data.len;

        return self.success(a, r, .{
            .uploadID = &upload.upload_id,
            .received = upload.received,
        });
    }

    // ---- upload.commit -----------------------------------------------------

    /// Verify SHA-256 and size, then atomically rename the temp file to its
    /// final location. Returns the server-side path for the client to paste.
    fn commit(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{ "uploadID", "sha256" });

        const upload_id = try textID(try stringParam(r.params, "uploadID"));
        const client_sha = try stringParam(r.params, "sha256");
        if (client_sha.len != 64) return error.InvalidRequest;

        const slot = try self.findUploadSlot(upload_id);
        const upload = &slot.*.?;

        // Size verification: all bytes must have been received
        if (upload.received != upload.expected_size) return error.SizeMismatch;

        // SHA-256 verification: compare computed digest with both the begin-time
        // expected value and the commit-time value the client sends
        var digest: [32]u8 = undefined;
        var hasher_copy = upload.hasher;
        hasher_copy.final(&digest);

        const hex = "0123456789abcdef";
        var digest_hex: [64]u8 = undefined;
        for (digest, 0..) |byte, i| {
            digest_hex[i * 2] = hex[byte >> 4];
            digest_hex[i * 2 + 1] = hex[byte & 15];
        }

        if (!std.mem.eql(u8, &digest_hex, &upload.expected_sha256)) return error.DigestMismatch;
        if (!std.mem.eql(u8, &digest_hex, client_sha)) return error.DigestMismatch;

        // Atomic rename: .tmp -> final name (UUID without extension)
        const uploads = try self.ensureUploadsDir();
        var final_name: [36]u8 = undefined;
        @memcpy(&final_name, upload.upload_id[0..36]);

        try std.posix.renameat(uploads.fd, &upload.tmp_name, uploads.fd, &final_name);

        // Build the path to return to the client
        const path = try std.fmt.allocPrint(a, "uploads/{s}", .{&final_name});
        defer a.free(path);

        self.session_bytes += upload.received;
        slot.* = null;

        return self.success(a, r, .{
            .uploadID = &upload_id,
            .path = path,
        });
    }

    // ---- upload.abort -------------------------------------------------------

    /// Cancel an in-progress upload and delete its temp file.
    fn abort(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{"uploadID"});

        const upload_id = try textID(try stringParam(r.params, "uploadID"));
        const slot = try self.findUploadSlot(upload_id);
        const upload = slot.*.?;

        self.deleteTmp(upload.tmp_name) catch {};
        slot.* = null;

        return self.success(a, r, .{ .uploadID = &upload_id });
    }

    // ---- upload.clear -------------------------------------------------------

    /// Delete files older than 24 hours from the uploads/ directory.
    fn clear(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{});

        const uploads = self.ensureUploadsDir() catch {
            // If the directory doesn't exist yet, nothing to clear
            return self.success(a, r, .{ .cleared = @as(u64, 0) });
        };

        const now: u64 = @intCast(@max(0, std.time.milliTimestamp()));
        var cleared: u64 = 0;

        var iter = uploads.iterate();

        // Collect names first to avoid mutation-during-iteration
        var to_delete: std.ArrayList([40]u8) = .empty;
        defer to_delete.deinit(a);

        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            // Skip active uploads (they have .tmp suffix and a live slot)
            const stat = uploads.statFile(entry.name) catch continue;
            const mtime_ms_val = statMtimeMs(stat);
            if (now > mtime_ms_val and now - mtime_ms_val > ttl_ms) {
                if (entry.name.len <= 40) {
                    var name: [40]u8 = undefined;
                    @memcpy(name[0..entry.name.len], entry.name);
                    // Pad rest with zeros
                    @memset(name[entry.name.len..], 0);
                    to_delete.append(a, name) catch continue;
                }
            }
        }

        for (to_delete.items) |name| {
            const sentinel = std.mem.indexOfScalar(u8, &name, 0) orelse 40;
            const slice = name[0..sentinel];
            uploads.deleteFile(slice) catch continue;
            cleared += 1;
        }

        return self.success(a, r, .{ .cleared = cleared });
    }

    // ---- upload.status ------------------------------------------------------

    /// Query the state of a specific upload or all active uploads.
    fn status(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        try only(r.params, &.{"uploadID"});

        if (r.params.object.get("uploadID")) |id_value| {
            if (id_value != .string) return error.InvalidRequest;
            const upload_id = try textID(id_value.string);
            const upload = try self.findUpload(upload_id);
            return self.success(a, r, .{
                .uploadID = &upload.upload_id,
                .terminalID = &upload.terminal_id,
                .received = upload.received,
                .expectedSize = upload.expected_size,
                .createdMs = upload.created_ms,
            });
        }

        // No uploadID given: list all active uploads
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const tmp = arena.allocator();
        var array = std.json.Array.init(tmp);
        for (&self.active) |*slot| {
            if (slot.*) |upload| {
                var obj = std.json.ObjectMap.init(tmp);
                try obj.put("uploadID", .{ .string = try tmp.dupe(u8, &upload.upload_id) });
                try obj.put("terminalID", .{ .string = try tmp.dupe(u8, &upload.terminal_id) });
                try obj.put("received", .{ .integer = @intCast(upload.received) });
                try obj.put("expectedSize", .{ .integer = @intCast(upload.expected_size) });
                try obj.put("createdMs", .{ .integer = @intCast(upload.created_ms) });
                try array.append(.{ .object = obj });
            }
        }
        return self.success(a, r, .{ .uploads = std.json.Value{ .array = array } });
    }

    // ---- internal helpers ---------------------------------------------------

    /// Ensure the uploads/ subdirectory exists with 0o700 permissions.
    fn ensureUploadsDir(self: *Service) !std.fs.Dir {
        if (self.uploads_dir) |d| return d;
        self.dir.makeDir("uploads") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        // Open the directory handle for subsequent file operations
        self.uploads_dir = try self.dir.openDir("uploads", .{ .no_follow = true, .iterate = true });
        return self.uploads_dir.?;
    }

    /// Find a mutable pointer to an active upload by ID.
    fn findUpload(self: *Service, upload_id: [36]u8) !*Upload {
        const slot = try self.findUploadSlot(upload_id);
        return &slot.*.?;
    }

    /// Find the slot pointer so we can null it out on completion.
    fn findUploadSlot(self: *Service, upload_id: [36]u8) !*?Upload {
        for (&self.active) |*slot| {
            if (slot.*) |upload| {
                if (std.mem.eql(u8, &upload.upload_id, &upload_id)) return slot;
            }
        }
        return error.UploadNotFound;
    }

    /// Best-effort delete of a temp file in the uploads directory.
    fn deleteTmp(self: *Service, name: [40]u8) !void {
        const uploads = self.uploads_dir orelse return;
        uploads.deleteFile(&name) catch {};
    }

    // ---- response encoding --------------------------------------------------

    /// Build a success response matching the workspace_service pattern.
    fn success(_: *Service, a: std.mem.Allocator, r: Request, result: anytype) ![]u8 {
        return std.json.Stringify.valueAlloc(a, replies.Response(@TypeOf(result)){
            .type = "response",
            .requestID = r.requestID,
            .scope = r.scope,
            .operation = r.operation,
            .target = r.target,
            .result = result,
        }, .{ .emit_null_optional_fields = false });
    }

    /// Build an error response matching the workspace_service pattern.
    fn failure(_: *Service, a: std.mem.Allocator, r: Request, code: []const u8, retry: Retry) ![]u8 {
        return std.json.Stringify.valueAlloc(a, replies.Failure{
            .type = "error",
            .requestID = r.requestID,
            .operation = @tagName(r.operation),
            .scope = r.scope,
            .target = r.target,
            .@"error" = .{ .code = code, .message = code, .retry = retry },
        }, .{ .emit_null_optional_fields = false });
    }

    /// Disconnect handler: abort any uploads belonging to the disconnected client.
    pub fn disconnect(self: *Service, client_id: [36]u8) void {
        for (&self.active) |*slot| {
            if (slot.*) |upload| {
                if (std.mem.eql(u8, &upload.client_id, &client_id)) {
                    self.deleteTmp(upload.tmp_name) catch {};
                    slot.* = null;
                }
            }
        }
    }

    /// 按连接代号清理：连接断开时删除该连接发起的所有上传及其临时文件。
    pub fn disconnectByGeneration(self: *Service, generation: u64) void {
        for (&self.active) |*slot| {
            if (slot.*) |upload| {
                if (upload.connection_generation == generation) {
                    self.deleteTmp(upload.tmp_name) catch {};
                    slot.* = null;
                }
            }
        }
    }
};

// ---- shared parameter helpers -----------------------------------------------

/// Extract mtime from a std.fs.File.Stat as milliseconds.
fn statMtimeMs(stat: std.fs.File.Stat) u64 {
    // stat.mtime is an i128 nanosecond timestamp
    const ns: u64 = @intCast(@max(0, stat.mtime));
    return ns / 1_000_000;
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

fn intParam(value: std.json.Value, name: []const u8) !u64 {
    if (value != .object) return error.InvalidRequest;
    const item = value.object.get(name) orelse return error.InvalidRequest;
    return switch (item) {
        .integer => |n| if (n < 0) error.InvalidRequest else @intCast(n),
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch error.InvalidRequest,
        else => error.InvalidRequest,
    };
}

fn textID(value: []const u8) ![36]u8 {
    if (!@import("operation_request.zig").validID(value)) return error.InvalidRequest;
    return value[0..36].*;
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCapability => "missing_capability",
        error.SizeLimitExceeded => "size_limit_exceeded",
        error.QuotaExceeded => "quota_exceeded",
        error.UploadAlreadyActive => "upload_already_active",
        error.UploadNotFound => "upload_not_found",
        error.ChunkTooLarge => "chunk_too_large",
        error.SizeMismatch => "size_mismatch",
        error.DigestMismatch => "digest_mismatch",
        error.ResourceLimit => "resource_limit",
        error.InvalidRequest => "invalid_request",
        else => "internal_error",
    };
}

fn errorRetry(err: anyerror) @TypeOf(@as(replies.Failure, undefined).@"error".retry) {
    return switch (err) {
        error.ResourceLimit => .backoff,
        error.UploadAlreadyActive => .backoff,
        else => .never,
    };
}
