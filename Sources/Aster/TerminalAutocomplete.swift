import AppKit
import AsterCore
import Foundation
@preconcurrency import GhosttyKit

/// Autocomplete 只依赖“发送字节、核对可见 prompt、提供 caret 视觉令牌”这组窄接口，
/// 不绑定 SwiftTerm 或 Ghostty 的网格实现。两个引擎都在各自 adapter 内完成坐标转换。
@MainActor
protocol TerminalAutocompleteHost: AnyObject {
  var autocompleteContainerView: NSView { get }
  var autocompleteCaretFrame: NSRect { get }
  var autocompleteFont: NSFont { get }
  var autocompleteForegroundColor: NSColor { get }
  var autocompleteBackgroundColor: NSColor { get }
  func sendAutocompleteBytes(_ bytes: ArraySlice<UInt8>) -> Bool
  func visiblePromptEnds(with text: String) -> Bool
}

extension AsterTerminalView: TerminalAutocompleteHost {
  var autocompleteContainerView: NSView { self }
  var autocompleteCaretFrame: NSRect { caretFrame }
  var autocompleteFont: NSFont { font }
  var autocompleteForegroundColor: NSColor { nativeForegroundColor }
  var autocompleteBackgroundColor: NSColor { nativeBackgroundColor }

  func sendAutocompleteBytes(_ bytes: ArraySlice<UInt8>) -> Bool {
    send(data: bytes)
    return true
  }

  func visiblePromptEnds(with text: String) -> Bool {
    let terminal = getTerminal()
    guard let line = terminal.getLine(row: terminal.buffer.y) else { return false }
    return line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
      .hasSuffix(text)
  }
}

extension GhosttySurfaceView: TerminalAutocompleteHost {
  var autocompleteContainerView: NSView { self }
  var autocompleteCaretFrame: NSRect { textCursorFrameInViewCoordinates }
  var autocompleteFont: NSFont {
    guard let surface, let fontPointer = ghostty_surface_quicklook_font(surface) else {
      // Surface 尚未创建或当前字体后端无法导出 CoreText 字体时，补全也不会具备可靠的
      // cursor 锚点；保留无副作用的系统字体仅用于防御性降级。
      return .monospacedSystemFont(ofSize: 13, weight: .regular)
    }
    // libghostty 返回 +1 retained CTFontRef，且 CoreText 与 NSFont 在 macOS 上可桥接。
    // 由 ARC 接管所有权，并使用与 Metal 网格相同的 face/size，保证相邻字形基线一致。
    return Unmanaged<NSFont>.fromOpaque(fontPointer).takeRetainedValue()
  }
  var autocompleteForegroundColor: NSColor { .textColor }
  var autocompleteBackgroundColor: NSColor { AsterTheme.panel }

  func sendAutocompleteBytes(_ bytes: ArraySlice<UInt8>) -> Bool {
    sendBytes(Array(bytes))
  }

  func visiblePromptEnds(with text: String) -> Bool {
    readText(includeScrollback: false, maximumLines: 1)?
      .trimmingCharacters(in: .newlines).hasSuffix(text) == true
  }
}

/// 终端按键到 Autocomplete 意图的稳定映射。物理 keyCode 用于不受当前键盘布局影响的
/// 导航键；Control-Space 等文字组合仍检查 modifier，避免吞掉普通空格。
enum TerminalAutocompleteKey: Equatable {
  case tab
  case right
  case up
  case down
  case enter
  case escape
  case optionEscape
  case controlSpace
  case functionFive
  case backspace
  case other

  static func resolve(_ event: NSEvent) -> TerminalAutocompleteKey {
    switch event.keyCode {
    case 48: return .tab
    case 124: return .right
    case 126: return .up
    case 125: return .down
    case 36, 76: return .enter
    case 53 where event.modifierFlags.contains(.option): return .optionEscape
    case 53: return .escape
    case 96: return .functionFive
    case 51: return .backspace
    default:
      if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " {
        return .controlSpace
      }
      return .other
    }
  }
}

