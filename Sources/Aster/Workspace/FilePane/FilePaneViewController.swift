import AppKit
import AsterCore
import Combine
import Highlighter
import Markdown
import PDFKit
import Quartz
import WebKit

/// 统一承载可编辑源文件和只读富预览的 Pane。持久化层仍只区分 `.editor` / `.preview`；
/// Source/Preview、锁定、语言和缩放均为当前 Pane 的运行态，不污染工作区快照。
@MainActor
final class FilePaneViewController: NSViewController, WKNavigationDelegate {
  private static let classificationPrefixBytes = 64 * 1_024
  private static let boundedPreviewBytes = 4 * 1_024 * 1_024

  private let runtime: WorkspacePaneRuntime
  private weak var tab: TerminalTabItem?
  private let model: AppModel
  private let preferences: AppPreferences
  private let contentHost = NSView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let modeControl = NSSegmentedControl(
    labels: ["Source", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
  private var presentationKind: FilePresentationKind = .sourceText
  private var showingPreview = false
  private var softWrap: Bool
  private var selectedLanguage: String?
  private var cancellables: Set<AnyCancellable> = []
  private var documentDelegate: DocumentTextDelegate?
  // Timer 只在主线程创建和失效；标记 unsafe 是为了允许 nonisolated deinit 回收它。
  private nonisolated(unsafe) var modificationTimer: Timer?
  private var lastModificationDate: Date?
  private var reportedExternalConflict = false
  private weak var overflowButton: NSButton?
  private weak var lockButton: IconHoverButton?
  private weak var shareButton: NSButton?
  private weak var statusSpinner: NSProgressIndicator?
  private var sharingPicker: NSSharingServicePicker?
  private(set) weak var sourceTextView: NSTextView?
  /// Workspace 控制器用它维护行跳转目标；锁定或切换 Source/Preview 会替换 NSTextView，
  /// 因此不能只在首次建 Pane 时登记一次。
  var onSourceTextViewChanged: ((NSTextView?) -> Void)?

  init(
    runtime: WorkspacePaneRuntime,
    tab: TerminalTabItem,
    model: AppModel,
    preferences: AppPreferences
  ) {
    self.runtime = runtime
    self.tab = tab
    self.model = model
    self.preferences = preferences
    self.softWrap = preferences.configuration.editor.lineWrap
    super.init(nibName: nil, bundle: nil)
    classifyDocument()
    showingPreview = runtime.descriptor.kind == .preview && presentationKind != .sourceText
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    let column = NSStackView(views: [makeToolbar(), contentHost])
    column.orientation = .vertical
    column.spacing = 0
    root.addSubview(column)
    column.pinEdges(to: root)
    view = root
    renderContent()
    observeRuntime()
    startModificationMonitoring()
  }

  deinit { modificationTimer?.invalidate() }

  private var fileURL: URL? {
    runtime.descriptor.resourcePath.map { URL(fileURLWithPath: $0) }
  }

  private func classifyDocument() {
    guard let fileURL else { return }
    let prefix = readPrefix(of: fileURL, maximumBytes: Self.classificationPrefixBytes)
    let trustedProvider = model.agentHistories.first(where: {
      $0.metadata.transcriptFileURL.standardizedFileURL == fileURL.standardizedFileURL
    })?.metadata.configuration.provider
    presentationKind = FileDocumentClassifier.classify(
      fileName: fileURL.lastPathComponent,
      prefix: prefix,
      trustedAgentProvider: trustedProvider
    )
  }

  private func makeToolbar() -> NSView {
    let bar = NSView()
    bar.wantsLayer = true
    bar.layer?.backgroundColor = AsterTheme.panel.cgColor
    bar.addBottomBorder(color: AsterTheme.hairline)
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.heightAnchor.constraint(equalToConstant: 42).isActive = true

    modeControl.segmentStyle = .texturedRounded
    modeControl.identifier = NSUserInterfaceItemIdentifier("file-pane-presentation")
    modeControl.target = self
    modeControl.action = #selector(changePresentationMode)
    modeControl.selectedSegment = showingPreview ? 1 : 0
    modeControl.isHidden = !presentationKind.supportsSourcePreviewToggle
    modeControl.setAccessibilityLabel("File presentation")
    let lock = IconHoverButton(
      symbol: runtime.isReadOnly ? "lock.fill" : "lock.open",
      accessibilityDescription: "Toggle read-only"
    ) { [weak self] in self?.toggleReadOnly() }
    lock.identifier = NSUserInterfaceItemIdentifier("file-pane-read-only")
    lockButton = lock
    let chat = IconHoverButton(symbol: "text.bubble", accessibilityDescription: "Send to Chat") {
      [weak self] in
      guard let self, let fileURL else { return }
      model.sendFileToChat(fileURL)
    }
    let share = IconHoverButton(symbol: "square.and.arrow.up", accessibilityDescription: "Share") {
      [weak self] in self?.showSharingPicker()
    }
    share.identifier = NSUserInterfaceItemIdentifier("file-pane-share")
    shareButton = share
    let left = NSStackView(views: [modeControl, lock, chat, share])
    left.orientation = .horizontal
    left.alignment = .centerY
    left.spacing = 7

    titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    titleLabel.textColor = AsterTheme.ink
    titleLabel.lineBreakMode = .byTruncatingMiddle
    let overflow = IconHoverButton(symbol: "ellipsis", accessibilityDescription: "File options") {
      [weak self] in self?.showOverflowMenu()
    }
    overflowButton = overflow
    let center = NSStackView(views: [titleLabel, overflow])
    center.orientation = .horizontal
    center.alignment = .centerY
    center.spacing = 5

    statusLabel.font = NSFont.systemFont(ofSize: 10.5)
    statusLabel.identifier = NSUserInterfaceItemIdentifier("file-pane-status")
    statusLabel.textColor = AsterTheme.secondaryInk
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    statusSpinner = spinner
    let save = IconHoverButton(symbol: "square.and.arrow.down", accessibilityDescription: "Save") {
      [weak self] in self?.save()
    }
    let close = ActionButton(title: "Close", bezelStyle: .inline) { [weak self] in
      self?.model.closeSelectedPaneOrTab()
    }
    let right = NSStackView(views: [spinner, statusLabel, save, close])
    right.orientation = .horizontal
    right.alignment = .centerY
    right.spacing = 7

    let row = NSStackView(views: [left, NSView(), center, NSView(), right])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    bar.addSubview(row)
    row.pinEdges(to: bar)
    updateToolbar()
    return bar
  }

  private func observeRuntime() {
    runtime.$documentText.dropFirst().sink { [weak self] _ in
      guard let self else { return }
      if sourceTextView?.string != runtime.documentText { renderContent() }
      updateToolbar()
    }.store(in: &cancellables)
    runtime.$isDirty.sink { [weak self] isDirty in
      guard let self else { return }
      if !isDirty {
        lastModificationDate = modificationDate()
        reportedExternalConflict = false
      }
      updateToolbar()
    }.store(in: &cancellables)
    runtime.$isReadOnly.sink { [weak self] _ in
      self?.updateToolbar()
      self?.renderContent()
    }.store(in: &cancellables)
    runtime.$documentError.sink { [weak self] _ in self?.updateToolbar() }.store(in: &cancellables)
    model.agentHistoriesChanged.sink { [weak self] _ in
      guard let self else { return }
      let previous = presentationKind
      classifyDocument()
      guard presentationKind != previous else { return }
      modeControl.isHidden = !presentationKind.supportsSourcePreviewToggle
      showingPreview = runtime.descriptor.kind == .preview && presentationKind != .sourceText
      modeControl.selectedSegment = showingPreview ? 1 : 0
      renderContent()
    }.store(in: &cancellables)
  }

  private func updateToolbar() {
    titleLabel.stringValue = fileURL?.lastPathComponent ?? "Untitled"
    if runtime.documentError != nil {
      statusLabel.stringValue = "Error"
      statusLabel.textColor = AsterTheme.warning
    } else if reportedExternalConflict {
      statusLabel.stringValue = "Modified on Disk"
      statusLabel.textColor = AsterTheme.warning
    } else if runtime.isDirty {
      statusLabel.stringValue = "Edited"
      statusLabel.textColor = AsterTheme.secondaryInk
    } else {
      statusLabel.stringValue = "✓ Saved"
      statusLabel.textColor = AsterTheme.secondaryInk
    }
    lockButton?.setSymbol(
      runtime.isReadOnly ? "lock.fill" : "lock.open",
      accessibilityDescription: runtime.isReadOnly ? "Unlock editing" : "Lock editing"
    )
  }

  @objc private func changePresentationMode() {
    showingPreview = modeControl.selectedSegment == 1
    renderContent()
  }

  private func toggleReadOnly() {
    guard presentationKind.supportsEditing else {
      model.notice = "This file type is preview-only."
      return
    }
    runtime.toggleReadOnly()
  }

  private func save() {
    guard !runtime.isReadOnly else {
      model.notice = "Unlock the file before saving."
      return
    }
    if reportedExternalConflict {
      let alert = NSAlert()
      alert.messageText = "The file changed on disk."
      alert.informativeText =
        "Saving now will replace the external version. Reload instead to keep the disk version."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Save Anyway")
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Reload")
      switch alert.runModal() {
      case .alertFirstButtonReturn: break
      case .alertThirdButtonReturn:
        performReloadFromDisk()
        return
      default: return
      }
    }
    statusSpinner?.startAnimation(nil)
    runtime.saveDocument()
    statusSpinner?.stopAnimation(nil)
    lastModificationDate = modificationDate()
    reportedExternalConflict = false
    updateToolbar()
  }

  private func renderContent() {
    guard isViewLoaded else { return }
    contentHost.removeAllSubviews()
    sourceTextView = nil
    documentDelegate = nil
    let content: NSView
    if showingPreview {
      content = makePreviewContent()
    } else {
      content = makeSourceContent()
    }
    contentHost.addSubview(content)
    content.pinEdges(to: contentHost)
    onSourceTextViewChanged?(sourceTextView)
  }

  private func makeSourceContent() -> NSView {
    let textView = NSTextView()
    sourceTextView = textView
    textView.isEditable = presentationKind.supportsEditing && !runtime.isReadOnly
    textView.isSelectable = true
    textView.backgroundColor = AsterTheme.paper
    textView.textColor = AsterTheme.ink
    textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.textContainerInset = NSSize(width: 16, height: 14)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.textContainer?.widthTracksTextView = softWrap
    textView.isHorizontallyResizable = !softWrap
    textView.textContainer?.containerSize = NSSize(
      width: softWrap ? 0 : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )

    let text = sourceText()
    if runtime.isReadOnly, let highlighted = highlightedSource(text) {
      textView.textStorage?.setAttributedString(highlighted)
    } else {
      textView.string = text
    }
    if textView.isEditable {
      let delegate = DocumentTextDelegate(runtime: runtime)
      documentDelegate = delegate
      textView.delegate = delegate
    }
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = !softWrap
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    return scroll
  }

  private func sourceText() -> String {
    if !runtime.documentText.isEmpty || runtime.documentError == nil { return runtime.documentText }
    guard let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) else {
      return runtime.documentError ?? "Unable to read this file."
    }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: Self.boundedPreviewBytes)
    if let text = String(data: data, encoding: .utf8) {
      let suffix =
        data.count == Self.boundedPreviewBytes ? "\n\n— Preview truncated at 4 MiB —" : ""
      return text + suffix
    }
    return makeHexPreview(data)
  }

