import Foundation

/// 详情面板 Git 页可发起的仓库写操作。面板从不后台执行写命令，只把命令文本预填到当前
/// 终端输入行，由用户审阅后自行回车；因此这里只负责生成可安全粘贴的命令行，不涉及执行。
public enum GitCommand: Equatable, Sendable {
  case commit
  case push
  case pull
  case fetch
  case merge(branch: String)
  case rebase(branch: String)
  case stage(path: String)
  case unstage(path: String)
  case stageAll
  case discard(path: String)

  /// 生成命令文本。分支名或路径非法时返回 nil —— 调用方必须放弃注入，而不是退化成
  /// 一条缺参数的 git 命令（那会让用户在输入行里看到一条语义不同的可执行命令）。
  public var commandLine: String? {
    switch self {
    case .commit:
      // 尾随空格是刻意的：光标停在 `-m` 之前，用户直接接着写提交信息。
      return "git commit "
    case .push:
      return "git push"
    case .pull:
      return "git pull"
    case .fetch:
      return "git fetch"
    case .merge(let branch):
      guard let branch = Self.sanitizedBranch(branch) else { return nil }
      return "git merge \(Self.quoted(branch))"
    case .rebase(let branch):
      guard let branch = Self.sanitizedBranch(branch) else { return nil }
      return "git rebase \(Self.quoted(branch))"
    case .stage(let path):
      guard let path = Self.sanitizedPath(path) else { return nil }
      return "git add -- \(Self.quoted(path))"
    case .unstage(let path):
      guard let path = Self.sanitizedPath(path) else { return nil }
      return "git restore --staged -- \(Self.quoted(path))"
    case .stageAll:
      return "git add -A"
    case .discard(let path):
      guard let path = Self.sanitizedPath(path) else { return nil }
      return "git restore -- \(Self.quoted(path))"
    }
  }

  /// 单引号包裹并转义内部单引号：路径与分支名可能含空格、`$`、反引号或换行，直接拼接
  /// 会在用户按下回车时变成命令替换。`--` 已经隔开选项，引用负责隔开 shell 语法。
  static func quoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// 分支名来自用户输入框，必须自行校验：拒绝空白、控制字符、以 `-` 开头（会被 git 当
  /// 成选项）以及超长输入。这里只做边界校验，是否真实存在交给 git 自己报错。
  public static func sanitizedBranch(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 255, !trimmed.hasPrefix("-") else { return nil }
    guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return trimmed
  }

  /// 变更路径来自 `git status` 解析结果，同样拒绝空值、控制字符与 `-` 开头。
  static func sanitizedPath(_ value: String) -> String? {
    guard !value.isEmpty, value.count <= 4_096, !value.hasPrefix("-") else { return nil }
    guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return value
  }
}

/// diff 预览中的一行及其语义类型。渲染层据此上色，不再自行判断前缀。
public struct GitDiffLine: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case fileHeader
    case hunkHeader
    case addition
    case deletion
    case context
    /// 解析器自己插入的提示行（例如超出上限被截断）。
    case notice
  }

  public let kind: Kind
  public let text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

/// `git diff` 文本 → 带类型的行。只按前缀分类，不重排也不合并内容，保证预览与终端里
/// 执行同一条命令看到的文本一致。
public enum GitDiffParser {
  public static let defaultLineLimit = 4_000

  public static func parse(_ text: String, lineLimit: Int = defaultLineLimit) -> [GitDiffLine] {
    guard lineLimit > 0 else { return [] }
    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // 末尾换行会产生一个空尾项，去掉后空 diff 才是真正的空数组。
    var lines = rawLines
    if lines.last?.isEmpty == true { lines.removeLast() }
    let truncated = lines.count > lineLimit
    var parsed = lines.prefix(lineLimit).map { line in
      GitDiffLine(kind: kind(of: line), text: line)
    }
    if truncated {
      parsed.append(
        GitDiffLine(
          kind: .notice,
          text: "… 已省略 \(lines.count - lineLimit) 行，完整 diff 请在终端中查看。"))
    }
    return parsed
  }

  /// `---`/`+++` 属于文件头，必须先于 `-`/`+` 判断，否则文件头会被染成增删行。
  private static func kind(of line: String) -> GitDiffLine.Kind {
    if line.hasPrefix("@@") { return .hunkHeader }
    if line.hasPrefix("---") || line.hasPrefix("+++") { return .fileHeader }
    for prefix in ["diff --git", "index ", "new file", "deleted file", "old mode", "new mode",
      "similarity index", "rename from", "rename to", "Binary files"] where line.hasPrefix(prefix) {
      return .fileHeader
    }
    if line.hasPrefix("+") { return .addition }
    if line.hasPrefix("-") { return .deletion }
    return .context
  }
}
