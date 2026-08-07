import Foundation

/// 从 PTY 字节流中镜像 OSC 标题与 xterm 标题栈，并按原始顺序报告标题变化。
///
/// SwiftTerm 的 macOS 视图不会向宿主转发 `setTerminalIconTitle`，且其 `23;1t` / `23;2t`
/// 恢复分支与 xterm 语义相反。该观察器不参与终端渲染，只在输出经过原始解析器后补发
/// 正确的标题事件。状态机保留跨读取分片的 7-bit ESC CSI/OSC 序列，避免 PTY 恰好拆包
/// 时漏报。它刻意不识别裸 8-bit C1：`0x9B...0x9D` 也是合法 UTF-8 续字节，脱离完整
/// 终端字符集状态直接解释会吞掉中文、Cyrillic 等普通输出后的标题序列。
public struct TerminalTitleStackObserver: Sendable {
  /// 一次标题更新。`code` 为 0（两者）、1（图标/标签）或 2（窗口）。
  public struct Update: Equatable, Sendable {
    public let code: Int
    public let title: String

    public init(code: Int, title: String) {
      self.code = code
      self.title = title
    }
  }

  private enum ParseState: Sendable {
    case ground
    case escape
    case csi([UInt8])
    case oscCode([UInt8])
    case oscPayload(code: Int, bytes: [UInt8])
    case oscEscape(code: Int, bytes: [UInt8])
  }

  /// 限制单条 OSC 的暂存体积；最终进入标题模型时还会执行更严格的 512 字节限制。
  private static let maximumBufferedPayloadBytes = 4_096

  private var state: ParseState = .ground
  private var windowTitle = ""
  private var iconTitle = ""
  private var windowTitleStack: [String] = []
  private var iconTitleStack: [String] = []

  public init() {}

  /// 消费一段原始 PTY 输出，返回本段中完成的普通 OSC 与标题恢复事件。
  ///
  /// 返回值严格遵循字节流顺序。调用方应在 SwiftTerm 处理完整分片后依次应用这些事件，
  /// 使其覆盖 macOS 端缺失、重复或顺序错误的 delegate 回调。未知、损坏或未结束的
  /// 序列会被忽略或留待下一分片继续解析。
  public mutating func consume<S: Sequence>(_ bytes: S) -> [Update]
  where S.Element == UInt8 {
    var updates: [Update] = []
    for byte in bytes {
      consume(byte, updates: &updates)
    }
    return updates
  }

  private mutating func consume(_ byte: UInt8, updates: inout [Update]) {
    switch state {
    case .ground:
      switch byte {
      case 0x1B: state = .escape
      default: break
      }

    case .escape:
      switch byte {
      case 0x5B: state = .csi([])  // ESC [
      case 0x5D: state = .oscCode([])  // ESC ]
      case 0x1B: state = .escape
      default: state = .ground
      }

    case .csi(var parameters):
      if (0x40...0x7E).contains(byte) {
        if byte == 0x74 {  // t
          handleWindowCommand(parameters, updates: &updates)
        }
        state = .ground
      } else if parameters.count < 64 {
        parameters.append(byte)
        state = .csi(parameters)
      } else {
        state = .ground
      }

    case .oscCode(var digits):
      if byte == 0x3B, let code = Int(String(decoding: digits, as: UTF8.self)) {  // ;
        state = .oscPayload(code: code, bytes: [])
      } else if (0x30...0x39).contains(byte), digits.count < 8 {
        digits.append(byte)
        state = .oscCode(digits)
      } else if byte == 0x1B {
        state = .escape
      } else {
        state = .ground
      }

    case .oscPayload(let code, var payload):
      switch byte {
      case 0x07:  // BEL
        handleOSC(code: code, payload: payload, updates: &updates)
        state = .ground
      case 0x1B:
        state = .oscEscape(code: code, bytes: payload)
      default:
        append(byte, to: &payload)
        state = .oscPayload(code: code, bytes: payload)
      }

    case .oscEscape(let code, var payload):
      if byte == 0x5C {  // ESC \
        handleOSC(code: code, payload: payload, updates: &updates)
        state = .ground
      } else {
        append(0x1B, to: &payload)
        append(byte, to: &payload)
        state = .oscPayload(code: code, bytes: payload)
      }
    }
  }

  private func append(_ byte: UInt8, to payload: inout [UInt8]) {
    guard payload.count < Self.maximumBufferedPayloadBytes else { return }
    payload.append(byte)
  }

  private mutating func handleOSC(code: Int, payload: [UInt8], updates: inout [Update]) {
    let title = String(bytes: payload, encoding: .utf8) ?? ""
    switch code {
    case 0:
      windowTitle = title
      iconTitle = title
      updates.append(Update(code: 0, title: title))
    case 1:
      iconTitle = title
      updates.append(Update(code: 1, title: title))
    case 2:
      windowTitle = title
      updates.append(Update(code: 2, title: title))
    default:
      break
    }
  }

  private mutating func handleWindowCommand(
    _ bytes: [UInt8], updates: inout [Update]
  ) {
    let components = String(decoding: bytes, as: UTF8.self)
      .split(separator: ";", omittingEmptySubsequences: false)
    let decoded = components.map { Int($0) }
    guard decoded.allSatisfy({ $0 != nil }) else { return }
    let parameters = decoded.compactMap { $0 }

    switch parameters {
    case [22, 0], [22, 0, 0]:
      windowTitleStack.append(windowTitle)
      iconTitleStack.append(iconTitle)
    case [22, 1]:
      iconTitleStack.append(iconTitle)
    case [22, 2]:
      windowTitleStack.append(windowTitle)
    case [23, 0], [23, 0, 0]:
      restoreWindowTitle(into: &updates)
      restoreIconTitle(into: &updates)
    case [23, 1]:
      restoreIconTitle(into: &updates)
    case [23, 2]:
      restoreWindowTitle(into: &updates)
    default:
      break
    }
  }

  private mutating func restoreWindowTitle(into updates: inout [Update]) {
    guard let restored = windowTitleStack.popLast() else { return }
    windowTitle = restored
    updates.append(Update(code: 2, title: restored))
  }

  private mutating func restoreIconTitle(into updates: inout [Update]) {
    guard let restored = iconTitleStack.popLast() else { return }
    iconTitle = restored
    updates.append(Update(code: 1, title: restored))
  }
}
