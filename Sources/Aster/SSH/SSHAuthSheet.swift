import AppKit
import AsterCore
import Foundation

// SSH 认证表单：口令 / passphrase 与键盘交互（2FA）。
// 表单挂在当前 key window（其次主窗口）上；没有可用窗口时退化为 App 模态。

/// 生产环境的弹窗实现：把请求交给对应的 AppKit 表单。
@MainActor
final class SSHAuthWindowPresenter: SSHAuthPresenting {
  /// 询问口令或 passphrase。
  func promptSecret(_ prompt: SSHSecretPrompt) async -> SSHSecretPromptResponse? {
    await SSHAuthSheet.promptSecret(prompt)
  }

  /// 询问键盘交互的各项回答。
  func promptKeyboardInteractive(_ prompt: SSHKeyboardInteractivePrompt) async -> [String]? {
    await SSHAuthSheet.promptKeyboardInteractive(prompt)
  }

  /// 确认主机密钥。
  func confirmHostKey(_ request: SSHHostKeyRequest) async -> Bool {
    await SSHHostKeySheet.confirm(request)
  }
}

/// 认证表单的构建与展示。
@MainActor
enum SSHAuthSheet {
  static let fieldWidth: CGFloat = 320

  // MARK: 口令 / passphrase

  /// 展示口令或 passphrase 表单；取消返回 nil。
  static func promptSecret(_ prompt: SSHSecretPrompt) async -> SSHSecretPromptResponse? {
    let alert = NSAlert()
    switch prompt.subject {
    case .password(let endpoint):
      alert.messageText = L("输入 \(endpoint) 的口令")
      alert.informativeText = prompt.isRetry ? L("口令错误，请重试。") : ""
    case .passphrase(let keyFile):
      let name = keyFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("私钥")
      alert.messageText = L("输入密钥 \(name) 的 passphrase")
      var lines: [String] = []
      if prompt.isRetry { lines.append(L("passphrase 错误，请重试。")) }
      if let keyFile { lines.append(keyFile) }
      alert.informativeText = lines.joined(separator: "\n")
    }
    if prompt.isRetry { alert.alertStyle = .warning }
    alert.addButton(withTitle: L("连接"))
    alert.addButton(withTitle: L("取消"))

    let field = NSSecureTextField()
    field.identifier = NSUserInterfaceItemIdentifier("ssh-auth-secret-field")
    field.setAccessibilityLabel(alert.messageText)
    let rememberBox = NSButton(checkboxWithTitle: L("记住到钥匙串"), target: nil, action: nil)
    rememberBox.identifier = NSUserInterfaceItemIdentifier("ssh-auth-remember")
    rememberBox.state = .on
    rememberBox.isHidden = !prompt.canRemember

    alert.accessoryView = stack([field, rememberBox])
    alert.window.initialFirstResponder = field

    guard await present(alert) == .alertFirstButtonReturn else { return nil }
    return SSHSecretPromptResponse(
      secret: field.stringValue, remember: prompt.canRemember && rememberBox.state == .on)
  }

  // MARK: 键盘交互

  /// 按 prompts 逐项生成输入框；`echo=false` 的用安全输入框。取消返回 nil。
  static func promptKeyboardInteractive(_ prompt: SSHKeyboardInteractivePrompt) async -> [String]? {
    let alert = NSAlert()
    let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
    alert.messageText = name.isEmpty ? L("\(prompt.endpoint) 需要验证") : name
    var lines: [String] = []
    if prompt.isRetry { lines.append(L("验证失败，请重试。")) }
    let instruction = prompt.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    if !instruction.isEmpty { lines.append(instruction) }
    if !name.isEmpty { lines.append(prompt.endpoint) }
    alert.informativeText = lines.joined(separator: "\n")
    if prompt.isRetry { alert.alertStyle = .warning }
    alert.addButton(withTitle: L("继续"))
    alert.addButton(withTitle: L("取消"))

    var rows: [NSView] = []
    var fields: [NSTextField] = []
    for (index, item) in prompt.prompts.enumerated() {
      // 提示文本来自服务器，原样显示；不参与本地化。
      let label = NSTextField(wrappingLabelWithString: item.text)
      label.preferredMaxLayoutWidth = fieldWidth
      let field = item.echo ? NSTextField() : NSSecureTextField()
      field.identifier = NSUserInterfaceItemIdentifier("ssh-auth-ki-field-\(index)")
      field.setAccessibilityLabel(item.text)
      rows += [label, field]
      fields.append(field)
    }
    alert.accessoryView = stack(rows)
    alert.window.initialFirstResponder = fields.first

    guard await present(alert) == .alertFirstButtonReturn else { return nil }
    return fields.map(\.stringValue)
  }

  // MARK: 展示

  /// 表单挂靠的窗口：当前 key window，其次主窗口；都不可见时返回 nil。
  static func hostWindow() -> NSWindow? {
    [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first { $0.isVisible }
  }

  /// 展示表单并等待结果。有窗口时用 sheet（不阻塞其它窗口），否则退化为 `runModal`。
  static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    guard let window = hostWindow() else {
      NSApp.activate(ignoringOtherApps: true)
      return alert.runModal()
    }
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
  }

  /// 把若干控件竖排成 NSAlert 的 accessory view。
  ///
  /// NSAlert 按 accessory view 的 frame 排版、不看约束，所以要先用约束算出 fittingSize 再写回 frame。
  static func stack(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    // 只给输入框定宽；说明文字按 preferredMaxLayoutWidth 自己换行。
    for case let field as NSTextField in views where field.isEditable {
      field.translatesAutoresizingMaskIntoConstraints = false
      field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
    }
    stack.widthAnchor.constraint(greaterThanOrEqualToConstant: fieldWidth).isActive = true
    stack.layoutSubtreeIfNeeded()
    stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
    return stack
  }
}
