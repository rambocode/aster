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
  /// 候选文字必须与面板底色(主题 surface)配对,而不是跟随系统 `.textColor`:深色终端
  /// 主题下 surface 可能是浅色,系统文字色却解析成白色,导致白字压在浅底上看不清。
  var autocompleteForegroundColor: NSColor { AsterTheme.ink }
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

/// 候选面板的显式状态。
///
/// 这里刻意不用裸 Bool:旧实现里 `receiveInput` 把它置 false、`refreshNow` 又无条件
/// 重算成 true,两处互相覆写,直接导致两个缺陷——`escape` 模式下手动打开的面板一敲键
/// 就被打字关掉(Otty 要求“继续打字来收窄”),`auto` 模式下 Esc 关掉的面板又被下一次
/// 刷新弹回来。可见性现在只在 `refreshNow` 的迁移 switch 里改写,其它路径一律只读。
enum AutocompletePanelState: Equatable {
  case hidden
  /// `origin` 决定 Return 归谁:自动弹出的面板在用户按方向键之前不武装 Return,
  /// 否则终端里最常用的一个键会被系统主动弹出的浮层吞掉。
  case open(origin: Origin, userSelected: Bool)

  enum Origin: Equatable {
    case automatic
    case manual
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

  private(set) var currentResult = AutocompleteResult.empty
  private(set) var panelState: AutocompletePanelState = .hidden
  /// 保留旧名字给外部读取与既有测试,语义不变。
  var panelVisible: Bool { panelState != .hidden }
  /// 用户是否已经用 ↑/↓ 主动选中过某一行(自动弹出的面板据此决定 Return 归属)。
  var hasUserSelection: Bool {
    if case .open(_, true) = panelState { true } else { false }
  }
  private(set) var selectedIndex = 0
  /// 滚动视窗的首行下标。放在控制器而不是 overlay:它是选择状态的一部分,必须能在
  /// 不触发 AppKit 布局的前提下被测试断言。
  private(set) var firstVisibleIndex = 0
  /// 用户在本轮 prompt 内按 Esc 关过面板。作用域刻意是“整条 prompt”而不是“当前
  /// token”:Esc 的语义是“我不要这个下拉”,按 token 清零会让面板在空格后又跳出来,
  /// 等于没关。
  private var panelSuppressedForPrompt = false
  private(set) var promptActive = false
  private(set) var lastSubmittedCommand: String?
  /// Ghostty 的 OSC 与 PTY write 来自不同 callback，C marker 可能抢在最后一个回车的
  /// 主线程投递前到达。仅在“commandStart 已到、但本轮命令尚未提交”时保持一次有界
  /// 接收窗口；拿到换行后立即关闭，运行中的 TUI 按键不会进入 Shell 命令跟踪器。
  private var acceptsLateSubmittedInput = false
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
      acceptsLateSubmittedInput = false
      panelSuppressedForPrompt = false
    case .inputStart:
      // B 明确表示光标已进入可编辑区。A 缺失时仍可从此处开始安全跟踪。
      if !promptActive {
        promptActive = true
        tracker.beginPrompt()
      }
      lastSubmittedCommand = nil
      acceptsLateSubmittedInput = true
      awaitingInputEcho = false
      panelSuppressedForPrompt = false
      scheduleRefresh()
    case .commandStart:
      promptActive = false
      runningCommand = lastSubmittedCommand
      // 正常顺序下提交回调已经给出命令，无需继续接收；只有 nil 才表示 PTY write
      // 仍排在主线程队列中，允许它补齐到第一个换行。
      acceptsLateSubmittedInput = lastSubmittedCommand == nil
      dismiss()
    case .commandFinished(let exitStatus):
      acceptsLateSubmittedInput = false
      finishCommand(exitStatus: exitStatus)
      runningCommand = nil
      completedCommandOutput = nil
      dismiss()
    }
  }

  func receiveInput(_ bytes: ArraySlice<UInt8>) {
    guard promptActive || acceptsLateSubmittedInput else { return }
    let submitted = tracker.receive(Array(bytes))
    if let command = submitted.last {
      lastSubmittedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
      if let lastSubmittedCommand {
        // commandStart 已抢先时补回 runningCommand，后续完成学习仍消费同一条真值。
        if runningCommand == nil { runningCommand = lastSubmittedCommand }
        onCommandSubmitted?(lastSubmittedCommand)
      }
      promptActive = false
      acceptsLateSubmittedInput = false
      dismiss()
      return
    }
    // commandStart 之后只负责吃完已排队的本轮输入；不再显示候选或启动 help probe。
    guard promptActive else { return }
    guard tracker.isReliable else {
      dismiss()
      return
    }
    inlineDismissed = false
    awaitingInputEcho = true
    // 打字**不关闭面板**,只清掉待重算的候选。Otty 的语义是“继续打字来收窄候选”,
    // 旧实现在这里无条件把面板关掉,于是手动打开的面板每敲一个字符就消失一次。
    // 自动弹出的面板要重新解除 Return 的武装;手动打开的保持在列表导航模式。
    if case .open(.automatic, _) = panelState {
      panelState = .open(origin: .automatic, userSelected: false)
    }
    // 候选重算有 debounce，而 PTY 回显会在这段窗口内继续推进终端网格。若保留上一轮
    // ghost，旧后缀会短暂覆盖新输入；先清空可见候选，待新输入回显并重算后再显示。
    clearCandidatesForRefilter()
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
      // Backspace 本身仍交给 Shell；这里只清掉旧候选，输入回调随后按新文本重算。
      // 面板保持打开:Otty 的退格是“清掉 ghost”,不是“关掉下拉”。
      clearCandidatesForRefilter()
      render()
      return false
    }

    if case .open(let origin, let userSelected) = panelState {
      switch key {
      case .up, .down:
        guard !currentResult.candidates.isEmpty else { return true }
        if !userSelected {
          // 自动弹出的面板此前没有选中行,第一个方向键要落在第 0 / 末行本身,
          // 而不是在隐含的第 0 行基础上再移动一格跳过第一条。
          selectedIndex = key == .down ? 0 : currentResult.candidates.count - 1
        } else {
          let delta = key == .down ? 1 : currentResult.candidates.count - 1
          selectedIndex = (selectedIndex + delta) % currentResult.candidates.count
        }
        panelState = .open(origin: origin, userSelected: true)
        updateVisibleWindow()
        render()
        return true
      case .enter:
        // 系统主动弹出、用户还没选过行的面板不吞回车——否则 `auto` 模式下永远无法
        // 直接提交命令。手动打开的面板(Otty 默认的 escape 模式)则立即接受。
        guard userSelected else { return false }
        return acceptCandidate(at: selectedIndex)
      case .tab:
        // 未选中态的 Tab 必须掉到下面的 inline 路径,让 `inlineSuggestionDisplayable`
        // 门控继续生效(zsh-autosuggestions 占据行尾时 Tab 要原样交给 shell)。
        if userSelected { return acceptCandidate(at: selectedIndex) }
      case .escape, .optionEscape:
        panelState = .hidden
        panelSuppressedForPrompt = true
        inlineDismissed = true
        render()
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
    // ghost 不可见但确实有候选时，接受键改为**打开候选面板**而不是放行给 Shell。
    //
    // 这是 zsh-autosuggestions 场景的关键分支：插件把自己的灰色建议画在行尾，回显
    // 校验因此一直不通过，Aster 的 ghost 保持隐藏。旧行为是把 Tab 原样交给 Shell，
    // 于是用户完全看不到 Aster 算出的候选（Shell 只会补第一个词）。打开面板既能
    // 展示候选，又不违反“绝不插入用户没看见的文本”——面板里的每一行都是可见凭据，
    // 真正的插入仍然要用户再按一次键。Aster 没有候选时依旧放行，Shell 自己的
    // 补全（`_docker` 之类）继续可用。
    if acceptsInline, !currentResult.candidates.isEmpty,
      configuration.resolvedAutocompleteCandidatePanel != .disabled
    {
      panelState = .open(origin: .manual, userSelected: true)
      panelSuppressedForPrompt = false
      selectedIndex = 0
      updateVisibleWindow()
      render()
      return true
    }

    if key == .escape, currentResult.ghostText != nil, inlineSuggestionDisplayable {
      inlineDismissed = true
      render()
      return true
    }

    let opensPanel: Bool
    switch configuration.resolvedAutocompleteCandidatePanel {
    case .disabled: opensPanel = false
    // `auto` 模式下 Esc 兼任“再给我看一次”:Esc 关闭后本轮 prompt 的自动弹出被闩锁
    // 挡住,没有这条用户就再也打不开面板了。
    case .automatic, .escape: opensPanel = key == .escape
    case .optionEscape: opensPanel = key == .optionEscape || key == .functionFive
    }
    if opensPanel, !currentResult.candidates.isEmpty {
      panelState = .open(origin: .manual, userSelected: true)
      panelSuppressedForPrompt = false
      selectedIndex = 0
      updateVisibleWindow()
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
    // Otty:inline suggestion 与候选面板同时关闭 = 整个功能停用,连内置规格库都不
    // 查询。本机学习是另一个开关,命令记录与纠错不受这里影响。
    guard configuration.resolvedAutocompleteInlineSuggestion
      || configuration.resolvedAutocompleteCandidatePanel != .disabled
    else {
      dismiss()
      return
    }
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
        score: Double.greatestFiniteMagnitude,
        replacement: .fullLine
      )
      result = AutocompleteResult(
        candidates: [candidate] + result.candidates.filter { $0.insertText != correction },
        ghostText: String(correction.dropFirst(tracker.line.count)),
        replacementStart: 0
      )
    }
    currentResult = result
    selectedIndex = min(selectedIndex, max(0, result.candidates.count - 1))
    // 面板可见性的唯一迁移点。旧实现在这里无条件重算、又在 receiveInput 里置 false,
    // 两处互相覆写;所有其它路径现在只读 `panelState`。
    switch (panelState, configuration.resolvedAutocompleteCandidatePanel) {
    case (_, .disabled):
      panelState = .hidden
    case (.hidden, .automatic):
      if !panelSuppressedForPrompt, result.candidates.count >= 2 {
        panelState = .open(origin: .automatic, userSelected: false)
      }
    case (.hidden, _):
      break
    case (.open(.automatic, _), .automatic):
      if result.candidates.count < 2 { panelState = .hidden }
    case (.open(.automatic, _), _):
      // 配置从 auto 改掉时,收起此前自动弹出的面板。
      panelState = .hidden
    case (.open(.manual, let selected), _):
      panelState = result.candidates.isEmpty
        ? .hidden : .open(origin: .manual, userSelected: selected)
    }
    updateVisibleWindow()
    render()
    scheduleHelpProbeIfNeeded(configuration: configuration)
  }

  /// 让 8 行视窗以最小移动跟上选中项。
  ///
  /// 三步钳位同时覆盖了 ↑/↓ 的循环:末行按 ↓ 回到 0 时第一步把首行拉到 0,首行按 ↑
  /// 跳到末行时第二步把首行推到 count-8,因此不需要为 wrap 写特例分支。
  private func updateVisibleWindow() {
    firstVisibleIndex = Self.clampedFirstVisibleIndex(
      current: firstVisibleIndex,
      selected: selectedIndex,
      count: currentResult.candidates.count,
      visibleRows: TerminalAutocompleteOverlayView.maximumVisibleRows
    )
  }

  static func clampedFirstVisibleIndex(
    current: Int, selected: Int, count: Int, visibleRows: Int
  ) -> Int {
    guard count > visibleRows else { return 0 }
    var first = min(current, selected)
    first = max(first, selected - (visibleRows - 1))
    return min(max(first, 0), count - visibleRows)
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
      let target = service.helpProbeTarget(for: tracker.line),
      probedCommands.insert(target.cacheKey).inserted
    else { return }
    helpProbeTask?.cancel()
    helpProbeTask = Task { @MainActor [weak self] in
      guard let spec = await AutocompleteHelpProbe.probe(
        command: target.command, subcommandPath: target.subcommandPath),
        !Task.isCancelled, let self
      else { return }
      do {
        try service.installLocalSpec(
          spec, command: target.command, subcommandPath: target.subcommandPath)
        refreshNow()
      } catch {
        // 本地规格写入失败只禁用本轮探测结果；补全仍可继续使用内置规格和历史。
      }
    }
  }

  @discardableResult
  private func acceptCandidate(at index: Int) -> Bool {
    guard currentResult.candidates.indices.contains(index), let terminalView else { return false }
    // 后缀由候选自带的替换范围唯一决定,与 ghost 的计算共用同一实现。过去这里独立
    // 推断一次“整行还是 token”,与引擎的判定可能不一致。
    guard let suffix = currentResult.candidates[index].appendableSuffix(from: tracker.line)
    else { return false }
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

  /// 彻底收起补全:关面板、清候选、取消待执行的刷新。
  private func dismiss() {
    refreshTask?.cancel()
    panelState = .hidden
    currentResult = .empty
    selectedIndex = 0
    firstVisibleIndex = 0
    render()
  }

  /// 只清掉待重算的候选,**保留面板状态**。打字与退格走这条路径,面板因此能按新前缀
  /// 收窄而不是消失。debounce 窗口内候选为空,`render` 会暂时隐藏面板视图、
  /// `acceptCandidate` 因索引不存在返回 false,回车照常交给 shell。
  private func clearCandidatesForRefilter() {
    currentResult = .empty
    selectedIndex = 0
    firstVisibleIndex = 0
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
      showsSelection: hasUserSelection,
      firstVisibleIndex: firstVisibleIndex,
      caretFrame: terminalView.autocompleteCaretFrame,
      font: terminalView.autocompleteFont,
      foreground: terminalView.autocompleteForegroundColor,
      // 自定义主题未来仍可能提供透明原生画布；候选浮层没有窗口材质，遇到透明色时
      // 必须回退到主题 surface，避免候选文字直接压在终端内容上。
      background: terminalView.autocompleteBackgroundColor.alphaComponent > 0.01
        ? terminalView.autocompleteBackgroundColor : AsterTheme.panel,
      accent: AsterTheme.accent
    )
  }
}

