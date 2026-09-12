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
            // Parse optional --takeover-fd for live handoff (P8.4).
            var takeover_fd: ?std.posix.fd_t = null;
            if (args.next()) |extra| {
                if (std.mem.eql(u8, extra, "--takeover-fd")) {
                    const fd_str = args.next() orelse return error.MissingTakeoverFD;
                    takeover_fd = std.fmt.parseInt(std.posix.fd_t, fd_str, 10) catch return error.InvalidTakeoverFD;
                    if (args.next() != null) return error.UnexpectedArgument;
                } else return error.UnexpectedArgument;
            }
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
            // Live handoff mode: receive state from old service via private FD.
            if (takeover_fd) |tfd| {
                try @import("service_server.zig").runTakeover(allocator, parent, name, tfd);
            } else {
                try @import("service_server.zig").run(allocator, parent, name, null, null);
            }
            return;
        }
        // P7 TUI 入口：完整终端客户端，工作区/标签/窗格导航、单终端交互、分离。
        // 支持本地模式（positional args）和远端模式（--remote 走 SSH exec）。
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "ui")) {
            var observe = false;
            var remote_target: ?[]const u8 = null;
            var session_name: ?[]const u8 = null;
            var positional: [2]?[]const u8 = .{ null, null };
            var pos_count: usize = 0;
            while (args.next()) |opt| {
                if (std.mem.eql(u8, opt, "--observe")) { observe = true; }
                else if (std.mem.eql(u8, opt, "--remote")) { remote_target = args.next() orelse return error.MissingRemoteTarget; }
                else if (std.mem.eql(u8, opt, "--session")) { session_name = args.next() orelse return error.MissingSessionName; }
                else if (opt.len > 0 and opt[0] == '-') { return error.UnexpectedArgument; }
                else { if (pos_count < 2) { positional[pos_count] = opt; pos_count += 1; } else return error.UnexpectedArgument; }
            }
            if (remote_target) |target| {
                // 远端模式：exec ssh 到目标机器运行 TUI。
                // argv 隔离：target 放在 -- 之后，远端命令做 shell 引用。
                remoteExec(allocator, target, session_name orelse "default", observe) catch |err| {
                    try std.fs.File.stderr().writeAll(@errorName(err));
                    try std.fs.File.stderr().writeAll("\n");
                    std.process.exit(1);
                };
                return;
            }
            // 本地模式：positional args 是 state-parent 和 name
            const parent_path = positional[0] orelse return error.MissingStateParent;
            const name = positional[1] orelse session_name orelse return error.MissingStateName;
            @import("tui.zig").run(allocator, parent_path, name, if (observe) .observe else .interactive) catch |err| {
                try std.fs.File.stderr().writeAll(@errorName(err));
                try std.fs.File.stderr().writeAll("\n");
                std.process.exit(1);
            };
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
        // Upload CLI: reads image from stdin and sends to session via RPC.
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "upload")) {
            const parent_path = args.next() orelse return error.MissingStateParent;
            const name = args.next() orelse return error.MissingStateName;
            var terminal_id: []const u8 = "00000000-0000-4000-8000-000000000000";
            var content_type: []const u8 = "application/octet-stream";
            while (args.next()) |opt| {
                if (std.mem.eql(u8, opt, "--terminal-id")) {
                    terminal_id = args.next() orelse return error.MissingTerminalID;
                } else if (std.mem.eql(u8, opt, "--content-type")) {
                    content_type = args.next() orelse return error.MissingContentType;
                } else return error.UnexpectedArgument;
            }
            @import("upload_cli.zig").run(allocator, parent_path, name, terminal_id, content_type) catch |err| {
                const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .type = "client_error", .code = @errorName(err) }, .{});
                defer allocator.free(encoded);
                try std.fs.File.stdout().writeAll(encoded);
                try std.fs.File.stdout().writeAll("\n");
                std.process.exit(1);
            };
            return;
        }
        // P7 配置 CLI：config get|reload <state-parent> <name>
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "config")) {
            const action = args.next() orelse return error.MissingAction;
            const parent_path = args.next() orelse return error.MissingStateParent;
            const name = args.next() orelse return error.MissingStateName;
            if (args.next() != null) return error.UnexpectedArgument;
            const command: @import("workspace_client.zig").Command = if (std.mem.eql(u8, action, "get"))
                .config_get
            else if (std.mem.eql(u8, action, "reload"))
                .config_reload
            else
                return error.UnsupportedConfigAction;
            const reply = try @import("workspace_client.zig").execute(allocator, parent_path, name, command, 15000);
            defer allocator.free(reply.bytes);
            try std.fs.File.stdout().writeAll(reply.bytes);
            try std.fs.File.stdout().writeAll("\n");
            if (reply.is_error) std.process.exit(1);
            return;
        }
        // P7 自定义命令 CLI：custom-command list|run <state-parent> <name> [command-name]
        if (@import("build_options").with_vt and std.mem.eql(u8, arg, "custom-command")) {
            const action = args.next() orelse return error.MissingAction;
            const parent_path = args.next() orelse return error.MissingStateParent;
            const name = args.next() orelse return error.MissingStateName;
            const command: @import("workspace_client.zig").Command = if (std.mem.eql(u8, action, "list")) blk: {
                if (args.next() != null) return error.UnexpectedArgument;
                break :blk .custom_command_list;
            } else if (std.mem.eql(u8, action, "run")) blk: {
                const cmd_name = args.next() orelse return error.MissingCommandName;
                if (args.next() != null) return error.UnexpectedArgument;
                break :blk .{ .custom_command_run = .{ .name = cmd_name } };
            } else
                return error.UnsupportedCustomCommandAction;
            const reply = try @import("workspace_client.zig").execute(allocator, parent_path, name, command, 30000);
            defer allocator.free(reply.bytes);
            try std.fs.File.stdout().writeAll(reply.bytes);
            try std.fs.File.stdout().writeAll("\n");
            if (reply.is_error) std.process.exit(1);
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
        try std.fs.File.stderr().writeAll("P1 service commands:\n  aster-session server serve <existing-state-parent> <name>\n  aster-session server status <existing-state-parent> <name>\n  aster-session server start <existing-state-parent> <name>\n  aster-session server stop <existing-state-parent> <name>\nP1 terminal commands:\n  aster-session terminal create <state-parent> <name> <cwd> <program> [args...]\n  aster-session terminal list <state-parent> <name>\n  aster-session terminal terminate <state-parent> <name> <terminal-id>\n  aster-session terminal attach <state-parent> <name> <terminal-id> [--takeover]\n  aster-session terminal observe <state-parent> <name> <terminal-id>\n  Ctrl+B q: detach; Ctrl+B Ctrl+B: literal Ctrl+B\nP4 registry and workspace commands:\n  aster-session session list <state-parent>\n  aster-session session create <state-parent> <name>\n  aster-session session attach|stop|delete <state-parent> <name-or-id>\n  aster-session session snapshot <state-parent> <name>\n  aster-session workspace list <state-parent> <name>\n  aster-session workspace create <state-parent> <name> --expected-revision <n> --title <t> --cwd <abs> -- <argv...>\n  aster-session workspace update <state-parent> <name> --workspace <id> --expected-revision <n> --title <t>\n  aster-session workspace close <state-parent> <name> --workspace <id> --expected-revision <n>\n  aster-session tab create <state-parent> <name> --workspace <id> --expected-revision <n> --title <t> --cwd <abs> -- <argv...>\n  aster-session tab update <state-parent> <name> --tab <id> --expected-revision <n> --title <t>\n  aster-session tab close <state-parent> <name> --tab <id> --expected-revision <n>\n  aster-session pane split <state-parent> <name> --pane <id> --direction <left|right|up|down> --expected-revision <n> --cwd <abs> -- <argv...>\n  aster-session pane update <state-parent> <name> --pane <id> --expected-revision <n> --title <t>\n  aster-session pane close <state-parent> <name> --pane <id> --expected-revision <n>\nP7 TUI client:\n  aster-session ui <state-parent> <name> [--observe]\n  Ctrl+B q: detach; Ctrl+B n/p: next/prev tab; Ctrl+B o: next pane; Ctrl+B ?: help\nP4 event stream:\n  aster-session event subscribe <state-parent> <name>\nP0 integration only:\n  aster-session probe-serve <private-socket> <cwd> <executable> [args...]\n  aster-session probe-bridge <private-socket>\n");
    }
    std.process.exit(2);
}

/// 远端 TUI 入口：fork+exec ssh，在远端运行 aster-session ui。
/// target 以 `--` 隔离（防止 SSH 把 target 当选项），远端命令在远端 shell 展开
/// 状态目录变量以确定实际路径。
fn remoteExec(a: std.mem.Allocator, target: []const u8, session_name: []const u8, observe: bool) !void {
    // 远端状态目录：以 shell 表达式在远端解析
    const remote_state = "${XDG_RUNTIME_DIR:-$HOME/.local/state}/aster";
    const observe_flag: []const u8 = if (observe) " --observe" else "";
    // 构造远端命令行：单引号保护 session_name 防止 shell 解释
    const remote_cmd = try std.fmt.allocPrint(a, "exec aster-session ui {s} '{s}'{s}", .{ remote_state, session_name, observe_flag });
    defer a.free(remote_cmd);
    // 用 Child 等价 exec：继承 stdio，等待完成后以 ssh 退出码退出
    var child = std.process.Child.init(&.{ "/usr/bin/ssh", "-tt", "--", target, remote_cmd }, a);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        .Signal => 128,
        else => 1,
    };
    std.process.exit(code);
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
