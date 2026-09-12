const std = @import("std");
const StateDirectory = @import("state_directory.zig").StateDirectory;
const Operation = @import("operation_kind.zig").Operation;
const name = "idempotency.log";
const staging = "idempotency.pending";
pub const retention_ms: u64 = 86_400_000;
pub const Limits = struct { entries: usize = 10000, bytes: usize = 16 * 1024 * 1024, response_bytes: usize = 65536 };
pub const Key = struct { client_id: [16]u8, request_id: [16]u8 };
pub const Intent = struct {
    key: Key,
    /// Optional for compatibility with AIL1 records written before status queries.
    operation: ?Operation = null,
    /// Hash canonical operation, arguments, expected revision and original created_ms.
    fingerprint: [32]u8,
    epoch: [16]u8,
    terminal_id: ?[16]u8 = null,
    created_ms: u64,
};
pub const Query = struct {
    operation: ?Operation = null,
    state: enum { pending, committed, failed, unknown, expired } = .unknown,
    terminal_id: ?[16]u8 = null,
    epoch: ?[16]u8 = null,
};
const Entry = struct { intent: Intent, response: ?[]const u8 = null };
const Snapshot = struct { clock_ms: u64, entries: []const Entry };
pub const Decision = union(enum) {
    reserved,
    conflict,
    request_expired,
    outcome_unknown,
    replay: struct { response: []const u8, resources_invalidated: bool, terminal_id: ?[16]u8 },
};

