import AppKit
import AsterCore
@preconcurrency import GhosttyKit

extension GhosttySurfaceView: NSMenuItemValidation {
  /// 以键盘文本事件写入前台程序；换行被转换为真实 Return，适用于命令与自动化输入。
  @discardableResult
  func typeText(_ text: String) -> Bool {
    guard let surface, isProcessRunning, !readOnly, !text.isEmpty else { return false }
    onUserInput?()
    var start = text.startIndex
    var index = start
    while index < text.endIndex {
      let character = text[index]
      if character == "\r" || character == "\n" {
        if start < index { sendKeyText(String(text[start..<index]), to: surface) }
        if character == "\r" {
          let next = text.index(after: index)
          if next < text.endIndex, text[next] == "\n" { index = next }
        }
        sendReturn(to: surface)
        index = text.index(after: index)
        start = index
      } else {
        index = text.index(after: index)
      }
    }
    if start < text.endIndex { sendKeyText(String(text[start...]), to: surface) }
    return true
  }

  /// IPC send-keys 使用的有界字节入口。libghostty 的 key text 必须是 NUL 结尾；
  /// 内嵌 NUL 不能表达为终端键入，明确拒绝而不是截断并报告假成功。
  @discardableResult
  func sendBytes(_ bytes: [UInt8]) -> Bool {
    guard let surface, isProcessRunning, !readOnly, !bytes.isEmpty, !bytes.contains(0) else {
      return false
    }
    onUserInput?()
    var storage = bytes + [0]
    return storage.withUnsafeMutableBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
        return false
      }
      var key = ghostty_input_key_s()
      key.action = GHOSTTY_ACTION_PRESS
      key.text = UnsafePointer(base)
      return ghostty_surface_key(surface, key)
    }
  }

  func sendInterrupt() {
    guard let surface, isProcessRunning, !readOnly else { return }
    onUserInput?()
    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    key.keycode = 8  // macOS virtual keycode for C
    key.mods = GHOSTTY_MODS_CTRL
    _ = ghostty_surface_key(surface, key)
    key.action = GHOSTTY_ACTION_RELEASE
    _ = ghostty_surface_key(surface, key)
  }

  /// 用户粘贴走 libghostty 的 `surface_text`，由内核按目标的 bracketed-paste 模式
  /// 自动包裹。Aster 仍在发送前做保守风险确认，控制字符永远不会静默放行。
  @discardableResult
  func pasteText(_ text: String) -> Bool {
    guard let surface, isProcessRunning, !readOnly, !text.isEmpty else { return false }
    let analysis = PasteRiskAnalyzer.analyze(text)
    if PasteProtectionPolicy.requiresConfirmation(
      for: analysis,
      protectionEnabled: pasteProtectionEnabled,
      isAlternateScreen: false,
      isBracketedPasteMode: false,
      treatsBracketedPasteAsSafe: pasteBracketedSafe
    ), !Self.presentPasteConfirmation(analysis) {
      return false
    }
    onUserInput?()
    text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    return true
  }

  func readSelection() -> String? {
    guard let surface, ghostty_surface_has_selection(surface) else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let pointer = text.text, text.text_len > 0 else { return nil }
    return String(
      decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
  }

  /// 读取可见区或完整 scrollback 的纯文本。调用方可限制内容行数，空屏返回空字符串，
  /// nil 只表示 surface 尚未创建或 C API 读取失败。
  func readText(includeScrollback: Bool, maximumLines: Int? = nil) -> String? {
    guard let surface else { return nil }
    let tag = includeScrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
    var selection = ghostty_selection_s()
    selection.top_left = ghostty_point_s(
      tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
    selection.bottom_right = ghostty_point_s(
      tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
    selection.rectangle = false
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let pointer = text.text, text.text_len > 0 else { return "" }
    let value = String(
      decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    guard let maximumLines, maximumLines > 0 else { return value }
    var lines = value.components(separatedBy: "\n")
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
      lines.removeLast()
    }
    return lines.suffix(maximumLines).joined(separator: "\n")
  }

  @discardableResult
  func performBindingAction(_ action: String) -> Bool {
    guard let surface else { return false }
    return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
  }

  func setReadOnly(_ enabled: Bool) {
    guard enabled != readOnly else { return }
    guard performBindingAction("toggle_readonly") else { return }
    // callback 会再次同步最终状态；先更新可阻止同一 runloop 中后续写入穿过门禁。
    handleReadOnly(enabled)
  }

  @discardableResult
  func find(_ term: String, previous: Bool) -> Bool {
    guard !term.isEmpty else { return false }
    if searchNeedle != term {
      _ = performBindingAction("start_search")
      guard performBindingAction("search:\(term)") else { return false }
      searchNeedle = term
    }
    return performBindingAction(
      previous
        ? "navigate_search:previous" : "navigate_search:next")
  }

  func clearSearch() {
    _ = performBindingAction("end_search")
    handleSearchEnd()
  }

  // MARK: - Standard responder-chain actions

  @objc func copy(_ sender: Any?) { _ = performBindingAction("copy_to_clipboard") }

  @objc func paste(_ sender: Any?) {
    guard let text = readSystemClipboard() else { return }
    _ = pasteText(text)
  }

  override func selectAll(_ sender: Any?) { _ = performBindingAction("select_all") }

  @objc func pasteBracketed(_ sender: Any?) {
    guard let text = readSystemClipboard() else { return }
    _ = pasteText(text)
  }

  @objc func pasteAndContinueInComposer(_ sender: Any?) {
    guard let text = readSystemClipboard() else { return }
    onPasteIntoComposer?(text)
  }

  @objc func sendSelectionToChat(_ sender: Any?) {
    guard surface.map(ghostty_surface_has_selection) == true else { return }
    onSendSelectionToChat?()
  }

  /// Ghostty 返回未消费的右键事件时展示 Aster 的原生菜单。迁移期仅公开当前引擎能
  /// 可靠完成的动作，避免保留看似可点但依赖 SwiftTerm 私有状态的入口。
  override func menu(for event: NSEvent) -> NSMenu? {
    let hasSelection = surface.map(ghostty_surface_has_selection) == true
    let menu = NSMenu(title: "终端")
    let copyItem = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
    copyItem.target = self
    copyItem.isEnabled = hasSelection
    menu.addItem(copyItem)

    let sendItem = NSMenuItem(
      title: "发送选区到 Chat",
      action: #selector(sendSelectionToChat(_:)),
      keyEquivalent: ""
    )
    sendItem.target = self
    sendItem.isEnabled = hasSelection && onSendSelectionToChat != nil
    menu.addItem(sendItem)
    menu.addItem(.separator())

    let pasteItem = NSMenuItem(title: "粘贴", action: #selector(paste(_:)), keyEquivalent: "")
    pasteItem.target = self
    pasteItem.isEnabled = surface != nil && !readOnly
    menu.addItem(pasteItem)

    let composerItem = NSMenuItem(
      title: "粘贴并在 Composer 中继续",
      action: #selector(pasteAndContinueInComposer(_:)),
      keyEquivalent: ""
    )
    composerItem.target = self
    composerItem.isEnabled = surface != nil && onPasteIntoComposer != nil
    menu.addItem(composerItem)
    return menu
  }

  @objc func scrollTerminalPageUp(_ sender: Any?) { _ = performBindingAction("scroll_page_up") }
  @objc func scrollTerminalPageDown(_ sender: Any?) { _ = performBindingAction("scroll_page_down") }
  @objc func scrollTerminalToTop(_ sender: Any?) { _ = performBindingAction("scroll_to_top") }
  @objc func scrollTerminalToBottom(_ sender: Any?) { _ = performBindingAction("scroll_to_bottom") }
  @objc func scrollToPreviousCommand(_ sender: Any?) {
    _ = performBindingAction("jump_to_prompt:-1")
  }
  @objc func scrollToNextCommand(_ sender: Any?) { _ = performBindingAction("jump_to_prompt:1") }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(copy(_:)):
      guard let surface else { return false }
      return ghostty_surface_has_selection(surface)
    case #selector(paste(_:)), #selector(pasteBracketed(_:)):
      return surface != nil && readSystemClipboard() != nil && !readOnly
    case #selector(pasteAndContinueInComposer(_:)):
      return surface != nil && readSystemClipboard() != nil && onPasteIntoComposer != nil
    case #selector(sendSelectionToChat(_:)):
      guard let surface else { return false }
      return ghostty_surface_has_selection(surface) && onSendSelectionToChat != nil
    case #selector(scrollTerminalPageUp(_:)), #selector(scrollTerminalPageDown(_:)),
      #selector(scrollTerminalToTop(_:)), #selector(scrollTerminalToBottom(_:)),
      #selector(scrollToPreviousCommand(_:)), #selector(scrollToNextCommand(_:)):
      return surface != nil
    default:
      return true
    }
  }

  private func sendKeyText(_ text: String, to surface: ghostty_surface_t) {
    text.withCString {
      var key = ghostty_input_key_s()
      key.action = GHOSTTY_ACTION_PRESS
      key.text = $0
      _ = ghostty_surface_key(surface, key)
    }
  }

  private func sendReturn(to surface: ghostty_surface_t) {
    var key = ghostty_input_key_s()
    key.keycode = 36
    key.action = GHOSTTY_ACTION_PRESS
    _ = ghostty_surface_key(surface, key)
    key.action = GHOSTTY_ACTION_RELEASE
    _ = ghostty_surface_key(surface, key)
  }

  private static func presentPasteConfirmation(_ analysis: PasteAnalysis) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "粘贴的内容可能立即执行命令"
    let reasons = analysis.risks.map { risk -> String in
      switch risk {
      case .multipleLines: "包含多行"
      case .trailingNewline: "末尾包含换行"
      case .privilegeEscalation: "包含 sudo 或 su"
      case .controlCharacters: "包含不可见控制字符"
      }
    }.sorted().joined(separator: "、")
    alert.informativeText = "检测到：\(reasons)\n\n\(analysis.preview())"
    alert.addButton(withTitle: "仍然粘贴")
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
