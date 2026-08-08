import Foundation

public enum OpenQuicklyKind: String, CaseIterable, Codable, Sendable {
  case opened
  case recent
  case folder
  case ssh
  case agent
  case current
  /// 当前 Pane 所跑 Agent 会话的近期提示词,只出现在「当前」与「全部」过滤器下。
  case prompt
  case recipe
}

public enum OpenQuicklyFilter: String, CaseIterable, Codable, Sendable {
  case all
  case opened
  case recent
  case folder
  case ssh
  case agent
  case current
  case recipe

  /// 判断结果类型是否落入该过滤器;「当前」同时包含 pane 条目与提示词条目。
  fileprivate func includes(_ kind: OpenQuicklyKind) -> Bool {
    switch self {
    case .all: true
    case .current: kind == .current || kind == .prompt
    default: rawValue == kind.rawValue
    }
  }
}

/// Open Quickly 的可跳转目标。`score` 只在同来源、同匹配质量内参与排序，避免高频
/// 历史目录把已经打开的精确标签挤出首屏。`timestamp` 不参与排序，仅供 UI 显示相对时间。
public struct OpenQuicklyItem: Identifiable, Equatable, Sendable {
  public let id: String
  public let kind: OpenQuicklyKind
  public let title: String
  public let detail: String
  public let score: Double
  public let timestamp: Date?

  public init(
    id: String,
    kind: OpenQuicklyKind,
    title: String,
    detail: String = "",
    score: Double = 0,
    timestamp: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.detail = detail
    self.score = score.isFinite ? score : 0
    self.timestamp = timestamp
  }
}

public struct OpenQuicklyIndex: Sendable {
  private let items: [OpenQuicklyItem]

  public init(items: [OpenQuicklyItem]) {
    self.items = Array(items.prefix(10_000))
  }

  public func search(
    query: String,
    filter: OpenQuicklyFilter,
    maximumResults: Int = 200
  ) -> [OpenQuicklyItem] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard needle.utf8.count <= 1_024 else { return [] }
    let limit = max(0, min(maximumResults, 1_000))
    return items.compactMap { item -> (OpenQuicklyItem, Int)? in
      guard filter.includes(item.kind) else { return nil }
      guard !needle.isEmpty else { return (item, 0) }
      let titleScore = Self.fuzzyScore(needle, in: item.title)
      let detailScore = Self.fuzzyScore(needle, in: item.detail).map { $0 + 40 }
      guard let match = [titleScore, detailScore].compactMap({ $0 }).min() else { return nil }
      return (item, match)
    }.sorted { lhs, rhs in
      let leftPriority = Self.priority(lhs.0.kind)
      let rightPriority = Self.priority(rhs.0.kind)
      if leftPriority != rightPriority { return leftPriority < rightPriority }
      if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
      if lhs.0.score != rhs.0.score { return lhs.0.score > rhs.0.score }
      return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
    }.prefix(limit).map(\.0)
  }

  /// 把搜索结果按 kind 保序分组，供浮层渲染小节标题；输入需已是 search 的排序结果。
  public static func sections(
    for items: [OpenQuicklyItem]
  ) -> [(kind: OpenQuicklyKind, items: [OpenQuicklyItem])] {
    var result: [(kind: OpenQuicklyKind, items: [OpenQuicklyItem])] = []
    for item in items {
      if result.last?.kind == item.kind {
        result[result.count - 1].items.append(item)
      } else {
        result.append((kind: item.kind, items: [item]))
      }
    }
    return result
  }

  private static func priority(_ kind: OpenQuicklyKind) -> Int {
    switch kind {
    case .opened: 0
    case .folder: 1
    case .current: 2
    case .prompt: 3
    case .recipe: 4
    case .recent: 5
    case .ssh: 6
    case .agent: 7
    }
  }

  /// Small deterministic subsequence matcher: contiguous/prefix matches win, then shorter gaps.
  private static func fuzzyScore(_ query: String, in candidate: String) -> Int? {
    let query = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    let candidate = Array(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    guard !query.isEmpty else { return 0 }
    var queryIndex = 0
    var firstMatch = 0
    var previousMatch: Int?
    var gapPenalty = 0
    for (index, character) in candidate.enumerated() where queryIndex < query.count {
      guard character == query[queryIndex] else { continue }
      if queryIndex == 0 { firstMatch = index }
      if let previousMatch { gapPenalty += max(0, index - previousMatch - 1) }
      previousMatch = index
      queryIndex += 1
    }
    guard queryIndex == query.count else { return nil }
    return firstMatch * 4 + gapPenalty * 2 + max(0, candidate.count - query.count) / 8
  }
}

