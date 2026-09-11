const std = @import("std");

/// Disk screen history: periodic VT screen snapshots persisted to per-terminal
/// files under the session state directory. Default off; when enabled, each
/// terminal's visible screen is periodically serialized to `history/<terminalID>.hist`.
/// Quota management limits total disk usage; cleanup removes oldest entries first.
pub const Config = struct {
    enabled: bool = false,
    /// Maximum bytes per terminal history file.
    per_terminal_limit: usize = 4 * 1024 * 1024, // 4 MiB
    /// Maximum total bytes across all terminal history files.
    session_limit: usize = 64 * 1024 * 1024, // 64 MiB
    /// Interval between snapshots in milliseconds.
    snapshot_interval_ms: u64 = 5000,
    /// Exclude terminals with this flag set (incognito/sensitive).
    respect_exclude: bool = true,
};

/// Marker in terminal data indicating this content is historical, not live.
pub const HistoryMarker = struct {
    is_history: bool = false,
    captured_at_ms: u64 = 0,
};

const magic = "ASTH";
const format_version: u8 = 1;
// magic(4) + version(1) + captured_at_ms(8) + data_len(4)
const header_len = 4 + 1 + 8 + 4;
const history_dir_name = "history";
const file_suffix = ".hist";
const staging_suffix = ".hist.tmp";
const name_len = 36 + file_suffix.len;
const staging_name_len = 36 + staging_suffix.len;

/// Build the final `<terminalID>.hist` filename into a caller-owned buffer.
fn fileName(id: [36]u8, buf: *[name_len]u8) []const u8 {
    @memcpy(buf[0..36], &id);
    @memcpy(buf[36..], file_suffix);
    return buf;
}

/// Build the staging `<terminalID>.hist.tmp` filename into a caller-owned buffer.
fn stagingName(id: [36]u8, buf: *[staging_name_len]u8) []const u8 {
    @memcpy(buf[0..36], &id);
    @memcpy(buf[36..], staging_suffix);
    return buf;
}

