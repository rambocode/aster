import AppKit

/// 发送前的人工确认面板。终端 stdout/stderr 并不天然分流，因此“Current Error”只表示
/// 当前 Pane 最近命令以非零状态结束；正文仍来自用户选择的可见终端文本。
@MainActor
final class AgentChatSendSheetController: NSObject {
  private weak var model: AppModel?
  private let presentation: AgentChatPresentation
  private let panel: NSPanel
  private let targetPopup = NSPopUpButton()
  private let selectionCheck = NSButton(checkboxWithTitle: "终端选区", target: nil, action: nil)
  private let transcriptCheck = NSButton(checkboxWithTitle: "当前终端 transcript", target: nil, action: nil)
  private let preview = NSTextView()
  private let comment = NSTextView()
  private let errorLabel = NSTextField(labelWithString: "")

  init(model: AppModel, presentation: AgentChatPresentation) {
    self.model = model
    self.presentation = presentation
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    super.init()
    panel.title = "Agent transcript"
    panel.isReleasedWhenClosed = false
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    buildInterface()
  }

  func present(on parent: NSWindow, completion: @escaping () -> Void) {
    parent.beginSheet(panel) { [weak self] _ in
      self?.panel.orderOut(nil)
      completion()
    }
  }

  private func buildInterface() {
    let root = NSView()
    panel.contentView = root

    let title = NSTextField(labelWithString: "Agent transcript")
    title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
    let status = NSTextField(labelWithString: statusText)
    status.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    status.textColor = AsterTheme.secondaryInk

    preview.isEditable = false
    preview.isSelectable = true
    preview.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    preview.textColor = AsterTheme.secondaryInk
    preview.backgroundColor = AsterTheme.panel.withAlphaComponent(0.72)
    preview.textContainerInset = NSSize(width: 12, height: 12)
    let previewScroll = scrollView(for: preview)
    previewScroll.heightAnchor.constraint(equalToConstant: 205).isActive = true

    selectionCheck.target = self
    selectionCheck.action = #selector(sourceChanged(_:))
    selectionCheck.state = presentation.selection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? .on : .off
    selectionCheck.isEnabled = selectionCheck.state == .on
    transcriptCheck.target = self
    transcriptCheck.action = #selector(sourceChanged(_:))
    transcriptCheck.state = presentation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? .on : .off
    transcriptCheck.isEnabled = transcriptCheck.state == .on
    let sources = NSStackView(views: [selectionCheck, transcriptCheck])
    sources.orientation = .horizontal
    sources.spacing = 16

    let sendLabel = NSTextField(labelWithString: "Send to:")
    sendLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
    targetPopup.addItems(withTitles: presentation.destinations.map(\.title))
    targetPopup.controlSize = .large
    targetPopup.font = NSFont.systemFont(ofSize: 15, weight: .medium)
    let destination = NSStackView(views: [sendLabel, targetPopup])
    destination.orientation = .horizontal
    destination.alignment = .centerY
    destination.spacing = 12

    let commentLabel = NSTextField(labelWithString: "Comment:")
    commentLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
    comment.font = NSFont.systemFont(ofSize: 14)
    comment.isAutomaticQuoteSubstitutionEnabled = false
    comment.isAutomaticDashSubstitutionEnabled = false
    comment.textContainerInset = NSSize(width: 8, height: 8)
    let commentScroll = scrollView(for: comment)
    commentScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

    errorLabel.textColor = AsterTheme.warning
    errorLabel.font = NSFont.systemFont(ofSize: 11)
    let copy = ActionButton(title: "Copy Message", bezelStyle: .rounded) { [weak self] in
      self?.copyMessage()
    }
    let cancel = ActionButton(title: "Cancel", bezelStyle: .rounded) { [weak self] in self?.dismiss() }
    let send = ActionButton(title: "Send", bezelStyle: .rounded) { [weak self] in self?.send() }
    send.keyEquivalent = "\r"
    let actions = NSStackView(views: [copy, NSView(), cancel, send])
    actions.orientation = .horizontal
    actions.spacing = 12

    let content = NSStackView(views: [title, status, previewScroll, sources, destination, commentLabel, commentScroll, errorLabel, actions])
    content.orientation = .vertical
    content.alignment = .width
    content.spacing = 10
    root.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
      content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
      content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
      content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
      targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
    ])
    updatePreview()
  }

  private var statusText: String {
    if presentation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "● Empty"
    }
    return presentation.transcriptHasError ? "● Current Error" : "● Current Output"
  }

  @objc private func sourceChanged(_ sender: Any?) { updatePreview() }

  private func updatePreview() {
    var chunks: [String] = []
    if selectionCheck.state == .on, let selection = presentation.selection { chunks.append(selection) }
    if transcriptCheck.state == .on { chunks.append(presentation.transcript) }
    preview.string = chunks.joined(separator: "\n\n")
  }

  private func send() {
    guard presentation.destinations.indices.contains(targetPopup.indexOfSelectedItem) else { return }
    let destination = presentation.destinations[targetPopup.indexOfSelectedItem]
    let selection = selectionCheck.state == .on ? presentation.selection : nil
    let transcript = transcriptCheck.state == .on ? presentation.transcript : nil
    guard let model else { return }
    guard model.prefillAgentChat(
      destination: destination,
      comment: comment.string,
      selection: selection,
      transcript: transcript
    ) else {
      errorLabel.stringValue = model.notice ?? "无法预填聊天内容。"
      return
    }
    dismiss()
  }

  /// Copy 是用户显式的本地剪贴板操作，不会改变目标 Agent 输入框。复制内容与当前
  /// 勾选状态一致，便于在发送前交由其它工具人工审阅。
  private func copyMessage() {
    let text = [comment.string.trimmingCharacters(in: .whitespacesAndNewlines), preview.string]
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    guard !text.isEmpty else {
      errorLabel.stringValue = "没有可复制的内容。"
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    errorLabel.stringValue = "已复制当前消息。"
  }

  private func dismiss() {
    guard let parent = panel.sheetParent else {
      panel.orderOut(nil)
      return
    }
    parent.endSheet(panel)
  }

  private func scrollView(for textView: NSTextView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = textView
    return scroll
  }
}
