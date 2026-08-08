import Foundation

public enum AgentChatContextSource: String, Codable, Equatable, Sendable {
  case terminalSelection = "terminal-selection"
  case lastCommandOutput = "last-command-output"
  case fileSelection = "file-selection"
  case transcriptSelection = "transcript-selection"
}

/// total budget 包含稳定的 provenance 包装和转义后的正文；reservedPromptBytes 为用户
/// 提问预留，防止“发送上下文”吃光整个请求而无法附加实际问题。
public struct AgentChatContextBudget: Equatable, Sendable {
  public let maximumItems: Int
  public let maximumTotalBytes: Int
  public let maximumItemBytes: Int
  public let reservedPromptBytes: Int

  public init(
    maximumItems: Int = 16,
    maximumTotalBytes: Int = 128 * 1_024,
    maximumItemBytes: Int = 64 * 1_024,
    reservedPromptBytes: Int = 8 * 1_024
  ) {
    self.maximumItems = max(maximumItems, 1)
    self.maximumTotalBytes = max(maximumTotalBytes, 0)
    self.maximumItemBytes = max(maximumItemBytes, 1)
    self.reservedPromptBytes = max(reservedPromptBytes, 0)
  }

  public var availableContextBytes: Int {
    max(maximumTotalBytes - reservedPromptBytes, 0)
  }
}

public struct AgentChatContextChip: Equatable, Sendable {
  public let source: AgentChatContextSource
  public let content: String
  public let originalByteCount: Int
  public let redactionCount: Int
  public let isTruncated: Bool
}

public enum AgentChatContextError: Error, Equatable {
  case emptyContent
  case tooManyItems(maximum: Int)
  case contextBudgetExhausted
}

/// 构造 Send to Chat 的有界、不可信上下文。该边界会移除终端控制字符、遮盖常见
/// secret，并用固定 provenance 标签包裹正文；它不会声称能识别所有业务敏感数据。
public struct AgentChatContextBuilder: Equatable, Sendable {
  public let budget: AgentChatContextBudget
  public private(set) var chips: [AgentChatContextChip] = []
  public private(set) var usedContextBytes = 0

  public init(budget: AgentChatContextBudget = AgentChatContextBudget()) {
    self.budget = budget
  }

  @discardableResult
  public mutating func add(
    source: AgentChatContextSource,
    content: String
  ) throws -> AgentChatContextChip {
    guard chips.count < budget.maximumItems else {
      throw AgentChatContextError.tooManyItems(maximum: budget.maximumItems)
    }

    let sanitized = Self.removeTerminalControls(content)
    let redacted = AgentContextRedactor.redact(sanitized)
    guard !redacted.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentChatContextError.emptyContent
    }

    let start = Self.startTag(for: source)
    let end = "\n</untrusted-context>"
    let remaining = budget.availableContextBytes - usedContextBytes
    let fixedBytes = start.utf8.count + end.utf8.count
    guard remaining > fixedBytes else { throw AgentChatContextError.contextBudgetExhausted }

    let bounded = Self.boundedContent(
      redacted.value,
      maximumPlainBytes: budget.maximumItemBytes,
      maximumRenderedBytes: remaining - fixedBytes
    )
    guard !bounded.value.isEmpty else { throw AgentChatContextError.contextBudgetExhausted }

    let chip = AgentChatContextChip(
      source: source,
      content: bounded.value,
      originalByteCount: content.utf8.count,
      redactionCount: redacted.count,
      isTruncated: bounded.wasTruncated
    )
    let rendered = Self.render(chip)
    guard usedContextBytes + rendered.utf8.count <= budget.availableContextBytes else {
      // `boundedContent` 已按同一转义规则计算；保留此 guard 防止未来格式变化绕过预算。
      throw AgentChatContextError.contextBudgetExhausted
    }
    chips.append(chip)
    usedContextBytes += rendered.utf8.count
    return chip
  }

  public var renderedForPrompt: String {
    chips.map(Self.render).joined(separator: "\n")
  }

  private static func startTag(for source: AgentChatContextSource) -> String {
    "<untrusted-context source=\"\(source.rawValue)\">\n"
  }

  private static func render(_ chip: AgentChatContextChip) -> String {
    startTag(for: chip.source) + xmlEscaped(chip.content) + "\n</untrusted-context>"
  }

  /// 保留换行和 Tab，移除 C0/C1 控制字符，阻止终端 escape/bell 混入模型上下文。
  private static func removeTerminalControls(_ value: String) -> String {
    String(
      value.unicodeScalars.filter { scalar in
        let number = scalar.value
        if scalar == "\n" || scalar == "\t" { return true }
        return number >= 0x20 && number != 0x7F && !(0x80...0x9F).contains(number)
      })
  }

  /// 同时受原文和 XML 转义后字节预算约束。按 Character 追加避免截断 Unicode 或组合
  /// 字符；转义预算防止大量 `<`/`&` 在包装阶段膨胀越界。
  private static func boundedContent(
    _ value: String,
    maximumPlainBytes: Int,
    maximumRenderedBytes: Int
  ) -> (value: String, wasTruncated: Bool) {
    var result = ""
    var plainBytes = 0
    var renderedBytes = 0
    for character in value {
      let text = String(character)
      let nextPlain = text.utf8.count
      let nextRendered = xmlEscaped(text).utf8.count
      guard plainBytes + nextPlain <= maximumPlainBytes,
        renderedBytes + nextRendered <= maximumRenderedBytes
      else { return (result, true) }
      result.append(character)
      plainBytes += nextPlain
      renderedBytes += nextRendered
    }
    return (result, false)
  }

  private static func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

private enum AgentContextRedactor {
  struct Result {
    let value: String
    let count: Int
  }

  /// 顺序从结构化 secret 到裸 token；前一步的 `[REDACTED]` 不会再次命中后续规则。
  static func redact(_ value: String) -> Result {
    let patterns: [(String, String)] = [
      (
        #"(?is)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
        "[REDACTED PRIVATE KEY]"
      ),
      (#"(?i)(\bAuthorization\s*:\s*Bearer\s+)[^\s]+"#, "$1[REDACTED]"),
      (
        #"(?i)(\b[A-Z0-9_]*(?:API[_-]?KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_]*\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|[^\s]+)"#,
        "$1[REDACTED]"
      ),
      (#"\b(?:sk|pk)-[A-Za-z0-9_-]{16,}\b"#, "[REDACTED TOKEN]"),
      (#"\bAKIA[0-9A-Z]{16}\b"#, "[REDACTED AWS KEY]"),
      (#"(?i)(https?://[^\s/:@]+:)[^\s@]+@"#, "$1[REDACTED]@"),
    ]

    var output = value
    var count = 0
    for (pattern, replacement) in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(output.startIndex..<output.endIndex, in: output)
      let matches = expression.matches(in: output, range: range)
      guard !matches.isEmpty else { continue }
      count += matches.count
      output = expression.stringByReplacingMatches(
        in: output,
        range: range,
        withTemplate: replacement
      )
    }
    return Result(value: output, count: count)
  }
}
