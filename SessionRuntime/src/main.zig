const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.next();
    if (args.next()) |arg| {
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "terminal")) {
            terminalCommand(allocator, &args) catch |err| {
                const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .type = "client_error", .code = @errorName(err) }, .{});
                defer allocator.free(encoded);
                try std.fs.File.stdout().writeAll(encoded);
                try std.fs.File.stdout().writeAll("\n");
                std.process.exit(1);
            };
            return;
        }
        if (@import("build_options").with_vt and (std.mem.eql(u8, arg, "session") or std.mem.eql(u8, arg, "workspace") or
            std.mem.eql(u8, arg, "tab") or std.mem.eql(u8, arg, "pane") or std.mem.eql(u8, arg, "agent")))
        {
            structuralCommand(allocator, arg, &args) catch |err| {
                const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .type = "client_error", .code = @errorName(err) }, .{});
                defer allocator.free(encoded);
                try std.fs.File.stdout().writeAll(encoded);
                try std.fs.File.stdout().writeAll("\n");
                std.process.exit(1);
            };
            return;
        }
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "server")) {
            const action = args.next() orelse return error.MissingServerAction;
            if (!std.mem.eql(u8, action, "serve") and !std.mem.eql(u8, action, "status") and !std.mem.eql(u8, action, "start") and !std.mem.eql(u8, action, "stop")) return error.UnsupportedServerAction;
            const parent_path = args.next() orelse return error.MissingStateParent;
            const name = args.next() orelse return error.MissingStateName;
            if (args.next() != null) return error.UnexpectedArgument;
            if (std.mem.eql(u8, action, "start")) {
                const result = @import("service_launch.zig").start(allocator, parent_path, name) catch |err| {
                    const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .type = "client_error", .code = @errorName(err) }, .{});
                    defer allocator.free(encoded);
                    try std.fs.File.stdout().writeAll(encoded);
                    try std.fs.File.stdout().writeAll("\n");
                    std.process.exit(1);
                };
                defer allocator.free(result);
                try std.fs.File.stdout().writeAll(result);
                try std.fs.File.stdout().writeAll("\n");
                return;
            }
            if (std.mem.eql(u8, action, "status") or std.mem.eql(u8, action, "stop")) {
                const client = @import("service_client.zig");
                const result = if (std.mem.eql(u8, action, "stop")) client.stopAtPath(allocator, parent_path, name, 5000) else client.statusAtPath(allocator, parent_path, name, 3000);
                const reply = result catch |err| {
                    const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .type = "client_error", .code = @errorName(err) }, .{});
                    defer allocator.free(encoded);
                    try std.fs.File.stdout().writeAll(encoded);
                    try std.fs.File.stdout().writeAll("\n");
                    std.process.exit(1);
                };
                defer allocator.free(reply.bytes);
                try std.fs.File.stdout().writeAll(reply.bytes);
                try std.fs.File.stdout().writeAll("\n");
                if (reply.is_error) std.process.exit(1);
                return;
            }
            var parent = try std.fs.cwd().openDir(parent_path, .{ .no_follow = true });
            defer parent.close();
            const info = try std.posix.fstat(parent.fd);
            if (info.uid != std.posix.geteuid() or info.mode & 0o077 != 0) return error.UnsafeStateParent;
            try @import("service_server.zig").run(allocator, parent, name, null, null);
            return;
        }
        // Streaming subscription entry point. Unlike every other CLI verb this
        // one never terminates on its own: it holds a control connection open
        // and relays events until the peer or a signal ends it.
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "event")) {
            const action = args.next() orelse return error.MissingEventAction;
            if (!std.mem.eql(u8, action, "subscribe")) return error.UnsupportedEventAction;
            const parent_path = args.next() orelse return error.MissingStateParent;
            const name = args.next() orelse return error.MissingStateName;
            if (args.next() != null) return error.UnexpectedArgument;
            @import("event_subscribe.zig").run(allocator, parent_path, name) catch |err| {
                try std.fs.File.stderr().writeAll(@errorName(err));
                try std.fs.File.stderr().writeAll("\n");
                std.process.exit(1);
            };
            return;
        }
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "probe-bridge")) {
            const socket = args.next() orelse return error.MissingSocket;
            if (args.next() != null) return error.UnexpectedArgument;
            try @import("bridge.zig").run(allocator, socket);
            return;
        }
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "probe-serve")) {
            const socket = args.next() orelse return error.MissingSocket;
            const cwd = args.next() orelse return error.MissingDirectory;
            const executable = args.next() orelse return error.MissingExecutable;
            var argv: std.ArrayList(?[*:0]const u8) = .empty;
            defer argv.deinit(allocator);
            try argv.append(allocator, executable.ptr);
            while (args.next()) |value| try argv.append(allocator, value.ptr);
            try argv.append(allocator, null);
            try @import("probe.zig").serve(allocator, socket, cwd, executable, @ptrCast(argv.items.ptr));
            return;
        }
        if (std.mem.eql(u8, arg, "--version") and args.next() == null) {
            try std.fs.File.stdout().writeAll("aster-session 0.1.0-dev protocol=1.0\n");
            return;
        }
    }
    try std.fs.File.stderr().writeAll("usage: aster-session --version\n");
    if (@import("build_options").with_vt) {
        try std.fs.File.stderr().writeAll("P1 service commands:\n  aster-session server serve <existing-state-parent> <name>\n  aster-session server status <existing-state-parent> <name>\n  aster-session server start <existing-state-parent> <name>\n  aster-session server stop <existing-state-parent> <name>\nP1 terminal commands:\n  aster-session terminal create <state-parent> <name> <cwd> <program> [args...]\n  aster-session terminal list <state-parent> <name>\n  aster-session terminal terminate <state-parent> <name> <terminal-id>\n  aster-session terminal attach <state-parent> <name> <terminal-id> [--takeover]\n  aster-session terminal observe <state-parent> <name> <terminal-id>\n  Ctrl+B q: detach; Ctrl+B Ctrl+B: literal Ctrl+B\nP4 registry and workspace commands:\n  aster-session session list <state-parent>\n  aster-session session create <state-parent> <name>\n  aster-session session attach|stop|delete <state-parent> <name-or-id>\n  aster-session session snapshot <state-parent> <name>\n  aster-session workspace list <state-parent> <name>\n  aster-session workspace create <state-parent> <name> --expected-revision <n> --title <t> --cwd <abs> -- <argv...>\n  aster-session workspace update <state-parent> <name> --workspace <id> --expected-revision <n> --title <t>\n  aster-session workspace close <state-parent> <name> --workspace <id> --expected-revision <n>\n  aster-session tab create <state-parent> <name> --workspace <id> --expected-revision <n> --title <t> --cwd <abs> -- <argv...>\n  aster-session tab update <state-parent> <name> --tab <id> --expected-revision <n> --title <t>\n  aster-session tab close <state-parent> <name> --tab <id> --expected-revision <n>\n  aster-session pane split <state-parent> <name> --pane <id> --direction <left|right|up|down> --expected-revision <n> --cwd <abs> -- <argv...>\n  aster-session pane update <state-parent> <name> --pane <id> --expected-revision <n> --title <t>\n  aster-session pane close <state-parent> <name> --pane <id> --expected-revision <n>\nP4 event stream:\n  aster-session event subscribe <state-parent> <name>\nP0 integration only:\n  aster-session probe-serve <private-socket> <cwd> <executable> [args...]\n  aster-session probe-bridge <private-socket>\n");
    }
    std.process.exit(2);
}

