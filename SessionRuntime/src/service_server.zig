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
const Domains = struct { terminals: *Terminals, surfaces: *Surfaces, workspaces: *Workspaces };
const Request = @import("operation_request.zig").Request;
const ids = @import("service_identity.zig");
const Report = @import("startup_report.zig").Writer;
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
    terminals.structure_hook = workspaces.hook();
    defer terminals.structure_hook = null;
    var surfaces = try Surfaces.init(allocator, &terminals, &reactor);
    defer surfaces.deinit();
    var domains = Domains{ .terminals = &terminals, .surfaces = &surfaces, .workspaces = &workspaces };
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
    reactor.control.advertised_capabilities = &.{ "health_check", "server_lifecycle", "terminal_control", "terminal_observe", "surface_interest", "session_snapshot", "workspace_mutation", "agent_state", "session_restore", "session_settings" };
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
        try waitResources(&reactor, instance, &pool, clock.read(), 1000, wake);
    }
}

/// Snapshot each terminal's visible screen to disk if the interval has elapsed.
/// Syncs the writer's enabled flag with the store so settings.update takes
/// effect without a server restart. Errors are caught and silently ignored:
/// screen history is best-effort and must never crash the service main loop.
fn persistScreenHistory(writer: *screen_history.Writer, store: *Store, pool: *Pool, now_ns: u64) void {
    // Dynamic toggle: track the store's flag each tick.
    writer.config.enabled = store.screen_history_enabled;
    if (!writer.config.enabled) return;
    const now_ms = now_ns / std.time.ns_per_ms;
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
        else => domains.terminals.respond(allocator, request, generation),
    };
}
fn terminalDisconnect(context: *anyopaque, generation: u64) void {
    const domains: *Domains = @ptrCast(@alignCast(context));
    domains.surfaces.disconnect(generation);
    domains.workspaces.disconnect(generation);
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