public enum WorkspaceOutlineKind: Sendable {
  case markdown
  case html
  case json
  case yaml
  case toml
  case diff
  case jsonLinesTranscript
}

public struct WorkspaceOutlineItem: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let line: Int
  public let level: Int

  public init(title: String, line: Int, level: Int = 1) {
    self.id = "\(line):\(title)"
    self.title = title
    self.line = line
    self.level = level
  }
}

public enum WorkspaceOutlineParser {
  private static let maximumBytes = 1_024 * 1_024
  private static let maximumItems = 1_000

  public static func parse(_ text: String, kind: WorkspaceOutlineKind) -> [WorkspaceOutlineItem] {
    guard text.utf8.count <= maximumBytes else { return [] }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let items: [WorkspaceOutlineItem]
    switch kind {
    case .markdown:
      items = lines.enumerated().compactMap { index, line in
        let marker = line.prefix(while: { $0 == "#" })
        guard !marker.isEmpty, marker.count <= 6,
          line.dropFirst(marker.count).first?.isWhitespace == true
        else { return nil }
        let title = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : .init(title: title, line: index + 1, level: marker.count)
      }
    case .html:
      items = lines.enumerated().compactMap { index, line in
        guard let match = line.range(
          of: #"<h([1-6])(?:\s[^>]*)?>(.*?)</h\1>"#,
          options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let fragment = String(line[match])
        let level = Int(fragment.dropFirst(2).first.map(String.init) ?? "1") ?? 1
        let title = fragment.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : .init(title: title, line: index + 1, level: level)
      }
    case .json:
      items = topLevelJSONKeys(text).enumerated().map {
        .init(title: $0.element, line: $0.offset + 1)
      }
    case .yaml, .toml:
      items = lines.enumerated().compactMap { index, line in
        guard !line.isEmpty, line.first?.isWhitespace != true, !line.hasPrefix("#") else { return nil }
        let separator: Character = kind == .yaml ? ":" : "="
        guard let offset = line.firstIndex(of: separator) else { return nil }
        let title = line[..<offset].trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'"))
        return title.isEmpty ? nil : .init(title: title, line: index + 1)
      }
    case .diff:
      items = lines.enumerated().compactMap { index, line in
        guard line.hasPrefix("diff --git ") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 4 else { return nil }
        let path = fields[3].hasPrefix("b/") ? fields[3].dropFirst(2) : fields[3][...]
        return .init(title: String(path), line: index + 1)
      }
    case .jsonLinesTranscript:
      items = lines.enumerated().compactMap { index, line in
        guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let role = (object["role"] as? String) ?? (object["type"] as? String)
        guard role == "user" else { return nil }
        let title = (object["message"] as? String) ?? (object["content"] as? String)
        let bounded = title?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240) ?? ""
        return bounded.isEmpty ? nil : .init(title: String(bounded), line: index + 1)
      }
    }
    return Array(items.prefix(maximumItems))
  }

  private static func topLevelJSONKeys(_ text: String) -> [String] {
    guard let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }
    return object.keys.sorted()
  }
}

public struct SSHHost: Equatable, Sendable {
  public let alias: String
  public let hostName: String
  public let user: String?
  public let port: Int?

  public var destination: String { user.map { "\($0)@\(hostName)" } ?? hostName }
}

public enum SSHConfigParser {
  public static func parse(_ text: String) -> [SSHHost] {
    guard text.utf8.count <= 1_024 * 1_024 else { return [] }
    var result: [SSHHost] = []
    var aliases: [String] = []
    var hostName: String?
    var user: String?
    var port: Int?

    func appendBlock() {
      for alias in aliases {
        result.append(.init(alias: alias, hostName: hostName ?? alias, user: user, port: port))
      }
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let fields = rawLine.split(whereSeparator: { $0.isWhitespace })
      guard let keyword = fields.first?.lowercased() else { continue }
      if keyword == "host" {
        appendBlock()
        aliases = fields.dropFirst().map(String.init).filter {
          !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && $0.utf8.count <= 255
        }
        hostName = nil
        user = nil
        port = nil
      } else if !aliases.isEmpty, fields.count >= 2 {
        let value = String(fields[1])
        switch keyword {
        case "hostname": hostName = value
        case "user": user = value
        case "port":
          if let parsed = Int(value), (1...65_535).contains(parsed) { port = parsed }
        default: break
        }
      }
    }
    appendBlock()
    var seen: Set<String> = []
    return result.filter { seen.insert($0.alias).inserted }.prefix(1_000).map { $0 }
  }
}