fn terminalCommand(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const client = @import("terminal_client.zig");
    const action = args.next() orelse return error.MissingTerminalAction;
    const parent = args.next() orelse return error.MissingStateParent;
    const name = args.next() orelse return error.MissingStateName;
    if (std.mem.eql(u8, action, "attach") or std.mem.eql(u8, action, "observe")) {
        const terminal_id = args.next() orelse return error.MissingTerminalID;
        const option = args.next();
        const takeover = if (option) |value| std.mem.eql(u8, value, "--takeover") else false;
        if ((option != null and !takeover) or args.next() != null) return error.UnexpectedArgument;
        @import("terminal_attach.zig").runWithTakeover(allocator, parent, name, terminal_id, std.mem.eql(u8, action, "observe"), takeover) catch |err| {
            try std.fs.File.stderr().writeAll(@errorName(err));
            try std.fs.File.stderr().writeAll("\n");
            std.process.exit(1);
        };
        return;
    }
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    const command: client.Command = if (std.mem.eql(u8, action, "create")) blk: {
        const cwd = args.next() orelse return error.MissingDirectory;
        while (args.next()) |value| {
            if (values.items.len == 128) return error.TooManyArguments;
            try values.append(allocator, value);
        }
        if (values.items.len == 0) return error.MissingExecutable;
        break :blk .{ .create = .{ .cwd = cwd, .argv = values.items } };
    } else if (std.mem.eql(u8, action, "list")) blk: {
        if (args.next() != null) return error.UnexpectedArgument;
        break :blk .list;
    } else if (std.mem.eql(u8, action, "terminate")) blk: {
        const id = args.next() orelse return error.MissingTerminalID;
        if (args.next() != null) return error.UnexpectedArgument;
        break :blk .{ .terminate = id };
    } else return error.UnsupportedTerminalAction;
    const reply = try client.execute(allocator, parent, name, command, 7000);
    defer allocator.free(reply.bytes);
    try std.fs.File.stdout().writeAll(reply.bytes);
    try std.fs.File.stdout().writeAll("\n");
    if (reply.is_error) std.process.exit(1);
}