  private func highlightedSource(_ text: String) -> NSAttributedString? {
    guard
      [.sourceText, .diff, .markdown, .restructuredText, .html, .svg].contains(presentationKind),
      let highlighter = Highlighter()
    else { return nil }
    // HighlighterSwift 的 `default-light` CSS 把 `hljs-params` 声明为空规则，主题解析器
    // 因而不会登记该 token，并在 Debug 构建中对正常的函数参数持续打印缺失样式警告。
    // `xcode` 主题为该 token 提供明确颜色，既保留浅色源码展示，也避免误报警告。
    _ = highlighter.setTheme("xcode")
    let language = selectedLanguage ?? languageName(for: fileURL?.pathExtension.lowercased() ?? "")
    return highlighter.highlight(text, as: language)
  }

  private func makePreviewContent() -> NSView {
    guard let fileURL else { return messageView("No file selected.", symbol: "doc") }
    switch presentationKind {
    case .markdown:
      let html = HTMLFormatter.format(sourceText())
      return makeWebPreview(body: html, baseURL: fileURL.deletingLastPathComponent())
    case .restructuredText:
      return makeWebPreview(
        body: restructuredTextHTML(sourceText()),
        baseURL: fileURL.deletingLastPathComponent())
    case .html:
      return makeWebPreview(
        body: sourceText(), baseURL: fileURL.deletingLastPathComponent())
    case .svg:
      return makeWebPreview(
        body: sourceText(), baseURL: fileURL.deletingLastPathComponent())
    case .image:
      guard let image = NSImage(contentsOf: fileURL) else {
        return messageView("Unable to decode this image.", symbol: "photo")
      }
      let imageView = NSImageView(image: image)
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.animates = true
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = true
      scroll.allowsMagnification = true
      scroll.minMagnification = 0.1
      scroll.maxMagnification = 8
      scroll.documentView = imageView
      imageView.frame = NSRect(origin: .zero, size: image.size)
      return scroll
    case .pdf:
      let pdf = PDFView()
      pdf.document = PDFDocument(url: fileURL)
      pdf.autoScales = true
      pdf.displayMode = .singlePageContinuous
      return pdf
    case .richDocument:
      guard preferences.configuration.editor.previewRichDocuments,
        let preview = QLPreviewView(frame: .zero, style: .normal)
      else {
        return messageView("Rich document preview is disabled in Settings.", symbol: "doc.richtext")
      }
      preview.previewItem = fileURL as QLPreviewItem
      return preview
    case .diff:
      return makeReadOnlyTextView(attributed: highlightedSource(sourceText()))
    case .agentTranscript:
      return makeAgentTranscript(fileURL)
    case .sourceText:
      return makeSourceContent()
    case .binary:
      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let data = readPrefix(of: fileURL, maximumBytes: Self.boundedPreviewBytes)
      return HexPreviewView(data: data, isTruncated: size > data.count)
    }
  }

