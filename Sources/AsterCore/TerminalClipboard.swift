import Darwin
import Foundation

/// OSC 52 对终端程序读写系统剪贴板的授权级别。
///
/// `.ask` 不会被自动记忆：每次请求都必须在 AppKit 边界重新确认，避免一个已获授权的
/// 程序把权限间接传递给随后运行的命令。
public enum ClipboardAccess: String, CaseIterable, Codable, Equatable, Sendable {
  case allow
  case ask
  case deny
}

/// 复制文本的纯转换逻辑。它不接触系统剪贴板，便于选择复制、菜单复制和测试复用。
public enum TerminalClipboardText {
  /// 删除每个物理行末尾的水平空白，同时原样保留 LF、CRLF 和 CR 换行序列。
  /// 行首空白和行内空白属于终端输出内容，不会被改变。
  public static func trimmingTrailingWhitespace(in text: String) -> String {
    var result = String.UnicodeScalarView()
    var pendingWhitespace = String.UnicodeScalarView()

    for scalar in text.unicodeScalars {
      if scalar == "\n" || scalar == "\r" {
        pendingWhitespace.removeAll(keepingCapacity: true)
        result.append(scalar)
      } else if CharacterSet.whitespaces.contains(scalar) {
        pendingWhitespace.append(scalar)
      } else {
        result.append(contentsOf: pendingWhitespace)
        pendingWhitespace.removeAll(keepingCapacity: true)
        result.append(scalar)
      }
    }
    // 故意丢弃最后一行尚未写出的水平空白。
    return String(result)
  }
}

/// 复制相关设置的组合语义。Copy on Select 需要保留高亮供用户继续扩展，因此它比
/// “显式复制后清除”优先；菜单、快捷键和右键复制都走同一决策。
public enum TerminalSelectionPolicy {
  public static func clearsAfterExplicitCopy(
    copyOnSelect: Bool,
    clearSelectionOnCopy: Bool
  ) -> Bool {
    clearSelectionOnCopy && !copyOnSelect
  }
}

/// 粘贴保护会展示的独立风险。使用 `Set` 可让同一内容同时报告多个风险而不重复。
public enum PasteRisk: String, CaseIterable, Hashable, Sendable {
  case multipleLines
  case trailingNewline
  case privilegeEscalation
  case controlCharacters
}

/// 一次粘贴分析的不可变结果。`text` 仅在当前粘贴操作内存活，不应写入日志或持久化。
public struct PasteAnalysis: Equatable, Sendable {
  public let text: String
  public let risks: Set<PasteRisk>

  public init(text: String, risks: Set<PasteRisk>) {
    self.text = text
    self.risks = risks
  }

  /// 生成用于确认框的有界预览。控制字符以可见转义展示，防止它们影响对话框渲染。
  public func preview(maximumCharacters: Int = 2_000) -> String {
    guard maximumCharacters > 0 else { return "" }
    var output = ""
    output.reserveCapacity(min(text.count, maximumCharacters))
    var count = 0
    for scalar in text.unicodeScalars {
      guard count < maximumCharacters else {
        output.append("…")
        break
      }
      switch scalar.value {
      case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0x9F:
        output.append(String(format: "\\u{%02X}", scalar.value))
      default:
        output.unicodeScalars.append(scalar)
      }
      count += 1
    }
    return output
  }
}

/// 识别可能在粘贴瞬间执行命令或隐藏行为的内容。这里只分类，不决定是否弹框。
public enum PasteRiskAnalyzer {
  public static func analyze(_ text: String) -> PasteAnalysis {
    var risks: Set<PasteRisk> = []
    if hasMultipleLogicalLines(text) { risks.insert(.multipleLines) }
    if text.last == "\n" || text.last == "\r" { risks.insert(.trailingNewline) }
    if containsPrivilegeEscalationCommand(text) { risks.insert(.privilegeEscalation) }
    if containsUnsafeControlCharacter(text) { risks.insert(.controlCharacters) }
    return PasteAnalysis(text: text, risks: risks)
  }

  /// 单个末尾换行由 `.trailingNewline` 单独报告；去掉它后仍有换行才属于多行粘贴。
  private static func hasMultipleLogicalLines(_ text: String) -> Bool {
    var body = text
    if body.hasSuffix("\r\n") {
      body.removeLast(2)
    } else if body.last == "\n" || body.last == "\r" {
      body.removeLast()
    }
    return body.contains("\n") || body.contains("\r")
  }

