import AsterCore
import Foundation
import Testing

@testable import AsterMemory

// `AsterMemoryMCP` 是 executable target，测试无法 import 它，
// 因此这里走**进程级集成测试**：spawn 已构建的 aster-memory-mcp 二进制，
// 用 ASTER_MEMORY_DIR 指向临时库，通过 stdin/stdout 走完整 JSON-RPC 往返。
// 这同时也是最接近真实 Claude Code 连接方式的验证。

// MARK: - 二进制定位

/// 从测试源文件位置反推仓库根目录，再在 `.build` 下寻找已构建的 MCP 二进制。
/// SwiftPM 可能把产物放在 `.build/debug` 或 `.build/<三元组>/debug`，两种都尝试。
private func mcpBinaryURL() -> URL? {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests/AsterMemoryTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // 仓库根
  let build = root.appendingPathComponent(".build", isDirectory: true)
  var candidates: [URL] = ["debug", "release"].map {
    build.appendingPathComponent($0, isDirectory: true)
      .appendingPathComponent("aster-memory-mcp")
  }
  if let entries = try? FileManager.default.contentsOfDirectory(atPath: build.path) {
    for entry in entries {
      for configuration in ["debug", "release"] {
        candidates.append(
          build.appendingPathComponent(entry, isDirectory: true)
            .appendingPathComponent(configuration, isDirectory: true)
            .appendingPathComponent("aster-memory-mcp"))
      }
    }
  }
  return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

// MARK: - 测试数据

/// 一套完整的测试库：项目 + task + session + 事件 + memory。
private struct Fixture {
  let root: URL
  let projectDirectory: URL
  let projectPath: String
  let sessionID: UUID
  let taskID: UUID
  let memoryID: UUID
}

/// 取路径的物理形态，与子进程 `getcwd()` 的结果逐字节一致。
///
/// 不能用 `URL.resolvingSymlinksInPath()`：它在解析完符号链接后还会把开头的 `/private`
/// 再去掉，于是 `/private/var/folders/…` 变回 `/var/folders/…`，而 `getcwd()` 返回的是
/// 带 `/private` 的真实路径 —— 两者不相等会让 cwd 推断的断言假失败。
private func physicalPath(_ url: URL) -> String {
  guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
  defer { free(resolved) }
  return String(cString: resolved)
}

/// 造一个真实目录 + 真实数据库的测试库。projectPath 用物理路径，
/// 这样它才能与子进程 `getcwd()` 得到的路径逐字节相等（macOS 的 /var → /private/var）。
private func makeFixture() async throws -> Fixture {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-mcp-tests-\(UUID().uuidString)", isDirectory: true)
  let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
  try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
  let projectPath = physicalPath(projectDirectory)

  let location = MemoryStoreLocation(rootDirectory: root.appendingPathComponent("store"))
  let writer = EventWriter(location: location)
  let base = Date(timeIntervalSince1970: 1_700_000_000)
  let sessionID = UUID()
  let taskID = UUID()
  let memoryID = UUID()

  let project = try #require(ProjectIdentity.make(path: projectPath))
  await writer.record(.upsertProject(project, openedAt: base))
  await writer.record(
    .upsertTask(
      TaskDescriptor(
        id: taskID, projectPath: projectPath, title: "修复登录重连",
        status: .open, summary: "跨 session 的 reconnect 修复",
        createdAt: base, updatedAt: base)))
  await writer.record(
    .startSession(
      RecordedSessionDescriptor(
        id: sessionID, projectPath: projectPath, shell: "/bin/zsh",
        agentProvider: "claude-code", startedAt: base, taskID: taskID,
        gitBranch: "feature/reconnect")))

  func event(
    _ sequence: Int, _ kind: MemoryEventKind, command: String? = nil, exit: Int? = nil,
    excerpt: String? = nil
  ) -> RecordedEvent {
    RecordedEvent(
      sessionID: sessionID, sequence: sequence,
      timestamp: base.addingTimeInterval(Double(sequence)), kind: kind, command: command,
      workingDirectory: projectPath, exitStatus: exit, outputExcerpt: excerpt, source: .terminal)
  }
  await writer.record(.appendEvent(event(0, .sessionStarted)))
  await writer.record(.appendEvent(event(1, .shellCommand, command: "cargo test reconnect")))
  await writer.record(.appendEvent(event(2, .commandFinished, exit: 1)))
  await writer.record(
    .appendEvent(
      event(
        3, .commandOutput, exit: 1,
        excerpt: "error: timeout in Sources/Login/Reconnect.swift line 42")))
  await writer.record(.appendEvent(event(4, .shellCommand, command: "swift build")))
  await writer.record(.appendEvent(event(5, .commandFinished, exit: 0)))
  await writer.record(
    .endSession(sessionID: sessionID, exitCode: 0, endedAt: base.addingTimeInterval(120)))
  await writer.record(
    .insertMemoryRecord(
      MemoryRecord(
        id: memoryID, projectPath: projectPath, sessionID: sessionID, taskID: taskID,
        type: .session, title: "reconnect 超时来自 Login 模块",
        content: "cargo test reconnect 先失败，改完 Reconnect.swift 后 swift build 通过。",
        summary: "重连超时定位", createdAt: base),
      sources: [MemorySourceRef(kind: .session, identifier: sessionID.uuidString)]))
  await writer.flush()

  return Fixture(
    root: root, projectDirectory: projectDirectory, projectPath: projectPath,
    sessionID: sessionID, taskID: taskID, memoryID: memoryID)
}

/// fixture 对应的只读 store 位置，用于在测试侧核对 receipt。
private func storeLocation(_ fixture: Fixture) -> MemoryStoreLocation {
  MemoryStoreLocation(rootDirectory: fixture.root.appendingPathComponent("store"))
}

// MARK: - JSON-RPC 客户端

/// 驱动 MCP 子进程的最小客户端。
///
/// 刻意不使用 `waitUntilExit`：它会泵 runloop（CLAUDE.md 纪律）。读取靠
/// `readabilityHandler`（跑在 Foundation 自己的队列上）填缓冲区 + 信号量唤醒，
/// 等待一律带超时，卡住的子进程只会让单个测试失败而不是整轮挂死。
private final class MCPClient: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var buffer = Data()
  private let arrival = DispatchSemaphore(value: 0)
  private var nextID = 0

  init(binary: URL, memoryDirectory: URL, workingDirectory: URL) throws {
    process.executableURL = binary
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.currentDirectoryURL = workingDirectory
    var environment = ProcessInfo.processInfo.environment
    environment["ASTER_MEMORY_DIR"] = memoryDirectory.path
    process.environment = environment
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let self else { return }
      self.lock.lock()
      self.buffer.append(data)
      self.lock.unlock()
      self.arrival.signal()
    }
    try process.run()
  }

  /// 发送一条 JSON-RPC 请求并等待响应。
  func call(_ method: String, params: [String: Any]? = nil) throws -> [String: Any] {
    nextID += 1
    var message: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method]
    if let params { message["params"] = params }
    let data = try JSONSerialization.data(withJSONObject: message)
    return try send(String(decoding: data, as: UTF8.self))
  }

  /// 发送任意一行原始文本（用于非法 JSON 的负例）。
  func send(_ line: String) throws -> [String: Any] {
    input.fileHandleForWriting.write(Data((line + "\n").utf8))
    guard let response = waitForLine(timeout: 10) else {
      throw MCPClientError.timeout
    }
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      throw MCPClientError.malformedResponse
    }
    return object
  }

  /// 调一个工具并返回 (文本, 是否错误)。
  func callTool(_ name: String, arguments: [String: Any] = [:]) throws -> (
    text: String, isError: Bool
  ) {
    let response = try call("tools/call", params: ["name": name, "arguments": arguments])
    let result = response["result"] as? [String: Any] ?? [:]
    let content = result["content"] as? [[String: Any]] ?? []
    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    return (text, result["isError"] as? Bool ?? false)
  }

  /// 关闭 stdin 让子进程的 readLine 循环自然结束，再兜底终止。
  func shutdown() {
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
  }

  private func waitForLine(timeout: TimeInterval) -> Data? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let line = takeLine() { return line }
      guard Date() < deadline else { return nil }
      _ = arrival.wait(timeout: .now() + 0.05)
    }
  }

  private func takeLine() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard let index = buffer.firstIndex(of: 0x0A) else { return nil }
    let line = buffer[buffer.startIndex..<index]
    buffer.removeSubrange(buffer.startIndex...index)
    return Data(line)
  }
}

