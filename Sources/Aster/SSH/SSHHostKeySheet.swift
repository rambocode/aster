import AppKit
import AsterCore
import Foundation

// 主机密钥确认表单。
// unknown：显示算法和指纹，默认按钮是「取消」，防止误按回车就信任了陌生主机。
// changed：醒目警告可能遭遇中间人攻击，必须手动输入 `yes` 才能继续。

/// 主机密钥确认的构建与展示。
@MainActor
enum SSHHostKeySheet {
  /// 密钥变更时要求用户输入的确认词。
  static let confirmationWord = "yes"

  /// 展示确认表单；true 表示用户信任该密钥。
  static func confirm(_ request: SSHHostKeyRequest) async -> Bool {
    switch request.status {
    case .unknown: await confirmUnknown(request)
    case .changed: await confirmChanged(request)
    }
  }

  /// 首次连接：核对指纹后选择信任或取消。
  private static func confirmUnknown(_ request: SSHHostKeyRequest) async -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("无法确认主机 \(request.endpoint) 的身份")
    alert.informativeText = L(
      "这是第一次连接这台主机。请和服务器管理员核对下面的指纹，一致后再连接。\n\n算法：\(request.algorithm)\n指纹：\(request.fingerprint)"
    )
    // 第一个按钮是默认按钮（回车）：放「取消」。
    alert.addButton(withTitle: L("取消"))
    let trust = alert.addButton(withTitle: L("信任并连接"))
    trust.keyEquivalent = ""
    return await SSHAuthSheet.present(alert) == .alertSecondButtonReturn
  }

  /// 密钥已变更：可能是中间人攻击，必须输入确认词才能替换旧密钥。
  private static func confirmChanged(_ request: SSHHostKeyRequest) async -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = L("警告：\(request.endpoint) 的主机密钥已改变！")
    alert.informativeText = L(
      "服务器发来的主机密钥和 known_hosts 里的记录不同。可能有人正在进行中间人攻击，窃听或篡改这次连接；也可能是服务器重装了系统或更换了密钥。\n\n算法：\(request.algorithm)\n新指纹：\(request.fingerprint)\n\n只有确认这次变更是预期的，才在下面输入 yes，替换旧密钥并连接。"
    )
    alert.addButton(withTitle: L("取消"))
    let replace = alert.addButton(withTitle: L("替换密钥并连接"))
    replace.keyEquivalent = ""
    replace.isEnabled = false

    let field = NSTextField()
    field.identifier = NSUserInterfaceItemIdentifier("ssh-hostkey-confirm-field")
    field.placeholderString = confirmationWord
    field.setAccessibilityLabel(L("输入 yes 确认替换主机密钥"))
    let gate = ConfirmationGate(button: replace)
    field.delegate = gate
    alert.accessoryView = SSHAuthSheet.stack([field])
    alert.window.initialFirstResponder = field

    let response = await SSHAuthSheet.present(alert)
    // field.delegate 是弱引用，gate 必须活到表单关闭。
    withExtendedLifetime(gate) {}
    return response == .alertSecondButtonReturn && isConfirmation(field.stringValue)
  }

  /// 输入是否等于确认词（忽略首尾空白，区分大小写，和 OpenSSH 的 yes/no 提示一致）。
  static func isConfirmation(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines) == confirmationWord
  }

  /// 输入框变化时切换「替换」按钮的可用状态。
  private final class ConfirmationGate: NSObject, NSTextFieldDelegate {
    private weak var button: NSButton?

    init(button: NSButton) { self.button = button }

    /// 每次输入都重新判断；只有确认词才放开按钮。
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      button?.isEnabled = SSHHostKeySheet.isConfirmation(field.stringValue)
    }
  }
}
