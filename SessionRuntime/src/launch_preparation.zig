const std = @import("std");
const Geometry = @import("geometry.zig").Geometry;

/// Used only when neither the service environment nor request supplies PATH.
pub const default_path = "/usr/bin:/bin:/usr/sbin:/sbin";
/// The service runs as a daemon without a controlling terminal, so its own
/// environment never carries TERM. A shell spawned without TERM cannot drive
/// its line editor (zsh redraws garbage, arrows stop working, prompts vanish).
/// xterm-256color exists in every terminfo database the runtime targets.
pub const default_term = "xterm-256color";
pub const default_colorterm = "truecolor";

/// Append TERM/COLORTERM when neither the inherited nor the request environment
/// set them. Existing values (including an explicit empty TERM) are untouched.
pub fn appendTerminalDefaults(a: std.mem.Allocator, environment: *std.ArrayList([]const u8)) !void {
    var has_term = false;
    var has_colorterm = false;
    for (environment.items) |item| {
        if (std.mem.eql(u8, name(item), "TERM")) has_term = true;
        if (std.mem.eql(u8, name(item), "COLORTERM")) has_colorterm = true;
    }
    if (!has_term) try environment.append(a, "TERM=" ++ default_term);
    if (!has_colorterm) try environment.append(a, "COLORTERM=" ++ default_colorterm);
}
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

/// 服务端起的 shell 是守护进程的子进程，拿不到 App 注入给原生 Pane 的 shell 集成环境
/// （OSC 133 提示符标记、OSC 7 目录跟踪、别名上报、命令退出徽标、补全学习全靠它）。
/// 这里按 App 侧 ShellIntegrationLaunchPlan 的同一套规则注入：集成目录从服务二进制的位置
/// 解析——App Bundle 里是 Contents/MacOS/../Resources/shell-integration，远端安装是
/// <bin>/../share/aster/shell-integration；两处都没有就跳过。请求已带 ASTER_INTEGRATION
/// 或用户设置 ASTER_DISABLE_INTEGRATION=1 时不动。
pub fn appendShellIntegration(a: std.mem.Allocator, environment: *std.ArrayList([]const u8), integration_dir: ?[]const u8) !void {
    const dir = integration_dir orelse return;
    if (lookup(environment.items, "ASTER_INTEGRATION") != null) return;
    if (lookup(environment.items, "ASTER_DISABLE_INTEGRATION")) |value| if (std.mem.eql(u8, value, "1")) return;
    try environment.append(a, "ASTER_INTEGRATION=1");
    try environment.append(a, try std.fmt.allocPrint(a, "ASTER_SHELL_INTEGRATION_DIR={s}", .{dir}));
    // zsh：临时 ZDOTDIR 指向注入目录，.zshenv 会 source 用户真实的启动文件并把 ZDOTDIR 还原。
    const real_zdotdir = lookup(environment.items, "ZDOTDIR");
    try replaceOrAppend(a, environment, "ASTER_REAL_ZDOTDIR", real_zdotdir orelse (lookup(environment.items, "HOME") orelse ""));
    try replaceOrAppend(a, environment, "ASTER_REAL_ZDOTDIR_SET", if (real_zdotdir != null) "1" else "0");
    try replaceOrAppend(a, environment, "ZDOTDIR", try std.fmt.allocPrint(a, "{s}/zsh", .{dir}));
    // fish：把注入目录放到 XDG_DATA_DIRS 最前，vendor_conf.d 自动加载。
    const fish_dir = try std.fmt.allocPrint(a, "{s}/fish", .{dir});
    const inherited_dirs = lookup(environment.items, "XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var joined: std.ArrayList(u8) = .empty;
    try joined.appendSlice(a, fish_dir);
    var parts = std.mem.splitScalar(u8, inherited_dirs, ':');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, fish_dir)) continue;
        try joined.append(a, ':');
        try joined.appendSlice(a, part);
    }
    try replaceOrAppend(a, environment, "XDG_DATA_DIRS", joined.items);
}