/// 轻量 AppKit overlay：ghost label 不接收鼠标，候选面板最多显示 8 行并允许点击。
/// 布局以终端 adapter 的 caretFrame 为锚点，优先显示在光标下方，空间不足时翻到上方。
@MainActor
final class TerminalAutocompleteOverlayView: NSView {
  /// 面板宽度的兜底区间。下限保证短候选不至于窄成一条，上限避免长路径把浮层
  /// 拉到整屏宽——超出的部分由行内文本截断处理。
  static let minimumPanelWidth: CGFloat = 220
  static let maximumPanelWidth: CGFloat = 560
  /// 同时可见的候选行数上限。超出部分由滚动视窗承载。
  static let maximumVisibleRows = 8
  /// 描述侧栏的固定宽度。刻意用定值而不是按列表列比例:比例式宽度会让侧栏随最长
  /// 命令忽宽忽窄,用户每敲一个字符整个浮层就换一次尺寸。
  static let descriptionSidebarWidth: CGFloat = 220

  var onCandidateSelected: ((Int) -> Void)?
  private let ghostLabel = NSTextField(labelWithString: "")
  /// 浮层容器：圆角、描边、投影和背景都挂在它上面。
  /// `panel` 的语义因此收窄为「候选行列表列」，布局验收锁定的行宽不变量继续成立。
  let panelContainer = NSView()
  /// 候选行列表列。internal 而不是 private：布局验收要读它的 frame 与行视图，
  /// 靠截图人眼比对既不稳定也无法在 CI 上跑。
  let panel = NSStackView()
  /// 描述侧栏：只呈现当前选中项的完整描述，对齐 Otty 的 side column。
  let descriptionSidebar = AutocompleteDescriptionSidebarView()
  /// 候选超过一屏时的细滚动条。
  let scrollThumb = NSView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    ghostLabel.isHidden = true
    ghostLabel.lineBreakMode = .byClipping
    // ghost 必须保持为第一个 subview：布局验收用 `subviews.first` 定位它。
    addSubview(ghostLabel)
    panel.orientation = .vertical
    panel.alignment = .width
    panel.spacing = 0
    panel.wantsLayer = true
    panelContainer.wantsLayer = true
    panelContainer.layer?.cornerRadius = 8
    panelContainer.layer?.borderWidth = 1
    panelContainer.isHidden = true
    scrollThumb.wantsLayer = true
    scrollThumb.layer?.cornerRadius = 1.5
    scrollThumb.isHidden = true
    panelContainer.addSubview(panel)
    panelContainer.addSubview(descriptionSidebar)
    panelContainer.addSubview(scrollThumb)
    addSubview(panelContainer)
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // 判容器而不是列表列：否则点在侧栏上会穿透到终端并起选区。
    guard !panelContainer.isHidden, panelContainer.frame.contains(point) else { return nil }
    return super.hitTest(point)
  }

  func render(
    result: AutocompleteResult,
    showInline: Bool,
    showPanel: Bool,
    selectedIndex: Int,
    showsSelection: Bool = true,
    firstVisibleIndex: Int = 0,
    caretFrame: NSRect,
    font: NSFont,
    foreground: NSColor,
    background: NSColor,
    accent: NSColor
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
      panelContainer.isHidden = true
      return
    }

    let rows = Self.maximumVisibleRows
    let total = result.candidates.count
    let first = min(max(0, firstVisibleIndex), max(0, total - min(total, rows)))
    let visible = Array(result.candidates[first..<min(total, first + rows)])

    // 宽度贴合最长的一行，而不是写死一个几乎总是撑满终端的值：候选浮层压在终端
    // 内容上，多占的每一像素都是遮挡。上下限只用来兜住极短和极长的候选。
    let hasDescription = visible.contains { !$0.description.isEmpty }
    let nameWidth = visible.reduce(CGFloat(0)) { widest, candidate in
      max(widest, AutocompleteCandidateRow.contentWidth(for: candidate, includingDescription: false))
    }
    let inlineWidth = visible.reduce(CGFloat(0)) { widest, candidate in
      max(widest, AutocompleteCandidateRow.contentWidth(for: candidate))
    }
    let available = max(0, bounds.width - 16)
    // 侧栏装不下时先压缩列表列，压到下限仍不够就整个放弃侧栏、退回行内描述。
    var sidebarWidth: CGFloat = hasDescription ? Self.descriptionSidebarWidth : 0
    var listWidth = min(max(nameWidth, Self.minimumPanelWidth), Self.maximumPanelWidth)
      .rounded(.up)
    if sidebarWidth > 0, listWidth + sidebarWidth > available {
      listWidth = max(Self.minimumPanelWidth, available - sidebarWidth).rounded(.up)
      if listWidth + sidebarWidth > available {
        sidebarWidth = 0
        listWidth = min(
          min(max(inlineWidth, Self.minimumPanelWidth), Self.maximumPanelWidth).rounded(.up),
          max(Self.minimumPanelWidth, available))
      }
    }
    if sidebarWidth == 0 {
      // 向上取整到整点：小数宽度会被 Auto Layout 各自对齐到设备像素，行宽和面板宽
      // 因此差出零点几个点，边框内侧露出一条毛边。
      listWidth = min(max(inlineWidth, Self.minimumPanelWidth), Self.maximumPanelWidth)
        .rounded(.up)
    }
    let showsInlineDescription = sidebarWidth == 0

    for (offset, candidate) in visible.enumerated() {
      // 点击必须回传**全集索引**：切片内偏移会在滚动后接受错误的候选。
      let index = first + offset
      let row = AutocompleteCandidateRow(
        candidate: candidate,
        selected: showsSelection && index == selectedIndex,
        showsDescription: showsInlineDescription,
        foreground: foreground,
        background: background,
        accent: accent
      ) { [weak self] in self?.onCandidateSelected?(index) }
      row.translatesAutoresizingMaskIntoConstraints = false
      // 行宽必须显式钉到列表列宽度：竖向 NSStackView 的 `.width` 对齐只保证各行彼此
      // 等宽，不保证等于面板宽度，剩下的空间会被摆到一侧——那正是候选内容整体
      // 靠右、图标位置逐行漂移的直接原因。
      NSLayoutConstraint.activate([
        row.heightAnchor.constraint(equalToConstant: AutocompleteCandidateRow.height),
        row.widthAnchor.constraint(equalToConstant: listWidth),
      ])
      panel.addArrangedSubview(row)
    }

    panelContainer.layer?.backgroundColor = background.withAlphaComponent(0.97).cgColor
    panelContainer.layer?.borderColor = foreground.withAlphaComponent(0.18).cgColor
    // 浮层浮在终端文字之上，只靠 1px 描边分不出层次；投影让它明确「盖住」而不是
    // 「混进」终端内容。阴影色跟随前景色，深浅主题下都不会变成灰雾。
    panelContainer.shadow = NSShadow()
    panelContainer.layer?.shadowColor = foreground.withAlphaComponent(0.35).cgColor
    panelContainer.layer?.shadowOpacity = 1
    panelContainer.layer?.shadowRadius = 12
    panelContainer.layer?.shadowOffset = CGSize(width: 0, height: -2)
    panelContainer.layer?.masksToBounds = false

    let panelHeight = CGFloat(visible.count) * AutocompleteCandidateRow.height
    let panelWidth = listWidth + sidebarWidth
    let belowY = caretFrame.minY - panelHeight - 4
    let originY = belowY >= bounds.minY + 4
      ? belowY : min(bounds.maxY - panelHeight - 4, caretFrame.maxY + 4)
    panelContainer.frame = NSRect(
      x: min(max(8, caretFrame.minX), max(8, bounds.maxX - panelWidth - 8)),
      y: max(4, originY),
      width: panelWidth,
      height: panelHeight
    )
    panel.frame = NSRect(x: 0, y: 0, width: listWidth, height: panelHeight)

    if sidebarWidth > 0 {
      descriptionSidebar.isHidden = false
      descriptionSidebar.frame = NSRect(
        x: listWidth, y: 0, width: sidebarWidth, height: panelHeight)
      let selected = result.candidates.indices.contains(selectedIndex)
        ? result.candidates[selectedIndex] : visible.first
      descriptionSidebar.update(
        candidate: selected, foreground: foreground, accent: accent)
    } else {
      descriptionSidebar.isHidden = true
    }

    // 滚动条只在超出一屏时出现：细条比 NSScrollView 便宜得多，也不会引入自己的
    // 裁剪与 tracking 去破坏「行宽 == 列表列宽」这条被测试锁定的不变量。
    if total > rows {
      let thumbHeight = max(24, panelHeight * CGFloat(rows) / CGFloat(total))
      let travel = panelHeight - thumbHeight
      let progress = CGFloat(first) / CGFloat(total - rows)
      scrollThumb.isHidden = false
      scrollThumb.layer?.backgroundColor = foreground.withAlphaComponent(0.28).cgColor
      scrollThumb.frame = NSRect(
        x: listWidth - 5, y: travel * (1 - progress), width: 3, height: thumbHeight)
    } else {
      scrollThumb.isHidden = true
    }
    panelContainer.isHidden = false
  }
}