/// Serialized owner must hold StateDirectory lock for this object's lifetime.
/// Only .reserved authorizes execution. Persist completion before acknowledging.
/// Disk errors poison the writer; reopen before any further mutation. Pending
/// intents remain unknown even in the same epoch and must never execute again.
pub const Log = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    limits: Limits,
    entries: std.ArrayList(Entry) = .empty,
    clock_ms: u64 = 0,
    poisoned: bool = false,

    pub fn open(allocator: std.mem.Allocator, state: *StateDirectory, limits: Limits) !Log {
        if (limits.entries == 0 or limits.entries > 10000 or limits.bytes < 1024 or limits.bytes > 256 * 1024 * 1024 or limits.response_bytes > limits.bytes) return error.InvalidLimits;
        var self = Log{ .allocator = allocator, .dir = state.dir, .limits = limits };
        errdefer self.deinit();
        const fd = std.posix.openat(self.dir.fd, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0) catch |err| switch (err) {
            error.FileNotFound => {
                try discardStaging(self.dir);
                return self;
            },
            else => return err,
        };
        var file = std.fs.File{ .handle = fd };
        defer file.close();
        const stat = try std.posix.fstat(fd);
        try validateFile(stat);
        if (stat.size < 36 or stat.size > limits.bytes) return error.CorruptLog;
        const bytes = try file.readToEndAlloc(allocator, limits.bytes);
        defer allocator.free(bytes);
        if (bytes.len < 36 or !std.mem.eql(u8, bytes[0..4], "AIL1")) return error.CorruptLog;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[36..], &digest, .{});
        if (!std.mem.eql(u8, bytes[4..36], &digest)) return error.CorruptLog;
        const parsed = std.json.parseFromSlice(Snapshot, allocator, bytes[36..], .{ .allocate = .alloc_always }) catch return error.CorruptLog;
        defer parsed.deinit();
        if (parsed.value.entries.len > limits.entries) return error.CorruptLog;
        self.clock_ms = parsed.value.clock_ms;
        for (parsed.value.entries) |entry| {
            if (entry.intent.created_ms > self.clock_ms or self.index(entry.intent.key) != null) return error.CorruptLog;
            if (entry.response) |response| if (response.len > limits.response_bytes) return error.CorruptLog;
            var owned = entry;
            owned.response = if (entry.response) |response| try allocator.dupe(u8, response) else null;
            errdefer if (owned.response) |response| allocator.free(response);
            try self.entries.append(allocator, owned);
        }
        try discardStaging(self.dir);
        return self;
    }
    pub fn deinit(self: *Log) void {
        for (self.entries.items) |entry| if (entry.response) |response| self.allocator.free(response);
        self.entries.deinit(self.allocator);
    }
    fn index(self: *const Log, key: Key) ?usize {
        for (self.entries.items, 0..) |entry, i| if (std.meta.eql(entry.intent.key, key)) return i;
        return null;
    }
    /// Read-only client/request lookup: never reserves, persists, updates the
    /// writer clock or grants execution permission. A poisoned writer cannot
    /// prove whether its last persistence operation committed.
    pub fn query(self: *const Log, key: Key, now_ms: u64) !Query {
        if (self.poisoned) return .{};
        if (now_ms < self.clock_ms) return error.ClockRegression;
        const entry = self.entries.items[self.index(key) orelse return .{}];
        var result = Query{ .operation = entry.intent.operation, .state = .pending, .terminal_id = entry.intent.terminal_id, .epoch = entry.intent.epoch };
        if (entry.response) |response| {
            result.state = .unknown;
            // Decode only persisted response metadata; arbitrary legacy payloads
            // stay unknown. Unknown operation names never invent an enum value.
            const Metadata = struct {
                type: enum { response, @"error" },
                operation: Operation,
                result: ?std.json.Value = null,
                @"error": ?std.json.Value = null,
            };
            const parsed = std.json.parseFromSlice(Metadata, self.allocator, response, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    if (expired(entry.intent, now_ms)) result.state = .expired;
                    return result;
                },
            };
            defer parsed.deinit();
            const metadata = parsed.value;
            const valid = switch (metadata.type) {
                .response => metadata.result != null and metadata.@"error" == null,
                .@"error" => metadata.@"error" != null and metadata.@"error".? == .object and metadata.result == null,
            };
            if (valid and (entry.intent.operation == null or entry.intent.operation.? == metadata.operation)) {
                result.operation = metadata.operation;
                result.state = if (metadata.type == .response) .committed else .failed;
                if (metadata.@"error") |failure| {
                    if (failure.object.get("code")) |code| {
                        if (code == .string and std.mem.eql(u8, code.string, "outcome_unknown")) result.state = .unknown;
                    }
                }
            }
        }
        if (expired(entry.intent, now_ms)) result.state = .expired;
        return result;
    }
    /// Replay bytes are borrowed until mutation/deinit. Compare client-owned
    /// fingerprint/time only; server-generated epoch/resource ID come from the
    /// original record, so response loss does not require knowing the allocated ID.
    pub fn lookup(self: *Log, intent: Intent, current_epoch: [16]u8, now_ms: u64) !?Decision {
        if (self.poisoned) return error.LogRequiresReopen;
        if (now_ms < self.clock_ms) return error.ClockRegression;
        if (intent.created_ms > now_ms) return error.FutureRequest;
        self.clock_ms = now_ms;
        if (self.index(intent.key)) |i| {
            const entry = self.entries.items[i];
            if (!std.mem.eql(u8, &entry.intent.fingerprint, &intent.fingerprint) or entry.intent.created_ms != intent.created_ms) return .conflict;
            if (expired(entry.intent, now_ms)) return .request_expired;
            if (entry.response) |response| return .{ .replay = .{ .response = response, .resources_invalidated = !std.mem.eql(u8, &entry.intent.epoch, &current_epoch), .terminal_id = entry.intent.terminal_id } };
            return .outcome_unknown;
        }
        if (expired(intent, now_ms)) return .request_expired;
        return null;
    }
    pub fn reserve(self: *Log, intent: Intent, current_epoch: [16]u8, now_ms: u64) !Decision {
        if (try self.lookup(intent, current_epoch, now_ms)) |decision| return decision;
        if (!std.mem.eql(u8, &intent.epoch, &current_epoch)) return error.StaleEpoch;
        var next: std.ArrayList(Entry) = .empty;
        defer next.deinit(self.allocator);
        for (self.entries.items) |entry| if (!expired(entry.intent, now_ms)) try next.append(self.allocator, entry);
        if (next.items.len >= self.limits.entries) return error.LogCapacity;
        try next.append(self.allocator, .{ .intent = intent });
        try self.persist(next.items);
        for (self.entries.items) |entry| if (expired(entry.intent, now_ms)) {
            if (entry.response) |response| self.allocator.free(response);
        };
        self.entries.deinit(self.allocator);
        self.entries = next;
        next = .empty;
        return .reserved;
    }
    pub fn complete(self: *Log, key: Key, fingerprint: [32]u8, response: []const u8) !void {
        if (self.poisoned) return error.LogRequiresReopen;
        if (response.len > self.limits.response_bytes) return error.ResponseTooLarge;
        const i = self.index(key) orelse return error.IntentNotFound;
        const entry = &self.entries.items[i];
        if (!std.mem.eql(u8, &entry.intent.fingerprint, &fingerprint)) return error.RequestConflict;
        if (entry.response) |existing| {
            if (!std.mem.eql(u8, existing, response)) return error.RequestConflict;
            return;
        }
        const owned = try self.allocator.dupe(u8, response);
        errdefer self.allocator.free(owned);
        entry.response = owned;
        self.persist(self.entries.items) catch |err| {
            entry.response = null;
            return err;
        };
    }
    fn persist(self: *Log, entries: []const Entry) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, Snapshot{ .clock_ms = self.clock_ms, .entries = entries }, .{});
        defer self.allocator.free(json);
        if (json.len > self.limits.bytes - 36) return error.LogCapacity;
        errdefer self.poisoned = true;
        try discardStaging(self.dir);
        const stat = std.posix.fstatat(self.dir.fd, name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat) |existing| try validateFile(existing);
        const fd = try std.posix.openat(self.dir.fd, staging, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
        var file = std.fs.File{ .handle = fd };
        defer file.close();
        try validateFile(try std.posix.fstat(fd));
        var header: [36]u8 = undefined;
        @memcpy(header[0..4], "AIL1");
        std.crypto.hash.sha2.Sha256.hash(json, header[4..36], .{});
        try file.writeAll(&header);
        try file.writeAll(json);
        try file.sync();
        try self.dir.rename(staging, name);
        try std.posix.fsync(self.dir.fd);
    }
};
fn expired(intent: Intent, now_ms: u64) bool {
    return now_ms >= intent.created_ms and now_ms - intent.created_ms >= retention_ms;
}
fn validateFile(stat: std.posix.Stat) !void {
    if (!std.posix.S.ISREG(stat.mode) or stat.uid != std.posix.geteuid() or stat.mode & 0o777 != 0o600 or stat.nlink != 1) return error.UnsafeLogFile;
}
fn discardStaging(dir: std.fs.Dir) !void {
    const stat = std.posix.fstatat(dir.fd, staging, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try validateFile(stat);
    try dir.deleteFile(staging);
}
fn fixture(n: u8) Intent {
    return .{ .key = .{ .client_id = [_]u8{1} ** 16, .request_id = [_]u8{n} ** 16 }, .fingerprint = [_]u8{2} ** 32, .epoch = [_]u8{3} ** 16, .terminal_id = [_]u8{4} ** 16, .created_ms = 10 };
}
test "durable pending cannot reexecute and completed replay reports old epoch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    var log = try Log.open(std.testing.allocator, &state, .{});
    const a = fixture(1);
    try std.testing.expectEqual(Decision.reserved, try log.reserve(a, a.epoch, 10));
    log.deinit();
    log = try Log.open(std.testing.allocator, &state, .{});
    try std.testing.expectEqual(Decision.outcome_unknown, try log.reserve(a, a.epoch, 11));
    var conflict = a;
    conflict.fingerprint[0] ^= 1;
    try std.testing.expectEqual(Decision.conflict, try log.reserve(conflict, a.epoch, 11));
    try log.complete(a.key, a.fingerprint, "created");
    log.deinit();
    log = try Log.open(std.testing.allocator, &state, .{});
    defer log.deinit();
    const replay = (try log.lookup(a, [_]u8{9} ** 16, 12)).?.replay;
    try std.testing.expectEqualStrings("created", replay.response);
    try std.testing.expect(replay.resources_invalidated);
    var retry = a;
    retry.epoch = [_]u8{9} ** 16;
    retry.terminal_id = null;
    const recovered = (try log.reserve(retry, retry.epoch, 12)).replay;
    try std.testing.expectEqualDeep(a.terminal_id, recovered.terminal_id);
    try log.complete(a.key, a.fingerprint, "created");
    try std.testing.expectError(error.RequestConflict, log.complete(a.key, a.fingerprint, "other"));
}
test "capacity expiry future and clock regression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    var log = try Log.open(std.testing.allocator, &state, .{ .entries = 1 });
    defer log.deinit();
    const a = fixture(1);
    var b = fixture(2);
    try std.testing.expectError(error.FutureRequest, log.reserve(a, a.epoch, 9));
    _ = try log.reserve(a, a.epoch, 10);
    try std.testing.expectError(error.LogCapacity, log.reserve(b, b.epoch, 11));
    try std.testing.expectError(error.ClockRegression, log.reserve(a, a.epoch, 10));
    b.created_ms += retention_ms;
    _ = try log.reserve(b, b.epoch, b.created_ms);
    try std.testing.expectEqual(Decision.request_expired, try log.reserve(a, a.epoch, b.created_ms));
}
test "partial staging recovery and corrupt committed data fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    var pending = try state.dir.createFile(staging, .{ .mode = 0o600 });
    try pending.writeAll("partial");
    pending.close();
    var log = try Log.open(std.testing.allocator, &state, .{});
    const a = fixture(1);
    _ = try log.reserve(a, a.epoch, 10);
    log.deinit();
    var damaged = try state.dir.createFile(name, .{ .mode = 0o600 });
    try damaged.writeAll("corrupt");
    damaged.close();
    try std.testing.expectError(error.CorruptLog, Log.open(std.testing.allocator, &state, .{}));
}
test "unsafe staging stops mutation and poisons writer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    var log = try Log.open(std.testing.allocator, &state, .{});
    defer log.deinit();
    try state.dir.symLink("outside", staging, .{});
    const a = fixture(1);
    try std.testing.expectError(error.UnsafeLogFile, log.reserve(a, a.epoch, 10));
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);
    try std.testing.expectError(error.LogRequiresReopen, log.reserve(a, a.epoch, 11));
    try std.testing.expectError(error.FileNotFound, state.dir.statFile("outside"));
}

