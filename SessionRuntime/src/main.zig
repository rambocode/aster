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
        try std.fs.File.stderr().writeAll("P1 service commands:\n  aster-session server serve <existing-state-parent> <name>\n  aster-session server status <existing-state-parent> <name>\n  aster-session server start <existing-state-parent> <name>\n  aster-session server stop <existing-state-parent> <name>\nP1 terminal commands:\n  aster-session terminal create <state-parent> <name> <cwd> <program> [args...]\n  aster-session terminal list <state-parent> <name>\n  aster-session terminal terminate <state-parent> <name> <terminal-id>\n  aster-session terminal attach <state-parent> <name> <terminal-id> [--takeover]\n  aster-session terminal observe <state-parent> <name> <terminal-id>\n  Ctrl+B q: detach; Ctrl+B Ctrl+B: literal Ctrl+B\nP0 integration only:\n  aster-session probe-serve <private-socket> <cwd> <executable> [args...]\n  aster-session probe-bridge <private-socket>\n");
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