/// 候选面板的描述侧栏：只呈现「当前选中项」的完整描述，对齐 Otty 的 side column。
///
/// 行内描述会被 `byTruncatingTail` 截断，Fig 规格里稍长一点的说明基本全丢；侧栏放在
/// 右列而不是底部条，是因为面板已有「下方放不下就翻到上方」的翻转逻辑，底部条会改变
/// 面板高度从而与翻转互相干扰，还会把行列表推离光标。
@MainActor
final class AutocompleteDescriptionSidebarView: NSView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let bodyLabel = NSTextField(labelWithString: "")
  private let separator = NSView()

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    titleLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    bodyLabel.font = .systemFont(ofSize: 11)
    bodyLabel.lineBreakMode = .byWordWrapping
    bodyLabel.usesSingleLineMode = false
    bodyLabel.cell?.wraps = true
    separator.wantsLayer = true
    for view in [separator, titleLabel, bodyLabel] as [NSView] { addSubview(view) }
  }

  required init?(coder: NSCoder) { nil }

  /// 侧栏不参与鼠标交互：吞掉点击，避免穿透到终端起选区。
  override func mouseDown(with event: NSEvent) {}

  func update(candidate: AutocompleteCandidate?, foreground: NSColor, accent: NSColor) {
    titleLabel.stringValue = candidate?.displayText ?? ""
    titleLabel.textColor = foreground.withAlphaComponent(0.92)
    bodyLabel.stringValue = candidate?.description ?? ""
    bodyLabel.textColor = foreground.withAlphaComponent(0.62)
    // 底色由前景色派生：固定灰在浅色主题里会发脏，跟随前景则永远只是「比列表列
    // 略深/略浅一点」。
    layer?.backgroundColor = foreground.withAlphaComponent(0.045).cgColor
    separator.layer?.backgroundColor = foreground.withAlphaComponent(0.12).cgColor
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  override func layout() {
    super.layout()
    let inset: CGFloat = 10
    separator.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
    let width = max(0, bounds.width - inset * 2)
    titleLabel.frame = NSRect(
      x: inset, y: bounds.height - 8 - 15, width: width, height: 15)
    bodyLabel.preferredMaxLayoutWidth = width
    let bodyHeight = max(0, titleLabel.frame.minY - 4 - 8)
    bodyLabel.frame = NSRect(x: inset, y: 8, width: width, height: bodyHeight)
    bodyLabel.cell?.truncatesLastVisibleLine = true
  }
}