/// P4 structured CLI: named-session registry plus workspace/tab/pane
/// transactions. Registry actions run directly against the state parent; the
/// structural actions are real RPCs to that session's own control socket.
/// `--expected-revision` is always explicit so two processes can deliberately
/// submit the same revision and prove that exactly one of them wins.
fn structuralCommand(allocator: std.mem.Allocator, domain: []const u8, args: *std.process.ArgIterator) !void {
    const registry = @import("registry_service.zig");
    const client = @import("workspace_client.zig");
    const action = args.next() orelse return error.MissingAction;
    if (std.mem.eql(u8, domain, "session") and !std.mem.eql(u8, action, "snapshot")) {
        const parent = args.next() orelse return error.MissingStateParent;
        const selector: ?[]const u8 = if (std.mem.eql(u8, action, "list")) null else args.next() orelse return error.MissingSessionName;
        if (args.next() != null) return error.UnexpectedArgument;
        // Resolve the name-or-id once into a named local: the CliAction borrows
        // this text for the whole call and must not point at a temporary.
        var session_id: [36]u8 = undefined;
        if (!std.mem.eql(u8, action, "list") and !std.mem.eql(u8, action, "create"))
            session_id = try registry.resolveCli(allocator, parent, selector.?);
        const request: registry.CliAction = if (std.mem.eql(u8, action, "list"))
            .list
        else if (std.mem.eql(u8, action, "create"))
            .{ .create = selector.? }
        else if (std.mem.eql(u8, action, "attach"))
            .{ .attach = &session_id }
        else if (std.mem.eql(u8, action, "stop"))
            .{ .stop = &session_id }
        else if (std.mem.eql(u8, action, "delete"))
            .{ .delete = &session_id }
        else
            return error.UnsupportedSessionAction;
        const outcome = try registry.runCli(allocator, parent, request);
        defer allocator.free(outcome.bytes);
        try std.fs.File.stdout().writeAll(outcome.bytes);
        try std.fs.File.stdout().writeAll("\n");
        if (outcome.is_error) std.process.exit(1);
        return;
    }
    // P5: Agent 操作不走 Options 解析，terminalID 是裸位置参数
    if (std.mem.eql(u8, domain, "agent")) {
        const parent = args.next() orelse return error.MissingStateParent;
        const name = args.next() orelse return error.MissingStateName;
        const command: client.Command = if (std.mem.eql(u8, action, "list"))
            .agent_list
        else if (std.mem.eql(u8, action, "report")) blk: {
            const stdin = std.fs.File.stdin();
            break :blk .{ .agent_report = .{ .body = try stdin.readToEndAlloc(allocator, 1024 * 1024) } };
        } else if (std.mem.eql(u8, action, "explain"))
            .{ .agent_explain = .{ .terminal_id = args.next() orelse return error.MissingTerminalID } }
        else if (std.mem.eql(u8, action, "ack") or std.mem.eql(u8, action, "acknowledge"))
            .{ .agent_acknowledge = .{ .terminal_id = args.next() orelse return error.MissingTerminalID } }
        else
            return error.UnsupportedAgentAction;
        const reply = try client.execute(allocator, parent, name, command, 15000);
        defer allocator.free(reply.bytes);
        try std.fs.File.stdout().writeAll(reply.bytes);
        try std.fs.File.stdout().writeAll("\n");
        if (reply.is_error) std.process.exit(1);
        return;
    }
    const parent = args.next() orelse return error.MissingStateParent;
    const name = args.next() orelse return error.MissingStateName;
    var options = Options{};
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try options.parse(allocator, args, &argv);
    const command: client.Command = if (std.mem.eql(u8, domain, "session"))
        .snapshot
    else if (std.mem.eql(u8, domain, "workspace") and std.mem.eql(u8, action, "list"))
        .workspace_list
    else if (std.mem.eql(u8, domain, "workspace") and std.mem.eql(u8, action, "create"))
        .{ .workspace_create = .{
            .title = options.title orelse return error.MissingTitle,
            .spec = .{ .cwd = options.cwd orelse return error.MissingDirectory, .argv = argv.items },
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else if (std.mem.eql(u8, domain, "workspace") and std.mem.eql(u8, action, "update"))
        .{ .workspace_update = .{
            .workspace_id = options.workspace orelse return error.MissingWorkspaceID,
            .title = options.title orelse return error.MissingTitle,
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else if (std.mem.eql(u8, domain, "workspace") and std.mem.eql(u8, action, "close"))
        .{ .workspace_close = .{
            .workspace_id = options.workspace orelse return error.MissingWorkspaceID,
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else if (std.mem.eql(u8, domain, "tab") and std.mem.eql(u8, action, "create"))
        .{ .tab_create = .{
            .workspace_id = options.workspace orelse return error.MissingWorkspaceID,
            .title = options.title orelse return error.MissingTitle,
            .spec = .{ .cwd = options.cwd orelse return error.MissingDirectory, .argv = argv.items },
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else if (std.mem.eql(u8, domain, "tab") and std.mem.eql(u8, action, "update"))
        .{ .tab_update = .{
            .tab_id = options.tab orelse return error.MissingTabID,
            .title = options.title orelse return error.MissingTitle,
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else if (std.mem.eql(u8, domain, "tab") and std.mem.eql(u8, action, "close"))
        .{ .tab_close = .{
            .tab_id = options.tab orelse return error.MissingTabID,
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else if (std.mem.eql(u8, domain, "pane") and std.mem.eql(u8, action, "split"))
        .{ .pane_split = .{
            .pane_id = options.pane orelse return error.MissingPaneID,
            .direction = options.direction orelse return error.MissingDirection,
            .spec = .{ .cwd = options.cwd orelse return error.MissingDirectory, .argv = argv.items },
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else if (std.mem.eql(u8, domain, "pane") and std.mem.eql(u8, action, "update"))
        .{ .pane_update = .{
            .pane_id = options.pane orelse return error.MissingPaneID,
            .title = options.title orelse return error.MissingTitle,
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else if (std.mem.eql(u8, domain, "pane") and std.mem.eql(u8, action, "close"))
        .{ .pane_close = .{
            .pane_id = options.pane orelse return error.MissingPaneID,
            .revision = options.revision orelse return error.MissingExpectedRevision,
        } }
    else
        return error.UnsupportedStructuralAction;
    const reply = try client.execute(allocator, parent, name, command, 15000);
    defer allocator.free(reply.bytes);
    try std.fs.File.stdout().writeAll(reply.bytes);
    try std.fs.File.stdout().writeAll("\n");
    if (reply.is_error) std.process.exit(1);
}

/// Flags accepted by the structural CLI. Everything after a bare `--` is the
/// literal argv of the terminal to launch and is never re-interpreted.
const Options = struct {
    revision: ?u64 = null,
    title: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    tab: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    direction: ?[]const u8 = null,

    fn parse(self: *Options, allocator: std.mem.Allocator, args: *std.process.ArgIterator, argv: *std.ArrayList([]const u8)) !void {
        while (args.next()) |flag| {
            if (std.mem.eql(u8, flag, "--")) {
                while (args.next()) |value| {
                    if (argv.items.len == 128) return error.TooManyArguments;
                    try argv.append(allocator, value);
                }
                return;
            }
            const value = args.next() orelse return error.MissingFlagValue;
            if (std.mem.eql(u8, flag, "--expected-revision")) {
                self.revision = std.fmt.parseInt(u64, value, 10) catch return error.InvalidExpectedRevision;
            } else if (std.mem.eql(u8, flag, "--title")) {
                self.title = value;
            } else if (std.mem.eql(u8, flag, "--cwd")) {
                self.cwd = value;
            } else if (std.mem.eql(u8, flag, "--workspace")) {
                self.workspace = value;
            } else if (std.mem.eql(u8, flag, "--tab")) {
                self.tab = value;
            } else if (std.mem.eql(u8, flag, "--pane")) {
                self.pane = value;
            } else if (std.mem.eql(u8, flag, "--direction")) {
                self.direction = value;
            } else return error.UnknownOption;
        }
    }
};