/// 单个终端 Pane 的补全编排器。领域候选和持久化由 `AsterCore` / `AutocompleteService`
/// 负责；这里仅把 OSC 133、键盘输入和 AppKit overlay 串起来。
@MainActor
final class TerminalAutocompleteController {
  private weak var terminalView: (any TerminalAutocompleteHost)?
  private let service: AutocompleteService
  private let sessionIdentifier: String
  private let controls: () -> ControlConfiguration
  private let currentDirectory: () -> String
  private let tracker = PromptInputTracker()
  private let overlay = TerminalAutocompleteOverlayView()

  private(set) var currentResult = AutocompleteResult(
    candidates: [], ghostText: nil, replacementStart: 0)
  private(set) var panelVisible = false
  private(set) var selectedIndex = 0
  private(set) var promptActive = false
  private(set) var lastSubmittedCommand: String?
  /// 命令文本只在当前 Pane 内存中用于自动进度匹配，不进入工作区快照或日志。
  var onCommandSubmitted: ((String) -> Void)?

  private var refreshTask: Task<Void, Never>?
  private var helpProbeTask: Task<Void, Never>?
  private var probedCommands: Set<String> = []
  private var runningCommand: String?
  private var outputCapture = ShellCommandOutputCapture()
  private var completedCommandOutput: ShellCapturedCommandOutput?
  private var pendingCorrection: String?
  private var aliases: [String] = []
  private var inlineDismissed = false
  /// 本地输入会先于 PTY 回显到达。等待回显期间保留候选数据但隐藏 ghost，避免它
  /// 锚定在旧 caretFrame 上并与 Shell 随后绘制的输入文字重叠。
  private var awaitingInputEcho = false

  init(
    service: AutocompleteService,
    sessionIdentifier: String,
    controls: @escaping () -> ControlConfiguration,
    currentDirectory: @escaping () -> String
  ) {
    self.service = service
    self.sessionIdentifier = sessionIdentifier
    self.controls = controls
    self.currentDirectory = currentDirectory
    overlay.onCandidateSelected = { [weak self] index in
      self?.acceptCandidate(at: index)
    }
  }

  deinit {
    refreshTask?.cancel()
    helpProbeTask?.cancel()
  }

  func attach(to terminalView: any TerminalAutocompleteHost) {
    self.terminalView = terminalView
    let container = terminalView.autocompleteContainerView
    container.addSubview(overlay, positioned: .above, relativeTo: nil)
    overlay.frame = container.bounds
    overlay.autoresizingMask = [.width, .height]
    render()
  }

  func receive(_ event: ShellIntegrationEvent) {
    switch event {
    case .promptStart:
      // A 只表示 prompt 即将开始；必须等 B 确认输入区已出现，避免慢 prompt 绘制期间
      // 把候选锚定到中间输出位置。
      promptActive = false
      tracker.beginPrompt()
      inlineDismissed = false
      awaitingInputEcho = false
    case .inputStart:
      // B 明确表示光标已进入可编辑区。A 缺失时仍可从此处开始安全跟踪。
      if !promptActive {
        promptActive = true
        tracker.beginPrompt()
      }
      awaitingInputEcho = false
      scheduleRefresh()
    case .commandStart:
      promptActive = false
      runningCommand = lastSubmittedCommand
      dismiss()
    case .commandFinished(let exitStatus):
      finishCommand(exitStatus: exitStatus)
      runningCommand = nil
      completedCommandOutput = nil
      dismiss()
    }
  }

  func receiveInput(_ bytes: ArraySlice<UInt8>) {
    guard promptActive else { return }
    let submitted = tracker.receive(Array(bytes))
    if let command = submitted.last {
      lastSubmittedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
      if let lastSubmittedCommand { onCommandSubmitted?(lastSubmittedCommand) }
      promptActive = false
      dismiss()
      return
    }
    guard tracker.isReliable else {
      dismiss()
      return
    }
    inlineDismissed = false
    panelVisible = false
    awaitingInputEcho = true
    // 候选重算有 debounce，而 PTY 回显会在这段窗口内继续推进终端网格。若保留上一轮
    // ghost，旧后缀会短暂覆盖新输入；先清空可见候选，待新输入回显并重算后再显示。
    currentResult = AutocompleteResult(candidates: [], ghostText: nil, replacementStart: 0)
    selectedIndex = 0
    render()
    scheduleRefresh()
  }

