import AppKit

/// 用户主动反馈的原生确认页。它只说明将被打包的脱敏内容，真正生成 ZIP 和显示系统
/// 分享面板均由用户点击触发；不会在打开面板时联网或读取终端正文。
@MainActor
final class FeedbackSheetController: NSObject {
  private let diagnostics: DiagnosticsCenter
  private let panel: NSPanel
  private let note = NSTextView()
  private let status = NSTextField(labelWithString: "")
  private let summaryLabel = NSTextField(labelWithString: "")
  private let saveButton: ActionButton
  private let shareButton: ActionButton
  private var sharingPicker: NSSharingServicePicker?
  private var isWorking = false { didSet { updateActionState() } }

  init(diagnostics: DiagnosticsCenter = .shared) {
    self.diagnostics = diagnostics
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 430),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    saveButton = ActionButton(title: "保存诊断包…", bezelStyle: .rounded) {}
    shareButton = ActionButton(title: "分享…", bezelStyle: .rounded) {}
    super.init()
    panel.title = "反馈问题"
    panel.isReleasedWhenClosed = false
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    buildInterface()
  }

  func present(on parent: NSWindow, completion: @escaping () -> Void) {
    refreshSummary()
    parent.beginSheet(panel) { [weak self] _ in
      self?.panel.orderOut(nil)
      completion()
    }
  }

  private func buildInterface() {
    let root = NSView()
    panel.contentView = root

    let title = NSTextField(labelWithString: "发送诊断反馈")
    title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
    let detail = NSTextField(wrappingLabelWithString:
      "Aster 只会在你保存或分享时生成诊断包。包内不包含终端输入输出、命令、路径、环境变量、配置或系统崩溃报告。")
    detail.font = NSFont.systemFont(ofSize: 13)
    detail.textColor = AsterTheme.secondaryInk
    detail.maximumNumberOfLines = 0

    summaryLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    summaryLabel.textColor = AsterTheme.secondaryInk
    let logs = NSStackView(views: [
      NSTextField(labelWithString: "将包含"), summaryLabel,
    ])
    logs.orientation = .horizontal
    logs.alignment = .centerY
    logs.spacing = 10

    let noteLabel = NSTextField(labelWithString: "问题描述（可选）")
    noteLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
    note.font = NSFont.systemFont(ofSize: 13)
    note.isAutomaticQuoteSubstitutionEnabled = false
    note.isAutomaticDashSubstitutionEnabled = false
    note.textContainerInset = NSSize(width: 8, height: 8)
    let noteScroll = NSScrollView()
    noteScroll.hasVerticalScroller = true
    noteScroll.borderType = .bezelBorder
    noteScroll.documentView = note
    noteScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

    status.font = NSFont.systemFont(ofSize: 11)
    status.textColor = AsterTheme.warning
    let folder = ActionButton(title: "打开日志文件夹", bezelStyle: .rounded) { [weak self] in
      self?.openLogsDirectory()
    }
    saveButton.target = self
    saveButton.action = #selector(saveArchive(_:))
    shareButton.target = self
    shareButton.action = #selector(shareArchive(_:))
    let cancel = ActionButton(title: "取消", bezelStyle: .rounded) { [weak self] in self?.dismiss() }
    let actions = NSStackView(views: [folder, NSView(), cancel, saveButton, shareButton])
    actions.orientation = .horizontal
    actions.spacing = 10

    let content = NSStackView(views: [title, detail, logs, noteLabel, noteScroll, status, actions])
    content.orientation = .vertical
    content.alignment = .width
    content.spacing = 10
    root.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
      content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
      content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
      content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
    ])
  }

  private func refreshSummary() {
    let summary = diagnostics.summary()
    let size = ByteCountFormatter.string(fromByteCount: Int64(summary.totalBytes), countStyle: .file)
    summaryLabel.stringValue = "\(summary.fileCount) 个日志文件 · \(size)（最多保留 7 天或 20 MB）"
    status.stringValue = ""
  }

  private func updateActionState() {
    saveButton.isEnabled = !isWorking
    shareButton.isEnabled = !isWorking
  }

  private func openLogsDirectory() {
    do {
      let directory = try diagnostics.logsDirectory()
      guard NSWorkspace.shared.open(directory) else { throw CocoaError(.fileNoSuchFile) }
    } catch {
      status.stringValue = "无法打开日志文件夹：\(error.localizedDescription)"
    }
  }

  @objc private func saveArchive(_ sender: Any?) {
    prepareArchive { [weak self] archive in
      guard let self, let archive else { return }
      let panel = NSSavePanel()
      panel.nameFieldStringValue = archive.lastPathComponent
      panel.canCreateDirectories = true
      panel.allowedContentTypes = [.zip]
      panel.beginSheetModal(for: self.panel) { response in
        guard response == .OK, let destination = panel.url else { return }
        do {
          try FileManager.default.copyItem(at: archive, to: destination)
          self.status.stringValue = "已保存诊断包。"
        } catch {
          self.status.stringValue = "保存诊断包失败：\(error.localizedDescription)"
        }
      }
    }
  }

  @objc private func shareArchive(_ sender: Any?) {
    prepareArchive { [weak self] archive in
      guard let self, let archive else { return }
      let picker = NSSharingServicePicker(items: [archive])
      self.sharingPicker = picker
      picker.show(relativeTo: self.shareButton.bounds, of: self.shareButton, preferredEdge: .minY)
      self.status.stringValue = "请选择系统分享方式。"
    }
  }

  private func prepareArchive(completion: @escaping (URL?) -> Void) {
    guard !isWorking else { return }
    isWorking = true
    status.stringValue = "正在生成脱敏诊断包…"
    let userNote = note.string
    let diagnostics = diagnostics
    Task { @MainActor [weak self] in
      // 后台任务只持有 Sendable 的诊断中心和不可变文本；完成后再回到本控制器更新 AppKit。
      let result = await Task.detached(priority: .userInitiated) {
        Result { try diagnostics.makeFeedbackArchive(note: userNote) }
      }.value
      guard let self else { return }
      self.isWorking = false
      switch result {
      case .success(let archive):
        self.status.stringValue = "诊断包已生成。"
        completion(archive)
      case .failure(let error):
        self.status.stringValue = "生成诊断包失败：\(error.localizedDescription)"
        completion(nil)
      }
    }
  }

  private func dismiss() {
    guard let parent = panel.sheetParent else {
      panel.orderOut(nil)
      return
    }
    parent.endSheet(panel)
  }
}