  private func makeWebPreview(body: String, baseURL: URL) -> NSView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    let document = """
      <!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'">
      <style>
      :root{color-scheme:light dark} body{font:15px -apple-system;margin:48px auto;max-width:920px;padding:0 32px;line-height:1.58;color:#2d3033;background:transparent}
      h1,h2,h3{line-height:1.25;margin-top:1.5em} pre,code{font:13px ui-monospace,monospace} pre{padding:14px;overflow:auto;background:rgba(127,127,127,.11);border-radius:7px}
      blockquote{border-left:3px solid #999;padding-left:14px;color:#666} table{border-collapse:collapse} th,td{border:1px solid #aaa;padding:6px 9px} img,svg{max-width:100%;height:auto}
      @media(prefers-color-scheme:dark){body{color:#ddd} blockquote{color:#aaa}}
      </style></head><body>\(body)</body></html>
      """
    webView.loadHTMLString(document, baseURL: baseURL)
    return webView
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme?.lowercased()
    let isInitialFileDocument =
      scheme == "file"
      && navigationAction.navigationType == .other
      && navigationAction.targetFrame?.isMainFrame == true
    // `loadHTMLString(_:baseURL:)` 会把本地 baseURL 作为初始主文档 URL；必须允许这一次
    // `.other` 导航，Markdown/HTML/SVG 才能装载。用户点击的 file 或远程链接仍被拒绝，
    // 本地图片等子资源则不经过 main-frame navigation 决策。
    decisionHandler(
      scheme == nil || scheme == "about" || isInitialFileDocument ? .allow : .cancel)
  }

  private func makeReadOnlyTextView(
    text: String = "",
    attributed: NSAttributedString? = nil
  ) -> NSView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.textColor = AsterTheme.ink
    textView.textContainerInset = NSSize(width: 18, height: 16)
    if let attributed {
      textView.textStorage?.setAttributedString(attributed)
    } else {
      textView.string = text
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = !softWrap
    scroll.documentView = textView
    return scroll
  }

  private func makeHexPreview<S: DataProtocol>(_ data: S) -> String {
    let bytes = Array(data)
    var lines: [String] = []
    lines.reserveCapacity(
      (bytes.count + HexLineFormatter.bytesPerLine - 1) / HexLineFormatter.bytesPerLine)
    for offset in stride(from: 0, to: bytes.count, by: HexLineFormatter.bytesPerLine) {
      let end = min(offset + HexLineFormatter.bytesPerLine, bytes.count)
      lines.append(HexLineFormatter.line(offset: offset, bytes: bytes[offset..<end]))
    }
    if bytes.count == Self.boundedPreviewBytes {
      lines.append("\n— Hex preview truncated at 4 MiB —")
    }
    return lines.joined(separator: "\n")
  }

  private func makeAgentTranscript(_ url: URL) -> NSView {
    guard
      let history = model.agentHistories.first(where: {
        $0.metadata.transcriptFileURL.standardizedFileURL == url.standardizedFileURL
      })
    else { return makeReadOnlyTextView(text: sourceText()) }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
    let title = NSTextField(labelWithString: history.metadata.title)
    title.font = NSFont.systemFont(ofSize: 19, weight: .bold)
    stack.addArrangedSubview(title)
    let actions = NSStackView(views: [
      ActionButton(title: "Resume", bezelStyle: .rounded) { [weak self] in
        self?.model.continueAgentSession(history.metadata, kind: .resume)
      },
      ActionButton(title: "Fork", bezelStyle: .rounded) { [weak self] in
        self?.model.continueAgentSession(history.metadata, kind: .fork)
      },
    ])
    actions.orientation = .horizontal
    stack.addArrangedSubview(actions)
    for entry in history.transcript.entries {
      let label: String =
        switch entry.kind {
        case .message(let role): role.rawValue.capitalized
        case .reasoning: "Reasoning"
        case .toolCall(let name): "Tool · \(name)"
        case .attachment(let name): "Attachment · \(name ?? "File")"
        }
      let heading = NSTextField(labelWithString: label)
      heading.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
      heading.textColor = AsterTheme.secondaryInk
      let text = NSTextField(wrappingLabelWithString: entry.text)
      text.font = NSFont.systemFont(ofSize: 13)
      text.textColor = AsterTheme.ink
      text.maximumNumberOfLines = 0
      stack.addArrangedSubview(heading)
      stack.addArrangedSubview(text)
      text.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
    }
    let document = NSView()
    document.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
    ])
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = document
    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    return scroll
  }

  private func showSharingPicker() {
    guard let fileURL, let button = shareButton else { return }
    let picker = NSSharingServicePicker(items: [fileURL])
    sharingPicker = picker
    picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  private func showOverflowMenu() {
    guard let button = overflowButton else { return }
    let menu = NSMenu(title: "File options")
    let readOnly = ActionMenuItem(title: runtime.isReadOnly ? "Unlock Editing" : "Make Read-only") {
      [weak self] in self?.toggleReadOnly()
    }
    readOnly.state = runtime.isReadOnly ? .on : .off
    menu.addItem(readOnly)
    menu.addItem(
      ActionMenuItem(title: "Reload from Disk") { [weak self] in self?.reloadFromDisk() })
    if presentationKind.supportsSourcePreviewToggle {
      menu.addItem(.separator())
      let source = ActionMenuItem(title: "View as Source") { [weak self] in
        self?.modeControl.selectedSegment = 0
        self?.changePresentationMode()
      }
      source.state = showingPreview ? .off : .on
      menu.addItem(source)
      let preview = ActionMenuItem(title: "View as Preview") { [weak self] in
        self?.modeControl.selectedSegment = 1
        self?.changePresentationMode()
      }
      preview.state = showingPreview ? .on : .off
      menu.addItem(preview)
    }
    menu.addItem(.separator())
    let wrap = ActionMenuItem(title: "Soft Wrap") { [weak self] in
      guard let self else { return }
      softWrap.toggle()
      renderContent()
    }
    wrap.state = softWrap ? .on : .off
    menu.addItem(wrap)
    let language = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
    let languageMenu = NSMenu(title: "Language")
    for value in [
      "Automatic", "swift", "javascript", "typescript", "python", "json", "bash", "diff", "html",
      "css",
    ] {
      let item = ActionMenuItem(title: value) { [weak self] in
        self?.selectedLanguage = value == "Automatic" ? nil : value
        self?.renderContent()
      }
      item.state =
        (value == "Automatic" && selectedLanguage == nil) || value == selectedLanguage ? .on : .off
      languageMenu.addItem(item)
    }
    language.submenu = languageMenu
    menu.addItem(language)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 3), in: button)
  }

  private func reloadFromDisk() {
    if runtime.isDirty {
      let alert = NSAlert()
      alert.messageText = "Discard unsaved changes?"
      alert.informativeText =
        "Reloading replaces the current editor contents with the version on disk."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Reload")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    performReloadFromDisk()
  }

  private func performReloadFromDisk() {
    runtime.reloadDocument()
    classifyDocument()
    lastModificationDate = modificationDate()
    reportedExternalConflict = false
    renderContent()
    updateToolbar()
  }

  private func startModificationMonitoring() {
    lastModificationDate = modificationDate()
    modificationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
      [weak self] _ in Task { @MainActor in self?.checkForExternalModification() }
    }
  }

  private func modificationDate() -> Date? {
    guard let fileURL else { return nil }
    return try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
  }

  private func readPrefix(of url: URL, maximumBytes: Int) -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
    defer { try? handle.close() }
    return handle.readData(ofLength: maximumBytes)
  }

  private func checkForExternalModification() {
    let current = modificationDate()
    guard current != lastModificationDate else { return }
    lastModificationDate = current
    guard current != nil else {
      reportedExternalConflict = true
      updateToolbar()
      return
    }
    if runtime.isDirty {
      reportedExternalConflict = true
      updateToolbar()
    } else {
      runtime.reloadDocument()
      classifyDocument()
      renderContent()
    }
  }

  private func restructuredTextHTML(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var output: [String] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if index + 1 < lines.count, !line.isEmpty,
        !lines[index + 1].isEmpty,
        Set(lines[index + 1]).isSubset(of: Set("=-~^\"`:+*#")),
        lines[index + 1].count >= line.count
      {
        let level = lines[index + 1].first == "=" ? 1 : 2
        output.append("<h\(level)>\(escapeHTML(line))</h\(level)>")
        index += 2
      } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
        output.append("<p>• \(escapeHTML(String(line.dropFirst(2))))</p>")
        index += 1
      } else {
        output.append(line.isEmpty ? "<br>" : "<p>\(escapeHTML(line))</p>")
        index += 1
      }
    }
    return output.joined(separator: "\n")
  }

  private func escapeHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private func languageName(for fileExtension: String) -> String? {
    switch fileExtension {
    case "js", "jsx": "javascript"
    case "ts", "tsx": "typescript"
    case "py": "python"
    case "sh", "bash", "zsh": "bash"
    case "yml": "yaml"
    case "patch": "diff"
    case "md", "markdown": "markdown"
    default: fileExtension.isEmpty ? nil : fileExtension
    }
  }

  private func messageView(_ message: String, symbol: String) -> NSView {
    let host = NSView()
    let image = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: message) ?? NSImage())
    let label = NSTextField(wrappingLabelWithString: message)
    label.textColor = AsterTheme.secondaryInk
    let stack = NSStackView(views: [image, label])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    host.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48),
    ])
    return host
  }
}