  func receiveOutput(_ bytes: ArraySlice<UInt8>) {
    if let completed = outputCapture.consume(bytes).last {
      completedCommandOutput = completed
    }
    guard promptActive, awaitingInputEcho else { return }
    // 输出捕获需先于同分片内的 OSC 命令完成事件，但 ghost 布局必须等终端 surface
    // 消费完回显并更新 caretFrame。终端的状态报告、光标控制等同样会走 PTY 输出，
    // 因此不能把“收到任意输出”当成回显完成，否则 ghost 会锚定旧光标并覆盖输入。
    Task { @MainActor [weak self] in
      guard let self, self.promptActive, self.awaitingInputEcho,
        self.currentPromptIsEchoed()
      else { return }
      self.awaitingInputEcho = false
      self.render()
    }
  }

  func receiveAliases(_ names: [String]) {
    guard aliases != names else { return }
    aliases = names
    if promptActive { scheduleRefresh() }
  }

  @discardableResult
  func handleKeyDown(_ event: NSEvent) -> Bool {
    handle(TerminalAutocompleteKey.resolve(event))
  }

  @discardableResult
  func handle(_ key: TerminalAutocompleteKey) -> Bool {
    if key == .backspace {
      // Backspace 本身仍交给 Shell；这里只立即清掉旧 ghost/panel，输入回调随后按新文本重算。
      dismiss()
      return false
    }

    if panelVisible {
      switch key {
      case .up:
        guard !currentResult.candidates.isEmpty else { return true }
        selectedIndex = (selectedIndex + currentResult.candidates.count - 1)
          % currentResult.candidates.count
        render()
        return true
      case .down:
        guard !currentResult.candidates.isEmpty else { return true }
        selectedIndex = (selectedIndex + 1) % currentResult.candidates.count
        render()
        return true
      case .enter, .tab:
        return acceptCandidate(at: selectedIndex)
      case .escape, .optionEscape:
        dismiss()
        inlineDismissed = true
        return true
      default:
        break
      }
    }

    let configuration = controls()
    let acceptsInline: Bool
    switch configuration.resolvedAutocompleteShortcut {
    case .tab: acceptsInline = key == .tab
    case .tabAndRightArrow: acceptsInline = key == .tab || key == .right
    case .controlSpace: acceptsInline = key == .controlSpace
    case .disabled: acceptsInline = false
    }
    // 只允许接受屏幕上真正显示的 ghost。等待回显期间（含 zsh-autosuggestions 等
    // shell 端建议占据行尾、导致回显校验一直不通过的场景）候选是不可见的；此时吞掉
    // Tab 会插入用户从未见过的文本，必须把按键放行给 Shell 自己的补全。
    if acceptsInline, currentResult.ghostText != nil, inlineSuggestionDisplayable {
      return acceptCandidate(at: 0)
    }

    if key == .escape, currentResult.ghostText != nil, inlineSuggestionDisplayable {
      inlineDismissed = true
      render()
      return true
    }

    let opensPanel: Bool
    switch configuration.resolvedAutocompleteCandidatePanel {
    case .disabled, .automatic: opensPanel = false
    case .escape: opensPanel = key == .escape
    case .optionEscape: opensPanel = key == .optionEscape || key == .functionFive
    }
    if opensPanel, !currentResult.candidates.isEmpty {
      panelVisible = true
      selectedIndex = 0
      render()
      return true
    }
    return false
  }

