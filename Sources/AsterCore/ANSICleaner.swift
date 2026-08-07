import Foundation

/// 将终端控制流转换成适合文本视图显示的可见文本。
///
/// 该类型只处理“不可见控制序列的清理”，不会解释颜色或光标位置；完整的
/// 终端状态仍由上层会话视图维护。输入可以包含 UTF-8 文本和常见 ANSI CSI
/// 序列，输出保证不包含这些转义序列。
public enum ANSICleaner {
  /// 移除 ANSI CSI 序列，保留用户实际应该看到的文本。
  ///
  /// - Parameter input: 已从 PTY 解码得到的字符串。
  /// - Returns: 去除 CSI 控制片段后的可见文本。
  public static func visibleText(from input: String) -> String {
    let pattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    return input.replacingOccurrences(
      of: pattern,
      with: "",
      options: .regularExpression
    )
  }

  /// 从输入尾部提取尚未收到终止字节的 CSI 序列。
  ///
  /// - Returns: 可以立即解释的完整前缀，以及需要与下一块拼接的尾部。
  public static func partitionIncompleteCSI(in input: String) -> (
    complete: String, pending: String
  ) {
    guard let escapeIndex = input.lastIndex(of: "\u{001B}") else {
      return (input, "")
    }

    let suffix = String(input[escapeIndex...])
    guard suffix == "\u{001B}" || suffix.hasPrefix("\u{001B}[") else {
      return (input, "")
    }
    if suffix == "\u{001B}" {
      return (String(input[..<escapeIndex]), suffix)
    }

    let payload = suffix.unicodeScalars.dropFirst(2)
    let hasFinalByte = payload.contains { (0x40...0x7E).contains($0.value) }
    guard !hasFinalByte else { return (input, "") }
    return (String(input[..<escapeIndex]), suffix)
  }
}
