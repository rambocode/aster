import AsterCore
import AsterMemory
import Foundation

/// MCP 协议处理器：把 initialize / tools/list / tools/call 映射到只读 store 查询。
/// 纯请求→响应函数，IO（stdin/stdout 循环）留在 main.swift。
struct MCPServer {
  /// 与客户端握手的 MCP 协议版本。
  static let protocolVersion = "2025-06-18"

  let location: MemoryStoreLocation
  /// server 进程的启动目录。Claude Code / Codex 都在项目根目录 spawn MCP server，
  /// 因此 `project_path` 缺省时用它推断项目归属，Agent 不必先问路径。
  let defaultProjectPath: String?

  init(
    location: MemoryStoreLocation,
    defaultProjectPath: String? = FileManager.default.currentDirectoryPath
  ) {
    self.location = location
    self.defaultProjectPath = defaultProjectPath.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// 一次工具调用的产物：给 Agent 的文本 + 写 Context Receipt 所需的归属信息。
  private struct ToolOutcome {
    var text: String
    /// 本次真正交给 Agent 的 memory id 列表（receipt 的核心字段）。
    var memoryIDs: [String] = []
    var projectPath: String?
    var sessionID: UUID?
    var taskID: UUID?
    /// receipt 里记录的查询描述（工具名 + 查询词）。
    var query: String
  }

  /// 处理一条请求；返回 nil 表示 notification（无 id），不回包。
  func handle(_ request: JSONRPCRequest) -> JSONRPCResponse? {
    switch request.method {
    case "initialize":
      return JSONRPCResponse(
        id: request.id,
        result: .object([
          "protocolVersion": .string(Self.protocolVersion),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object([
            "name": .string("aster-memory"),
            "version": .string("0.1.0"),
          ]),
        ]))
    case "notifications/initialized", "notifications/cancelled":
      return nil
    case "ping":
      return JSONRPCResponse(id: request.id, result: .object([:]))
    case "tools/list":
      return JSONRPCResponse(id: request.id, result: .object(["tools": .array(MCPTools.listPayload)]))
    case "tools/call":
      return callTool(request)
    default:
      guard request.id != nil else { return nil }
      return JSONRPCResponse(
        id: request.id,
        error: JSONRPCError(code: -32601, message: "method not found: \(request.method)"))
    }
  }

  // MARK: - tools/call

  private func callTool(_ request: JSONRPCRequest) -> JSONRPCResponse? {
    let name = MCPArguments.sanitize(
      request.params?["name"]?.stringValue ?? "", maximumBytes: MCPArguments.maximumNameBytes)
    let arguments = request.params?["arguments"]
    guard MCPTools.names.contains(name) else {
      return toolError(request.id, "unknown tool: \(name)")
    }
    do {
      // 每次调用现开只读连接：主应用（写端）可能刚刚建库或迁移，
      // 长连接会持有过期 schema 句柄。
      let reader = try MemoryStoreReader(location: location)
      let outcome = try execute(tool: name, arguments: arguments, reader: reader)
      recordReceipt(outcome)
      return JSONRPCResponse(id: request.id, result: Self.toolResult(outcome.text))
    } catch let error as ToolArgumentError {
      return toolError(request.id, error.message)
    } catch {
      // 库缺失、schema 版本不匹配等都以 tool 结果的 isError 呈现，
      // 让 Agent 看到可读原因而不是连接层崩溃。
      return toolError(request.id, "memory store unavailable: \(error)")
    }
  }

  /// 工具分发。每个分支只做「参数 → reader 查询 → 渲染」，不做任何写操作。
  private func execute(tool: String, arguments: JSONValue?, reader: MemoryStoreReader) throws
    -> ToolOutcome
  {
    switch tool {
    case "search_memory":
      let query = try MCPArguments.requiredString(
        arguments, "query", maximumBytes: MCPArguments.maximumQueryBytes)
      let project = projectFilter(arguments)
      // federation 回落：项目内零命中时自动放宽到全部项目（命中带 cross-project 标注），
      // Agent 不用再调一次；项目内有命中时绝不触发。
      let hits = try reader.search(
        query: query, projectPath: project,
        limit: MCPArguments.integer(arguments, "limit", default: 10, minimum: 1, maximum: 50),
        fallbackAcrossProjects: true)
      return ToolOutcome(
        text: MCPRenderer.hits(
          hits, header: "# Aster memory search: \(query)",
          emptyHint: hits.isEmpty ? emptyResultHint(project: project, reader: reader) : nil),
        memoryIDs: memoryIdentifiers(in: hits),
        projectPath: project,
        query: "search_memory: \(query)")

    case "get_project_context":
      let project = try requiredProjectPath(arguments)
      let snapshot = try reader.projectContext(projectPath: project)
      // 项目下一无所有时补库状态行；项目有数据时逐条时间戳已足够判断新鲜度。
      let empty = snapshot.sessions.isEmpty && snapshot.memories.isEmpty && snapshot.tasks.isEmpty
      return ToolOutcome(
        text: MCPRenderer.projectContext(
          snapshot, statusLine: empty ? storeStatusLine(reader: reader) : nil),
        memoryIDs: (snapshot.pinned + snapshot.memories).map(\.id.uuidString),
        projectPath: project,
        query: "get_project_context: \(project)")

    case "get_session":
      guard let sessionID = try MCPArguments.uuid(arguments, "session_id") else {
        throw ToolArgumentError("missing required argument: session_id")
      }
      guard let detail = try reader.sessionDetail(id: sessionID) else {
        throw ToolArgumentError("session not found: \(sessionID.uuidString)")
      }
      let artifacts = (try? reader.artifacts(sessionID: sessionID)) ?? []
      return ToolOutcome(
        text: MCPRenderer.sessionDetail(detail, artifacts: artifacts),
        memoryIDs: detail.memory.map { [$0.id.uuidString] } ?? [],
        projectPath: detail.descriptor.projectPath,
        sessionID: sessionID,
        taskID: detail.descriptor.taskID,
        query: "get_session: \(sessionID.uuidString)")

    case "get_related_history":
      // file_path 更具体，优先于自由关键词；两者都缺失才算参数错误。
      let keyword =
        MCPArguments.string(arguments, "file_path")
        ?? MCPArguments.string(arguments, "keyword", maximumBytes: MCPArguments.maximumQueryBytes)
      guard let keyword else {
        throw ToolArgumentError("missing required argument: provide file_path or keyword")
      }
      let project = projectFilter(arguments)
      let hits = try reader.relatedHistory(
        keyword: keyword, projectPath: project,
        limit: MCPArguments.integer(arguments, "limit", default: 20, minimum: 1, maximum: 50),
        fallbackAcrossProjects: true)
      return ToolOutcome(
        text: MCPRenderer.hits(
          hits, header: "# Aster related history: \(keyword)",
          emptyHint: hits.isEmpty ? emptyResultHint(project: project, reader: reader) : nil),
        memoryIDs: memoryIdentifiers(in: hits),
        projectPath: project,
        query: "get_related_history: \(keyword)")

    case "get_task":
      if let taskID = try MCPArguments.uuid(arguments, "task_id") {
        guard let detail = try reader.taskDetail(id: taskID) else {
          throw ToolArgumentError("task not found: \(taskID.uuidString)")
        }
        return ToolOutcome(
          text: MCPRenderer.taskDetail(detail.task, sessions: detail.sessions),
          projectPath: detail.task.projectPath,
          taskID: taskID,
          query: "get_task: \(taskID.uuidString)")
      }
      let project = projectFilter(arguments)
      let tasks = try reader.tasks(projectPath: project)
      return ToolOutcome(
        text: MCPRenderer.taskList(tasks, projectPath: project),
        projectPath: project,
        query: "get_task: list \(project ?? "*")")

    case "get_recent_commands":
      let project = projectFilter(arguments)
      let hits = try reader.recentCommands(
        projectPath: project,
        limit: MCPArguments.integer(arguments, "limit", default: 20, minimum: 1, maximum: 100))
      return ToolOutcome(
        text: MCPRenderer.hits(
          hits, header: "# Aster recent commands",
          emptyHint: hits.isEmpty ? emptyResultHint(project: project, reader: reader) : nil),
        projectPath: project,
        query: "get_recent_commands: \(project ?? "*")")

    default:
      throw ToolArgumentError("unknown tool: \(tool)")
    }
  }

  // MARK: - 项目归属

  /// 解析 `project_path` 过滤器：显式传值优先，`*` 表示跨项目，缺省回落到进程 cwd。
  private func projectFilter(_ arguments: JSONValue?) -> String? {
    guard let raw = MCPArguments.string(arguments, "project_path") else {
      return defaultProjectPath
    }
    return raw == "*" ? nil : raw
  }

  /// `get_project_context` 必须落到具体项目：`*`（跨项目）与 cwd 不可用时同样映射为 nil，
  /// 都给出可操作的错误文案而不是拿空结果糊弄 Agent。
  private func requiredProjectPath(_ arguments: JSONValue?) throws -> String {
    guard let project = projectFilter(arguments) else {
      throw ToolArgumentError(
        "missing required argument: project_path (the server working directory is not usable)")
    }
    return project
  }

  /// 零命中时的放宽提示。只在确实做了项目过滤时给出，避免在全库查询后说废话。
  private func widenHint(_ project: String?) -> String? {
    guard let project else { return nil }
    return "Scope was project \(project). Retry with project_path \"*\" to search every "
      + "recorded project, or pass the correct project root."
  }

  /// 零命中时的组合提示：库状态行 + 放宽范围建议。
  /// 库状态让 Agent 分清三种情况：记录没开（库为空）、项目过滤太窄、真的没发生过。
  private func emptyResultHint(project: String?, reader: MemoryStoreReader) -> String? {
    let parts = [storeStatusLine(reader: reader), widenHint(project)].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  /// 一行库状态。状态查询失败不影响主结果（返回 nil 即不附加）。
  private func storeStatusLine(reader: MemoryStoreReader) -> String? {
    guard let status = try? reader.storeStatus() else { return nil }
    if status.eventCount == 0, status.memoryCount == 0 {
      return "Store status: empty — recording is likely turned off in Aster settings "
        + "(Session Memory), so nothing has been captured yet."
    }
    var line =
      "Store status: \(status.sessionCount) sessions, \(status.eventCount) events, "
      + "\(status.memoryCount) memories"
    if let latest = status.latestEventAt {
      line += ", latest event \(MCPRenderer.timestamp(latest))"
    }
    return line + ". The store has data, so no match likely means it was never recorded."
  }

  /// 从混合命中里挑出 memory id —— command 命中的 identifier 是 session id，不算 memory。
  private func memoryIdentifiers(in hits: [MemorySearchHit]) -> [String] {
    hits.filter { $0.kind == "memory" && !$0.identifier.isEmpty }.map(\.identifier)
  }

  // MARK: - Context Receipt

  /// 每次成功的 tools/call 都留痕（PRD §50）：用户能看到 Agent 到底拿走了什么。
  /// 写入失败一律静默 —— 留痕失败绝不能让 Agent 的查询失败。
  private func recordReceipt(_ outcome: ToolOutcome) {
    ContextReceiptWriter.append(
      ContextReceipt(
        projectPath: outcome.projectPath,
        sessionID: outcome.sessionID,
        taskID: outcome.taskID,
        trigger: "agent_query",
        query: outcome.query,
        memoryIDs: outcome.memoryIDs,
        tokenEstimate: ContextReceipt.estimateTokens(outcome.text),
        deliveryMethod: "mcp"),
      location: location)
  }

  // MARK: - 结果封装

  /// 成功结果的 MCP text content 封装。
  private static func toolResult(_ text: String) -> JSONValue {
    .object([
      "content": .array([
        .object(["type": .string("text"), "text": .string(text)])
      ])
    ])
  }

  /// 错误结果：MCP 约定用 `isError: true` 的 tool result，而不是 JSON-RPC 错误，
  /// 这样 Agent 能读到原因并自行修正参数或换工具。
  private func toolError(_ id: JSONRPCID?, _ message: String) -> JSONRPCResponse {
    JSONRPCResponse(
      id: id,
      result: .object([
        "content": .array([
          .object(["type": .string("text"), "text": .string(message)])
        ]),
        "isError": .bool(true),
      ]))
  }
}