/// 从服务自身可执行文件位置解析 shell 集成目录；以 zsh/.zshenv 是否可读为准。
/// 只有内存不足会向上抛；找不到可执行文件或目录一律视为"没有集成目录"。
pub fn resolveIntegrationDirectory(a: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    const exe = std.fs.selfExePathAlloc(a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const bin_dir = std.fs.path.dirname(exe) orelse return null;
    // 远端安装：版本化目录里二进制旁边的 shell-integration/（install 事务解包到这里）；
    // App Bundle：Contents/MacOS/../Resources/shell-integration；开发布局：../share/aster/…。
    const candidates = [_][]const u8{ "shell-integration", "../Resources/shell-integration", "../share/aster/shell-integration" };
    for (candidates) |candidate| {
        const dir = try std.fs.path.resolve(a, &.{ bin_dir, candidate });
        const probe = try std.fs.path.join(a, &.{ dir, "zsh", ".zshenv" });
        std.fs.accessAbsolute(probe, .{}) catch continue;
        return dir;
    }
    return null;
}

fn lookup(environment: []const []const u8, key: []const u8) ?[]const u8 {
    for (environment) |item| if (std.mem.eql(u8, name(item), key)) return item[key.len + 1 ..];
    return null;
}

fn replaceOrAppend(a: std.mem.Allocator, environment: *std.ArrayList([]const u8), key: []const u8, value: []const u8) !void {
    const entry = try std.fmt.allocPrint(a, "{s}={s}", .{ key, value });
    for (environment.items) |*item| if (std.mem.eql(u8, name(item.*), key)) {
        item.* = entry;
        return;
    };
    try environment.append(a, entry);
}

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
    try appendTerminalDefaults(a, &environment);
    try appendShellIntegration(a, &environment, try resolveIntegrationDirectory(a));
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

test "launch preparation supplies TERM and COLORTERM when the daemon environment lacks them" {
    const a = std.testing.allocator;
    var ready = try prepare(a, .{ .cwd = "/", .argv = &.{"sh"} }, &.{"PATH=/bin"});
    defer ready.deinit();
    var term: ?[]const u8 = null;
    var colorterm: ?[]const u8 = null;
    for (ready.environment) |item| {
        if (std.mem.eql(u8, name(item), "TERM")) term = item;
        if (std.mem.eql(u8, name(item), "COLORTERM")) colorterm = item;
    }
    try std.testing.expectEqualStrings("TERM=" ++ default_term, term.?);
    try std.testing.expectEqualStrings("COLORTERM=" ++ default_colorterm, colorterm.?);

    // 请求或服务环境已给出的值不被覆盖。
    var kept = try prepare(a, .{ .cwd = "/", .argv = &.{"sh"}, .environment = &.{"TERM=xterm-ghostty"} }, &.{ "PATH=/bin", "COLORTERM=no" });
    defer kept.deinit();
    for (kept.environment) |item| {
        if (std.mem.eql(u8, name(item), "TERM")) try std.testing.expectEqualStrings("TERM=xterm-ghostty", item);
        if (std.mem.eql(u8, name(item), "COLORTERM")) try std.testing.expectEqualStrings("COLORTERM=no", item);
    }
}

test "launch preparation injects shell integration like the app launch plan and respects opt-out" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    var env: std.ArrayList([]const u8) = .empty;
    try env.append(t, "HOME=/Users/me");
    try env.append(t, "XDG_DATA_DIRS=/usr/share");
    try appendShellIntegration(t, &env, "/app/Contents/Resources/shell-integration");
    try std.testing.expectEqualStrings("1", lookup(env.items, "ASTER_INTEGRATION").?);
    try std.testing.expectEqualStrings("/app/Contents/Resources/shell-integration", lookup(env.items, "ASTER_SHELL_INTEGRATION_DIR").?);
    try std.testing.expectEqualStrings("/app/Contents/Resources/shell-integration/zsh", lookup(env.items, "ZDOTDIR").?);
    try std.testing.expectEqualStrings("/Users/me", lookup(env.items, "ASTER_REAL_ZDOTDIR").?);
    try std.testing.expectEqualStrings("0", lookup(env.items, "ASTER_REAL_ZDOTDIR_SET").?);
    try std.testing.expectEqualStrings("/app/Contents/Resources/shell-integration/fish:/usr/share", lookup(env.items, "XDG_DATA_DIRS").?);

    // 用户自己的 ZDOTDIR 被记住并标记为显式设置。
    var custom: std.ArrayList([]const u8) = .empty;
    try custom.append(t, "ZDOTDIR=/Users/me/.zsh");
    try appendShellIntegration(t, &custom, "/x");
    try std.testing.expectEqualStrings("/Users/me/.zsh", lookup(custom.items, "ASTER_REAL_ZDOTDIR").?);
    try std.testing.expectEqualStrings("1", lookup(custom.items, "ASTER_REAL_ZDOTDIR_SET").?);
    try std.testing.expectEqualStrings("/x/zsh", lookup(custom.items, "ZDOTDIR").?);

    // 已注入或显式关闭时不动；没有集成目录时也不动。
    var off: std.ArrayList([]const u8) = .empty;
    try off.append(t, "ASTER_DISABLE_INTEGRATION=1");
    try appendShellIntegration(t, &off, "/x");
    try std.testing.expectEqual(@as(usize, 1), off.items.len);
    var none: std.ArrayList([]const u8) = .empty;
    try appendShellIntegration(t, &none, null);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}