  /// 采用命令词边界识别 `sudo`/`su`。这是保守告警：即使词出现在引号中，也宁可让
  /// 用户看到一次确认；但 `sudoer`、`assumption` 等普通单词不会误报。
  private static func containsPrivilegeEscalationCommand(_ text: String) -> Bool {
    var token = ""
    func isTokenScalar(_ scalar: UnicodeScalar) -> Bool {
      CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
    }
    for scalar in text.unicodeScalars {
      if isTokenScalar(scalar) {
        token.unicodeScalars.append(scalar)
      } else {
        if token == "sudo" || token == "su" { return true }
        token.removeAll(keepingCapacity: true)
      }
    }
    return token == "sudo" || token == "su"
  }

  /// Tab 和换行是正常终端文本；其余 C0、DEL 与 C1 控制字符可能隐藏按键或转义序列。
  private static func containsUnsafeControlCharacter(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x09, 0x0A, 0x0D: false
      case 0x00...0x1F, 0x7F...0x9F: true
      default: false
      }
    }
  }
}

/// 把内容风险与当前终端模式组合成最终粘贴保护决策。
public enum PasteProtectionPolicy {
  public static func requiresConfirmation(
    for analysis: PasteAnalysis,
    protectionEnabled: Bool,
    isAlternateScreen: Bool = false,
    isBracketedPasteMode: Bool = false,
    treatsBracketedPasteAsSafe: Bool = true
  ) -> Bool {
    guard protectionEnabled, !analysis.risks.isEmpty else { return false }
    // ESC、C0/C1 等控制字符可以提前结束 bracketed paste 或向 TUI 注入按键。即使位于
    // 备用屏或程序声明 bracketed paste，也必须让用户看到明确风险。
    if analysis.risks.contains(.controlCharacters) { return true }
    guard !isAlternateScreen else { return false }
    if isBracketedPasteMode, treatsBracketedPasteAsSafe { return false }
    return true
  }
}

/// 生成写入 PTY 的完整粘贴字节。括号模式使用 xterm `CSI 200~`/`CSI 201~`，正文
/// 保持原始 UTF-8，不经过 Shell 插值或换行规范化。
public enum PasteTransmissionEncoder {
  private static let bracketedStart = Array("\u{1B}[200~".utf8)
  private static let bracketedEnd = Array("\u{1B}[201~".utf8)

  public static func encode(_ text: String, bracketed: Bool) -> [UInt8] {
    guard bracketed else { return Array(text.utf8) }
    // Bracketed paste 没有协议级转义机制。把正文中的结束标记转换为可见文本，防止它
    // 提前关闭粘贴模式并让后续换行作为实时命令执行。C1 CSI 等价形式一并中和。
    let safeText =
      text
      .replacingOccurrences(of: "\u{1B}[201~", with: "\\x1B[201~")
      .replacingOccurrences(of: "\u{009B}201~", with: "\\x9B201~")
    return bracketedStart + safeText.utf8 + bracketedEnd
  }
}

/// 在原始 PTY 字节进入 SwiftTerm 前限制 OSC 缓冲。超限时向下游发送 CAN 取消当前
/// 序列，并丢弃至真实终止符；这样组件内部 `_osc` 永远不会先于业务层限长而无界增长。
public struct TerminalOSCStreamLimiter: Sendable {
  private enum State: Sendable {
    case ground
    case escape
    case code(digits: [UInt8], forwardedBytes: Int)
    case payload(code: Int?, forwardedBytes: Int)
    case forwardedEscape
    case dropping
    case droppingEscape
  }

  public let maximumSequenceBytes: Int
  public let maximumClipboardSequenceBytes: Int
  public let maximumNotificationSequenceBytes: Int
  private var state: State = .ground