test "committed permissions links and checksum damage are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    try state.dir.symLink("outside", name, .{});
    if (Log.open(std.testing.allocator, &state, .{})) |value| {
        var accidental = value;
        accidental.deinit();
        return error.ExpectedFailure;
    } else |_| {}
    try state.dir.deleteFile(name);
    var log = try Log.open(std.testing.allocator, &state, .{});
    const a = fixture(1);
    _ = try log.reserve(a, a.epoch, 10);
    log.deinit();
    var file = try state.dir.openFile(name, .{ .mode = .read_write });
    try file.chmod(0o644);
    try std.testing.expectError(error.UnsafeLogFile, Log.open(std.testing.allocator, &state, .{}));
    try file.chmod(0o600);
    try file.pwriteAll("X", 40);
    file.close();
    try std.testing.expectError(error.CorruptLog, Log.open(std.testing.allocator, &state, .{}));
}

test "failed completion remains unknown after reopen and does not repeat mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    var log = try Log.open(std.testing.allocator, &state, .{});
    const a = fixture(1);
    _ = try log.reserve(a, a.epoch, 10);
    // An unsafe staging path deterministically injects a persistence failure.
    try state.dir.symLink("outside", staging, .{});
    try std.testing.expectError(error.UnsafeLogFile, log.complete(a.key, a.fingerprint, "created"));
    log.deinit();
    try state.dir.deleteFile(staging);
    var partial = try state.dir.createFile(staging, .{ .mode = 0o600 });
    try partial.writeAll("AIL1 interrupted replacement");
    partial.close();
    log = try Log.open(std.testing.allocator, &state, .{});
    defer log.deinit();
    try std.testing.expectEqual(Decision.outcome_unknown, try log.reserve(a, a.epoch, 11));
}

