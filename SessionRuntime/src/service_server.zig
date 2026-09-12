const std = @import("std");
const Instance = @import("service_instance.zig").ServiceInstance;
const Reactor = @import("service_reactor.zig").Reactor;
const Pool = @import("terminal_pool.zig").Pool;
const Terminals = @import("terminal_service.zig").Service;
const Surfaces = @import("surface_service.zig").Service;
const Workspaces = @import("workspace_service.zig").Service;
const Store = @import("workspace_store.zig").Store;
const RegistryEndpoint = @import("registry_service.zig").Endpoint;
const Session = @import("session_registry.zig").Session;
const screen_history = @import("screen_history.zig");
const Uploads = @import("upload_service.zig").Service;
const Configs = @import("config_service.zig").Service;
const Domains = struct { terminals: *Terminals, surfaces: *Surfaces, workspaces: *Workspaces, uploads: *Uploads, configs: *Configs };
const Request = @import("operation_request.zig").Request;
const ids = @import("service_identity.zig");
const Report = @import("startup_report.zig").Writer;
const handoff = @import("handoff.zig");
const c = @cImport({
    @cInclude("bridge_signals.h");
    @cInclude("signal.h");
});

/// Runs one service in the current process. A daemon launcher must detach and
/// redirect standard descriptors before entering. The optional private startup
/// report is sent only after signals, persistent identity, listener and reactor
/// are all initialized. PTYs belong to this loop, never to control connections.
pub fn run(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, report: ?*Report, startup_epoch: ?[16]u8) !void {
    errdefer if (report) |writer| {
        if (writer.fd != null) writer.finish(.initialization_failed) catch {};
    };
    const wake = c.session_bridge_signals_start();
    if (wake < 0) return error.ServiceSignalSetupFailed;
    defer c.session_bridge_signals_stop();
    var instance = Instance.open(parent, name) catch |err| {
        if (err == error.AlreadyRunning) {
            if (report) |writer| {
                try writer.finish(.already_running);
                return;
            }
        }
        return err;
    };
    if (startup_epoch) |epoch| instance.epoch = epoch;
    const result = runInitialized(allocator, &instance, name, report, wake);
    const cleanup = instance.close();
    try result;
    try cleanup;
}