  public init(
    maximumSequenceBytes: Int = 16 * 1_024 * 1_024,
    maximumClipboardSequenceBytes: Int = 8 * 1_024 * 1_024,
    maximumNotificationSequenceBytes: Int = 8_224
  ) {
    self.maximumSequenceBytes = max(8, maximumSequenceBytes)
    self.maximumClipboardSequenceBytes = min(
      max(8, maximumClipboardSequenceBytes),
      self.maximumSequenceBytes
    )
    // OSC 9/99/777 的协议 payload 上限为 8 KiB；额外 32 字节容纳 introducer、
    // metadata 和终止符，但绝不允许它们继承通用 OSC 的 16 MiB 缓冲上限。
    self.maximumNotificationSequenceBytes = min(
      max(8, maximumNotificationSequenceBytes),
      self.maximumSequenceBytes
    )
  }

  /// 返回可以安全交给终端解析器的字节。方法保持跨 PTY 分片状态，不要求 OSC 起止符
  /// 位于同一读取块；正常序列逐字节原样返回。
  public mutating func consume<S: Sequence>(_ bytes: S) -> [UInt8]
  where S.Element == UInt8 {
    var output: [UInt8] = []
    output.reserveCapacity(bytes.underestimatedCount)
    for byte in bytes { consume(byte, into: &output) }
    return output
  }

  private mutating func consume(_ byte: UInt8, into output: inout [UInt8]) {
    // SwiftTerm 把 C1 OSC(0x9D) 定义为“任意状态”转换。必须在状态分派前处理，
    // 否则 `ESC 0x9D` 或一条 OSC 内嵌 0x9D 都会让两层状态机分叉并绕过限长。
    if byte == 0x9D {
      restartWithEightBitOSC(into: &output)
      return
    }
    switch state {
    case .ground:
      output.append(byte)
      if byte == 0x1B {
        state = .escape
      }

    case .escape:
      output.append(byte)
      if byte == 0x5D {  // ESC ]
        state = .code(digits: [], forwardedBytes: 2)
      } else if !Self.swiftTermKeepsEscapeState(after: byte) {
        state = .ground
      }

    case .code(var digits, let forwardedBytes):
      if let terminator = normalizedTerminator(byte) {
        output.append(contentsOf: terminator)
        state = .ground
      } else if byte == 0x1B {
        output.append(byte)
        state = .forwardedEscape
      } else if forwardedBytes >= maximumSequenceBytes {
        output.append(0x18)  // CAN：让 SwiftTerm 清空已缓存 OSC 且不派发 handler。
        state = .dropping
      } else {
        output.append(byte)
        let nextCount = forwardedBytes + 1
        if byte == 0x3B {  // ;
          let code = digits.isEmpty ? nil : Int(String(decoding: digits, as: UTF8.self))
          state = .payload(code: code, forwardedBytes: nextCount)
        } else if (0x30...0x39).contains(byte), digits.count < 8 {
          digits.append(byte)
          state = .code(digits: digits, forwardedBytes: nextCount)
        } else {
          state = .payload(code: nil, forwardedBytes: nextCount)
        }
      }

    case .payload(let code, let forwardedBytes):
      if let terminator = normalizedTerminator(byte) {
        output.append(contentsOf: terminator)
        state = .ground
      } else if byte == 0x1B {
        output.append(byte)
        state = .forwardedEscape
      } else {
        let limit: Int
        if code == 52 {
          limit = maximumClipboardSequenceBytes
        } else if code == 9 || code == 99 || code == 777 {
          limit = maximumNotificationSequenceBytes
        } else {
          limit = maximumSequenceBytes
        }
        if forwardedBytes >= limit {
          output.append(0x18)
          state = .dropping
        } else {
          output.append(byte)
          state = .payload(code: code, forwardedBytes: forwardedBytes + 1)
        }
      }

    case .forwardedEscape:
      // SwiftTerm 已把前一个 ESC 作为 OSC 终止并进入 escape；当前字节仍需原样交付。
      output.append(byte)
      if byte == 0x5D {  // 同一个 ESC 后接 ] 会立即开始下一条 OSC。
        state = .code(digits: [], forwardedBytes: 2)
      } else if Self.swiftTermKeepsEscapeState(after: byte) {
        state = .escape
      } else {
        state = .ground
      }

    case .dropping:
      if normalizedTerminator(byte) != nil {
        state = .ground
      } else if byte == 0x1B {
        state = .droppingEscape
      }

    case .droppingEscape:
      if byte == 0x5C {  // 丢弃 ST 的反斜线；synthetic CAN 已终止下游序列。
        state = .ground
      } else {
        // ESC 也可能同时终止旧 OSC 并作为下一条 ESC 序列的起点。下游只看到了 CAN，
        // 因此补回该 ESC，再按正常 escape 状态消费当前字节。
        output.append(0x1B)
        state = .escape
        consume(byte, into: &output)
      }
    }
  }