@MainActor
final class AutocompleteCandidateRow: NSButton {
  static let height: CGFloat = 26
  private static let iconWidth: CGFloat = 16
  private static let horizontalInset: CGFloat = 10
  private static let spacing: CGFloat = 8
  private static let nameFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
  private static let descriptionFont = NSFont.systemFont(ofSize: 11)

  private let actionClosure: () -> Void
  /// 选中行的前导标记条。测试据此确认「有确定性的定位提示，但不是整行反白」。
  private(set) var selectionBar: NSView?

  init(
    candidate: AutocompleteCandidate,
    selected: Bool,
    showsDescription: Bool = true,
    foreground: NSColor,
    background: NSColor,
    accent: NSColor,
    action: @escaping () -> Void
  ) {
    actionClosure = action
    super.init(frame: .zero)
    title = ""
    isBordered = false
    wantsLayer = true
    // 旧结论保留：候选行只有 26pt 高，整行**不透明反白**会在终端上糊成一条亮带，
    // 反而看不清选中的是哪条命令。这里改用 accent 的低透明度淡染 + 一根前导竖条：
    // 淡染由 accent 与终端底色混合而来，深浅主题下都只是「染了一层」而不是换掉底色；
    // 竖条在任意底色上都给出确定性的定位提示。
    layer?.backgroundColor = selected
      ? accent.withAlphaComponent(0.15).cgColor
      : background.withAlphaComponent(0.01).cgColor
    target = self
    self.action = #selector(activate)

    if selected {
      let bar = NSView()
      bar.wantsLayer = true
      bar.layer?.backgroundColor = accent.cgColor
      bar.layer?.cornerRadius = 1.25
      bar.translatesAutoresizingMaskIntoConstraints = false
      addSubview(bar)
      NSLayoutConstraint.activate([
        bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
        bar.widthAnchor.constraint(equalToConstant: 2.5),
        bar.topAnchor.constraint(equalTo: topAnchor, constant: 3),
        bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
      ])
      selectionBar = bar
    }

    let icon = NSImageView()
    icon.image = Self.icon(for: candidate.kind)
    icon.contentTintColor = selected ? accent : foreground.withAlphaComponent(0.55)
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: Self.iconWidth).isActive = true
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let name = NSTextField(labelWithString: candidate.displayText)
    name.font = Self.nameFont
    name.textColor = selected ? accent : foreground
    name.lineBreakMode = .byTruncatingMiddle
    name.alignment = .left
    name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    // 尾部弹性视图吸收整行的剩余宽度，前面的图标和命令因此始终顶在左边。有侧栏时
    // 它是一块透明 spacer，没有侧栏时它就是行内描述——两种形态下行内元素的位置完全
    // 一致。这正是旧实现用空 `NSView()` 加 NSStackView 撑不出来的效果，那里每行都按
    // 自身内容宽度重新排，标签位置逐行漂移。
    let trailing: NSView
    if showsDescription {
      let description = NSTextField(labelWithString: candidate.description)
      description.font = Self.descriptionFont
      description.textColor = foreground.withAlphaComponent(selected ? 0.75 : 0.5)
      description.lineBreakMode = .byTruncatingTail
      description.alignment = .left
      trailing = description
    } else {
      trailing = NSView()
    }
    trailing.setContentHuggingPriority(.init(1), for: .horizontal)
    trailing.setContentCompressionResistancePriority(.init(1), for: .horizontal)