fn runInitialized(allocator: std.mem.Allocator, instance: *Instance, name: []const u8, report: ?*Report, wake: std.posix.fd_t) !void {
    var reactor = try Reactor.init(allocator, instance, .{});
    defer reactor.deinit();
    var pool = try Pool.init(allocator, .{ .scope_cleanup = true });
    defer pool.deinit();
    // A damaged layout stops startup on purpose: silently serving an empty
    // session would look exactly like the user's workspaces having vanished.
    var store = Store.init(allocator);
    defer store.deinit();
    try store.load(instance.state.dir);
    // Screen history: periodic VT snapshots to disk. Tracks the
    // store's screen_history_enabled flag so settings updates take
    // effect without a restart.
    // Allow test overrides via env vars so quota eviction can be exercised
    // with a tiny budget without changing product defaults.
    var history_config = screen_history.Config{ .enabled = store.screen_history_enabled };
    if (std.posix.getenv("ASTER_HISTORY_SESSION_LIMIT")) |val| {
        history_config.session_limit = std.fmt.parseInt(usize, val, 10) catch history_config.session_limit;
    }
    if (std.posix.getenv("ASTER_HISTORY_PER_TERMINAL_LIMIT")) |val| {
        history_config.per_terminal_limit = std.fmt.parseInt(usize, val, 10) catch history_config.per_terminal_limit;
    }
    if (std.posix.getenv("ASTER_HISTORY_SNAPSHOT_INTERVAL_MS")) |val| {
        history_config.snapshot_interval_ms = std.fmt.parseInt(u64, val, 10) catch history_config.snapshot_interval_ms;
    }
    var history_writer = try screen_history.Writer.init(allocator, instance.state.dir, history_config);
    defer history_writer.deinit();
    var terminals = try Terminals.init(allocator, &pool, &instance.state, instance.identity, instance.epoch);
    defer terminals.deinit();
    terminals.shared_revision = &store.revision;
    var workspaces = try Workspaces.init(allocator, &store, &terminals, &pool, instance.state.dir);
    defer workspaces.deinit();
    workspaces.screen_history_writer = &history_writer;
    var uploads = Uploads.init(allocator, instance.state.dir);
    defer uploads.deinit();
    var configs = Configs.init(allocator, instance.state.dir);
    defer configs.deinit();
    terminals.structure_hook = workspaces.hook();
    defer terminals.structure_hook = null;
    var surfaces = try Surfaces.init(allocator, &terminals, &reactor);
    defer surfaces.deinit();
    var domains = Domains{ .terminals = &terminals, .surfaces = &surfaces, .workspaces = &workspaces, .uploads = &uploads, .configs = &configs };
    reactor.control.handler = .{ .context = &domains, .respond = terminalRespond, .disconnect = terminalDisconnect, .input_closed = terminalInputClosed };
    // Reactor's original teardown occurs after domain teardown; clear callback
    // borrowing first. Domain deinit already owns attachment cleanup on exit.
    defer reactor.control.handler = null;
    // The serving session answers registry queries about itself from its own
    // identity: it cannot connect to its own control socket mid-request.
    var registry = RegistryEndpoint{
        .registry = .{
            .parent = instance.parent,
            .launcher = .child_process,
            .live = Session.withKnown(ids.uuidText(instance.identity.session_id), ids.uuidText(instance.identity.server_id), ids.uuidText(instance.epoch), name),
        },
        .log = &terminals.log,
        .epoch = instance.epoch,
    };
    reactor.control.registry = .{ .context = &registry, .respond = registryRespond };
    defer reactor.control.registry = null;
    reactor.control.advertised_capabilities = &.{ "health_check", "server_lifecycle", "terminal_control", "terminal_observe", "surface_interest", "session_snapshot", "workspace_mutation", "agent_state", "session_restore", "session_settings", "image_upload", "server_config", "custom_commands", "server_replace", "live_handoff" };
    var clock = try std.time.Timer.start();
    if (try stopping()) return error.ServiceStartupCancelled;
    if (report) |writer| try writer.finish(.ready);
    var shutdown_started = false;
    while (true) {
        if (try stopping()) reactor.control.stop_requested = true;
        if (reactor.control.stop_requested and !shutdown_started) {
            pool.beginShutdown();
            shutdown_started = true;
        }
        pool.tick();
        try terminals.tick();
        try workspaces.tick();
        try deliverTerminalMessages(allocator, &reactor, &terminals);
        try deliverWorkspaceMessages(allocator, &reactor, &terminals, &workspaces);
        try reactor.step(instance, clock.read());
        try terminals.tick();
        try workspaces.tick();
        try deliverTerminalMessages(allocator, &reactor, &terminals);
        try deliverWorkspaceMessages(allocator, &reactor, &terminals, &workspaces);
        try surfaces.tick(clock.read() / std.time.ns_per_ms);
        workspaces.maybeSyncAgentBindings();
        persistScreenHistory(&history_writer, &store, &pool, clock.read());
        reactor.control.revision = store.revision;
        // P8.4: main loop trigger for live handoff. When the control handler
        // accepts server.handoff, the flag is set; we freeze control writes,
        // fork/exec the new binary, transfer PTY FDs via SCM_RIGHTS, and
        // exit if the new service confirms takeover.
        if (reactor.control.handoff_requested) {
            reactor.control.handoff_requested = false;
            const binary_path = std.posix.getenv("ASTER_SESSION_BINARY") orelse blk: {
                // Default: re-exec ourselves from /proc/self/exe (Linux) or argv[0].
                var self_buf: [std.fs.max_path_bytes]u8 = undefined;
                break :blk std.fs.selfExePath(&self_buf) catch null;
            };
            if (binary_path) |bp| {
                const parent_path = instance.parent.realpathAlloc(allocator, ".") catch null;
                defer if (parent_path) |pp| allocator.free(pp);
                if (parent_path) |pp| {
                    const success = handoff.performHandoff(
                        allocator,
                        &pool,
                        &store,
                        &terminals.agent_store,
                        instance.epoch,
                        bp,
                        pp,
                        name,
                    ) catch false;
                    if (success) {
                        // Handoff confirmed. Drain pending responses (including
                        // the server.handoff accepted reply) before exiting.
                        {
                            var drain_clock = std.time.Timer.start() catch null;
                            while (drain_clock) |*dc| {
                                if (dc.read() > 250 * std.time.ns_per_ms or reactor.drain()) break;
                                reactor.waitWithWake(instance, dc.read(), 5, wake) catch break;
                            }
                        }
                        // Invalidate pool entries so deinit won't double-close them.
                        // Also don't kill the child processes — they belong to the new service.
                        for (pool.entries.items) |*entry| {
                            entry.session.process.master = -1;
                            entry.session.process.pid = -1;
                        }
                        return;
                    }
                    // Handoff failed or was rejected; continue serving.
                }
            }
        }
        if (reactor.control.stop_requested and !shutdown_started) {
            pool.beginShutdown();
            shutdown_started = true;
        }
        if (reactor.control.stop_requested and pool.quiescent()) {
            const deadline = clock.read() + 250 * std.time.ns_per_ms;
            while (clock.read() < deadline and !reactor.drain())
                try reactor.waitWithWake(instance, clock.read(), 10, wake);
            return;
        }
        // When terminals produced output, poll() would return immediately
        // (data always available), creating a CPU-bound busy loop. Cap the
        // maximum wait to 1 ms so the loop yields briefly between ticks.
        const max_wait: u32 = if (pool.last_tick_active) 1 else 1000;
        try waitResources(&reactor, instance, &pool, clock.read(), max_wait, wake);
    }
}

