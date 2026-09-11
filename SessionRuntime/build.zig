const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "aster-session",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const vt_prefix = b.option([]const u8, "vt-prefix", "Built pinned libghostty-vt prefix");
    const options = b.addOptions();
    options.addOption(bool, "with_vt", vt_prefix != null);
    exe.root_module.addOptions("build_options", options);
    if (vt_prefix) |prefix| {
        exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libghostty-vt.a" }) });
        exe.root_module.link_libc = true;
        exe.root_module.addIncludePath(b.path(".build/ghostty/src/stb"));
        exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/png.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        exe.root_module.addIncludePath(b.path("src/platform"));
        exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/daemon.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/bridge_signals.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    }
    b.installArtifact(exe);
    for ([_]struct { name: []const u8, source: []const u8, filter: []const u8 }{
        .{ .name = "test-surface-interest", .source = "src/surface_interest.zig", .filter = "surface interest" },
        .{ .name = "test-surface-stream", .source = "src/surface_stream.zig", .filter = "surface stream" },
    }) |suite| {
        const surface_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(suite.source),
            .target = target,
            .optimize = optimize,
        }), .filters = &.{suite.filter} });
        b.step(suite.name, "Run bounded surface protocol module tests").dependOn(&b.addRunArtifact(surface_tests).step);
    }
    const async_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/pty_startup.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }), .filters = &.{"startup"} });
    async_tests.root_module.addIncludePath(b.path("src/platform"));
    async_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    async_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    async_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    b.step("test-async-startup", "Run nonblocking PTY startup tests").dependOn(&b.addRunArtifact(async_tests).step);
    const layout_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/workspace_store.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }), .filters = &.{"workspace store"} });
    b.step("test-workspace-store", "Run workspace/tab/pane tree and layout persistence tests").dependOn(&b.addRunArtifact(layout_tests).step);
    const agent_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent_store.zig"),
        .target = target,
        .optimize = optimize,
    }), .filters = &.{"agent store"} });
    b.step("test-agent-store", "Run bounded agent state store tests").dependOn(&b.addRunArtifact(agent_tests).step);
    const idempotency_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/idempotency_log.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-idempotency", "Run bounded durable mutation journal tests").dependOn(&b.addRunArtifact(idempotency_tests).step);
    const lease_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/writer_lease.zig"),
        .target = target,
        .optimize = optimize,
    }), .filters = &.{"writer lease"} });
    b.step("test-lease", "Run single writer lease transitions").dependOn(&b.addRunArtifact(lease_tests).step);
    const signals_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/service_signals.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    signals_tests.root_module.addIncludePath(b.path("src/platform"));
    signals_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/bridge_signals.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    b.step("test-signals", "Run service child wakeup and signal ownership tests").dependOn(&b.addRunArtifact(signals_tests).step);
    // 事件订阅只在这条 CLI 里使用，因此帧解码的边界（拼接帧、损坏帧头）单独成一个
    // 快速套件；端到端行为由 tests/event_stream.py 用真实服务证明。
    const event_stream_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/event_subscribe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }), .filters = &.{"frame decoder"} });
    event_stream_tests.root_module.addIncludePath(b.path("src/platform"));
    event_stream_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/bridge_signals.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    event_stream_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    event_stream_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    event_stream_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    b.step("test-event-stream", "Run event subscription frame decoding tests").dependOn(&b.addRunArtifact(event_stream_tests).step);
    const launch_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/launch_preparation.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }), .filters = &.{"launch preparation"} });
    b.step("test-launch", "Run execution-machine launch preparation tests").dependOn(&b.addRunArtifact(launch_tests).step);
    const pty_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/pty.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    pty_tests.root_module.link_libc = true;
    pty_tests.root_module.addIncludePath(b.path("src/platform"));
    pty_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    pty_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    pty_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    const run_pty = b.addRunArtifact(pty_tests);
    b.step("test-pty", "Run real PTY lifecycle tests").dependOn(&run_pty.step);
    const install_tests = b.step("test-binaries", "Install cross-platform test executables without running");
    install_tests.dependOn(&b.addInstallArtifact(layout_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "workspace-store-tests" }).step);
    install_tests.dependOn(&b.addInstallArtifact(pty_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "pty-tests" }).step);
    const reactor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/service_reactor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    reactor_tests.root_module.addIncludePath(b.path("src/platform"));
    reactor_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    reactor_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    reactor_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    b.step("test-reactor", "Run bounded multi-client control scheduler tests").dependOn(&b.addRunArtifact(reactor_tests).step);
    install_tests.dependOn(&b.addInstallArtifact(reactor_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "reactor-tests" }).step);
    const connection_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/service_connection.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    connection_tests.root_module.addIncludePath(b.path("src/platform"));
    connection_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    connection_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    connection_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    b.step("test-connection", "Run authenticated control socket transport tests").dependOn(&b.addRunArtifact(connection_tests).step);
    install_tests.dependOn(&b.addInstallArtifact(connection_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "connection-tests" }).step);
    const control_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/service_control.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-control", "Run service control handlers and handshake tests").dependOn(&b.addRunArtifact(control_tests).step);
    install_tests.dependOn(&b.addInstallArtifact(control_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "control-tests" }).step);
    const identity_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/service_identity.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-identity", "Run durable service identity tests").dependOn(&b.addRunArtifact(identity_tests).step);
    install_tests.dependOn(&b.addInstallArtifact(identity_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "identity-tests" }).step);
    const startup_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/startup_report.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    startup_tests.root_module.addIncludePath(b.path("src/platform"));
    startup_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    startup_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    startup_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    b.step("test-startup", "Run bounded daemon readiness report tests").dependOn(&b.addRunArtifact(startup_tests).step);
    install_tests.dependOn(&b.addInstallArtifact(startup_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "startup-tests" }).step);
    const socket_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/service_socket.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    socket_tests.root_module.addIncludePath(b.path("src/platform"));
    socket_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    socket_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    socket_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
    b.step("test-socket", "Run private service socket lifecycle tests").dependOn(&b.addRunArtifact(socket_tests).step);
    install_tests.dependOn(&b.addInstallArtifact(socket_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "socket-tests" }).step);
    const state_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/state_directory.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    b.step("test-state", "Run private state and service lifetime lock tests").dependOn(&b.addRunArtifact(state_tests).step);
    install_tests.dependOn(&b.addInstallArtifact(state_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "state-tests" }).step);
    if (vt_prefix) |prefix| {
        const history_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/history_budget.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }), .filters = &.{"history budget"} });
        history_tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        history_tests.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libghostty-vt.a" }) });
        history_tests.root_module.addIncludePath(b.path(".build/ghostty/src/stb"));
        history_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/png.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        b.step("test-history", "Run retained history allocation and trimming tests").dependOn(&b.addRunArtifact(history_tests).step);
        b.step("install-history-test", "Build only retained history tests").dependOn(&b.addInstallArtifact(history_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "history-tests" }).step);
        const service_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/service_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }), .filters = &.{"service scheduling"} });
        service_tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        service_tests.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libghostty-vt.a" }) });
        service_tests.root_module.addIncludePath(b.path(".build/ghostty/src/stb"));
        service_tests.root_module.addIncludePath(b.path("src/platform"));
        for ([_][]const u8{ "png.c", "pty.c", "pty_startup.c", "bridge_signals.c", "process_scope.c" }) |file| {
            service_tests.root_module.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "src/platform", file })), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        }
        b.step("test-service-pool", "Run service scheduling with asynchronous PTYs").dependOn(&b.addRunArtifact(service_tests).step);
        b.step("install-service-pool-test", "Build only service/PTY scheduling test executable").dependOn(&b.addInstallArtifact(service_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "service-pool-tests" }).step);
        const terminal_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/terminal_service.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }), .filters = &.{ "terminal service", "completion persistence failure" } });
        terminal_tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        terminal_tests.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libghostty-vt.a" }) });
        terminal_tests.root_module.addIncludePath(b.path(".build/ghostty/src/stb"));
        terminal_tests.root_module.addIncludePath(b.path("src/platform"));
        for ([_][]const u8{ "png.c", "pty.c", "pty_startup.c", "bridge_signals.c", "process_scope.c" }) |file| {
            terminal_tests.root_module.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "src/platform", file })), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        }
        b.step("test-terminal-service", "Run terminal lifecycle and persistence failure tests").dependOn(&b.addRunArtifact(terminal_tests).step);
        b.step("install-terminal-service-test", "Build only terminal service test executable").dependOn(&b.addInstallArtifact(terminal_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "terminal-service-tests" }).step);
        const registry_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/session_registry.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }), .filters = &.{"session registry"} });
        registry_tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        registry_tests.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libghostty-vt.a" }) });
        registry_tests.root_module.addIncludePath(b.path(".build/ghostty/src/stb"));
        registry_tests.root_module.addIncludePath(b.path("src/platform"));
        for ([_][]const u8{ "png.c", "pty.c", "pty_startup.c", "bridge_signals.c", "process_scope.c", "daemon.c" }) |file| {
            registry_tests.root_module.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "src/platform", file })), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        }
        b.step("test-registry", "Run named session registry naming and listing tests").dependOn(&b.addRunArtifact(registry_tests).step);
        install_tests.dependOn(&b.addInstallArtifact(registry_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "registry-tests" }).step);
        const pool_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/terminal_pool.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        pool_tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        pool_tests.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libghostty-vt.a" }) });
        pool_tests.root_module.addIncludePath(b.path(".build/ghostty/src/stb"));
        pool_tests.root_module.addIncludePath(b.path("src/platform"));
        pool_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/png.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        pool_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        pool_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        pool_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        b.step("test-pool", "Run service-owned multi-PTY tests").dependOn(&b.addRunArtifact(pool_tests).step);
        install_tests.dependOn(&b.addInstallArtifact(pool_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "pool-tests" }).step);
        const vt_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/vt.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        vt_tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        vt_tests.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libghostty-vt.a" }) });
        vt_tests.root_module.link_libc = true;
        vt_tests.root_module.addIncludePath(b.path(".build/ghostty/src/stb"));
        vt_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/png.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        install_tests.dependOn(&b.addInstallArtifact(vt_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "vt-tests" }).step);
        const session_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/session.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        session_tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        session_tests.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libghostty-vt.a" }) });
        session_tests.root_module.link_libc = true;
        session_tests.root_module.addIncludePath(b.path(".build/ghostty/src/stb"));
        session_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/png.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        session_tests.root_module.addIncludePath(b.path("src/platform"));
        session_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        session_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/process_scope.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        session_tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/pty_startup.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE" } });
        install_tests.dependOn(&b.addInstallArtifact(session_tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "session-tests" }).step);
        b.step("test-session", "Run real PTY-to-VT session tests").dependOn(&b.addRunArtifact(session_tests).step);
        const run_vt = b.addRunArtifact(vt_tests);
        b.step("test-vt", "Run pinned VT adapter tests").dependOn(&run_vt.step);
    }
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    install_tests.dependOn(&b.addInstallArtifact(tests, .{ .dest_dir = .{ .override = .bin }, .dest_sub_path = "protocol-tests" }).step);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run session protocol tests").dependOn(&run_tests.step);
}