test "durable query pending committed reopen expiry client boundary and poison" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    var log = try Log.open(std.testing.allocator, &state, .{});
    var intent = fixture(1);
    intent.operation = .@"terminal.create";
    _ = try log.reserve(intent, intent.epoch, 10);
    const pending = try log.query(intent.key, 11);
    try std.testing.expectEqual(.pending, pending.state);
    try std.testing.expectEqual(intent.operation, pending.operation);
    try std.testing.expectEqualDeep(intent.terminal_id, pending.terminal_id);
    try std.testing.expectEqualDeep(@as(?[16]u8, intent.epoch), pending.epoch);
    try std.testing.expectEqual(@as(u64, 10), log.clock_ms);
    var other = intent.key;
    other.client_id[0] ^= 1;
    try std.testing.expectEqual(.unknown, (try log.query(other, 11)).state);
    log.deinit();
    log = try Log.open(std.testing.allocator, &state, .{});
    try std.testing.expectEqual(.pending, (try log.query(intent.key, 11)).state);
    try log.complete(intent.key, intent.fingerprint, "{\"type\":\"response\",\"operation\":\"terminal.create\",\"result\":{}}");
    log.deinit();
    log = try Log.open(std.testing.allocator, &state, .{});
    defer log.deinit();
    try std.testing.expectEqual(.committed, (try log.query(intent.key, 12)).state);
    try std.testing.expectEqual(.expired, (try log.query(intent.key, intent.created_ms + retention_ms)).state);
    try std.testing.expectEqual(@as(u64, 10), log.clock_ms);
    log.poisoned = true;
    const unknown = try log.query(intent.key, 12);
    try std.testing.expectEqual(.unknown, unknown.state);
    try std.testing.expect(unknown.operation == null and unknown.terminal_id == null and unknown.epoch == null);
}

