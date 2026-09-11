const std = @import("std");
const Geometry = @import("geometry.zig").Geometry;

/// Used only when neither the service environment nor request supplies PATH.
pub const default_path = "/usr/bin:/bin:/usr/sbin:/sbin";
pub const Request = struct {
    cwd: []const u8,
    argv: []const []const u8,
    environment: []const []const u8 = &.{},
    geometry: Geometry = .{ .rows = 24, .columns = 80 },
};

/// Owns every launch string. No input slice is retained, and preparation never
/// starts a process. Call deinit after Pool.create has consumed asLaunch().
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    cwd: []const u8,
    argv: []const []const u8,
    environment: []const []const u8,
    geometry: Geometry,

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn asLaunch(self: *const Prepared) @import("terminal_pool.zig").Launch {
        return .{ .cwd = self.cwd, .argv = self.argv, .environment = self.environment, .geometry = self.geometry };
    }
};

/// Merge trusted execution-machine environment with validated request overrides.
/// Duplicate names within either source fail; an override replaces one inherited
/// value. Empty PATH is intentional (cwd), while absent PATH uses default_path.
/// Errors contain no argument or environment values. Filesystem checks are an
/// early rejection only: the actual exec remains authoritative after any race.
pub fn prepare(allocator: std.mem.Allocator, request: Request, inherited: []const []const u8) !Prepared {
    if (request.cwd.len == 0 or request.cwd.len > 4096 or !std.fs.path.isAbsolute(request.cwd) or hasNul(request.cwd)) return error.InvalidTerminalDirectory;
    if (request.argv.len == 0 or request.argv.len > 128 or request.argv[0].len == 0) return error.InvalidTerminalArguments;
    for (request.argv) |arg| if (arg.len > 4096 or hasNul(arg)) return error.InvalidTerminalArguments;
    try request.geometry.validate();
    try validateEnvironment(inherited);
    try validateEnvironment(request.environment);
    // Entering cwd requires search permission, not directory-listing permission.
    // The child chdir remains authoritative if permissions change after this check.
    const directory = std.fs.cwd().statFile(request.cwd) catch return error.InvalidTerminalDirectory;
    if (directory.kind != .directory) return error.InvalidTerminalDirectory;
    std.posix.access(request.cwd, std.posix.X_OK) catch return error.InvalidTerminalDirectory;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var environment: std.ArrayList([]const u8) = .empty;
    for (inherited) |item| try environment.append(a, try a.dupe(u8, item));
    for (request.environment) |item| {
        var replaced = false;
        for (environment.items) |*existing| {
            if (std.mem.eql(u8, name(existing.*), name(item))) {
                existing.* = try a.dupe(u8, item);
                replaced = true;
                break;
            }
        }
        if (!replaced) try environment.append(a, try a.dupe(u8, item));
    }
    var path: ?[]const u8 = null;
    for (environment.items) |item| if (std.mem.eql(u8, name(item), "PATH")) {
        path = item[5..];
        break;
    };
    if (path == null) try environment.append(a, "PATH=" ++ default_path);
    if (environment.items.len > 128) return error.InvalidTerminalEnvironment;
    const argv = try a.alloc([]const u8, request.argv.len);
    for (request.argv, 0..) |arg, index| argv[index] = try a.dupe(u8, arg);
    argv[0] = try resolveExecutable(a, request.cwd, argv[0], path orelse default_path);
    if (argv[0].len > 4096) return error.InvalidTerminalArguments;
    const owned_cwd = try a.dupe(u8, request.cwd);
    const owned_environment = try environment.toOwnedSlice(a);
    // Finish all allocations before moving the arena state into the result.
    return .{ .arena = arena, .cwd = owned_cwd, .argv = argv, .environment = owned_environment, .geometry = request.geometry };
}

fn hasNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}
fn name(item: []const u8) []const u8 {
    return item[0..std.mem.indexOfScalar(u8, item, '=').?];
}
fn validateEnvironment(items: []const []const u8) !void {
    if (items.len > 128) return error.InvalidTerminalEnvironment;
    for (items, 0..) |item, index| {
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse return error.InvalidTerminalEnvironment;
        if (eq == 0 or eq > 256 or item.len - eq - 1 > 8192 or hasNul(item)) return error.InvalidTerminalEnvironment;
        for (items[0..index]) |previous| if (std.mem.eql(u8, name(previous), item[0..eq])) return error.DuplicateEnvironmentName;
    }
}
fn executable(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    if (stat.kind != .file) return false;
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}
/// Resolve a program name to an absolute path via PATH lookup.
pub fn resolveExecutable(a: std.mem.Allocator, cwd: []const u8, program: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        const candidate = if (std.fs.path.isAbsolute(program)) try a.dupe(u8, program) else try std.fs.path.join(a, &.{ cwd, program });
        if (!executable(candidate)) return error.ExecutableUnavailable;
        return candidate;
    }
    var segments = std.mem.splitScalar(u8, path, ':');
    while (segments.next()) |segment| {
        // Preserve .. across symlinks: filesystem traversal, not lexical normalization.
        const candidate = if (std.fs.path.isAbsolute(segment)) try std.fs.path.join(a, &.{ segment, program }) else try std.fs.path.join(a, &.{ cwd, segment, program });
        if (executable(candidate)) return candidate;
    }
    return error.ExecutableUnavailable;
}

fn makeExecutable(dir: std.fs.Dir, path: []const u8) !void {
    var file = try dir.createFile(path, .{ .mode = 0o700 });
    defer file.close();
    try file.writeAll("#!/bin/sh\nexit 0\n");
}

