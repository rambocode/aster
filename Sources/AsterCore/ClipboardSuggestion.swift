import Foundation

// 剪贴板建议的内容准入规则：判定一段剪贴板文本能否作为提示符上的整行命令建议。
// 与 AppKit 无关，剪贴板的读取、变更追踪以及「首词是不是已知命令」的查询都在外层。

/// 决定剪贴板文本是否可以在空提示符上作为命令建议呈现。
public enum ClipboardSuggestionPolicy {
  /// 建议文本的最大字符数。
  ///
  /// 上限同时服务两个目的：ghost 是一个单行 label，太长会被 Pane 宽度裁掉，用户看到的
  /// 和回车写进去的就不再是同一串；而真实命令很少超过这个长度，复制一整段文章、一段
  /// 日志或一封邮件时提示「粘贴」毫无意义。
  public static let maximumLength = 128

  /// 命令名（首词）的最大长度。
  private static let maximumTokenLength = 64

  /// 剪贴板文本能否作为当前输入行的建议；不合格返回 nil。
  ///
  /// 这里只做**内容结构**判定。首词是否真的是一条已知命令由调用方查询（内置规格库、
  /// 别名、历史、`PATH`），两段判定合起来才能把「一条命令」和「一段话」区分开。
  ///
  /// - Parameters:
  ///   - clipboard: 系统剪贴板中的纯文本。
  ///   - line: 当前提示符上已输入的内容。
  /// - Returns: 可建议时返回原样的剪贴板文本（不做 trim，用户复制的空格可能是有意的）。
  public static func suggestion(clipboard: String, line: String) -> String? {
    // 只在空提示符上提示。用户已经在打字时，他的意图比剪贴板明确，插进来只会打扰。
    guard line.isEmpty else { return nil }
    guard !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard clipboard.count <= maximumLength else { return nil }
    // 多行内容既画不进单行 ghost，其中的换行又会在写入 PTY 时被 shell 当作提交，
    // 直接绕过「回车只粘贴不执行」的约定。这类内容仍可用常规 Cmd+V 粘贴。
    guard !clipboard.contains("\n"), !clipboard.contains("\r") else { return nil }
    // 控制字符可能隐藏按键或转义序列，复用粘贴保护的同一套识别规则。
    // sudo 提权不在这里拦：回车只写入不执行，整行明文可见，执行仍需用户再按一次回车。
    guard !PasteRiskAnalyzer.analyze(clipboard).risks.contains(.controlCharacters) else {
      return nil
    }
    guard commandToken(in: clipboard) != nil else { return nil }
    return clipboard
  }

  /// 取出可以拿去核对的命令名；文本结构上不像命令行时返回 nil。
  ///
  /// 判据刻意保守——宁可漏掉一条真命令，也不要在用户复制了一段话之后弹出「回车粘贴」。
  public static func commandToken(in text: String) -> String? {
    // CJK 字符和全角标点是自然语言文本的强信号。命令行里出现它们通常是参数值，
    // 而首词永远不会是中文，直接整条拒绝比逐词判断更简单也更稳。
    guard !text.unicodeScalars.contains(where: isNaturalLanguageScalar) else { return nil }
    // 裸 URL 本身不是命令。用户想下载它时会连同 curl / wget 一起复制。
    guard !text.contains("://") else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let token = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init),
      !token.isEmpty, token.count <= maximumTokenLength
    else { return nil }
    // 以 `-` 开头的是选项，不是命令；纯数字是版本号、金额或行号一类的片段。
    guard !token.hasPrefix("-"), Int(token) == nil else { return nil }
    guard token.unicodeScalars.allSatisfy(isCommandNameScalar) else { return nil }
    return token
  }

  /// 首词是否写成了路径形式（`./script`、`/usr/bin/env`、`~/bin/tool`）。
  /// 这类首词不必再去规格库或 `PATH` 里查，写法本身就表明它指向一个可执行文件。
  public static func isPathLikeCommand(_ token: String) -> Bool {
    token.hasPrefix("./") || token.hasPrefix("../") || token.hasPrefix("/") || token.hasPrefix("~/")
  }

  /// 文本自身的写法是否已经足以证明它是一条命令，无需再核对首词是不是本机认得的程序。
  ///
  /// 存在的理由：要求首词一定已知太严格——`uvx ruff check`、刚装上的工具、要贴到远端
  /// 主机去执行的命令，本机都不认识。而选项、管道、重定向、环境变量赋值这些写法在
  /// 自然语言里几乎不会出现，看到它们就可以放行；只有「几个普通单词拼起来」这种既像
  /// 命令又像一句话的情况，才需要回去查首词。
  public static func isSelfEvidentCommand(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    guard let first = tokens.first.map(String.init) else { return false }
    if isPathLikeCommand(first) { return true }
    // 环境变量前缀（`NODE_ENV=production npm start`）。
    if first.contains("=") { return true }
    // 选项标志。`-` 开头的 token 在一句话里不会出现。
    if tokens.dropFirst().contains(where: { $0.hasPrefix("-") }) { return true }
    // Shell 元字符：管道、重定向、逻辑连接、命令替换。
    if shellOperators.contains(where: trimmed.contains) { return true }
    // 只有一个词时没有更多线索可用，但一个孤零零的 token 也不构成「一段话」，
    // 放行的代价只是偶尔多一条无用建议，用户敲一下键就没了。
    return tokens.count == 1
  }

  private static let shellOperators = ["|", ">", "<", "&&", "||", ";", "$(", "`", "&"]

  private static func isNaturalLanguageScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x3000...0x303F,  // CJK 标点
      0x4E00...0x9FFF,  // CJK 统一表意文字
      0x3040...0x30FF,  // 日文假名
      0xAC00...0xD7AF,  // 谚文音节
      0xFF00...0xFFEF:  // 全角字符
      true
    default: false
    }
  }

  private static func isCommandNameScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9": true
    case ".", "_", "-", "+", "/", "~", ":", "@": true
    default: false
    }
  }
}