  /// 把八位 OSC 起始符规范化为七位形式。若当前正在转发一条 OSC，先用 CAN 取消旧
  /// 序列，避免 `ESC ]` 为启动新序列而意外派发不完整的旧 handler；丢弃态的下游
  /// 已由 synthetic CAN 回到 ground，无需重复取消。
  private mutating func restartWithEightBitOSC(into output: inout [UInt8]) {
    switch state {
    case .code, .payload:
      output.append(0x18)
    case .ground, .escape, .forwardedEscape, .dropping, .droppingEscape:
      break
    }
    output.append(contentsOf: [0x1B, 0x5D])
    state = .code(digits: [], forwardedBytes: 2)
  }

  /// SwiftTerm 在 Escape 状态执行 C0 控制字符和 DEL 后仍停留在 Escape；因此
  /// `ESC BEL ]` 仍会启动 OSC。limiter 必须镜像这一点，否则 `]` 会被误判为普通文本。
  private static func swiftTermKeepsEscapeState(after byte: UInt8) -> Bool {
    (0x00...0x18).contains(byte) || (0x1C...0x1F).contains(byte) || byte == 0x7F
      || byte == 0x1B
  }

  /// SwiftTerm 的 `oscPut` 快速路径对 C1 ST/SUB 的行为取决于分片边界。统一转换为其
  /// 稳定处理的七位 ST 或 CAN，保证 limiter 与下游 parser 永远在同一状态。
  private func normalizedTerminator(_ byte: UInt8) -> [UInt8]? {
    switch byte {
    case 0x07, 0x18: [byte]  // BEL / CAN
    case 0x1A: [0x18]  // SUB 与 CAN 都表示取消，不派发截断 OSC。
    case 0x9C: [0x1B, 0x5C]  // 8-bit ST -> ESC \
    default: nil
    }
  }
}

/// “转义特殊字符后粘贴”的 POSIX Shell 编码。单引号包裹可阻止变量展开、命令替换、
/// glob 和换行执行；正文中的单引号用结束引号、转义引号、重新开引号的标准形式表示。
public enum ShellPasteEscaper {
  public static func escape(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

public enum TerminalFilePasteError: Error, Equatable, Sendable {
  case unsupportedFile
  case fileTooLarge
  case readFailed
}

/// “以 Base64 粘贴文件”的有界文件边界。先打开文件描述符再用 `fstat` 验证最终对象，
/// 因而路径在选择后被替换成 FIFO、socket 或设备时不会阻塞，也不会读取特殊文件。
public enum TerminalFilePasteEncoder {
  public static func encodeBase64(
    path: String,
    maximumBytes: Int = 8 * 1_024 * 1_024
  ) throws -> String {
    guard maximumBytes >= 0 else { throw TerminalFilePasteError.fileTooLarge }
    var expectedMetadata = stat()
    guard Darwin.lstat(path, &expectedMetadata) == 0 else {
      throw TerminalFilePasteError.readFailed
    }
    guard expectedMetadata.st_mode & S_IFMT == S_IFREG else {
      throw TerminalFilePasteError.unsupportedFile
    }
    let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw TerminalFilePasteError.readFailed }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw TerminalFilePasteError.readFailed
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw TerminalFilePasteError.unsupportedFile
    }
    guard expectedMetadata.st_dev == metadata.st_dev,
      expectedMetadata.st_ino == metadata.st_ino
    else { throw TerminalFilePasteError.readFailed }
    guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
      throw TerminalFilePasteError.fileTooLarge
    }