public struct GitChange: Equatable, Sendable {
  public let path: String
  public let originalPath: String?
  public let status: String
}

/// `git diff --shortstat` 的汇总行解析结果,驱动详情面板 Git 页的 +/− 统计。
public struct GitDiffStat: Equatable, Sendable {
  public let filesChanged: Int
  public let insertions: Int
  public let deletions: Int

  public init(filesChanged: Int, insertions: Int, deletions: Int) {
    self.filesChanged = filesChanged
    self.insertions = insertions
    self.deletions = deletions
  }
}

public struct GitStatusSummary: Equatable, Sendable {
  public var branch: String?
  public var objectID: String?
  public var changes: [GitChange]
  public var diffStat: GitDiffStat?

  public init(
    branch: String? = nil,
    objectID: String? = nil,
    changes: [GitChange] = [],
    diffStat: GitDiffStat? = nil
  ) {
    self.branch = branch
    self.objectID = objectID
    self.changes = changes
    self.diffStat = diffStat
  }

  /// porcelain v2 的 XY 状态码:X 位描述已暂存变更("??" 未跟踪文件没有 X 位)。
  public var stagedChanges: [GitChange] {
    changes.filter { change in
      guard let code = change.status.first, change.status != "??" else { return false }
      return code != "."
    }
  }

  /// Y 位描述工作区未暂存变更;未跟踪文件("??")整体归入未暂存。
  public var unstagedChanges: [GitChange] {
    changes.filter { change in
      if change.status == "??" { return true }
      guard change.status.count >= 2 else { return false }
      return change.status[change.status.index(after: change.status.startIndex)] != "."
    }
  }
}

public enum GitStatusParser {
  public static func parsePorcelainV2(_ text: String) -> GitStatusSummary {
    guard text.utf8.count <= 1_024 * 1_024 else { return .init() }
    var summary = GitStatusSummary()
    for line in text.split(separator: "\n").prefix(10_000) {
      if line.hasPrefix("# branch.head ") {
        summary.branch = String(line.dropFirst("# branch.head ".count))
      } else if line.hasPrefix("# branch.oid ") {
        summary.objectID = String(line.dropFirst("# branch.oid ".count))
      } else if line.hasPrefix("? ") {
        summary.changes.append(.init(path: String(line.dropFirst(2)), originalPath: nil, status: "??"))
      } else if line.hasPrefix("1 ") {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        if fields.count == 9 {
          summary.changes.append(.init(path: String(fields[8]), originalPath: nil, status: String(fields[1])))
        }
      } else if line.hasPrefix("2 ") {
        let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
        if fields.count == 10 {
          let paths = fields[9].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
          summary.changes.append(.init(
            path: String(paths[0]),
            originalPath: paths.count > 1 ? String(paths[1]) : nil,
            status: String(fields[1])))
        }
      }
    }
    return summary
  }
}

/// 解析 `git diff --shortstat` 的单行汇总,例如
/// " 3 files changed, 10 insertions(+), 2 deletions(-)"。空输出代表干净仓库,
/// 返回全零统计而不是 nil,让调用方能区分「干净」与「采集失败」。
public enum GitShortStatParser {
  public static func parse(_ text: String) -> GitDiffStat? {
    guard text.utf8.count <= 512 * 1_024 else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return GitDiffStat(filesChanged: 0, insertions: 0, deletions: 0) }
    var filesChanged = 0
    var insertions = 0
    var deletions = 0
    var matchedAny = false
    for part in trimmed.split(separator: ",") {
      let fields = part.split(whereSeparator: { $0.isWhitespace })
      // 每段形如 "<n> file(s) changed" / "<n> insertion(s)(+)" / "<n> deletion(s)(-)"
      guard fields.count >= 2, let value = Int(fields[0]) else { continue }
      // 词形带后缀："insertions(+)" / "deletion(-)"，按词干前缀匹配并覆盖单复数。
      if fields[1].hasPrefix("file") {
        filesChanged = value; matchedAny = true
      } else if fields[1].hasPrefix("insertion") {
        insertions = value; matchedAny = true
      } else if fields[1].hasPrefix("deletion") {
        deletions = value; matchedAny = true
      }
    }
    guard matchedAny else { return nil }
    return GitDiffStat(filesChanged: filesChanged, insertions: insertions, deletions: deletions)
  }
}

