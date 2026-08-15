import AppKit
import AsterCore
import Combine
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
  private let renderer: any FileRendering
  private let contentHost = NSView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let modeControl = NSSegmentedControl(
    labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
  private var presentationKind: FilePresentationKind = .sourceText
  private var showingPreview = false
  private var observedDirty: Bool
  private var observedReadOnly: Bool
  private var observedDocumentError: String?
  private var softWrap: Bool
  private var selectedLanguage: String?
  private var cancellables: Set<AnyCancellable> = []
  private var documentDelegate: DocumentTextDelegate?
  private var sourceScrollView: NSScrollView?
  private var cachedPreviewView: NSView?
  private(set) weak var previewWebView: WKWebView?
  private var sourceRenderRevision = 0
  private var previewRenderRevision = 0
  private var renderedPreviewText: String?
  private var pendingPreviewBody: String?
  private var sourceRenderTask: Task<Void, Never>?
  private var previewRenderTask: Task<Void, Never>?
  // Timer 只在主线程创建和失效；标记 unsafe 是为了允许 nonisolated deinit 回收它。
  private nonisolated(unsafe) var modificationTimer: Timer?
  private var lastModificationDate: Date?
  private var reportedExternalConflict = false
  private weak var overflowButton: NSButton?
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
    preferences: AppPreferences,
    renderer: any FileRendering = FileRenderPipeline()
  ) {
    self.runtime = runtime
    self.tab = tab
    self.model = model
    self.preferences = preferences
    self.renderer = renderer
    self.softWrap = preferences.configuration.editor.lineWrap
    self.observedDirty = runtime.isDirty
    self.observedReadOnly = runtime.isReadOnly
    self.observedDocumentError = runtime.documentError
    super.init(nibName: nil, bundle: nil)
    classifyDocument()
    showingPreview = runtime.descriptor.kind == .preview && presentationKind != .sourceText
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    let column = NSStackView(views: [makeToolbar(), contentHost])
    column.orientation = .vertical
    // 纵向 NSStackView 默认 centerX 对齐：内容视图一旦有固有宽度（如 transcript
    // 页头的 label），就会被按 fitting 宽度居中而不是撑满 Pane。显式 .width 让
    // 工具条与内容区始终跟随 Pane 宽度（规则 5：容器两个方向都要有确定尺寸）。
    column.alignment = .width
    column.spacing = 0
    root.addSubview(column)
    column.pinEdges(to: root)
    view = root
    renderContent()
    observeRuntime()
    startModificationMonitoring()
  }

  deinit {
    modificationTimer?.invalidate()
    sourceRenderTask?.cancel()
    previewRenderTask?.cancel()
  }

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
    modeControl.setWidth(32, forSegment: 0)
    modeControl.setWidth(32, forSegment: 1)
    modeControl.setAccessibilityLabel("File presentation")
    configureModeControl()
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
    let left = NSStackView(views: [modeControl, chat, share])
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
    runtime.$documentText.dropFirst().sink { [weak self] text in
      guard let self else { return }
      // 使用 @Published 发出的新值；在 willSet 通知期间回读 runtime 属性可能仍是旧文本，
      // 会把用户刚输入的字符错误覆盖回去。
      if sourceTextView?.string != text {
        sourceTextView?.string = text
      }
      scheduleSourceRendering()
      schedulePreviewRendering(text: text)
      updateToolbar()
    }.store(in: &cancellables)
    runtime.$isDirty.sink { [weak self] isDirty in
      guard let self else { return }
      observedDirty = isDirty
      if !isDirty {
        lastModificationDate = modificationDate()
        reportedExternalConflict = false
      }
      updateToolbar()
    }.store(in: &cancellables)
    runtime.$isReadOnly.sink { [weak self] isReadOnly in
      guard let self else { return }
      observedReadOnly = isReadOnly
      sourceTextView?.isEditable = presentationKind.supportsEditing && !isReadOnly
      updateToolbar()
    }.store(in: &cancellables)
    runtime.$documentError.sink { [weak self] error in
      self?.observedDocumentError = error
      self?.updateToolbar()
    }.store(in: &cancellables)
    model.agentHistoriesChanged.sink { [weak self] _ in
      guard let self else { return }
      let previous = presentationKind
      classifyDocument()
      guard presentationKind != previous else { return }
      showingPreview = runtime.descriptor.kind == .preview && presentationKind != .sourceText
      cachedPreviewView = nil
      previewWebView = nil
      renderedPreviewText = nil
      pendingPreviewBody = nil
      configureModeControl()
      renderContent()
    }.store(in: &cancellables)
  }

  private func updateToolbar() {
    titleLabel.stringValue = fileURL?.lastPathComponent ?? "Untitled"
    if observedDocumentError != nil {
      statusLabel.stringValue = "Error"
      statusLabel.textColor = AsterTheme.warning
    } else if reportedExternalConflict {
      statusLabel.stringValue = "Modified on Disk"
      statusLabel.textColor = AsterTheme.warning
    } else if observedDirty {
      statusLabel.stringValue = "Edited"
      statusLabel.textColor = AsterTheme.secondaryInk
    } else {
      statusLabel.stringValue = "✓ Saved"
      statusLabel.textColor = AsterTheme.secondaryInk
    }
    configureModeControl()
  }

  @objc private func changePresentationMode() {
    if presentationKind.supportsSourcePreviewToggle {
      showingPreview = modeControl.selectedSegment == 1
    } else if presentationKind.supportsEditing {
      runtime.setReadOnly(modeControl.selectedSegment == 1)
    }
    if !showingPreview { statusSpinner?.stopAnimation(nil) }
    renderContent()
  }

  /// Markdown 等双形态文本使用 code/eye；普通源码使用 code/lock。预览专用类型不显示
  /// 无效开关，避免 transcript、图片或 PDF 出现点了也不能编辑的控件。
  private func configureModeControl() {
    let canPreview = presentationKind.supportsSourcePreviewToggle
    modeControl.isHidden = !canPreview && !presentationKind.supportsEditing
    modeControl.setImage(
      NSImage(
        systemSymbolName: "chevron.left.forwardslash.chevron.right",
        accessibilityDescription: "Source"
      ),
      forSegment: 0
    )
    modeControl.setImage(
      NSImage(
        systemSymbolName: canPreview ? "eye" : "lock.fill",
        accessibilityDescription: canPreview ? "Preview" : "Lock editing"
      ),
      forSegment: 1
    )
    modeControl.setToolTip("Source", forSegment: 0)
    modeControl.setToolTip(canPreview ? "Preview" : "Lock editing", forSegment: 1)
    modeControl.selectedSegment =
      canPreview ? (showingPreview ? 1 : 0) : (observedReadOnly ? 1 : 0)
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
    let content = showingPreview ? ensurePreviewContent() : ensureSourceContent()
    if content.superview !== contentHost {
      contentHost.removeAllSubviews()
      contentHost.addSubview(content)
      content.pinEdges(to: contentHost)
    }
    onSourceTextViewChanged?(showingPreview ? nil : sourceTextView)
    if showingPreview {
      schedulePreviewRendering()
    } else {
      scheduleSourceRendering()
      // 只预计算 HTML，不提前创建 WKWebView；这样打开仍轻量，首次切换也无需再等待
      // Markdown/RST 转换，WebKit 的一次性初始化留到用户真正需要预览时。
      schedulePreviewRendering()
    }
  }

  /// 源码视图在 Pane 生命周期内只创建一次。模式与锁定切换仅更新可编辑状态和层级，
  /// 因而保留滚动位置、选区、undo manager 以及 Workspace 的行跳转引用。
  private func ensureSourceContent() -> NSView {
    if let sourceScrollView {
      updateSourceLayout()
      return sourceScrollView
    }
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
    textView.string = sourceText()
    let delegate = DocumentTextDelegate(runtime: runtime) { [weak self] in
      self?.scheduleSourceRendering(debounced: true)
      self?.schedulePreviewRendering(debounced: true)
    }
    documentDelegate = delegate
    textView.delegate = delegate
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    sourceScrollView = scroll
    updateSourceLayout()
    return scroll
  }

  private func updateSourceLayout() {
    guard let textView = sourceTextView, let scroll = sourceScrollView else { return }
    textView.isEditable = presentationKind.supportsEditing && !runtime.isReadOnly
    textView.textContainer?.widthTracksTextView = softWrap
    textView.isHorizontallyResizable = !softWrap
    textView.textContainer?.containerSize = NSSize(
      width: softWrap ? 0 : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    scroll.hasHorizontalScroller = !softWrap
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

  private func scheduleSourceRendering(debounced: Bool = false) {
    guard let textView = sourceTextView,
      [.sourceText, .diff, .markdown, .restructuredText, .html, .svg].contains(presentationKind)
    else { return }
    sourceRenderRevision += 1
    let revision = sourceRenderRevision
    let text = textView.string
    let language = selectedLanguage ?? languageName(for: fileURL?.pathExtension.lowercased() ?? "")
    sourceRenderTask?.cancel()
    sourceRenderTask = Task { [weak self] in
      if debounced {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
      }
      guard let self,
        case .highlightedRTF(let data)? = await renderer.renderSource(text, language: language),
        !Task.isCancelled,
        revision == sourceRenderRevision,
        let textView = sourceTextView,
        textView.string == text,
        let highlighted = try? NSAttributedString(
          data: data,
          options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil
        ), highlighted.string == text
      else { return }
      let selections = textView.selectedRanges
      guard let storage = textView.textStorage else { return }
      // 只替换属性，不替换字符；这样不会制造一轮伪编辑，也不会清空 undo 栈。
      storage.beginEditing()
      storage.setAttributes([:], range: NSRange(location: 0, length: storage.length))
      highlighted.enumerateAttributes(
        in: NSRange(location: 0, length: highlighted.length)
      ) { attributes, range, _ in
        storage.addAttributes(attributes, range: range)
      }
      storage.endEditing()
      textView.selectedRanges = selections
    }
  }

  private func schedulePreviewRendering(text requestedText: String? = nil, debounced: Bool = false) {
    guard presentationKind.supportsSourcePreviewToggle else { return }
    let text = requestedText ?? sourceTextView?.string ?? sourceText()
    if renderedPreviewText == text, pendingPreviewBody != nil { return }
    previewRenderRevision += 1
    let revision = previewRenderRevision
    let renderer = self.renderer
    let kind = presentationKind
    previewRenderTask?.cancel()
    if showingPreview { statusSpinner?.startAnimation(nil) }
    previewRenderTask = Task { [weak self] in
      if debounced {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
      }
      let artifact = await renderer.renderPreview(text, kind: kind)
      guard let self else { return }
      if revision == previewRenderRevision, showingPreview {
        statusSpinner?.stopAnimation(nil)
      }
      guard !Task.isCancelled, revision == previewRenderRevision,
        case .webBody(let body)? = artifact
      else { return }
      renderedPreviewText = text
      pendingPreviewBody = body
      if showingPreview {
        let webView = previewWebView ?? (ensurePreviewContent() as? WKWebView)
        if let webView { loadWebPreview(body, into: webView) }
      }
    }
  }

  private func ensurePreviewContent() -> NSView {
    if let cachedPreviewView { return cachedPreviewView }
    let preview = makePreviewContent()
    cachedPreviewView = preview
    return preview
  }

  private func makePreviewContent() -> NSView {
    guard let fileURL else { return messageView("No file selected.", symbol: "doc") }
    switch presentationKind {
    case .markdown, .restructuredText, .html, .svg:
      return makeWebPreview(baseURL: fileURL.deletingLastPathComponent())
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
      return ensureSourceContent()
    case .agentTranscript:
      return makeAgentTranscript(fileURL)
    case .sourceText:
      return ensureSourceContent()
    case .binary:
      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let data = readPrefix(of: fileURL, maximumBytes: Self.boundedPreviewBytes)
      return HexPreviewView(data: data, isTruncated: size > data.count)
    }
  }

  private func makeWebPreview(baseURL: URL) -> NSView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    previewWebView = webView
    loadWebPreview(pendingPreviewBody ?? "<p>Rendering preview…</p>", into: webView, baseURL: baseURL)
    return webView
  }

  private func loadWebPreview(_ body: String, into webView: WKWebView, baseURL: URL? = nil) {
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
    webView.loadHTMLString(document, baseURL: baseURL ?? fileURL?.deletingLastPathComponent())
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
    // 标题下给出会话文件与归属元信息（对齐 Otty 的会话页头）：文件名一行，
    // 项目路径 · provider · 更新时间一行，便于核对「这是哪个项目的哪次会话」。
    let fileLine = NSTextField(labelWithString: url.lastPathComponent)
    fileLine.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    fileLine.textColor = AsterTheme.tertiaryInk
    fileLine.lineBreakMode = .byTruncatingMiddle
    stack.addArrangedSubview(fileLine)
    var metaParts: [String] = []
    if !history.metadata.projectDirectory.isEmpty {
      metaParts.append((history.metadata.projectDirectory as NSString).abbreviatingWithTildeInPath)
    }
    metaParts.append(history.metadata.configuration.provider.commandName)
    metaParts.append(RelativeTime.string(since: history.metadata.updatedAt))
    let metaLine = NSTextField(labelWithString: metaParts.joined(separator: "  ·  "))
    metaLine.font = NSFont.systemFont(ofSize: 11)
    metaLine.textColor = AsterTheme.secondaryInk
    metaLine.lineBreakMode = .byTruncatingMiddle
    stack.addArrangedSubview(metaLine)
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

    // 正文用与 Markdown 预览同源的加固 WKWebView（无 JS、CSP 锁死、无网络）渲染 HTML：
    // 用户消息进浅色卡片、Claude 输出按 Markdown 渲染、工具调用折叠成 <details> 摘要，
    // 展开是原生 HTML 行为。构建在主线程外完成——曾经逐条建 wrapping NSTextField 的
    // 实现在真实大会话上会把主线程卡死；HTML 拼装同样受单条/总量双重上限约束。
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.loadHTMLString(
      AgentTranscriptHTML.document(body: "<p class=\"notice\">正在渲染会话…</p>"), baseURL: nil)
    let entries = history.transcript.entries
    Task.detached(priority: .userInitiated) {
      let document = AgentTranscriptHTML.document(body: AgentTranscriptHTML.body(entries: entries))
      await MainActor.run { [weak webView] in
        webView?.loadHTMLString(document, baseURL: nil)
      }
    }
    let body: NSView = webView

    let container = NSView()
    container.addSubview(stack)
    container.addSubview(body)
    stack.translatesAutoresizingMaskIntoConstraints = false
    body.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      body.topAnchor.constraint(equalTo: stack.bottomAnchor),
      body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
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
    if presentationKind.supportsEditing {
      let readOnly = ActionMenuItem(
        title: runtime.isReadOnly ? "Unlock Editing" : "Make Read-only"
      ) { [weak self] in self?.toggleReadOnly() }
      readOnly.state = runtime.isReadOnly ? .on : .off
      menu.addItem(readOnly)
    }
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
    renderedPreviewText = nil
    pendingPreviewBody = nil
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
