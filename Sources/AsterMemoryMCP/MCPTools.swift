import Foundation

/// 工具目录：`tools/list` 的真值表。
///
/// description 是 Agent 决定「什么时候该调用」的唯一依据，因此每条都明确写出
/// 这是 **Aster 终端记录的跨 Agent 项目记忆**（不是当前会话的上下文），
/// 并给出典型触发场景。schema 里所有参数都是可选或有明确必填标注。
enum MCPTools {
  /// 一个工具参数的 JSON Schema 描述。
  struct Property: Sendable {
    let name: String
    let type: String
    let description: String
  }

  /// 一个工具的完整定义。
  struct Definition: Sendable {
    let name: String
    let description: String
    let properties: [Property]
    let required: [String]
  }

  /// `project_path` 的统一说明：所有工具共用同一套缺省语义。
  private static let projectPathDescription =
    "Absolute project directory. Defaults to the directory this MCP server was started in "
    + "(normally the current project root). Pass \"*\" to search across all recorded projects."

  /// P0 工具集合（PRD §88）。顺序即 tools/list 的展示顺序。
  static let definitions: [Definition] = [
    Definition(
      name: "search_memory",
      description:
        "Full-text search over the Aster terminal's cross-agent project memory: distilled session "
        + "memories plus the raw shell commands (with exit codes and output excerpts) recorded "
        + "from every terminal session in this project, no matter which coding agent ran them. "
        + "Call this before guessing how something was built, run, or fixed here — e.g. "
        + "\"how do we run the tests\", \"why did the release build fail\", \"migration script\". "
        + "Memories the user disabled are never returned.",
      properties: [
        Property(name: "query", type: "string", description: "Keywords to search for (required)."),
        Property(name: "project_path", type: "string", description: projectPathDescription),
        Property(name: "limit", type: "number", description: "Maximum results, 1-50 (default 10)."),
      ],
      required: ["query"]
    ),
    Definition(
      name: "get_project_context",
      description:
        "Get an orientation briefing for a project from the Aster terminal's cross-agent memory: "
        + "project name, the most recent terminal sessions (with command/failure counts), the "
        + "currently active memories, and the open tasks. Call this once at the start of work in "
        + "an unfamiliar repository, or when resuming after a break, to learn what happened here "
        + "before this conversation existed.",
      properties: [
        Property(name: "project_path", type: "string", description: projectPathDescription)
      ],
      required: []
    ),
    Definition(
      name: "get_session",
      description:
        "Replay one recorded terminal session from the Aster terminal: its summary (project, "
        + "shell, agent, git branch, duration, command and failure counts), the distilled session "
        + "memory, and the ordered event timeline of commands, exit codes and output excerpts. "
        + "Use it after search_memory or get_project_context surfaces a session id and you need "
        + "the exact sequence of what was run.",
      properties: [
        Property(
          name: "session_id", type: "string",
          description: "UUID of the session, as returned by the other tools (required).")
      ],
      required: ["session_id"]
    ),
    Definition(
      name: "get_related_history",
      description:
        "Find what previously happened around a specific file, module or topic, using the Aster "
        + "terminal's cross-agent history: past commands, failures and memories that mention it. "
        + "Call this before editing an unfamiliar file — prior failures and the commands that "
        + "fixed them are usually recorded here.",
      properties: [
        Property(
          name: "file_path", type: "string",
          description:
            "Path of the file of interest; only its last path component is matched. "
            + "Provide either file_path or keyword."),
        Property(
          name: "keyword", type: "string",
          description: "Free-text topic. Provide either file_path or keyword."),
        Property(name: "project_path", type: "string", description: projectPathDescription),
        Property(name: "limit", type: "number", description: "Maximum results, 1-50 (default 20)."),
      ],
      required: []
    ),
    Definition(
      name: "get_task",
      description:
        "Read the Aster terminal's tasks — user-declared units of work that span several terminal "
        + "sessions and several coding agents. Without task_id it lists the project's tasks with "
        + "their status; with task_id it returns that task plus every session attached to it. "
        + "Call this to find out whether the thing you are asked to do is already in flight.",
      properties: [
        Property(
          name: "task_id", type: "string",
          description: "UUID of a task. Omit to list all tasks of the project."),
        Property(name: "project_path", type: "string", description: projectPathDescription),
      ],
      required: []
    ),
    Definition(
      name: "get_recent_commands",
      description:
        "List the most recent shell commands recorded by the Aster terminal for a project, newest "
        + "first, with exit codes. Use it to see what the user just tried in their terminal — "
        + "including commands run outside this conversation.",
      properties: [
        Property(name: "project_path", type: "string", description: projectPathDescription),
        Property(
          name: "limit", type: "number", description: "Maximum results, 1-100 (default 20)."),
      ],
      required: []
    ),
  ]

  /// 合法工具名集合，dispatch 前做白名单校验。
  static let names: Set<String> = Set(definitions.map(\.name))

  /// tools/list 的 JSON 载荷。
  static var listPayload: [JSONValue] {
    definitions.map { definition in
      var properties: [String: JSONValue] = [:]
      for property in definition.properties {
        properties[property.name] = .object([
          "type": .string(property.type),
          "description": .string(property.description),
        ])
      }
      return .object([
        "name": .string(definition.name),
        "description": .string(definition.description),
        "inputSchema": .object([
          "type": .string("object"),
          "properties": .object(properties),
          "required": .array(definition.required.map(JSONValue.string)),
        ]),
      ])
    }
  }
}