private enum MCPClientError: Error {
  case timeout
  case malformedResponse
}

/// 在已构建的二进制上跑一次会话；二进制不存在时跳过（未构建产物不该让测试变红）。
private func withClient(
  memoryDirectory: URL, workingDirectory: URL, _ body: (MCPClient) throws -> Void
) throws {
  // 产物未构建时静默跳过：`swift test` 会先构建 executable target，
  // 但独立跑测试 bundle 的场景不该因此变红。
  guard let binary = mcpBinaryURL() else { return }
  let client = try MCPClient(
    binary: binary, memoryDirectory: memoryDirectory, workingDirectory: workingDirectory)
  defer { client.shutdown() }
  _ = try client.call("initialize", params: ["protocolVersion": "2025-06-18"])
  try body(client)
}

// MARK: - 测试

@Suite struct MCPProtocolTests {
  @Test("initialize 握手返回协议版本与 server 信息")
  func initializeHandshake() async throws {
    let fixture = try await makeFixture()
    guard let binary = mcpBinaryURL() else { return }
    let client = try MCPClient(
      binary: binary, memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory)
    defer { client.shutdown() }
    let response = try client.call("initialize", params: ["protocolVersion": "2025-06-18"])
    let result = try #require(response["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-06-18")
    #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "aster-memory")
    #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
  }