public struct WorkspaceSearchOptions: Equatable, Sendable {
  public var caseSensitive: Bool
  public var regularExpression: Bool

  public init(caseSensitive: Bool = false, regularExpression: Bool = false) {
    self.caseSensitive = caseSensitive
    self.regularExpression = regularExpression
  }
}

public struct WorkspaceSearchDocument: Sendable {
  public let tabID: UUID
  public let paneID: UUID
  public let title: String
  public let firstAbsoluteRow: Int
  public let lines: [String]

  public init(
    tabID: UUID,
    paneID: UUID,
    title: String,
    firstAbsoluteRow: Int = 0,
    lines: [String]
  ) {
    self.tabID = tabID
    self.paneID = paneID
    self.title = title
    self.firstAbsoluteRow = max(firstAbsoluteRow, 0)
    self.lines = Array(lines.prefix(100_000))
  }
}

public struct WorkspaceSearchResult: Equatable, Sendable {
  public let tabID: UUID
  public let paneID: UUID
  public let title: String
  public let line: Int
  public let absoluteRow: Int
  public let preview: String
}

public enum GlobalWorkspaceSearch {
  public static func search(
    documents: [WorkspaceSearchDocument],
    query: String,
    options: WorkspaceSearchOptions,
    maximumResults: Int = 2_000
  ) -> [WorkspaceSearchResult] {
    guard !query.isEmpty, query.utf8.count <= 4_096 else { return [] }
    let limit = max(0, min(maximumResults, 10_000))
    let expression: NSRegularExpression?
    if options.regularExpression {
      let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
      expression = try? NSRegularExpression(pattern: query, options: regexOptions)
      guard expression != nil else { return [] }
    } else {
      expression = nil
    }
    var results: [WorkspaceSearchResult] = []
    for document in documents {
      for (index, line) in document.lines.enumerated() {
        let matched: Bool
        if let expression {
          matched = expression.firstMatch(
            in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
        } else {
          matched = line.range(
            of: query,
            options: options.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if matched {
          results.append(.init(
            tabID: document.tabID,
            paneID: document.paneID,
            title: document.title,
            line: index + 1,
            absoluteRow: document.firstAbsoluteRow + index,
            preview: String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))))
          if results.count == limit { return results }
        }
      }
    }
    return results
  }
}

public struct WorkspaceProcess: Equatable, Sendable {
  public let processIdentifier: Int32
  public let parentProcessIdentifier: Int32
  public let command: String
  /// `ps etime` 列的原文（[[dd-]hh:]mm:ss），仅用于展示，不做进一步解析。
  public let elapsedTime: String?

  public init(
    processIdentifier: Int32,
    parentProcessIdentifier: Int32,
    command: String,
    elapsedTime: String? = nil
  ) {
    self.processIdentifier = processIdentifier
    self.parentProcessIdentifier = parentProcessIdentifier
    self.command = command
    self.elapsedTime = elapsedTime
  }
}

/// 解析 macOS `ps -axo pid=,ppid=,etime=,comm=` 的固定列输出，并只保留目标 Shell 的
/// 后代进程。遍历关系而不是按命令文本猜测，避免同名进程被错误归入当前 Pane。
public enum WorkspaceProcessParser {
  public static func descendants(
    from text: String,
    rootProcessIdentifier: Int32,
    maximumResults: Int = 200
  ) -> [WorkspaceProcess] {
    guard rootProcessIdentifier > 0, text.utf8.count <= 4 * 1_024 * 1_024 else { return [] }
    let limit = max(0, min(maximumResults, 1_000))
    let processes = text.split(separator: "\n").prefix(50_000).compactMap { line -> WorkspaceProcess? in
      let fields = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
      guard fields.count >= 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
        pid > 0, parent >= 0
      else { return nil }
      // 四列新输出的第三列是 etime（[[dd-]hh:]mm:ss，只含数字、冒号、短横线）；不满足
      // 该形态说明是旧的三列输出或命令本身带空格，第三列起整体是命令文本。
      let elapsed: String?
      let command: String
      if fields.count == 4, isElapsedTimeColumn(fields[2]) {
        elapsed = fields[2].utf8.count <= 32 ? String(fields[2]) : nil
        command = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        elapsed = nil
        command = fields.dropFirst(2).joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !command.isEmpty, command.utf8.count <= 4_096 else { return nil }
      return .init(
        processIdentifier: pid, parentProcessIdentifier: parent, command: command,
        elapsedTime: elapsed)
    }
    var included: Set<Int32> = [rootProcessIdentifier]
    var result: [WorkspaceProcess] = []
    // `ps` 通常按 PID 排序，但父子不保证相邻。多轮收敛能处理任意顺序，进程上限使
    // 最坏复杂度保持有界；根 Shell 自身不显示，只显示它启动的任务。
    var pending = processes
    while !pending.isEmpty, result.count < limit {
      var progressed = false
      pending.removeAll { process in
        guard included.contains(process.parentProcessIdentifier) else { return false }
        included.insert(process.processIdentifier)
        result.append(process)
        progressed = true
        return true
      }
      if !progressed { break }
    }
    return Array(result.prefix(limit))
  }

  /// `ps etime` 列形如 [[dd-]hh:]mm:ss：只由数字、冒号、短横线组成且含冒号。
  private static func isElapsedTimeColumn(_ field: Substring) -> Bool {
    field.contains(":") && field.allSatisfy { $0.isNumber || $0 == ":" || $0 == "-" }
  }
}

public struct ListeningPort: Equatable, Sendable {
  public let processIdentifier: Int32
  public let endpoint: String