    // 不用 NSStackView：它的分布策略会把整组元素按内容宽度推向一侧，正是旧实现里
    // 「类别标签逐行漂移」的来源。这里逐条钉死约束，图标和命令永远从左边同一个
    // x 开始，尾部视图吃掉剩余宽度。
    for view in [icon, name, trailing] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    let inset = Self.horizontalInset
    let spacing = Self.spacing
    let trailingLeading = trailing.leadingAnchor.constraint(
      equalTo: name.trailingAnchor, constant: spacing)
    trailingLeading.priority = .defaultHigh
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: spacing),
      name.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
      trailingLeading,
      trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailing.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
    ])
  }

  required init?(coder: NSCoder) { nil }

  @objc private func activate() { actionClosure() }

  /// 单行在不截断时需要的宽度，供面板计算自适应宽度。
  /// `includingDescription` 为 false 时算的是「只有图标 + 命令名」的宽度，用于
  /// 描述交给侧栏承载的布局。
  static func contentWidth(
    for candidate: AutocompleteCandidate, includingDescription: Bool = true
  ) -> CGFloat {
    let name = (candidate.displayText as NSString)
      .size(withAttributes: [.font: nameFont]).width
    let description = !includingDescription || candidate.description.isEmpty
      ? 0
      : (candidate.description as NSString)
        .size(withAttributes: [.font: descriptionFont]).width + spacing
    return horizontalInset * 2 + iconWidth + spacing + name + description
  }

  /// 候选类别用图标表达，不再占一列中文标签：图标一眼可辨，也把宽度还给命令本身。
  private static func icon(for kind: AutocompleteCandidateKind) -> NSImage? {
    let symbol = switch kind {
    case .command: "terminal"
    case .subcommand: "chevron.forward"
    case .option: "switch.2"
    case .argument: "textformat"
    case .dynamicArgument: "arrow.triangle.branch"
    case .file: "doc"
    case .folder: "folder"
    case .alias: "link"
    case .snippet: "pin"
    case .learnedCommand: "clock.arrow.circlepath"
    case .readmeCommand: "book"
    case .correction: "wand.and.stars"
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return image?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
  }
}
