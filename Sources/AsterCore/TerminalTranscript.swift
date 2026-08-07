import Foundation

/// 维护终端滚动记录中的可见文本状态。
///
/// PTY 输出可能通过回车覆盖进度行、通过退格修正输入，或通过 ANSI 指令清屏。
/// 本类型将这些常见控制行为收敛为稳定的纯文本状态，便于视图增量刷新和单元测试。
public struct TerminalTranscript: Sendable {
  /// 当前可见的完整滚动文本。
  public private(set) var text = ""
  private var pendingCarriageReturn = false
  private var pendingCSI = ""

  /// 创建空白终端记录。
  public init() {}

  /// 追加一段 PTY 输出，并应用常见的行编辑控制字符。
  ///
  /// - Parameter chunk: 已完成 UTF-8 解码的终端输出片段。
  public mutating func append(_ chunk: String) {
    let eraseDisplay = "\u{001B}[2J"
    let partition = ANSICleaner.partitionIncompleteCSI(in: pendingCSI + chunk)
    pendingCSI = partition.pending
    var visibleChunk = partition.complete

    if let clearRange = visibleChunk.range(of: eraseDisplay, options: .backwards) {
      text.removeAll(keepingCapacity: true)
      pendingCarriageReturn = false
      visibleChunk = String(visibleChunk[clearRange.upperBound...])
    }

    let cleanedChunk = ANSICleaner.visibleText(from: visibleChunk)
      .replacingOccurrences(of: "\r\n", with: "\n")

    for character in cleanedChunk {
      if pendingCarriageReturn {
        pendingCarriageReturn = false
        if character == "\n" {
          text.append("\n")
          continue
        }
        removeCurrentLine()
      }

      switch character {
      case "\r":
        // PTY 通常输出 CRLF。先延迟判断：若下一字符是 LF，则它是普通换行；
        // 否则再按独立 CR 的“回到行首并覆盖”语义处理。
        pendingCarriageReturn = true
      case "\u{8}", "\u{7F}":
        if !text.isEmpty, text.last != "\n" {
          text.removeLast()
        }
      case "\n", "\t":
        text.append(character)
      default:
        if character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
          text.append(character)
        }
      }
    }
  }

  /// 回车的语义是把光标移回当前行开头。纯文本模型无法原位覆盖单元格，
  /// 因此删除当前行，随后到达的内容会成为该行的新状态。
  private mutating func removeCurrentLine() {
    guard let newline = text.lastIndex(of: "\n") else {
      text.removeAll(keepingCapacity: true)
      return
    }
    text.removeSubrange(text.index(after: newline)..<text.endIndex)
  }
}
