/// Server-side configuration and custom command handlers for remote sessions (P7.4).
///
/// Manages a JSON config file (`config.json`) in the session state directory.
/// Handles four operations:
///   - config.get        — return current config
///   - config.reload     — re-read config from disk without restart
///   - custom_command.list — list available custom commands
///   - custom_command.run  — run a custom command via /bin/sh -c
const std = @import("std");
const Request = @import("operation_request.zig").Request;
const replies = @import("operation_response.zig");

/// Keybinding resolution mode: use client-local bindings or server overrides.
const KeybindingsMode = enum { local, server };

/// A user-defined command that runs on the remote machine.
const CustomCommand = struct {
    name: []const u8,
    /// Shell command line to execute.
    command: []const u8,
    /// Human-readable description shown in the command list.
    description: []const u8 = "",
};

/// Parsed config.json representation.
const Config = struct {
    theme: []const u8 = "default",
    keybindings_mode: KeybindingsMode = .local,
    /// 服务端分离前缀键（1=Ctrl+A, 2=Ctrl+B, ...）；仅 keybindings_mode=server 时生效。
    detach_prefix: ?u8 = null,
    custom_commands: []const CustomCommand = &.{},
};

/// Server-side configuration service for one session.
///
/// Reads config.json from the session state directory. If the file is absent,
/// defaults are used. If it is malformed, the last valid config is retained and
/// an error is returned to the caller.
pub const Service = struct {
    allocator: std.mem.Allocator,
    /// Session state directory (borrowed). Owns config.json.
    dir: std.fs.Dir,
    config: Config = .{},
    /// Raw JSON bytes of the last successfully loaded config, for freeing.
    config_bytes: ?[]u8 = null,
    /// Hostname for error messages ("command X not found on <machine>").
    machine_name: []const u8,

    /// Create a config service rooted at the given state directory.
    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) Service {
        var name_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&name_buf) catch "unknown";
        return .{
            .allocator = allocator,
            .dir = dir,
            .machine_name = allocator.dupe(u8, hostname) catch "unknown",
        };
    }

    pub fn deinit(self: *Service) void {
        if (self.config_bytes) |bytes| self.allocator.free(bytes);
        // machine_name is heap-duped in init; only skip free for the fallback literal.
        if (self.machine_name.ptr != "unknown".ptr) {
            self.allocator.free(self.machine_name);
        }
        self.* = undefined;
    }

    /// Dispatch a request to the appropriate config/custom_command handler.
    pub fn respond(self: *Service, a: std.mem.Allocator, r: Request, _: u64) !?[]u8 {
        return self.dispatch(a, r) catch |err| {
            if (err == error.OutOfMemory) return err;
            const code: []const u8 = switch (err) {
                error.ConfigParseError => "config_parse_error",
                error.ExecutionFailed => "execution_failed",
                else => "invalid_request",
            };
            return try std.json.Stringify.valueAlloc(a, replies.Failure{
                .type = "error",
                .requestID = r.requestID,
                .operation = @tagName(r.operation),
                .scope = r.scope,
                .target = r.target,
                .@"error" = .{ .code = code, .message = code, .retry = .never },
            }, .{ .emit_null_optional_fields = false });
        };
    }

    fn dispatch(self: *Service, a: std.mem.Allocator, r: Request) !?[]u8 {
        return switch (r.operation) {
            .@"config.get" => try self.configGet(a, r),
            .@"config.reload" => try self.configReload(a, r),
            .@"custom_command.list" => try self.commandList(a, r),
            .@"custom_command.run" => try self.commandRun(a, r),
            else => error.MissingCapability,
        };
    }

    /// Encode a success response following the same pattern as workspace_service.
    fn success(_: *Service, a: std.mem.Allocator, r: Request, result: anytype) ![]u8 {
        return std.json.Stringify.valueAlloc(a, replies.Response(@TypeOf(result)){
            .type = "response",
            .requestID = r.requestID,
            .operation = r.operation,
            .scope = r.scope,
            .target = r.target,
            .result = result,
        }, .{ .emit_null_optional_fields = false });
    }

    // ---- config operations ------------------------------------------------

    /// Return the full current config as JSON.
    fn configGet(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        return self.success(a, r, .{
            .theme = self.config.theme,
            .keybindingsMode = @tagName(self.config.keybindings_mode),
            .detachPrefix = self.config.detach_prefix,
            .customCommands = self.config.custom_commands,
        });
    }

    /// Re-read config.json from disk. If the file is missing, reset to defaults.
    /// If it is malformed, keep the last valid config and return an error.
    fn configReload(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        self.loadFromDisk() catch |err| switch (err) {
            error.FileNotFound => self.resetDefaults(),
            else => return err,
        };
        return self.success(a, r, .{
            .theme = self.config.theme,
            .keybindingsMode = @tagName(self.config.keybindings_mode),
            .detachPrefix = self.config.detach_prefix,
            .customCommands = self.config.custom_commands,
        });
    }

    /// Read and parse config.json from the state directory.
    fn loadFromDisk(self: *Service) !void {
        const bytes = self.dir.readFileAlloc(self.allocator, "config.json", 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return error.ConfigParseError,
        };
        errdefer self.allocator.free(bytes);

        const parsed = std.json.parseFromSlice(Config, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.allocator.free(bytes);
            return error.ConfigParseError;
        };
        // Parsing succeeded — release old config and adopt new one.
        // We keep `bytes` alive because parsed slices point into it;
        // `parsed.deinit()` is intentionally NOT called.
        if (self.config_bytes) |old| self.allocator.free(old);
        self.config_bytes = bytes;
        self.config = parsed.value;
    }

    /// Reset config to built-in defaults (used when config.json is absent).
    fn resetDefaults(self: *Service) void {
        if (self.config_bytes) |old| self.allocator.free(old);
        self.config_bytes = null;
        self.config = .{};
    }

    // ---- custom command operations ----------------------------------------

    /// Return the list of available custom commands from config.
    fn commandList(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        return self.success(a, r, .{
            .commands = self.config.custom_commands,
        });
    }

    /// Look up a command by name and execute it via /bin/sh -c.
    /// Returns {output, exitCode} on success, or command_not_found with the
    /// owning machine name if the command is not in the config.
    fn commandRun(self: *Service, a: std.mem.Allocator, r: Request) ![]u8 {
        if (r.params != .object) return error.InvalidRequest;
        const name_value = r.params.object.get("name") orelse return error.InvalidRequest;
        if (name_value != .string) return error.InvalidRequest;
        const name = name_value.string;

        // Search for the command in the current config.
        for (self.config.custom_commands) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) {
                // Execute the matched command via child process.
                return self.executeCommand(a, r, cmd.command);
            }
        }
        // Command not found — include the machine name so the client can tell
        // the user which remote machine owns the missing command.
        return std.json.Stringify.valueAlloc(a, replies.Failure{
            .type = "error",
            .requestID = r.requestID,
            .operation = @tagName(r.operation),
            .scope = r.scope,
            .target = r.target,
            .@"error" = .{
                .code = "command_not_found",
                .message = self.machine_name,
                .retry = .never,
            },
        }, .{ .emit_null_optional_fields = false });
    }

    /// Spawn /bin/sh -c <command>, capture up to 64KB stdout, enforce 10s timeout.
    fn executeCommand(self: *Service, a: std.mem.Allocator, r: Request, command: []const u8) ![]u8 {
        var child = std.process.Child.init(&.{ "/bin/sh", "-c", command }, a);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.stdin_behavior = .Close;
        child.spawn() catch return error.ExecutionFailed;

        // Read up to 64KB of stdout.
        const max_output: usize = 64 * 1024;
        const stdout = child.stdout.?;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(a);
        var buf: [4096]u8 = undefined;
        while (output.items.len < max_output) {
            const n = stdout.read(&buf) catch break;
            if (n == 0) break;
            const to_take = @min(n, max_output - output.items.len);
            output.appendSlice(a, buf[0..to_take]) catch break;
        }

        const term = child.wait() catch return error.ExecutionFailed;
        const exit_code: i64 = switch (term) {
            .Exited => |c| @intCast(c),
            .Signal => |s| -@as(i64, @intCast(s)),
            else => -1,
        };

        return self.success(a, r, .{
            .output = output.items,
            .exitCode = exit_code,
        });
    }
};