test "durable query reads legacy missing operation and rejects invented outcomes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state = try StateDirectory.acquire(tmp.dir, "session");
    defer state.deinit();
    var log = try Log.open(std.testing.allocator, &state, .{});
    const intent = fixture(1);
    _ = try log.reserve(intent, intent.epoch, 10);
    try log.complete(intent.key, intent.fingerprint, "{\"type\":\"error\",\"operation\":\"terminal.create\",\"error\":{\"code\":\"failed\"}}");
    // Rewrite the test fixture as an actual legacy AIL1 payload with the field
    // absent, including a valid digest, rather than merely using operation:null.
    const original = try state.dir.readFileAlloc(std.testing.allocator, name, 65536);
    defer std.testing.allocator.free(original);
    const needle = "\"operation\":null,";
    const position = std.mem.indexOf(u8, original[36..], needle) orelse return error.MissingFixtureField;
    const payload = try std.mem.concat(std.testing.allocator, u8, &.{ original[36..][0..position], original[36..][position + needle.len ..] });
    defer std.testing.allocator.free(payload);
    var header: [36]u8 = undefined;
    @memcpy(header[0..4], "AIL1");
    std.crypto.hash.sha2.Sha256.hash(payload, header[4..36], .{});
    var file = try state.dir.createFile(name, .{ .mode = 0o600 });
    try file.writeAll(&header);
    try file.writeAll(payload);
    file.close();
    log.deinit();
    log = try Log.open(std.testing.allocator, &state, .{});
    defer log.deinit();
    const query = try log.query(intent.key, 11);
    try std.testing.expectEqual(.failed, query.state);
    try std.testing.expectEqual(@as(?Operation, .@"terminal.create"), query.operation);
    const unknown_intent = fixture(2);
    _ = try log.reserve(unknown_intent, unknown_intent.epoch, 11);
    try log.complete(unknown_intent.key, unknown_intent.fingerprint, "created");
    const unknown = try log.query(unknown_intent.key, 11);
    try std.testing.expectEqual(.unknown, unknown.state);
    try std.testing.expect(unknown.operation == null);
}