    var data = Data()
    data.reserveCapacity(Int(metadata.st_size))
    let boundedReadSize = maximumBytes >= 64 * 1_024 ? 64 * 1_024 : maximumBytes + 1
    var buffer = [UInt8](repeating: 0, count: max(boundedReadSize, 1))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw TerminalFilePasteError.readFailed
      }
      guard data.count + count <= maximumBytes else {
        throw TerminalFilePasteError.fileTooLarge
      }
      data.append(buffer, count: count)
    }
    var finalMetadata = stat()
    guard Darwin.fstat(descriptor, &finalMetadata) == 0,
      metadata.st_dev == finalMetadata.st_dev,
      metadata.st_ino == finalMetadata.st_ino,
      metadata.st_size == finalMetadata.st_size,
      metadata.st_mtimespec.tv_sec == finalMetadata.st_mtimespec.tv_sec,
      metadata.st_mtimespec.tv_nsec == finalMetadata.st_mtimespec.tv_nsec,
      metadata.st_ctimespec.tv_sec == finalMetadata.st_ctimespec.tv_sec,
      metadata.st_ctimespec.tv_nsec == finalMetadata.st_ctimespec.tv_nsec
    else { throw TerminalFilePasteError.readFailed }
    return data.base64EncodedString()
  }
}

/// 已通过语法与大小校验的 OSC 52 请求。
public enum OSC52Request: Equatable, Sendable {
  case read(selection: String)
  case write(selection: String, text: String)
}

public enum OSC52ParseError: Error, Equatable, Sendable {
  case malformed
  case invalidSelection
  case payloadTooLarge
  case invalidBase64
  case invalidUTF8
}

/// 有界解析 OSC 52 的 `selection;payload` 数据。限制在 Base64 解码前生效，避免终端
/// 输出用巨型载荷造成无界内存分配。
public struct OSC52RequestParser: Sendable {
  public let maximumEncodedBytes: Int
  public let maximumDecodedBytes: Int

  public init(
    maximumEncodedBytes: Int = 8 * 1_024 * 1_024, maximumDecodedBytes: Int = 6 * 1_024 * 1_024
  ) {
    self.maximumEncodedBytes = max(0, maximumEncodedBytes)
    self.maximumDecodedBytes = max(0, maximumDecodedBytes)
  }

  public func parse(_ bytes: ArraySlice<UInt8>) throws -> OSC52Request {
    guard bytes.count <= maximumEncodedBytes,
      let separator = bytes.firstIndex(of: UInt8(ascii: ";"))
    else {
      throw bytes.count > maximumEncodedBytes ? OSC52ParseError.payloadTooLarge : .malformed
    }
    let selectionBytes = bytes[..<separator]
    let payload = bytes[bytes.index(after: separator)...]
    guard let selection = String(bytes: selectionBytes, encoding: .utf8),
      Self.isValidSelection(selection)
    else { throw OSC52ParseError.invalidSelection }

    if payload.elementsEqual([UInt8(ascii: "?")]) {
      return .read(selection: selection.isEmpty ? "c" : selection)
    }
    guard let decoded = Data(base64Encoded: Data(payload)) else {
      throw OSC52ParseError.invalidBase64
    }
    guard decoded.count <= maximumDecodedBytes else { throw OSC52ParseError.payloadTooLarge }
    guard let text = String(data: decoded, encoding: .utf8) else {
      throw OSC52ParseError.invalidUTF8
    }
    return .write(selection: selection.isEmpty ? "c" : selection, text: text)
  }

  /// XTerm 允许 clipboard、primary、select 和 cut-buffer 标识；空值按 clipboard 处理。
  public static func isValidSelection(_ selection: String) -> Bool {
    selection.count <= 8 && selection.allSatisfy { "cpqs01234567".contains($0) }
  }
}

public enum OSC52ResponseError: Error, Equatable, Sendable {
  case invalidSelection
  case textTooLarge
}

/// 为 OSC 52 读取请求生成七位控制序列响应。调用方只能把返回字节写回同一个 PTY。
public struct OSC52ResponseEncoder: Sendable {
  public let maximumTextBytes: Int

  public init(maximumTextBytes: Int = 1 * 1_024 * 1_024) {
    self.maximumTextBytes = max(0, maximumTextBytes)
  }

  public func encode(selection: String, text: String) throws -> [UInt8] {
    guard OSC52RequestParser.isValidSelection(selection), !selection.isEmpty else {
      throw OSC52ResponseError.invalidSelection
    }
    let data = Data(text.utf8)
    guard data.count <= maximumTextBytes else { throw OSC52ResponseError.textTooLarge }
    let payload = data.base64EncodedString()
    return Array("\u{1B}]52;\(selection);\(payload)\u{1B}\\".utf8)
  }
}