  /// 测试和立即设置变更使用的同步刷新 seam；正常输入通过 150ms debounce 调用。
  func refreshNow() {
    refreshTask?.cancel()
    guard promptActive, tracker.isReliable, tracker.isCursorAtEnd else {
      dismiss()
      return
    }
    let configuration = controls()
    var result = service.suggestions(
      line: tracker.line,
      directory: currentDirectory(),
      sessionIdentifier: sessionIdentifier,
      controls: configuration,
      aliases: aliases
    )
    if configuration.resolvedAutocompleteOnDeviceLearning,
      let correction = pendingCorrection,
      correction.hasPrefix(tracker.line), correction != tracker.line
    {
      let candidate = AutocompleteCandidate(
        insertText: correction,
        description: "修正上一条命令",
        kind: .correction,
        score: Double.greatestFiniteMagnitude
      )
      result = AutocompleteResult(
        candidates: [candidate] + result.candidates.filter { $0.insertText != correction },
        ghostText: String(correction.dropFirst(tracker.line.count)),
        replacementStart: 0
      )
    }
    currentResult = result
    selectedIndex = min(selectedIndex, max(0, result.candidates.count - 1))
    panelVisible = configuration.resolvedAutocompleteCandidatePanel == .automatic
      && result.candidates.count >= 2
    render()
    scheduleHelpProbeIfNeeded(configuration: configuration)
  }

  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      self?.refreshNow()
    }
  }

  /// 只有用户已经输入“未知可执行文件 + 空格”后才探测 help；输入中的命令前缀不会
  /// 触发进程。每个会话每个命令最多一次，关闭本地学习时完全跳过。
  private func scheduleHelpProbeIfNeeded(configuration: ControlConfiguration) {
    guard configuration.resolvedAutocompleteOnDeviceLearning,
      currentDirectory().hasPrefix("/"),
      tracker.line.contains(where: \.isWhitespace),
      let command = ShellCommandTokenizer.tokenize(tracker.line).tokens.first,
      !command.isEmpty,
      !service.containsDetailedSpec(for: command),
      probedCommands.insert(command).inserted
    else { return }
    helpProbeTask?.cancel()
    helpProbeTask = Task { @MainActor [weak self] in
      guard let spec = await AutocompleteHelpProbe.probe(command: command), !Task.isCancelled,
        let self
      else { return }
      do {
        try service.installLocalSpec(spec)
        refreshNow()
      } catch {
        // 本地规格写入失败只禁用本轮探测结果；补全仍可继续使用内置规格和历史。
      }
    }
  }

  @discardableResult
  private func acceptCandidate(at index: Int) -> Bool {
    guard currentResult.candidates.indices.contains(index), let terminalView else { return false }
    let candidate = currentResult.candidates[index]
    let line = tracker.line
    let currentToken = ShellCommandTokenizer.tokenize(line).currentToken
    let suffix: String
    if candidate.insertText.hasPrefix(line) {
      suffix = String(candidate.insertText.dropFirst(line.count))
    } else if candidate.insertText.hasPrefix(currentToken) {
      suffix = String(candidate.insertText.dropFirst(currentToken.count))
    } else {
      return false
    }
    guard !suffix.isEmpty else { return false }
    dismiss()
    return terminalView.sendAutocompleteBytes(Array(suffix.utf8)[...])
  }

  private func finishCommand(exitStatus: Int?) {
    guard let command = runningCommand, !command.isEmpty else { return }
    let configuration = controls()
    guard configuration.resolvedAutocompleteOnDeviceLearning else {
      pendingCorrection = nil
      return
    }
    let executable = ShellCommandTokenizer.tokenize(command).tokens.first ?? ""
    let status = exitStatus ?? 0
    _ = service.record(
      command: command,
      directory: currentDirectory(),
      exitStatus: status,
      ignorePatterns: configuration.resolvedAutocompleteHistoryIgnore,
      knownOptions: service.knownOptions(for: executable),
      sessionIdentifier: sessionIdentifier
    )
    let output = ANSICleaner.visibleText(from: completedCommandOutput?.text ?? "")
    pendingCorrection = status == 0 ? nil : CommandCorrectionParser.suggestion(
      command: command,
      output: output,
      knownCommands: Set(service.specDatabase.commands.map(\.name))
    )
  }

  private func dismiss() {
    refreshTask?.cancel()
    panelVisible = false
    currentResult = AutocompleteResult(candidates: [], ghostText: nil, replacementStart: 0)
    selectedIndex = 0
    render()
  }

  /// Vi、Hint 或 Read-only 接管输入时清空候选；Prompt tracker 保留当前命令行，退出
  /// 模式后的下一次正常输入仍可从可靠状态继续刷新。
  func dismissForPaneMode() {
    dismiss()
  }

  /// 仅当终端当前可见输入行已包含本地跟踪的完整命令时，才允许显示 ghost。
  /// PTY 会混入 OSC、CSI 等非回显字节；它们可能在用户输入与真实回显之间到达，不能
  /// 以它们为依据提前读取旧 `caretFrame`。
  private func currentPromptIsEchoed() -> Bool {
    guard !tracker.line.isEmpty, tracker.isCursorAtEnd, let terminalView else { return false }
    return terminalView.visiblePromptEnds(with: tracker.line)
  }

  /// Inline ghost 当前是否具备显示条件；接受候选与渲染必须共用同一判定，
  /// 否则会出现“接受了一个不可见 ghost”的错乱（Tab 插入用户没看到的文本）。
  private var inlineSuggestionDisplayable: Bool {
    controls().resolvedAutocompleteInlineSuggestion
      && !inlineDismissed
      && !awaitingInputEcho
  }

  private func render() {
    guard let terminalView else { return }
    overlay.render(
      result: currentResult,
      showInline: inlineSuggestionDisplayable,
      showPanel: panelVisible,
      selectedIndex: selectedIndex,
      caretFrame: terminalView.autocompleteCaretFrame,
      font: terminalView.autocompleteFont,
      foreground: terminalView.autocompleteForegroundColor,
      // 自定义主题未来仍可能提供透明原生画布；候选浮层没有窗口材质，遇到透明色时
      // 必须回退到主题 surface，避免候选文字直接压在终端内容上。
      background: terminalView.autocompleteBackgroundColor.alphaComponent > 0.01
        ? terminalView.autocompleteBackgroundColor : AsterTheme.panel
    )
  }
}