/// Runs the new service in takeover mode: receives state from an old service
/// via the private socket FD, adopts terminals, and starts serving. The old
/// service blocks until we send confirmation or timeout.
pub fn runTakeover(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, takeover_fd: std.posix.fd_t) !void {
    // 30s receive timeout: if old service dies before sending state, exit
    // instead of blocking forever. Also ensures SIGTERM produces an error
    // return from recvmsg rather than silently restarting the syscall.
    const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
    std.posix.setsockopt(takeover_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Receive state (PTY FDs + envelope) from old service via SCM_RIGHTS.
    var received = try handoff.receiveState(allocator, takeover_fd);
    defer received.deinit();

    // Verify FDs are readable and child processes alive.
    const valid = try handoff.verifyReceivedState(&received);
    _ = valid;

    // Generate new epoch for this incarnation.
    const new_epoch = ids.newUUID();

    // Do NOT confirm yet: the old service must keep serving until we have
    // acquired the lock and adopted terminals. Confirmation moves into
    // runWithAdoptedState after lock + pool setup succeed.
    try runWithAdoptedState(allocator, parent, name, new_epoch, &received, takeover_fd);
}

/// Starts the service loop with terminals adopted from a live handoff.
/// Mirrors runInitialized but pre-populates the pool and agent store from
/// the received handoff state before entering the main loop.
fn runWithAdoptedState(allocator: std.mem.Allocator, parent: std.fs.Dir, name: []const u8, new_epoch: [16]u8, received: *handoff.ReceivedState, takeover_fd: ?std.posix.fd_t) !void {
    const wake = c.session_bridge_signals_start();
    if (wake < 0) return error.ServiceSignalSetupFailed;
    defer c.session_bridge_signals_stop();
    // The old service still holds the lock while cleaning up. Retry with
    // a short backoff until it releases (typically <100ms).
    var instance: Instance = undefined;
    {
        var attempt: u32 = 0;
        while (attempt < 50) : (attempt += 1) {
            instance = Instance.open(parent, name) catch |err| {
                if (err == error.AlreadyRunning) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            break;
        } else {
            return error.HandoffLockTimeout;
        }
    }
    instance.epoch = new_epoch;
    defer {
        const cleanup = instance.close();
        cleanup catch {};
    }

    var reactor = try Reactor.init(allocator, &instance, .{});
    defer reactor.deinit();
    var pool = try Pool.init(allocator, .{ .scope_cleanup = true });
    defer pool.deinit();

    // Adopt terminals from the old service: each PTY FD + PID pair becomes
    // a pool entry with the same terminalID. VT state rebuilds from PTY output.
    const envelope = received.envelope.value;
    for (received.fds, envelope.terminals) |fd, terminal| {
        var id_buf: [36]u8 = undefined;
        @memcpy(&id_buf, terminal.id[0..36]);
        pool.adoptTerminal(id_buf, fd, terminal.pid, terminal.cwd, terminal.history_excluded) catch |err| {
            std.log.err("adoptTerminal failed for {s}: {}", .{ terminal.id, err });
            continue;
        };
    }

    // All terminals adopted and lock acquired. NOW confirm takeover to old
    // service so it closes its FD copies and exits. If we crash before this
    // point, the old service times out (5s) and continues serving — no data
    // loss, no double-ownership.
    if (takeover_fd) |tfd| {
        handoff.sendConfirmation(tfd, true, new_epoch) catch |err| {
            std.log.err("handoff confirmation failed: {}", .{err});
        };
        std.posix.close(tfd);
    }

    var store = Store.init(allocator);
    defer store.deinit();
    // Restore layout from handoff envelope if available; otherwise load from disk.
    if (envelope.layout_json) |layout_json| {
        store.loadFromJson(layout_json) catch {
            store.load(instance.state.dir) catch {};
        };
    } else {
        store.load(instance.state.dir) catch {};
    }

    var history_config = screen_history.Config{ .enabled = store.screen_history_enabled };
    if (std.posix.getenv("ASTER_HISTORY_SESSION_LIMIT")) |val| {
        history_config.session_limit = std.fmt.parseInt(usize, val, 10) catch history_config.session_limit;
    }
    if (std.posix.getenv("ASTER_HISTORY_PER_TERMINAL_LIMIT")) |val| {
        history_config.per_terminal_limit = std.fmt.parseInt(usize, val, 10) catch history_config.per_terminal_limit;
    }
    if (std.posix.getenv("ASTER_HISTORY_SNAPSHOT_INTERVAL_MS")) |val| {
        history_config.snapshot_interval_ms = std.fmt.parseInt(u64, val, 10) catch history_config.snapshot_interval_ms;
    }
    var history_writer = try screen_history.Writer.init(allocator, instance.state.dir, history_config);
    defer history_writer.deinit();
    var terminals = try Terminals.init(allocator, &pool, &instance.state, instance.identity, new_epoch);
    defer terminals.deinit();
    terminals.shared_revision = &store.revision;

    // Restore agent metadata from the handoff envelope. The agent store
    // uses the same JSON array format as serializeAgents in handoff.zig.
    if (envelope.agents_json) |agents_json| {
        restoreAgentStore(&terminals.agent_store, allocator, agents_json);
    }

    var workspaces = try Workspaces.init(allocator, &store, &terminals, &pool, instance.state.dir);
    defer workspaces.deinit();
    workspaces.screen_history_writer = &history_writer;
    var uploads = Uploads.init(allocator, instance.state.dir);
    defer uploads.deinit();
    var configs = Configs.init(allocator, instance.state.dir);
    defer configs.deinit();
    terminals.structure_hook = workspaces.hook();
    defer terminals.structure_hook = null;
    var surfaces = try Surfaces.init(allocator, &terminals, &reactor);
    defer surfaces.deinit();
    var domains = Domains{ .terminals = &terminals, .surfaces = &surfaces, .workspaces = &workspaces, .uploads = &uploads, .configs = &configs };
    reactor.control.handler = .{ .context = &domains, .respond = terminalRespond, .disconnect = terminalDisconnect, .input_closed = terminalInputClosed };
    defer reactor.control.handler = null;
    var registry = RegistryEndpoint{
        .registry = .{
            .parent = instance.parent,
            .launcher = .child_process,
            .live = Session.withKnown(ids.uuidText(instance.identity.session_id), ids.uuidText(instance.identity.server_id), ids.uuidText(new_epoch), name),
        },
        .log = &terminals.log,
        .epoch = new_epoch,
    };
    reactor.control.registry = .{ .context = &registry, .respond = registryRespond };
    defer reactor.control.registry = null;
    reactor.control.advertised_capabilities = &.{ "health_check", "server_lifecycle", "terminal_control", "terminal_observe", "surface_interest", "session_snapshot", "workspace_mutation", "agent_state", "session_restore", "session_settings", "image_upload", "server_config", "custom_commands", "server_replace", "live_handoff" };
    var clock = try std.time.Timer.start();
    if (try stopping()) return error.ServiceStartupCancelled;
    // Lease state for adopted terminals: clients reconnecting with the old
    // epoch get stale_server_epoch and must re-acquire leases. Existing lease
    // state is intentionally empty so old holders see lease_lost on reconnect.
    var shutdown_started = false;
    while (true) {
        if (try stopping()) reactor.control.stop_requested = true;
        if (reactor.control.stop_requested and !shutdown_started) {
            pool.beginShutdown();
            shutdown_started = true;
        }
        pool.tick();
        try terminals.tick();
        try workspaces.tick();
        try deliverTerminalMessages(allocator, &reactor, &terminals);
        try deliverWorkspaceMessages(allocator, &reactor, &terminals, &workspaces);
        try reactor.step(&instance, clock.read());
        try terminals.tick();
        try workspaces.tick();
        try deliverTerminalMessages(allocator, &reactor, &terminals);
        try deliverWorkspaceMessages(allocator, &reactor, &terminals, &workspaces);
        try surfaces.tick(clock.read() / std.time.ns_per_ms);
        workspaces.maybeSyncAgentBindings();
        persistScreenHistory(&history_writer, &store, &pool, clock.read());
        reactor.control.revision = store.revision;
        if (reactor.control.handoff_requested) {
            reactor.control.handoff_requested = false;
            const binary_path = std.posix.getenv("ASTER_SESSION_BINARY") orelse blk: {
                var self_buf: [std.fs.max_path_bytes]u8 = undefined;
                break :blk std.fs.selfExePath(&self_buf) catch null;
            };
            if (binary_path) |bp| {
                const parent_path = instance.parent.realpathAlloc(allocator, ".") catch null;
                defer if (parent_path) |pp| allocator.free(pp);
                if (parent_path) |pp| {
                    const success = handoff.performHandoff(
                        allocator,
                        &pool,
                        &store,
                        &terminals.agent_store,
                        instance.epoch,
                        bp,
                        pp,
                        name,
                    ) catch false;
                    if (success) {
                        // Drain pending responses before exit.
                        {
                            var drain_clock = std.time.Timer.start() catch null;
                            while (drain_clock) |*dc| {
                                if (dc.read() > 250 * std.time.ns_per_ms or reactor.drain()) break;
                                reactor.waitWithWake(&instance, dc.read(), 5, wake) catch break;
                            }
                        }
                        for (pool.entries.items) |*entry| {
                            entry.session.process.master = -1;
                            entry.session.process.pid = -1;
                        }
                        return;
                    }
                }
            }
        }
        if (reactor.control.stop_requested and !shutdown_started) {
            pool.beginShutdown();
            shutdown_started = true;
        }
        if (reactor.control.stop_requested and pool.quiescent()) {
            const deadline = clock.read() + 250 * std.time.ns_per_ms;
            while (clock.read() < deadline and !reactor.drain())
                try reactor.waitWithWake(&instance, clock.read(), 10, wake);
            return;
        }
        const max_wait: u32 = if (pool.last_tick_active) 1 else 1000;
        try waitResources(&reactor, &instance, &pool, clock.read(), max_wait, wake);
    }
}

/// Snapshot each terminal's visible screen to disk if the interval has elapsed.
/// Syncs the writer's enabled flag with the store so settings.update takes
/// effect without a server restart. Checks the interval before iterating
/// terminals so expensive snapshotForClient calls are skipped entirely when
/// the cadence has not elapsed. Errors are silently ignored: screen history
/// is best-effort and must never crash the service main loop.
fn persistScreenHistory(writer: *screen_history.Writer, store: *Store, pool: *Pool, now_ns: u64) void {
    // Dynamic toggle: track the store's flag each tick.
    writer.config.enabled = store.screen_history_enabled;
    if (!writer.config.enabled) return;
    const now_ms = now_ns / std.time.ns_per_ms;
    // Skip the entire snapshot pass when the interval has not elapsed yet.
    // Previously the interval check was inside maybePersist, but
    // snapshotForClient had already allocated and captured each terminal's
    // screen -- wasted work under high-output load.
    if (writer.last_snapshot_ms != 0 and now_ms >= writer.last_snapshot_ms and
        now_ms - writer.last_snapshot_ms < writer.config.snapshot_interval_ms) return;
    for (pool.entries.items) |*entry| {
        const screen_text = entry.session.snapshotForClient(writer.config.per_terminal_limit) catch continue;
        const text = screen_text orelse continue;
        defer entry.session.allocator.free(text);
        writer.maybePersist(entry.id, text, now_ms, entry.history_excluded) catch {};
    }
}

fn stopping() !bool {
    const signal = c.session_bridge_signals_take();
    if (signal < 0) return error.ServiceSignalReadFailed;
    return signal == c.SIGTERM or signal == c.SIGINT or signal == c.SIGHUP;
}

/// Restores agent metadata from the handoff envelope's agents_json into
/// the terminal service's agent store. Best-effort: malformed entries are
/// silently skipped so handoff is not blocked by agent state corruption.
fn restoreAgentStore(store: *@import("agent_store.zig").Store, allocator: std.mem.Allocator, json_bytes: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return;
    defer parsed.deinit();
    const array = switch (parsed.value) {
        .array => |a| a,
        else => return,
    };
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const tid_str = if (obj.get("terminalID")) |v| switch (v) {
            .string => |s| s,
            else => continue,
        } else continue;
        if (tid_str.len != 36) continue;
        var tid: [36]u8 = undefined;
        @memcpy(&tid, tid_str[0..36]);
        const provider = if (obj.get("provider")) |v| switch (v) {
            .string => |s| s,
            else => continue,
        } else continue;
        const state_str = if (obj.get("state")) |v| switch (v) {
            .string => |s| s,
            else => "unknown",
        } else "unknown";
        const state = @import("agent_store.zig").State.fromString(state_str) orelse .unknown;
        const name_val = if (obj.get("name")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
        const native_session = if (obj.get("nativeSession")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
        const source = if (obj.get("source")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
        _ = store.report(tid, provider, state, name_val, native_session, source) catch continue;
    }
}

fn waitResources(reactor: *Reactor, instance: *Instance, pool: *Pool, now: u64, maximum_ms: u32, wake: ?std.posix.fd_t) !void {
    var buffer: [64]std.posix.pollfd = undefined;
    const descriptors = try pool.pollDescriptors(&buffer);
    const timeout: u32 = @intCast(pool.maximumWaitMilliseconds(@intCast(maximum_ms)));
    try reactor.waitWithDescriptors(instance, now, timeout, wake, descriptors);
}

test "service scheduling drains detached terminal while another startup fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var instance = try Instance.open(tmp.dir, "session");
    defer instance.close() catch @panic("service test cleanup failed");
    var reactor = try Reactor.init(std.testing.allocator, &instance, .{});
    defer reactor.deinit();
    var pool = try Pool.init(std.testing.allocator, .{});
    defer pool.deinit();
    const id = "00000000-0000-4000-8000-000000000001".*;
    const failed_id = "00000000-0000-4000-8000-000000000002".*;
    try pool.beginCreate(id, .{ .cwd = "/", .argv = &.{ "/bin/sh", "-c", "printf BEFORE; sleep 0.08; printf AFTER; exit 7" } });
    try pool.beginCreate(failed_id, .{ .cwd = "/", .argv = &.{"/aster-missing-test-program"} });
    var clock = try std.time.Timer.start();
    var created = false;
    var failed = false;
    while (clock.read() < 3 * std.time.ns_per_s) {
        pool.tick();
        try reactor.step(&instance, clock.read());
        while (pool.takeCompletion()) |completion| {
            if (std.mem.eql(u8, &completion.id, &id)) {
                try std.testing.expect(completion.result == .created);
                created = true;
            } else {
                try std.testing.expect(completion.result == .failed);
                failed = true;
            }
        }
        if (pool.find(id)) |entry| {
            if (entry.session.exit_status != null and entry.session.eof) break;
        }
        try waitResources(&reactor, &instance, &pool, clock.read(), 100, null);
    }
    try std.testing.expect(created and failed);
    const entry = pool.find(id).?;
    try std.testing.expect(entry.failure == null);
    try std.testing.expectEqual(@as(u8, 7), std.posix.W.EXITSTATUS(entry.session.exit_status.?));
    const screen = try entry.session.terminal.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "BEFOREAFTER") != null);
}

fn terminalRespond(context: *anyopaque, allocator: std.mem.Allocator, request: Request, generation: u64) anyerror!?[]u8 {
    const domains: *Domains = @ptrCast(@alignCast(context));
    return switch (request.operation) {
        .@"surface.subscribe", .@"surface.unsubscribe", .@"surface.snapshot" => domains.surfaces.respond(allocator, request, generation),
        .@"session.snapshot", .@"session.restore", .@"session.settings.get", .@"session.settings.update", .@"workspace.list", .@"workspace.create", .@"workspace.update", .@"workspace.close", .@"tab.create", .@"tab.update", .@"tab.close", .@"pane.split", .@"pane.update", .@"pane.close" => domains.workspaces.respond(allocator, request, generation),
        .@"upload.begin", .@"upload.chunk", .@"upload.commit", .@"upload.abort", .@"upload.clear", .@"upload.status" => domains.uploads.respond(allocator, request, generation),
        .@"config.get", .@"config.reload", .@"custom_command.list", .@"custom_command.run" => domains.configs.respond(allocator, request, generation),
        // P8.3: server.replace returns accepted; orchestration is deferred.
        // server.handoff is handled at the Control level (sets handoff_requested flag).
        .@"server.replace" => {
            const Accepted = struct { accepted: bool };
            const replies = @import("operation_response.zig");
            const response = replies.Response(Accepted){
                .type = "response",
                .requestID = request.requestID,
                .operation = request.operation,
                .scope = request.scope,
                .target = request.target,
                .revision = 0,
                .result = .{ .accepted = true },
            };
            return try std.json.Stringify.valueAlloc(allocator, response, .{ .emit_null_optional_fields = false });
        },
        else => domains.terminals.respond(allocator, request, generation),
    };
}
fn terminalDisconnect(context: *anyopaque, generation: u64) void {
    const domains: *Domains = @ptrCast(@alignCast(context));
    domains.surfaces.disconnect(generation);
    domains.workspaces.disconnect(generation);
    // 断线时清理该连接发起的上传，删除临时文件防止半文件残留
    domains.uploads.disconnectByGeneration(generation);
    domains.terminals.disconnect(generation);
}

fn registryRespond(context: *anyopaque, allocator: std.mem.Allocator, request: Request) anyerror![]u8 {
    const endpoint: *RegistryEndpoint = @ptrCast(@alignCast(context));
    return endpoint.respond(allocator, request);
}

/// Broadcasts structural changes. The body is domain-owned; only the envelope
/// (eventID plus this connection's next sequence and the current revision)
/// belongs to the transport, so no two connections share a sequence.
fn deliverWorkspaceMessages(allocator: std.mem.Allocator, reactor: *Reactor, terminals: *Terminals, workspaces: *Workspaces) !void {
    while (workspaces.takeReply()) |reply| {
        defer allocator.free(reply.bytes);
        _ = reactor.deliver(reply.connection_generation, reply.bytes, true);
    }
    while (workspaces.takeEvent()) |event| {
        defer allocator.free(event.body);
        var generations: [64]u64 = undefined;
        const recipients = try reactor.controlGenerations(&generations);
        const event_id = ids.uuidText(ids.newUUID());
        for (recipients) |generation| {
            const sequence = reactor.nextEventSequence(generation) orelse {
                reactor.drop(generation);
                continue;
            };
            const encoded = std.fmt.allocPrint(allocator,
                "{{\"type\":\"event\",\"event\":\"{s}\",\"eventID\":\"{s}\",\"target\":{{\"serverID\":\"{s}\",\"serverEpoch\":\"{s}\",\"sessionID\":\"{s}\"}},\"sequence\":{d},\"revision\":{d},\"body\":{s}}}",
                .{ event.name, &event_id, &terminals.server_id, &terminals.epoch_text, &terminals.session_id, sequence, event.revision, event.body }) catch {
                reactor.drop(generation);
                continue;
            };
            defer allocator.free(encoded);
            _ = reactor.deliver(generation, encoded, false);
        }
    }
}
fn deliverTerminalMessages(allocator: std.mem.Allocator, reactor: *Reactor, terminals: *Terminals) !void {
    while (terminals.takeReply()) |reply| {
        defer allocator.free(reply.bytes);
        _ = reactor.deliver(reply.connection_generation, reply.bytes, true);
    }
    while (terminals.takeExitEvent()) |terminal| {
        var generations: [64]u64 = undefined;
        const recipients = try reactor.controlGenerations(&generations);
        const event_id = ids.uuidText(ids.newUUID());
        for (recipients) |generation| {
            const sequence = reactor.nextEventSequence(generation) orelse {
                reactor.drop(generation);
                continue;
            };
            const encoded = std.json.Stringify.valueAlloc(allocator, .{
                .type = "event",
                .event = "terminal.exited",
                .eventID = &event_id,
                .target = .{ .serverID = &terminals.server_id, .serverEpoch = &terminals.epoch_text, .sessionID = &terminals.session_id },
                .sequence = sequence,
                .revision = terminals.currentRevision(),
                .body = terminal,
            }, .{ .emit_null_optional_fields = false }) catch {
                reactor.drop(generation);
                continue;
            };
            defer allocator.free(encoded);
            _ = reactor.deliver(generation, encoded, false);
        }
    }
    while (terminals.takeLeaseEvent()) |event| {
        const sequence = reactor.nextEventSequence(event.connection_generation) orelse {
            reactor.drop(event.connection_generation);
            continue;
        };
        const event_id = ids.uuidText(ids.newUUID());
        const encoded = std.json.Stringify.valueAlloc(allocator, .{
            .type = "event",
            .event = "lease.revoked",
            .eventID = &event_id,
            .target = .{ .serverID = &terminals.server_id, .serverEpoch = &terminals.epoch_text, .sessionID = &terminals.session_id },
            .sequence = sequence,
            .revision = terminals.currentRevision(),
            .body = .{ .terminalID = &event.terminal_id, .leaseID = &event.grant.lease.lease_id, .leaseEpoch = event.grant.lease.lease_epoch, .reason = event.reason },
        }, .{}) catch {
            reactor.drop(event.connection_generation);
            continue;
        };
        defer allocator.free(encoded);
        _ = reactor.deliver(event.connection_generation, encoded, false);
    }
    // agent.changed 事件广播给所有控制连接
    while (terminals.takeAgentEvent()) |body| {
        defer allocator.free(body);
        var generations: [64]u64 = undefined;
        const recipients = try reactor.controlGenerations(&generations);
        const event_id = ids.uuidText(ids.newUUID());
        for (recipients) |generation| {
            const sequence = reactor.nextEventSequence(generation) orelse {
                reactor.drop(generation);
                continue;
            };
            const encoded = std.fmt.allocPrint(allocator,
                "{{\"type\":\"event\",\"event\":\"agent.changed\",\"eventID\":\"{s}\",\"target\":{{\"serverID\":\"{s}\",\"serverEpoch\":\"{s}\",\"sessionID\":\"{s}\"}},\"sequence\":{d},\"revision\":{d},\"body\":{s}}}",
                .{ &event_id, &terminals.server_id, &terminals.epoch_text, &terminals.session_id, sequence, terminals.currentRevision(), body }) catch {
                reactor.drop(generation);
                continue;
            };
            defer allocator.free(encoded);
            _ = reactor.deliver(generation, encoded, false);
        }
    }
}

fn terminalInputClosed(context: *anyopaque, generation: u64) void {
    const domains: *Domains = @ptrCast(@alignCast(context));
    domains.terminals.inputClosed(generation);
}
