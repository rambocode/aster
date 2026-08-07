import AppKit
import AsterCore
import Foundation

/// OSC 52 提示只说明访问方向，不包含剪贴板正文，避免敏感信息出现在对话框或日志中。
enum OSC52ClipboardOperation: Equatable, Sendable {
  case read
  case write
}

/// OSC 52 的唯一 AppKit 边界。解析和响应编码由 AsterCore 完成；本类型只负责读取
/// 当前权限、按需确认和访问 `NSPasteboard`。授权不记忆，`.ask` 每次请求都会触发确认。
@MainActor
final class OSC52ClipboardCoordinator {
  typealias AccessProvider = @MainActor (OSC52ClipboardOperation) -> ClipboardAccess
  typealias ConfirmationHandler = @MainActor (OSC52ClipboardOperation) -> Bool
  typealias ClipboardReader = @MainActor () -> String?
  typealias ClipboardWriter = @MainActor (String) -> Bool
  typealias Clock = @MainActor () -> Date

  private let parser: OSC52RequestParser
  private let responseEncoder: OSC52ResponseEncoder
  private let access: AccessProvider
  private let confirm: ConfirmationHandler
  private let readClipboard: ClipboardReader
  private let writeClipboard: ClipboardWriter
  private let now: Clock
  private let promptCooldown: TimeInterval
  private var promptInProgress = false
  private var suppressPromptsUntil = Date.distantPast

  init(
    parser: OSC52RequestParser = OSC52RequestParser(),
    responseEncoder: OSC52ResponseEncoder = OSC52ResponseEncoder(),
    access: @escaping AccessProvider,
    confirm: @escaping ConfirmationHandler = OSC52ClipboardCoordinator.presentConfirmation,
    readClipboard: @escaping ClipboardReader = {
      NSPasteboard.general.string(forType: .string)
    },
    writeClipboard: @escaping ClipboardWriter = { text in
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      return pasteboard.setString(text, forType: .string)
    },
    now: @escaping Clock = Date.init,
    promptCooldown: TimeInterval = 5
  ) {
    self.parser = parser
    self.responseEncoder = responseEncoder
    self.access = access
    self.confirm = confirm
    self.readClipboard = readClipboard
    self.writeClipboard = writeClipboard
    self.now = now
    self.promptCooldown = max(0, promptCooldown)
  }

  /// 处理一个 OSC 52 payload。读取成功时返回应写回同一 PTY 的响应字节；写入、拒绝、
  /// 取消或畸形请求返回 nil。协议错误不会显示弹框，防止恶意输出造成提示风暴。
  func handle(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
    guard let request = try? parser.parse(bytes) else { return nil }
    switch request {
    case .write(_, let text):
      guard isAllowed(.write) else { return nil }
      _ = writeClipboard(text)
      return nil
    case .read(let selection):
      guard isAllowed(.read), let text = readClipboard() else { return nil }
      return try? responseEncoder.encode(selection: selection, text: text)
    }
  }

  private func isAllowed(_ operation: OSC52ClipboardOperation) -> Bool {
    switch access(operation) {
    case .allow: return true
    case .ask:
      let currentTime = now()
      guard !promptInProgress, currentTime >= suppressPromptsUntil else { return false }
      promptInProgress = true
      defer {
        promptInProgress = false
        suppressPromptsUntil = now().addingTimeInterval(promptCooldown)
      }
      return confirm(operation)
    case .deny: return false
    }
  }

  private static func presentConfirmation(_ operation: OSC52ClipboardOperation) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    switch operation {
    case .read:
      alert.messageText = "允许终端读取剪贴板？"
      alert.informativeText = "当前终端程序请求读取系统剪贴板。剪贴板可能包含敏感信息。"
    case .write:
      alert.messageText = "允许终端写入剪贴板？"
      alert.informativeText = "当前终端程序请求替换系统剪贴板内容。"
    }
    alert.addButton(withTitle: "允许一次")
    alert.addButton(withTitle: "拒绝")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