/// 轻量 AppKit overlay：ghost label 不接收鼠标，候选面板最多显示 8 行并允许点击。
/// 布局以终端 adapter 的 caretFrame 为锚点，优先显示在光标下方，空间不足时翻到上方。
@MainActor
private final class TerminalAutocompleteOverlayView: NSView {
  var onCandidateSelected: ((Int) -> Void)?
  private let ghostLabel = NSTextField(labelWithString: "")
  private let panel = NSStackView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    ghostLabel.isHidden = true
    ghostLabel.lineBreakMode = .byClipping
    addSubview(ghostLabel)
    panel.orientation = .vertical
    panel.alignment = .width
    panel.spacing = 0
    panel.wantsLayer = true
    panel.layer?.cornerRadius = 8
    panel.layer?.borderWidth = 1
    panel.isHidden = true
    addSubview(panel)
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !panel.isHidden, panel.frame.contains(point) else { return nil }
    return super.hitTest(point)
  }

  func render(
    result: AutocompleteResult,
    showInline: Bool,
    showPanel: Bool,
    selectedIndex: Int,
    caretFrame: NSRect,
    font: NSFont,
    foreground: NSColor,
    background: NSColor
  ) {
    ghostLabel.font = font
    ghostLabel.textColor = foreground.withAlphaComponent(0.42)
    ghostLabel.stringValue = showInline ? (result.ghostText ?? "") : ""
    ghostLabel.isHidden = ghostLabel.stringValue.isEmpty
    ghostLabel.sizeToFit()
    let naturalBaselineFromBottom =
      ghostLabel.frame.height - ghostLabel.firstBaselineOffsetFromTop
    let centeredBaselineFromBottom =
      naturalBaselineFromBottom + (caretFrame.height - ghostLabel.frame.height) / 2
    let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let alignedBaselineFromBottom =
      (centeredBaselineFromBottom * backingScale).rounded() / backingScale
    // Ghostty 会把 adjust-cell-height 增减的空间分到字形上下两侧；AppKit label 的
    // sizeToFit 只包含字体自然行高。按 cell 中线平移并把 baseline 对齐到设备像素，
    // 可避免补全文字始终贴住 cell 底边而比 Metal 字形低一个 Retina 像素。
    ghostLabel.frame.origin = NSPoint(
      x: caretFrame.maxX,
      y: caretFrame.minY + alignedBaselineFromBottom - naturalBaselineFromBottom
    )
    ghostLabel.frame.size.width = min(ghostLabel.frame.width, max(0, bounds.maxX - caretFrame.maxX))

    panel.arrangedSubviews.forEach {
      panel.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    guard showPanel, !result.candidates.isEmpty else {
      panel.isHidden = true
      return
    }

    let visible = Array(result.candidates.prefix(8))
    let panelWidth = min(480, max(280, bounds.width - 24))
    for (index, candidate) in visible.enumerated() {
      let row = AutocompleteCandidateRow(
        candidate: candidate,
        selected: index == selectedIndex,
        foreground: foreground,
        background: background
      ) { [weak self] in self?.onCandidateSelected?(index) }
      row.translatesAutoresizingMaskIntoConstraints = false
      row.heightAnchor.constraint(equalToConstant: 30).isActive = true
      panel.addArrangedSubview(row)
    }
    panel.layer?.backgroundColor = background.withAlphaComponent(0.97).cgColor
    panel.layer?.borderColor = foreground.withAlphaComponent(0.18).cgColor
    let panelHeight = CGFloat(visible.count) * 30
    let belowY = caretFrame.minY - panelHeight - 4
    let originY = belowY >= bounds.minY + 4 ? belowY : min(bounds.maxY - panelHeight - 4, caretFrame.maxY + 4)
    panel.frame = NSRect(
      x: min(max(8, caretFrame.minX), max(8, bounds.maxX - panelWidth - 8)),
      y: max(4, originY),
      width: panelWidth,
      height: panelHeight
    )
    panel.isHidden = false
  }
}