  @Test("tools/list 返回 P0 全量工具且 schema 完整")
  func toolsList() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let response = try client.call("tools/list")
      let tools = try #require(
        (response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
      let names = Set(tools.compactMap { $0["name"] as? String })
      #expect(
        names == [
          "search_memory", "get_project_context", "get_session",
          "get_related_history", "get_task", "get_recent_commands",
        ])
      for tool in tools {
        // description 是 Agent 判断「何时调用」的唯一依据，必须点名 Aster 记忆库。
        let description = tool["description"] as? String ?? ""
        #expect(description.contains("Aster"))
        #expect(description.count > 80)
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["properties"] is [String: Any])
        #expect(schema["required"] is [Any])
      }
    }
  }

  @Test("search_memory 同时命中 memory 与历史命令")
  func searchMemory() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let result = try client.callTool(
        "search_memory", arguments: ["query": "reconnect", "project_path": fixture.projectPath])
      #expect(!result.isError)
      #expect(result.text.contains("[memory]"))
      #expect(result.text.contains("reconnect 超时来自 Login 模块"))
      #expect(result.text.contains("memory_id: \(fixture.memoryID.uuidString)"))
      #expect(result.text.contains("cargo test reconnect"))
    }
  }

  @Test("search_memory 缺少 query 参数返回 isError")
  func searchMemoryMissingArgument() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let result = try client.callTool("search_memory")
      #expect(result.isError)
      #expect(result.text.contains("query"))
    }
  }

  @Test("项目内零命中时自动 federation 回落并标注 cross-project")
  func projectScopeWidening() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      // 项目过滤查不到 → 自动放宽到全部项目，命中必须带跨项目声明，
      // Agent 才知道这些结论来自别的项目、未必适用（zero-mem federation 语义）。
      let narrow = try client.callTool(
        "search_memory", arguments: ["query": "reconnect", "project_path": "/nowhere"])
      #expect(!narrow.isError)
      #expect(narrow.text.contains("[cross-project]"))
      #expect(narrow.text.contains("OTHER projects"))
      #expect(narrow.text.contains("memory_id: \(fixture.memoryID.uuidString)"))

      let wide = try client.callTool(
        "search_memory", arguments: ["query": "reconnect", "project_path": "*"])
      #expect(wide.text.contains("memory_id: \(fixture.memoryID.uuidString)"))
      // 显式 "*" 是用户/Agent 主动跨项目，不算回落，不该标 cross-project。
      #expect(!wide.text.contains("[cross-project]"))
    }
  }

  @Test("零命中时附带库状态：区分「库有数据」与「记录未开启」")
  func zeroHitReportsStoreStatus() async throws {
    // 库有数据但查询无匹配：状态行给出计数与最后事件时间。
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let miss = try client.callTool(
        "search_memory", arguments: ["query": "zzzqqqnevermatched", "project_path": "*"])
      #expect(!miss.isError)
      #expect(miss.text.contains("No results."))
      #expect(miss.text.contains("Store status: 1 sessions"))
      #expect(miss.text.contains("latest event"))
    }

    // 库存在但没有任何事件与 memory：提示记录可能未开启。
    let emptyRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-mcp-empty-\(UUID().uuidString)", isDirectory: true)
    let writer = EventWriter(location: MemoryStoreLocation(rootDirectory: emptyRoot))
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: UUID(), projectPath: "/tmp/elsewhere", shell: "zsh", startedAt: Date())))
    await writer.flush()
    try withClient(memoryDirectory: emptyRoot, workingDirectory: fixture.projectDirectory) {
      client in
      let result = try client.callTool(
        "search_memory", arguments: ["query": "anything", "project_path": "*"])
      #expect(!result.isError)
      #expect(result.text.contains("Store status: empty"))
      #expect(result.text.contains("recording is likely turned off"))
    }
  }

  @Test("get_project_context 返回 session、memory 与未完成 task")
  func projectContext() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let result = try client.callTool(
        "get_project_context", arguments: ["project_path": fixture.projectPath])
      #expect(!result.isError)
      #expect(result.text.contains("# Project project"))
      #expect(result.text.contains("session_id: \(fixture.sessionID.uuidString)"))
      #expect(result.text.contains("memory_id: \(fixture.memoryID.uuidString)"))
      #expect(result.text.contains("task_id: \(fixture.taskID.uuidString)"))
      #expect(result.text.contains("agent=claude-code"))
      #expect(result.text.contains("branch=feature/reconnect"))
    }
  }

  @Test("project_path 缺省时按 MCP 进程的工作目录推断项目")
  func projectPathDefaultsToWorkingDirectory() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let result = try client.callTool("get_project_context")
      #expect(!result.isError)
      #expect(result.text.contains(fixture.projectPath))
      #expect(result.text.contains("session_id: \(fixture.sessionID.uuidString)"))
    }
  }

  @Test("get_session 渲染摘要与事件时间线")
  func sessionTimeline() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let result = try client.callTool(
        "get_session", arguments: ["session_id": fixture.sessionID.uuidString])
      #expect(!result.isError)
      #expect(result.text.contains("# Session \(fixture.sessionID.uuidString)"))
      #expect(result.text.contains("agent: claude-code"))
      #expect(result.text.contains("git branch: feature/reconnect"))
      #expect(result.text.contains("commands: 2, failures: 1"))
      #expect(result.text.contains("## Session memory"))
      #expect(result.text.contains("shell_command $ cargo test reconnect"))
      #expect(result.text.contains("command_finished (exit 1)"))
      // 输出摘录以缩进引用块呈现，方便 Agent 区分命令与输出。
      #expect(result.text.contains("    | error: timeout in Sources/Login/Reconnect.swift line 42"))
    }
  }

  @Test("get_session 传入非 UUID 与不存在的 id 都返回 isError")
  func sessionErrors() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let malformed = try client.callTool("get_session", arguments: ["session_id": "not-a-uuid"])
      #expect(malformed.isError)
      #expect(malformed.text.contains("session_id"))

      let missing = try client.callTool(
        "get_session", arguments: ["session_id": UUID().uuidString])
      #expect(missing.isError)
      #expect(missing.text.contains("session not found"))

      let absent = try client.callTool("get_session")
      #expect(absent.isError)
    }
  }

  @Test("get_related_history 用文件名关联到历史失败")
  func relatedHistory() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let result = try client.callTool(
        "get_related_history",
        arguments: [
          "file_path": "\(fixture.projectPath)/Sources/Login/Reconnect.swift",
          "project_path": fixture.projectPath,
        ])
      #expect(!result.isError)
      #expect(result.text.contains("Reconnect.swift"))

      let empty = try client.callTool("get_related_history")
      #expect(empty.isError)
      #expect(empty.text.contains("file_path"))
    }
  }

  @Test("get_task 支持列表与详情两种形态")
  func taskTool() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let list = try client.callTool(
        "get_task", arguments: ["project_path": fixture.projectPath])
      #expect(!list.isError)
      #expect(list.text.contains("[open] 修复登录重连"))
      #expect(list.text.contains("task_id: \(fixture.taskID.uuidString)"))

      let detail = try client.callTool(
        "get_task", arguments: ["task_id": fixture.taskID.uuidString])
      #expect(!detail.isError)
      #expect(detail.text.contains("# Task 修复登录重连"))
      #expect(detail.text.contains("session_id: \(fixture.sessionID.uuidString)"))

      let missing = try client.callTool("get_task", arguments: ["task_id": UUID().uuidString])
      #expect(missing.isError)
      #expect(missing.text.contains("task not found"))
    }
  }

  @Test("get_recent_commands 按时间倒序返回命令与退出码")
  func recentCommands() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let result = try client.callTool(
        "get_recent_commands", arguments: ["project_path": fixture.projectPath, "limit": 5])
      #expect(!result.isError)
      let build = try #require(result.text.range(of: "swift build"))
      let cargo = try #require(result.text.range(of: "cargo test reconnect"))
      #expect(build.lowerBound < cargo.lowerBound)
    }
  }

  @Test("每次成功的 tools/call 都写入 Context Receipt")
  func contextReceipts() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      _ = try client.callTool(
        "search_memory", arguments: ["query": "reconnect", "project_path": fixture.projectPath])
    }
    let reader = try MemoryStoreReader(location: storeLocation(fixture))
    let receipts = try reader.contextReceipts(projectPath: fixture.projectPath)
    let receipt = try #require(receipts.first)
    #expect(receipt.trigger == "agent_query")
    #expect(receipt.deliveryMethod == "mcp")
    #expect(receipt.query?.hasPrefix("search_memory:") == true)
    #expect(receipt.memoryIDs.contains(fixture.memoryID.uuidString))
    #expect(receipt.tokenEstimate > 0)
  }

  @Test("未知方法返回 -32601，非法 JSON 返回 -32700")
  func protocolErrors() async throws {
    let fixture = try await makeFixture()
    try withClient(
      memoryDirectory: storeLocation(fixture).rootDirectory,
      workingDirectory: fixture.projectDirectory
    ) { client in
      let unknownMethod = try client.call("resources/list")
      #expect((unknownMethod["error"] as? [String: Any])?["code"] as? Int == -32601)

      let unknownTool = try client.callTool("delete_everything")
      #expect(unknownTool.isError)
      #expect(unknownTool.text.contains("unknown tool"))

      let malformed = try client.send("{not json")
      #expect((malformed["error"] as? [String: Any])?["code"] as? Int == -32700)

      // 解析失败不得让循环退出：后续请求仍要正常响应。
      let recovered = try client.call("ping")
      #expect(recovered["result"] != nil)
    }
  }

  @Test("记忆库不存在时所有工具返回 isError 而不是崩溃")
  func missingStore() async throws {
    let empty = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-mcp-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try withClient(memoryDirectory: empty, workingDirectory: empty) { client in
      for tool in [
        "search_memory", "get_project_context", "get_session", "get_related_history",
        "get_task", "get_recent_commands",
      ] {
        let result = try client.callTool(
          tool,
          arguments: [
            "query": "anything", "keyword": "anything", "session_id": UUID().uuidString,
          ])
        #expect(result.isError, "\(tool) 应在库缺失时返回 isError")
        #expect(result.text.contains("memory store unavailable"))
      }
    }
  }
}