test "launch preparation resolves literal relative PATH and owns merged values" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makeDir("bin space;$");
    try makeExecutable(temp.dir, "bin space;$/tool");
    const cwd = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);
    var value = "VALUE=request".*;
    var ready = try prepare(std.testing.allocator, .{ .cwd = cwd, .argv = &.{ "tool", "$(literal); spaced" }, .environment = &.{ "PATH=bin space;$", &value } }, &.{ "PATH=/missing", "VALUE=old", "KEEP=yes" });
    defer ready.deinit();
    value[6] = 'X';
    const expected = try std.fs.path.join(std.testing.allocator, &.{ cwd, "bin space;$/tool" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, ready.argv[0]);
    try std.testing.expectEqualStrings("$(literal); spaced", ready.argv[1]);
    try std.testing.expectEqualStrings("VALUE=request", ready.environment[1]);
    try std.testing.expectEqualStrings("KEEP=yes", ready.environment[2]);
}

test "launch preparation supports empty PATH and explicit relative executable" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try makeExecutable(temp.dir, "no-extension");
    const cwd = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);
    for ([_][]const u8{ "no-extension", "./no-extension" }) |program| {
        var ready = try prepare(std.testing.allocator, .{ .cwd = cwd, .argv = &.{program}, .environment = &.{"PATH="} }, &.{});
        defer ready.deinit();
        try std.testing.expect(std.mem.endsWith(u8, ready.argv[0], "/no-extension"));
    }
}

test "launch preparation rejects missing executable directory and invalid environment" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.ExecutableUnavailable, prepare(a, .{ .cwd = "/", .argv = &.{"/"} }, &.{}));
    try std.testing.expectError(error.ExecutableUnavailable, prepare(a, .{ .cwd = "/", .argv = &.{"/aster-missing-program"} }, &.{}));
    try std.testing.expectError(error.InvalidTerminalDirectory, prepare(a, .{ .cwd = "/aster-missing-directory", .argv = &.{"sh"} }, &.{}));
    for ([_][]const []const u8{ &.{"=empty"}, &.{"MISSING"}, &.{"A=x\x00y"} }) |env| {
        try std.testing.expectError(error.InvalidTerminalEnvironment, prepare(a, .{ .cwd = "/", .argv = &.{"sh"}, .environment = env }, &.{}));
    }
    try std.testing.expectError(error.DuplicateEnvironmentName, prepare(a, .{ .cwd = "/", .argv = &.{"sh"}, .environment = &.{ "A=1", "A=2" } }, &.{}));
    try std.testing.expectError(error.DuplicateEnvironmentName, prepare(a, .{ .cwd = "/", .argv = &.{"sh"} }, &.{ "A=1", "A=2" }));
    try std.testing.expectError(error.InvalidTerminalArguments, prepare(a, .{ .cwd = "/", .argv = &.{"sh\x00"} }, &.{}));
}

fn allocationExercise(a: std.mem.Allocator) !void {
    var ready = try prepare(a, .{ .cwd = "/", .argv = &.{ "sh", "literal" }, .environment = &.{"A=override"} }, &.{"A=base"});
    defer ready.deinit();
    try std.testing.expectEqualStrings("PATH=" ++ default_path, ready.environment[1]);
}
test "launch preparation frees every failed allocation and defaults absent PATH" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}

test "launch preparation rejects nonexecutable files and bounded inputs" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var file = try temp.dir.createFile("plain", .{ .mode = 0o600 });
    file.close();
    const cwd = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);
    try std.testing.expectError(error.ExecutableUnavailable, prepare(std.testing.allocator, .{ .cwd = cwd, .argv = &.{"./plain"} }, &.{}));
    const too_many = [_][]const u8{"sh"} ** 129;
    const too_long = [_]u8{'a'} ** 4097;
    try std.testing.expectError(error.InvalidTerminalArguments, prepare(std.testing.allocator, .{ .cwd = "/", .argv = &too_many }, &.{}));
    try std.testing.expectError(error.InvalidTerminalArguments, prepare(std.testing.allocator, .{ .cwd = "/", .argv = &.{ "sh", &too_long } }, &.{}));
    const long_value = "A=" ++ ([_]u8{'v'} ** 8193);
    try std.testing.expectError(error.InvalidTerminalEnvironment, prepare(std.testing.allocator, .{ .cwd = "/", .argv = &.{"sh"}, .environment = &.{long_value} }, &.{}));
}

test "launch preparation preserves symlink parent traversal" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("actual/child");
    try temp.dir.symLink("actual/child", "link", .{ .is_directory = true });
    try makeExecutable(temp.dir, "actual/tool");
    const cwd = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);
    var ready = try prepare(std.testing.allocator, .{ .cwd = cwd, .argv = &.{"tool"}, .environment = &.{"PATH=link/.."} }, &.{});
    defer ready.deinit();
    try std.testing.expect(std.mem.endsWith(u8, ready.argv[0], "/link/../tool"));
    var direct = try prepare(std.testing.allocator, .{ .cwd = cwd, .argv = &.{"link/../tool"} }, &.{});
    defer direct.deinit();
    try std.testing.expectEqualStrings(ready.argv[0], direct.argv[0]);
}

test "launch preparation accepts searchable cwd without directory read permission" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const cwd = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);
    try temp.dir.chmod(0o111);
    defer temp.dir.chmod(0o700) catch {};
    var ready = try prepare(std.testing.allocator, .{ .cwd = cwd, .argv = &.{"/bin/sh"} }, &.{});
    defer ready.deinit();
    try std.testing.expectEqualStrings(cwd, ready.cwd);
    if (std.posix.geteuid() != 0) {
        // Prove this exercises a directory that cannot be opened for listing.
        const fd = std.posix.open(cwd, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch |err| {
            try std.testing.expectEqual(error.AccessDenied, err);
            return;
        };
        std.posix.close(fd);
        return error.ExpectedDirectoryReadDenial;
    }
}