  public init(processIdentifier: Int32, endpoint: String) {
    self.processIdentifier = processIdentifier
    self.endpoint = endpoint
  }
}

/// 解析 `lsof -Fpn` 的机器可读记录。只接受 PID 与网络端点字段，文件名、用户环境
/// 或完整命令行不会进入详情面板，减少无关信息和潜在敏感数据暴露。
public enum ListeningPortParser {
  public static func parse(_ text: String, maximumResults: Int = 200) -> [ListeningPort] {
    guard text.utf8.count <= 2 * 1_024 * 1_024 else { return [] }
    let limit = max(0, min(maximumResults, 1_000))
    var processIdentifier: Int32?
    var result: [ListeningPort] = []
    for line in text.split(separator: "\n").prefix(50_000) {
      guard let field = line.first else { continue }
      let value = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
      switch field {
      case "p":
        processIdentifier = Int32(value)
      case "n":
        guard let processIdentifier, processIdentifier > 0, !value.isEmpty,
          value.utf8.count <= 1_024
        else { continue }
        result.append(.init(processIdentifier: processIdentifier, endpoint: value))
        if result.count == limit { return result }
      default:
        continue
      }
    }
    return result
  }
}

public struct WorkspaceFileNode: Identifiable, Equatable, Sendable {
  public let path: String
  public let name: String
  public let depth: Int
  public let isDirectory: Bool
  public let isSymbolicLink: Bool

  public var id: String { path }

  public init(
    path: String,
    name: String,
    depth: Int,
    isDirectory: Bool,
    isSymbolicLink: Bool = false
  ) {
    self.path = path
    self.name = name
    self.depth = max(depth, 0)
    self.isDirectory = isDirectory
    self.isSymbolicLink = isSymbolicLink
  }
}

/// 生成详情面板使用的有界目录树。符号链接作为叶节点显示但绝不递归，既保留用户
/// 可见信息，也阻止工作目录内链接把扫描带到仓库外或形成循环。
public enum WorkspaceFileTree {
  public static func enumerate(
    root: URL,
    maximumDepth: Int = 3,
    maximumItems: Int = 500,
    fileManager: FileManager = .default
  ) -> [WorkspaceFileNode] {
    let depthLimit = max(0, min(maximumDepth, 16))
    let itemLimit = max(0, min(maximumItems, 10_000))
    guard root.isFileURL, itemLimit > 0,
      let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory == true, values.isSymbolicLink != true
    else { return [] }

    var result: [WorkspaceFileNode] = []
    func visit(_ directory: URL, depth: Int) {
      guard depth <= depthLimit, result.count < itemLimit else { return }
      let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
      guard let entries = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsPackageDescendants]
      ) else { return }
      let sorted = entries.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
      for entry in sorted where result.count < itemLimit {
        guard let values = try? entry.resourceValues(forKeys: keys), values.isHidden != true else {
          continue
        }
        let directory = values.isDirectory == true
        result.append(.init(
          path: entry.path,
          name: entry.lastPathComponent,
          depth: depth,
          isDirectory: directory,
          isSymbolicLink: values.isSymbolicLink == true
        ))
        if directory, values.isSymbolicLink != true, depth < depthLimit {
          visit(entry, depth: depth + 1)
        }
      }
    }
    visit(root, depth: 0)
    return result
  }
}