/// 二进制预览只保留有界字节，并让 `NSTableView` 按可见行请求内容；即使达到 4 MiB
/// 上限也不会预先构造二十多万行字符串或同等数量的 AppKit 视图。
@MainActor
private final class HexPreviewView: NSView, NSTableViewDataSource, NSTableViewDelegate {
  private let data: Data
  private let isTruncated: Bool

  init(data: Data, isTruncated: Bool) {
    self.data = data
    self.isTruncated = isTruncated
    super.init(frame: .zero)
    let table = NSTableView()
    table.headerView = nil
    table.style = .plain
    table.backgroundColor = .clear
    table.rowHeight = 19
    table.intercellSpacing = .zero
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hex")))
    table.dataSource = self
    table.delegate = self
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.documentView = table
    addSubview(scroll)
    scroll.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }

  func numberOfRows(in tableView: NSTableView) -> Int {
    let dataRows = (data.count + HexLineFormatter.bytesPerLine - 1) / HexLineFormatter.bytesPerLine
    return dataRows + (isTruncated ? 1 : 0)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let dataRows = (data.count + HexLineFormatter.bytesPerLine - 1) / HexLineFormatter.bytesPerLine
    let identifier = NSUserInterfaceItemIdentifier("hex-row")
    let label =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
      ?? NSTextField(labelWithString: "")
    label.identifier = identifier
    label.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    label.textColor = AsterTheme.ink
    if row >= dataRows {
      label.stringValue = "— Hex preview truncated at 4 MiB —"
      label.textColor = AsterTheme.secondaryInk
    } else {
      let offset = row * HexLineFormatter.bytesPerLine
      let end = min(offset + HexLineFormatter.bytesPerLine, data.count)
      label.stringValue = HexLineFormatter.line(
        offset: offset,
        bytes: Array(data[offset..<end])[...]
      )
    }
    return label
  }
}