/// Periodic per-terminal disk snapshot writer, reader and quota enforcer.
/// The caller supplies an already-open session state directory; the `history/`
/// subdirectory is created lazily, only once a snapshot is actually persisted,
/// so a disabled or never-triggered writer leaves no trace on disk.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    config: Config,
    /// Timestamp of the last snapshot written by this Writer, across all
    /// terminals. This is a deliberate global cadence gate (matching the
    /// struct's single field), not a per-terminal timer.
    last_snapshot_ms: u64 = 0,
    total_bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, state_dir: std.fs.Dir, config: Config) !Writer {
        return .{ .allocator = allocator, .dir = state_dir, .config = config };
    }

    pub fn deinit(self: *Writer) void {
        self.* = undefined;
    }

    /// Open `history/` if it already exists; returns null rather than creating
    /// it, so read-only paths never conjure the directory into existence.
    fn openHistoryDirIfExists(self: *Writer) !?std.fs.Dir {
        return self.dir.openDir(history_dir_name, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    /// Create (if missing) and open `history/` with private 0700 permissions.
    fn ensureHistoryDir(self: *Writer) !std.fs.Dir {
        std.posix.mkdirat(self.dir.fd, history_dir_name, 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return self.dir.openDir(history_dir_name, .{ .iterate = true });
    }

    /// Write a screen snapshot for the given terminal if enough time has passed.
    /// No-op if history is disabled or the terminal is excluded.
    pub fn maybePersist(self: *Writer, terminal_id: [36]u8, screen_text: []const u8, now_ms: u64, excluded: bool) !void {
        if (!self.config.enabled) return;
        if (self.config.respect_exclude and excluded) return;
        // Zero means "never snapshotted yet"; always allow the first write so a
        // freshly enabled session does not wait a full interval for coverage.
        if (self.last_snapshot_ms != 0 and now_ms >= self.last_snapshot_ms and
            now_ms - self.last_snapshot_ms < self.config.snapshot_interval_ms) return;
        // Per-terminal quota keeps only the most recent bytes of the screen.
        const data = if (screen_text.len > self.config.per_terminal_limit)
            screen_text[screen_text.len - self.config.per_terminal_limit ..]
        else
            screen_text;
        try self.writeFile(terminal_id, data, now_ms);
        self.last_snapshot_ms = now_ms;
        try self.enforceQuota();
    }

    /// Atomically stage-then-rename a single terminal's snapshot file.
    fn writeFile(self: *Writer, terminal_id: [36]u8, data: []const u8, captured_at_ms: u64) !void {
        var dir = try self.ensureHistoryDir();
        defer dir.close();
        var staging_buf: [staging_name_len]u8 = undefined;
        var final_buf: [name_len]u8 = undefined;
        const staging = stagingName(terminal_id, &staging_buf);
        const final = fileName(terminal_id, &final_buf);
        dir.deleteFile(staging) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        var file = try dir.createFile(staging, .{ .mode = 0o600 });
        defer file.close();
        var header: [header_len]u8 = undefined;
        @memcpy(header[0..4], magic);
        header[4] = format_version;
        std.mem.writeInt(u64, header[5..13], captured_at_ms, .little);
        std.mem.writeInt(u32, header[13..17], @intCast(data.len), .little);
        try file.writeAll(&header);
        try file.writeAll(data);
        try file.sync();
        try dir.rename(staging, final);
        try std.posix.fsync(dir.fd);
    }

    /// Read the history for a terminal. Returns null if no history exists.
    /// Truncated or corrupted files fail closed by returning null rather than
    /// propagating an error: history is best-effort and must never crash the
    /// session because a snapshot was interrupted mid-write.
    pub fn read(self: *Writer, terminal_id: [36]u8) !?[]u8 {
        var dir = (try self.openHistoryDirIfExists()) orelse return null;
        defer dir.close();
        var final_buf: [name_len]u8 = undefined;
        const final = fileName(terminal_id, &final_buf);
        const fd = std.posix.openat(dir.fd, final, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        var file = std.fs.File{ .handle = fd };
        defer file.close();
        const stat = std.posix.fstat(fd) catch return null;
        if (!std.posix.S.ISREG(stat.mode)) return null;
        const max_size = header_len + self.config.per_terminal_limit;
        if (stat.size < header_len or stat.size > max_size) return null;
        const bytes = file.readToEndAlloc(self.allocator, max_size) catch return null;
        defer self.allocator.free(bytes);
        if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], magic) or bytes[4] != format_version) return null;
        const data_len = std.mem.readInt(u32, bytes[13..17], .little);
        if (data_len > bytes.len - header_len) return null; // truncated/corrupt
        return try self.allocator.dupe(u8, bytes[header_len .. header_len + data_len]);
    }

    /// Clear history for a specific terminal, including any leftover staging file.
    pub fn clearTerminal(self: *Writer, terminal_id: [36]u8) void {
        var dir = (self.openHistoryDirIfExists() catch return) orelse return;
        defer dir.close();
        var final_buf: [name_len]u8 = undefined;
        var staging_buf: [staging_name_len]u8 = undefined;
        dir.deleteFile(fileName(terminal_id, &final_buf)) catch {};
        dir.deleteFile(stagingName(terminal_id, &staging_buf)) catch {};
    }

    /// Clear all history files. Best-effort: an unreadable directory is treated
    /// as already empty rather than surfacing an error to the caller.
    pub fn clearAll(self: *Writer) void {
        self.clearAllFallible() catch {};
    }

    fn clearAllFallible(self: *Writer) !void {
        var dir = (try self.openHistoryDirIfExists()) orelse return;
        defer dir.close();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        // Collect names before deleting: mutating a directory while iterating
        // it is not guaranteed safe across platforms.
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            try names.append(arena.allocator(), try arena.allocator().dupe(u8, entry.name));
        }
        for (names.items) |file_name| dir.deleteFile(file_name) catch {};
        self.total_bytes = 0;
    }

    const Item = struct {
        name: [name_len]u8,
        mtime: i128,
        size: u64,
    };

    /// Enforce quota by removing oldest files (by mtime) until the session's
    /// total is back under the configured limit.
    pub fn enforceQuota(self: *Writer) !void {
        var dir = (try self.openHistoryDirIfExists()) orelse return;
        defer dir.close();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var items: std.ArrayList(Item) = .empty;
        var total: u64 = 0;
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, file_suffix)) continue;
            const stat = dir.statFile(entry.name) catch continue;
            var item: Item = .{ .name = undefined, .mtime = stat.mtime, .size = stat.size };
            @memcpy(item.name[0..entry.name.len], entry.name);
            try items.append(arena.allocator(), item);
            total += stat.size;
        }
        std.mem.sort(Item, items.items, {}, struct {
            fn lessThan(_: void, a: Item, b: Item) bool {
                return a.mtime < b.mtime;
            }
        }.lessThan);
        var i: usize = 0;
        while (total > self.config.session_limit and i < items.items.len) : (i += 1) {
            const item = items.items[i];
            dir.deleteFile(&item.name) catch continue;
            total -= item.size;
        }
        self.total_bytes = total;
    }
};