@MainActor
private final class AutocompleteCandidateRow: NSButton {
  private let actionClosure: () -> Void

  init(
    candidate: AutocompleteCandidate,
    selected: Bool,
    foreground: NSColor,
    background: NSColor,
    action: @escaping () -> Void
  ) {
    actionClosure = action
    super.init(frame: .zero)
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.backgroundColor = selected
      ? foreground.withAlphaComponent(0.12).cgColor : background.withAlphaComponent(0.01).cgColor
    target = self
    self.action = #selector(activate)

    let kind = NSTextField(labelWithString: Self.label(for: candidate.kind))
    kind.font = .systemFont(ofSize: 10, weight: .medium)
    kind.textColor = foreground.withAlphaComponent(0.5)
    kind.alignment = .center
    kind.translatesAutoresizingMaskIntoConstraints = false
    kind.widthAnchor.constraint(equalToConstant: 62).isActive = true
    let name = NSTextField(labelWithString: candidate.displayText)
    name.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
    name.textColor = foreground
    name.lineBreakMode = .byTruncatingTail
    let description = NSTextField(labelWithString: candidate.description)
    description.font = .systemFont(ofSize: 11)
    description.textColor = foreground.withAlphaComponent(0.58)
    description.alignment = .right
    description.lineBreakMode = .byTruncatingTail
    description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let stack = NSStackView(views: [kind, name, NSView(), description])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
    addSubview(stack)
    stack.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }

  @objc private func activate() { actionClosure() }

  private static func label(for kind: AutocompleteCandidateKind) -> String {
    switch kind {
    case .command: "命令"
    case .subcommand: "子命令"
    case .option: "选项"
    case .argument: "参数"
    case .file: "文件"
    case .folder: "文件夹"
    case .alias: "别名"
    case .snippet: "固定"
    case .learnedCommand: "历史"
    case .readmeCommand: "README"
    case .correction: "修正"
    }
  }
}