fn testID(last: u8) [36]u8 {
    var id: [36]u8 = ("00000000-0000-0000-0000-00000000000" ++ [_]u8{'0'}).*;
    id[35] = last;
    return id;
}

test "write and read roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{ .enabled = true });
    defer writer.deinit();
    try writer.maybePersist(testID('1'), "hello screen", 1000, false);
    const read_back = (try writer.read(testID('1'))).?;
    defer std.testing.allocator.free(read_back);
    try std.testing.expectEqualStrings("hello screen", read_back);
}

test "disabled config produces no files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{ .enabled = false });
    defer writer.deinit();
    try writer.maybePersist(testID('1'), "hello", 1000, false);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(history_dir_name, .{}));
    try std.testing.expectEqual(@as(?[]u8, null), try writer.read(testID('1')));
}

test "corrupted file returns null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{ .enabled = true });
    defer writer.deinit();
    try tmp.dir.makeDir(history_dir_name);
    var dir = try tmp.dir.openDir(history_dir_name, .{});
    defer dir.close();
    var final_buf: [name_len]u8 = undefined;
    var damaged = try dir.createFile(fileName(testID('1'), &final_buf), .{ .mode = 0o600 });
    try damaged.writeAll("not a valid history file");
    damaged.close();
    try std.testing.expectEqual(@as(?[]u8, null), try writer.read(testID('1')));
}

test "excluded terminal is skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{ .enabled = true });
    defer writer.deinit();
    try writer.maybePersist(testID('1'), "secret", 1000, true);
    try std.testing.expectEqual(@as(?[]u8, null), try writer.read(testID('1')));
}

test "quota enforcement removes oldest files first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{ .enabled = true, .session_limit = 40, .snapshot_interval_ms = 0 });
    defer writer.deinit();
    try writer.writeFile(testID('1'), "aaaaaaaaaa", 1000);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    try writer.writeFile(testID('2'), "bbbbbbbbbb", 1001);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    try writer.writeFile(testID('3'), "cccccccccc", 1002);
    try writer.enforceQuota();
    try std.testing.expect(writer.total_bytes <= 40);
    try std.testing.expectEqual(@as(?[]u8, null), try writer.read(testID('1')));
    const newest = (try writer.read(testID('3'))).?;
    defer std.testing.allocator.free(newest);
    try std.testing.expectEqualStrings("cccccccccc", newest);
}

test "clearTerminal and clearAll remove files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{ .enabled = true });
    defer writer.deinit();
    try writer.maybePersist(testID('1'), "first", 1000, false);
    try writer.maybePersist(testID('2'), "second", 6000, false);
    writer.clearTerminal(testID('1'));
    try std.testing.expectEqual(@as(?[]u8, null), try writer.read(testID('1')));
    const still_there = (try writer.read(testID('2'))).?;
    std.testing.allocator.free(still_there);
    writer.clearAll();
    try std.testing.expectEqual(@as(?[]u8, null), try writer.read(testID('2')));
}
