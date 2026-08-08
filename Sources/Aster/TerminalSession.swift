import AppKit
import AsterCore
import Combine
import Darwin
import Foundation
import SwiftTerm

/// 集中托管已经从工作区移除、但底层进程尚未完成 `waitpid` 的终端视图。
///
/// 托管器由进程级单例强持有，关闭 Pane 后不会随 `TerminalSession` 一起释放。它先发送
/// `SIGHUP`，750ms 后仍在运行则升级为 `SIGKILL`，并持续保留 View 直到 SwiftTerm 的
/// monitor 把 `process.running` 更新为 `false`，避免后台进程或僵尸泄漏。
@MainActor
private final class TerminalRetirementCoordinator {
  static let shared = TerminalRetirementCoordinator()

  private var views: [ObjectIdentifier: LocalProcessTerminalView] = [:]

  func retire(_ view: LocalProcessTerminalView, immediately: Bool) {
    let identifier = ObjectIdentifier(view)
    let processIdentifier = view.process.shellPid
    guard view.process.running, processIdentifier > 0 else { return }
    views[identifier] = view

    if immediately {
      if Darwin.kill(-processIdentifier, SIGKILL) != 0 {
        _ = Darwin.kill(processIdentifier, SIGKILL)
      }
    } else if Darwin.kill(-processIdentifier, SIGHUP) != 0 {
      _ = Darwin.kill(processIdentifier, SIGTERM)
    }

    // `self` 和 `view` 均被任务强持有；即使原 Session/Pane 已释放，升级信号和
    // SwiftTerm monitor 仍能完成。SIGKILL 后轮询的唯一目的，是等待 monitor 回收。
    Task { @MainActor [self, view] in
      if !immediately {
        try? await Task.sleep(for: .milliseconds(750))
      }
      guard views[identifier] === view else { return }
      if view.process.running, view.process.shellPid == processIdentifier {
        if Darwin.kill(-processIdentifier, SIGKILL) != 0 {
          _ = Darwin.kill(processIdentifier, SIGKILL)
        }
      }

      for _ in 0..<120 {
        guard views[identifier] === view, view.process.running else { break }
        try? await Task.sleep(for: .milliseconds(250))
      }
      views.removeValue(forKey: identifier)
    }
  }

  func complete(_ source: TerminalView) {
    guard let view = source as? LocalProcessTerminalView else { return }
    views.removeValue(forKey: ObjectIdentifier(view))
  }
}

/// 终端 Outline 的只读投影。命令正文只从当前内存中的网格读取，不持久化；当对应
/// scrollback 已被裁剪时不生成条目，避免跳转到错误位置。
struct TerminalCommandOutlineEntry: Equatable {
  let title: String
  let absoluteRow: Int
  let exitStatus: Int?
  let finishedAt: Date?
}

/// 全局搜索使用的终端文本快照。`firstAbsoluteRow` 保留 SwiftTerm 的单调行号，搜索
/// 结果可在输出继续增长后尽可能稳定地跳回原位置。
struct TerminalTextSnapshot: Equatable {
  let firstAbsoluteRow: Int
  let lines: [String]
}

/// SwiftTerm 视图子类：实现 Otty 的 `Default` / `Always` 光标优先级。
/// `Default` 只给出初始状态，之后接受 DECSCUSR / DEC mode 12；`Always` 把用户设置
/// 作为最终真值，并在 SwiftTerm 回调返回后纠正程序端写入。
final class AsterTerminalView: LocalProcessTerminalView {
  /// 观察 SwiftTerm 网格尺寸真正变化的测试 seam。生产环境保持 nil；测试用它区分
  /// 一次合法终态 reflow 与 Panel 过渡导致的重复 resize，不保存终端内容或尺寸历史。
  var onGridSizeChange: ((Int, Int) -> Void)?
  /// SwiftTerm 在 macOS 的标题回调存在缺失和顺序差异；此回调按 PTY 原始顺序校正。
  var onObservedTitleUpdate: ((Int, String) -> Void)?
  /// 所有链接打开请求必须先进入 Aster 的解析与授权层，禁止调用 SwiftTerm 默认的
  /// `NSWorkspace.open` 路径绕过 scheme、可执行文件和特殊文件检查。
  var onRequestOpenTarget: ((String, DetectedTargetSource) -> Void)?
  /// Hint Mode 的复制动作需要规范化 URL 或相对路径，但不能触发文件打开和权限确认。
  var onResolveHintCopyTarget: ((String, DetectedTargetSource) -> String?)?
  /// Read-only 拒绝用户输入时只发出一次即时反馈；测试可替换该回调避免系统声音。
  var onInputRejected: () -> Void = { NSSound.beep() }
  /// SwiftTerm 自动生成的 DA/DSR 等协议响应必须穿过 Read-only 锁。该观察 seam 只用于
  /// 验证协议回包没有被误当作用户输入，生产路径默认不保存回包内容。
  var onTerminalProtocolOutput: ((ArraySlice<UInt8>) -> Void)?
  /// Vi 的 `/`、`?` 和 `n`/`N` 复用现有查找栏与缓冲区搜索，不复制第二套搜索实现。
  var onRequestViSearch: ((TerminalViSearchDirection) -> Void)?
  var onRepeatViSearch: ((Bool) -> Void)?
  /// 进入本地模式时清除 Autocomplete ghost/panel，避免视觉上仍暗示可以把候选写入 PTY。
  var onPaneModeActivated: (() -> Void)?
  private var titleStackObserver = TerminalTitleStackObserver()
  /// 必须先于 SwiftTerm parser 处理原始 PTY 字节；handler 层限长时组件已经缓存完整 OSC。
  private var oscStreamLimiter = TerminalOSCStreamLimiter()
  private var didForwardLinkInCurrentMouseUp = false
  private var currentLinkClickEvent: NSEvent?
  /// 普通文字链接的运行时检测策略；OSC 8 由 SwiftTerm 显式 payload 路径处理。
  var linkSchemePolicy: LinkSchemePolicy = .all
  /// 复制与粘贴偏好在 `TerminalSession.apply` 中实时下发，已有 Pane 无需重启。
  var copyOnSelect = false
  var trimTrailingSpacesOnCopy = false
  var clearSelectionOnCopy = false
  /// Otty 默认由 Shift+Arrow 驱动原生选区；关闭时菜单快捷键失效，事件回到 TUI。
  var shiftArrowSelectionEnabled = true
  var pasteProtectionEnabled = true
  var pasteBracketedSafe = true
  /// Composer 在对应 Agent 批次接入；存在回调时“粘贴并在 Composer 中继续”可用。
  var onPasteIntoComposer: ((String) -> Void)?
  /// Send to Chat 由工作区模型负责清理和预算；终端视图只提供当前原生选区入口。
  var onSendSelectionToChat: (() -> Void)?
  var onConfirmPaste: @MainActor (PasteAnalysis) -> Bool =
    AsterTerminalView.presentPasteConfirmation
  /// PTY termios 变化没有独立通知；输出到达和用户输入发送前都触发一次同步，既让
  /// 密码提示出现时立即保护，也保证首个按键写入 PTY 前已完成最终检查。
  var onTerminalIO: (() -> Void)?
  /// 观察终端编码后即将写入 PTY 的输入；功能测试用它证明原生选择不会泄漏鼠标报告。
  /// 回调只接收瞬时字节且不持久化，生产路径默认 nil。
  var onEncodedInput: ((ArraySlice<UInt8>) -> Void)?
  /// OSC 133 命令状态的领域快照。只发布位置与退出码，不包含用户命令文本。
  var onShellIntegrationStateChange: ((ShellCommandTimeline) -> Void)?
  /// Autocomplete 使用独立回调，避免覆盖测试或其它功能对原始输入的观察。
  var onAutocompleteInput: ((ArraySlice<UInt8>) -> Void)?
  var onAutocompleteOutput: ((ArraySlice<UInt8>) -> Void)?
  /// SwiftTerm 解析完成后的光标行可见文本；等待输入检测不得读取原始 OSC/CSI 字节。
  var onTerminalOutputActivity: ((String) -> Void)?
  var onTerminalUserInput: (() -> Void)?
  var onShellIntegrationEvent: ((ShellIntegrationEvent) -> Void)?
  var onShellAliases: (([String]) -> Void)?
  var onAutocompleteKeyDown: ((NSEvent) -> Bool)?
  /// 进度与通知观察器只镜像状态，不覆盖 SwiftTerm 自己的 OSC 9;4 顶部进度条。
  var onTerminalProgress: ((TerminalProgressState) -> Void)?
  var onTerminalNotification: ((TerminalNotification) -> Void)?
  var onTerminalBadgeDirective: ((TerminalBadgeDirective) -> Void)?
  var onAgentTerminalDirective: ((AgentTerminalDirective) -> Void)?
  /// Kitty capability query 必须直接回到 PTY，不能经过用户输入和补全跟踪器。
  var onTerminalProtocolResponse: ((String) -> Void)?
  var terminalBellEnabled = true
  var titleShellControlled = true
  var terminalBellHandler: () -> Void = { NSSound.beep() }
  private(set) var shellCommandTimeline = ShellCommandTimeline()
  private var shellNavigationAbsoluteRow: Int?
  private var shellIntegrationHandlerInstalled = false
  private var activityHandlersInstalled = false
  private var titleHandlersInstalled = false
  private var kittyNotificationAssembler = KittyNotificationAssembler()
  private var paneModeState = TerminalPaneModeState()
  private var viEngine: TerminalViEngine?
  private var viScrollInvariantLowerBound: Int?
  private var viUsesAlternateBuffer: Bool?
  private var hintTargets: [HintTarget] = []
  private var hintMatcher = TerminalHintMatcher(labels: [])
  private var showsViKeyHints = true
  private var isApplyingModeSelection = false
  /// `TerminalDelegate.send` 与用户输入最终都会进入 `send(source: TerminalView, ...)`。
  /// 仅在 SwiftTerm 自己生成协议响应时置位，避免 Read-only 把协议握手一起截断。
  private var isForwardingTerminalProtocolResponse = false
  private lazy var paneModeHUD = TerminalPaneModeHUD(frame: bounds)

  private struct HintTarget {
    let link: Terminal.VisibleLink
    let label: String
    let source: DetectedTargetSource
  }

  var navigationMode: TerminalNavigationMode { paneModeState.navigationMode }
  var isReadOnly: Bool { paneModeState.readOnly }
  var viCursor: TerminalBufferPoint? { viEngine?.cursor }
  var hintTargetCount: Int { hintTargets.count }

  /// 用户配置的光标形状；nil 表示配置尚未下发，此时保持 SwiftTerm 默认行为。
  var preferredCursorStyle: SwiftTerm.CursorStyle? {
    didSet { applyEffectiveCursorStyle() }
  }
  private var programCursorStyle: SwiftTerm.CursorStyle?
  /// 窗口是否持有键盘焦点。非活动窗口停止光标闪烁（形状不变），与系统终端一致：
  /// 同屏多个窗口时只有正在输入的那个在闪。SwiftTerm 的 `caretView.focused` 只切换
  /// 实心/空心，闪烁完全由 `CursorStyle` 的 blink 变体决定，所以必须换样式。
  private var isWindowActive = true

  /// 实际下发给 SwiftTerm 的样式：窗口失焦时取同形状的不闪烁变体。
  private var effectiveCursorStyle: SwiftTerm.CursorStyle? {
    guard let style = preferredCursorStyle ?? programCursorStyle else { return nil }
    return isWindowActive ? style : style.nonBlinking
  }

  func configureCursor(initialStyle: SwiftTerm.CursorStyle, pinsProgramControl: Bool) {
    programCursorStyle = initialStyle
    preferredCursorStyle = pinsProgramControl ? initialStyle : nil
    applyEffectiveCursorStyle()
  }

  func setWindowActive(_ active: Bool) {
    guard isWindowActive != active else { return }
    isWindowActive = active
    applyEffectiveCursorStyle()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    setWindowActive(window?.isKeyWindow ?? true)
  }

  override func layout() {
    super.layout()
    if paneModeHUD.superview === self {
      paneModeHUD.frame = bounds
      updatePaneModeHUD()
    }
  }

  /// SwiftTerm 的像素尺寸变化经 `setFrameSize` 计算网格并调用它自己的
  /// `TerminalViewDelegate`，不会进入下面接收显式 `resize(cols:rows:)` 的重载。
  /// 在这里比较前后网格，测试才能准确捕获 Panel 布局产生的真实 reflow。
  override func setFrameSize(_ newSize: NSSize) {
    let terminal = getTerminal()
    let previousSize = (columns: terminal.cols, rows: terminal.rows)
    super.setFrameSize(newSize)
    let currentSize = (columns: terminal.cols, rows: terminal.rows)
    guard currentSize != previousSize else { return }
    onGridSizeChange?(currentSize.columns, currentSize.rows)
  }

  override func sizeChanged(source: Terminal) {
    super.sizeChanged(source: source)
    onGridSizeChange?(source.cols, source.rows)
    switch paneModeState.navigationMode {
    case .normal:
      break
    case .hint:
      // Reflow 会改变缓存目标的 bufferRow/range；旧标签不能继续打开错误单元格。
      leaveHintMode()
    case .vi:
      // Vi 端点同样绑定旧网格。重排后没有无损映射，安全退出并清除旧选区。
      leaveViMode(clearSelection: true)
    }
  }

  override func scrolled(source terminal: Terminal, yDisp: Int) {
    super.scrolled(source: terminal, yDisp: yDisp)
    if paneModeState.navigationMode == .hint { leaveHintMode() }
    updatePaneModeHUD()
  }

  override func keyDown(with event: NSEvent) {
    if paneModeState.navigationMode != .normal {
      handlePaneModeKeyDown(event)
      return
    }
    // Read-only 必须在 Autocomplete 和提示符删除逻辑之前生效，否则本地控制器可能先
    // 改写建议状态。让 SwiftTerm 正常编码按键，再由统一 send gate 拒绝并反馈一次。
    if paneModeState.readOnly {
      super.keyDown(with: event)
      return
    }
    if handleBidirectionalArrow(event) { return }
    if onAutocompleteKeyDown?(event) == true { return }
    // macOS keyCode 51 is the backward Delete/Backspace key. Only consume it when OSC 133
    // proves the selection belongs to the current editable prompt; otherwise preserve TUI input.
    if event.keyCode == 51, deletePromptSelectionIfSafe() { return }
    super.keyDown(with: event)
  }

  /// Shell 行编辑器只理解逻辑 Left/Right。隐式 BiDi 开启时，根据当前逻辑光标在
  /// UAX #9 视觉映射中的邻居交换方向键，使单步移动与屏幕上的左右方向一致。
  /// Alternate screen 和增强键盘协议交给应用自行布局，配合 BDSM mode 8 避免双重处理。
  private func handleBidirectionalArrow(_ event: NSEvent) -> Bool {
    guard bidirectionalTextEnabled,
      event.keyCode == 123 || event.keyCode == 124,
      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    else { return false }
    let terminal = getTerminal()
    guard !terminal.explicitBidirectionalMode,
      TerminalInputPolicy.usesNaturalTextEditing(
        isAlternateScreen: terminal.isCurrentBufferAlternate,
        hasEnhancedKeyboardProtocol: !terminal.keyboardEnhancementFlags.isEmpty
      )
    else { return false }

    let cursor = terminal.activeBufferCursorPosition
    let visualOffset = event.keyCode == 123 ? -1 : 1
    let target = logicalColumn(
      visuallyAdjacentToLogicalColumn: cursor.col,
      offset: visualOffset,
      bufferRow: cursor.row
    )
    let shouldSwap = (visualOffset < 0 && target > cursor.col)
      || (visualOffset > 0 && target < cursor.col)
    guard shouldSwap, let swapped = event.replacingArrowKeyCode(event.keyCode == 123 ? 124 : 123)
    else { return false }
    super.keyDown(with: swapped)
    return true
  }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    onTerminalIO?()
    // 先让 SwiftTerm 完成渲染和内部标题栈操作，再按 PTY 字节顺序重放本分片的全部
    // 标题事件。重放排在 SwiftTerm 错误、缺失或提前入队的 macOS delegate 回调之后，
    // 因此工作区最终状态既符合协议语义，也保留恢复后紧随的新 OSC 更新。
    let safeBytes = oscStreamLimiter.consume(slice)
    if !safeBytes.isEmpty {
      shellNavigationAbsoluteRow = nil
      // 输出捕获必须先于 SwiftTerm 解析 OSC 133 D，确保命令完成事件能读到同一分片；
      // overlay 自己延后一轮主线程布局，等下方 SwiftTerm 更新 caretFrame 后再显示。
      onAutocompleteOutput?(safeBytes[...])
      let previousMouseReporting = allowMouseReporting
      if paneModeState.inputDecision != .forwardToProcess {
        // SwiftTerm 的 feedPrepare/linefeed 以该开关决定是否清除选区。Read-only 与
        // Vi/Mark 都必须在持续输出时保留用户或模式选区。
        allowMouseReporting = false
      }
      super.dataReceived(slice: safeBytes[...])
      allowMouseReporting = previousMouseReporting
      if paneModeState.navigationMode == .hint {
        // Hint 标签绑定当前可见网格；输出一旦改变就立即失效，并恢复进入 Hint 前的
        // Vi/普通模式，避免标签指向另一段文本。
        leaveHintMode()
      }
      if case .vi = paneModeState.navigationMode {
        reconcileViModeAfterOutput()
      }
      if paneModeState.navigationMode == .normal {
        // 普通模式的新输出回到底部。Vi/Mark 则固定用户正在检查的 viewport。
        scrollToBottom()
      }
      let terminal = getTerminal()
      if let line = terminal.getLine(row: terminal.buffer.y) {
        onTerminalOutputActivity?(
          line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
        )
      }
      updatePaneModeHUD()
    }
    if titleShellControlled {
      for update in titleStackObserver.consume(safeBytes) {
        onObservedTitleUpdate?(update.code, update.title)
      }
    } else {
      // 仍需消费字节以保持跨分片解析状态同步，只丢弃其业务副作用。
      _ = titleStackObserver.consume(safeBytes)
    }
  }

  override func send(source: TerminalView, data: ArraySlice<UInt8>) {
    if isForwardingTerminalProtocolResponse {
      super.send(source: source, data: data)
      return
    }
    switch paneModeState.inputDecision {
    case .consumeLocally:
      return
    case .rejectWithFeedback:
      onInputRejected()
      return
    case .forwardToProcess:
      break
    }
    shellNavigationAbsoluteRow = nil
    onTerminalIO?()
    onEncodedInput?(data)
    onAutocompleteInput?(data)
    onTerminalUserInput?()
    super.send(source: source, data: data)
  }

  /// SwiftTerm 在清选区和回到底部前调用该门禁。Read-only 与本地导航模式由此在任何
  /// 副作用发生前拒绝应用命令、IME 和键盘输入；协议响应仍走 Terminal delegate 通道。
  override func shouldSendUserData(_ data: ArraySlice<UInt8>) -> Bool {
    switch paneModeState.inputDecision {
    case .forwardToProcess:
      return true
    case .consumeLocally:
      return false
    case .rejectWithFeedback:
      onInputRejected()
      return false
    }
  }

  /// Terminal parser 产生的设备属性、状态报告等响应也会走 TerminalViewDelegate。用
  /// 动态作用域标记该次转发，让只读锁只拦用户动作，不破坏前台程序协议协商。
  override func send(source: Terminal, data: ArraySlice<UInt8>) {
    guard source.outboundDataOrigin == .protocolResponse else {
      super.send(source: source, data: data)
      return
    }
    isForwardingTerminalProtocolResponse = true
    onTerminalProtocolOutput?(data)
    defer { isForwardingTerminalProtocolResponse = false }
    super.send(source: source, data: data)
  }

  // MARK: - Pane navigation and read-only modes

  @objc func toggleReadOnly(_ sender: Any?) {
    paneModeState.toggleReadOnly()
    if paneModeState.readOnly {
      onPaneModeActivated?()
      ensurePaneModeHUD()
    }
    updatePaneModeHUD()
  }

  func setReadOnly(_ value: Bool) {
    paneModeState.setReadOnly(value)
    if value {
      onPaneModeActivated?()
      ensurePaneModeHUD()
    }
    updatePaneModeHUD()
  }

  @objc func enterViMode(_ sender: Any?) {
    beginViMode(style: .vi)
  }

  @objc func enterMarkMode(_ sender: Any?) {
    beginViMode(style: .mark)
  }

  @objc func openHintMode(_ sender: Any?) {
    let links = getTerminal().visibleLinks(maximumCount: 26 * 26)
    let labels = TerminalHintLabeler.labels(count: links.count)
    guard !labels.isEmpty else {
      onInputRejected()
      return
    }
    hintTargets = zip(links, labels).map { link, label in
      HintTarget(
        link: link,
        label: label,
        source: link.isExplicit ? .osc8 : .plainText
      )
    }
    hintMatcher = TerminalHintMatcher(labels: labels)
    if paneModeState.navigationMode != .hint { paneModeState.enterHintMode() }
    onPaneModeActivated?()
    ensurePaneModeHUD()
    updatePaneModeHUD()
  }

  @objc func toggleViKeyHints(_ sender: Any?) {
    guard case .vi = paneModeState.navigationMode else { return }
    showsViKeyHints.toggle()
    updatePaneModeHUD()
  }

  private func beginViMode(style: TerminalViStyle) {
    if paneModeState.navigationMode == .hint { leaveHintMode() }
    let terminal = getTerminal()
    let cursor = terminal.activeBufferCursorPosition
    let snapshot = navigationSnapshot()
    let row = min(
      max(0, cursor.row),
      max(0, snapshot.lines.count - 1)
    )
    let lineColumn = min(cursor.col, snapshot.lastNavigableColumn(at: row))
    viEngine = TerminalViEngine(cursor: TerminalBufferPoint(column: lineColumn, row: row))
    viScrollInvariantLowerBound = terminal.scrollInvariantLineRange.lowerBound
    viUsesAlternateBuffer = terminal.isCurrentBufferAlternate
    setViewportFrozen(true)
    paneModeState.enterViMode(style: style)
    onPaneModeActivated?()
    if style == .mark, var engine = viEngine {
      _ = engine.consume(.character("v"), in: snapshot)
      viEngine = engine
    }
    applyViSelection()
    ensurePaneModeHUD()
    updatePaneModeHUD()
  }

  private func handlePaneModeKeyDown(_ event: NSEvent) {
    if event.keyCode == 53 || event.characters?.first == "\u{1B}" {
      if paneModeState.navigationMode == .hint {
        leaveHintMode()
      } else {
        leaveViMode(clearSelection: true)
      }
      return
    }

    switch paneModeState.navigationMode {
    case .normal:
      return
    case .hint:
      handleHintKeyDown(event)
    case .vi:
      if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "/" {
        toggleViKeyHints(nil)
        return
      }
      guard let input = viInput(for: event), var engine = viEngine else { return }
      let result = engine.consume(input, in: navigationSnapshot())
      viEngine = engine
      handleViResult(result)
    }
  }

  private func viInput(for event: NSEvent) -> TerminalViInput? {
    switch event.keyCode {
    case 123: return .arrow(.left)
    case 124: return .arrow(.right)
    case 125: return .arrow(.down)
    case 126: return .arrow(.up)
    case 36, 76: return .enter
    default: break
    }
    if let scalar = event.characters?.unicodeScalars.first?.value {
      switch scalar {
      case 0x02: return .controlBackward
      case 0x04: return .controlDown
      case 0x06: return .controlForward
      case 0x15: return .controlUp
      case 0x16: return .controlVisualBlock
      default: break
      }
    }
    guard !event.modifierFlags.contains(.command), let character = event.characters?.first else {
      return nil
    }
    return .character(character)
  }

  private func handleViResult(_ result: TerminalViResult) {
    switch result {
    case .updated:
      applyViSelection()
      revealViCursor()
      updatePaneModeHUD()
    case .ignored:
      break
    case .copyAndExit:
      applyViSelection()
      copyCurrentSelection(clearAfterCopy: true)
      leaveViMode(clearSelection: false)
    case .search(let direction):
      onRequestViSearch?(direction)
      updatePaneModeHUD()
    case .repeatSearch(let reverse):
      onRepeatViSearch?(reverse)
    case .enterHintMode:
      openHintMode(nil)
    case .exit:
      leaveViMode(clearSelection: true)
    }
  }

  private func handleHintKeyDown(_ event: NSEvent) {
    guard !event.modifierFlags.contains(.command), let character = event.characters?.first else {
      return
    }
    switch hintMatcher.consume(
      character,
      shifted: event.modifierFlags.contains(.shift)
    ) {
    case .pending:
      updatePaneModeHUD()
    case .noMatch:
      onInputRejected()
      updatePaneModeHUD()
    case .selected(let index, let copies):
      guard hintTargets.indices.contains(index) else {
        leaveHintMode()
        return
      }
      let target = hintTargets[index]
      if copies {
        guard let value = onResolveHintCopyTarget?(target.link.text, target.source) else {
          onInputRejected()
          leaveHintMode()
          return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
      } else {
        onRequestOpenTarget?(target.link.text, target.source)
      }
      leaveHintMode()
    }
  }

  private func leaveHintMode() {
    hintTargets.removeAll(keepingCapacity: false)
    hintMatcher = TerminalHintMatcher(labels: [])
    paneModeState.leaveHintMode()
    updatePaneModeHUD()
  }

  private func leaveViMode(clearSelection: Bool) {
    paneModeState.leaveNavigationMode()
    viEngine = nil
    viScrollInvariantLowerBound = nil
    viUsesAlternateBuffer = nil
    setViewportFrozen(false)
    if clearSelection { selectNone() }
    updatePaneModeHUD()
  }

  private func reconcileViModeAfterOutput() {
    let terminal = getTerminal()
    guard viUsesAlternateBuffer == terminal.isCurrentBufferAlternate,
      let previousLowerBound = viScrollInvariantLowerBound
    else {
      // 切换 normal/alternate buffer 后原坐标没有合法映射，宁可退出也不能选中错文本。
      leaveViMode(clearSelection: true)
      return
    }
    let currentLowerBound = terminal.scrollInvariantLineRange.lowerBound
    guard currentLowerBound >= previousLowerBound else {
      // RIS/缓冲重建会让 scroll-invariant 基准回退，同样视为快照失效。
      leaveViMode(clearSelection: true)
      return
    }
    let droppedLines = currentLowerBound - previousLowerBound
    viScrollInvariantLowerBound = currentLowerBound
    guard droppedLines > 0, var engine = viEngine else { return }
    guard engine.rebaseAfterDroppingLines(droppedLines, in: navigationSnapshot()) else {
      leaveViMode(clearSelection: true)
      return
    }
    viEngine = engine
    applyViSelection()
  }

  /// 快照行号从 0 开始，与 SwiftTerm selection 的活动 Buffer 坐标一致。底层公开范围
  /// 仍使用 scroll-invariant 行号，因此先读取完整历史，再减去被裁剪的 lowerBound。
  private func navigationSnapshot() -> TerminalNavigationSnapshot {
    let terminal = getTerminal()
    let range = terminal.scrollInvariantLineRange
    let cellLines: [[Character?]] = range.map { row in
      guard let line = terminal.getScrollInvariantLine(row: row) else { return [] }
      let lastContent = stride(from: terminal.cols - 1, through: 0, by: -1)
        .first(where: { line.hasContent(index: $0) })
      guard let lastContent else { return [] }
      return (0...lastContent).map { column -> Character? in
        // 宽字符后续 cell 的 width 为 0；保留 nil 占位后，Vi 左右移动会跨过它，
        // 选区坐标仍直接对应 SwiftTerm 的真实网格列。
        guard line.getWidth(index: column) != 0 else { return nil }
        return line.hasContent(index: column) ? terminal.getCharacter(for: line[column]) : " "
      }
    }
    let lower = min(max(0, terminal.buffer.yDisp), cellLines.count)
    let upper = min(cellLines.count, lower + terminal.rows)
    return TerminalNavigationSnapshot(
      cellLines: cellLines,
      columns: terminal.cols,
      viewport: lower..<upper
    )
  }

  /// 读取完整 scrollback 的有界纯文本副本。默认限制高于 SwiftTerm 的常规历史容量，
  /// 但仍设置行数与字符数双重上限，防止全局搜索因异常超长输出占用无界内存。
  func boundedTextSnapshot(
    maximumLines: Int = 100_000,
    maximumCharacters: Int = 4_000_000
  ) -> TerminalTextSnapshot {
    let terminal = getTerminal()
    let range = terminal.scrollInvariantLineRange
    let lineLimit = max(0, min(maximumLines, 200_000))
    let characterLimit = max(0, min(maximumCharacters, 16_000_000))
    guard lineLimit > 0, characterLimit > 0, !range.isEmpty else {
      return .init(firstAbsoluteRow: range.lowerBound, lines: [])
    }
    let lowerBound = max(range.lowerBound, range.upperBound - lineLimit)
    var lines: [String] = []
    var characters = 0
    for row in lowerBound..<range.upperBound {
      guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
      let text = line.translateToString(trimRight: true)
      guard characters + text.count <= characterLimit else { break }
      lines.append(text)
      characters += text.count
    }
    return .init(firstAbsoluteRow: lowerBound, lines: lines)
  }

  /// 从 OSC 133 锚点和网格文本生成命令列表。只取输入起点所在行；复杂多行命令仍可
  /// 通过行锚点跳转，但标题保持有界，且不会把输出区误当成命令正文。
  func commandOutlineEntries(maximumItems: Int = 1_000) -> [TerminalCommandOutlineEntry] {
    let terminal = getTerminal()
    let range = terminal.scrollInvariantLineRange
    let limit = max(0, min(maximumItems, 5_000))
    return shellCommandTimeline.marks.suffix(limit).compactMap { mark in
      guard range.contains(mark.inputStart.row),
        let line = terminal.getScrollInvariantLine(row: mark.inputStart.row)
      else { return nil }
      let upperColumn = min(terminal.cols, max(mark.inputStart.column, 0))
      let text = line.translateToString(trimRight: true)
      // OSC 133 的列是网格列；常见命令提示符为 ASCII，按 Character 裁切即可得到
      // 准确标题。宽字符提示符存在歧义时保留整行，比丢失命令正文更可诊断。
      let title: String
      if text.unicodeScalars.allSatisfy({ $0.isASCII }), upperColumn <= text.count {
        title = String(text.dropFirst(upperColumn))
      } else {
        title = text
      }
      let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
      return TerminalCommandOutlineEntry(
        title: normalized.isEmpty ? "命令" : String(normalized.prefix(240)),
        absoluteRow: mark.promptStart.row,
        exitStatus: mark.exitStatus,
        finishedAt: mark.finishedAt
      )
    }
  }

  /// 将 scroll-invariant 行号转换回当前 Buffer 坐标并滚动。已被裁剪的锚点返回 false，
  /// 调用方可保持当前视口，不会误跳到同下标的新内容。
  @discardableResult
  func revealAbsoluteRow(_ absoluteRow: Int) -> Bool {
    let terminal = getTerminal()
    guard let row = terminal.bufferRow(forAbsoluteRow: absoluteRow) else { return false }
    scrollTo(row: row)
    return true
  }

  private func applyViSelection() {
    guard let selection = viEngine?.selection else {
      isApplyingModeSelection = true
      selectNone()
      isApplyingModeSelection = false
      return
    }
    let anchor = selection.anchor
    let focus = selection.focus
    let first: TerminalBufferPoint
    let last: TerminalBufferPoint
    if anchor.row < focus.row || (anchor.row == focus.row && anchor.column <= focus.column) {
      first = anchor
      last = focus
    } else {
      first = focus
      last = anchor
    }

    let start: Position
    let end: Position
    let rectangular: Bool
    switch selection.kind {
    case .character:
      start = Position(col: first.column, row: first.row)
      end = Position(col: last.column + 1, row: last.row)
      rectangular = false
    case .line:
      start = Position(col: 0, row: min(anchor.row, focus.row))
      end = Position(col: getTerminal().cols, row: max(anchor.row, focus.row))
      rectangular = false
    case .block:
      start = Position(
        col: min(anchor.column, focus.column),
        row: min(anchor.row, focus.row)
      )
      end = Position(
        col: max(anchor.column, focus.column) + 1,
        row: max(anchor.row, focus.row)
      )
      rectangular = true
    }
    isApplyingModeSelection = true
    setSelection(start: start, end: end, rectangular: rectangular)
    isApplyingModeSelection = false
  }

  private func revealViCursor() {
    guard let cursor = viEngine?.cursor else { return }
    let terminal = getTerminal()
    let firstVisible = terminal.buffer.yDisp
    let lastVisible = firstVisible + max(0, terminal.rows - 1)
    if cursor.row < firstVisible {
      scrollTo(row: cursor.row)
    } else if cursor.row > lastVisible {
      scrollTo(row: cursor.row - max(0, terminal.rows - 1))
    }
    setViewportFrozen(true)
  }

  private func ensurePaneModeHUD() {
    guard paneModeHUD.superview !== self else { return }
    paneModeHUD.frame = bounds
    addSubview(paneModeHUD, positioned: .above, relativeTo: nil)
  }

  private func updatePaneModeHUD() {
    let pillText: String?
    let detail: String?
    var showsKeyHints = false
    switch paneModeState.navigationMode {
    case .normal:
      pillText = paneModeState.showsReadOnlyIndicator ? "READ ONLY" : nil
      detail = nil
    case .hint:
      pillText = "HINT"
      detail = hintMatcher.prefix.isEmpty ? nil : hintMatcher.prefix.uppercased()
    case .vi(let style):
      pillText = style == .mark ? "MARK MODE" : "VI MODE"
      detail = viEngine?.pendingCount.map(String.init)
      showsKeyHints = self.showsViKeyHints
    }

    let cursorFrame: NSRect?
    if case .vi = paneModeState.navigationMode, let cursor = viEngine?.cursor {
      cursorFrame = frameForCell(column: cursor.column, bufferRow: cursor.row)
    } else {
      cursorFrame = nil
    }
    let labels = hintTargets.compactMap { target -> TerminalPaneModeHUD.HintLabel? in
      guard let frame = frameForCell(
        column: target.link.range.lowerBound,
        bufferRow: target.link.bufferRow
      ) else { return nil }
      let width = max(frame.width, CGFloat(target.label.count * 9 + 8))
      return TerminalPaneModeHUD.HintLabel(
        text: target.label,
        frame: NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
      )
    }
    paneModeHUD.update(
      pillText: pillText,
      detail: detail,
      showsKeyHints: showsKeyHints,
      cursorFrame: cursorFrame,
      hints: labels
    )
  }

  private func frameForCell(column: Int, bufferRow: Int) -> NSRect? {
    let terminal = getTerminal()
    let screenRow = bufferRow - terminal.buffer.yDisp
    guard column >= 0, column < terminal.cols, screenRow >= 0, screenRow < terminal.rows else {
      return nil
    }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    guard let pixels = cellSizeInPixels(source: terminal), pixels.width > 0, pixels.height > 0 else {
      return nil
    }
    let width = CGFloat(pixels.width) / scale
    let height = CGFloat(pixels.height) / scale
    let visualColumn = visualColumn(forLogicalColumn: column, bufferRow: bufferRow)
    return NSRect(
      x: bounds.minX + CGFloat(visualColumn) * width,
      y: bounds.maxY - CGFloat(screenRow + 1) * height,
      width: width,
      height: height
    )
  }

  override func bell(source: Terminal) {
    guard terminalBellEnabled else { return }
    terminalBellHandler()
  }

  /// SwiftTerm 对 OSC 8 与隐式文字使用同一个回调且不暴露来源。原始 PTY 观察器维护
  /// 有界 URL 集合，使自定义 scheme 模式下显式链接仍按协议要求被识别。
  override func requestOpenLink(
    source: TerminalView,
    link: String,
    params: [String: String]
  ) {
    didForwardLinkInCurrentMouseUp = true
    let payload = currentLinkClickEvent.flatMap(explicitLinkPayload)
    let detectedSource = detectedSource(for: link, payload: payload)
    onRequestOpenTarget?(link, detectedSource)
  }

  /// 仅当当前单元格 payload 的 URI 与回调值完全相等时认定为 OSC 8。该纯比较 seam
  /// 供代码测试覆盖“同 URL 普通文字不能继承历史显式来源”。
  func detectedSource(for link: String, payload: String?) -> DetectedTargetSource {
    guard let payload, OSC8Payload.link(from: payload) == link else { return .plainText }
    return .osc8
  }

  /// SwiftTerm 的隐式列表只包含固定 scheme。Command-click 的文字本身若是其它合法
  /// `scheme://`，在 mouseDown 阶段先截住，避免 TUI 收到一半鼠标序列；mouseUp 再由
  /// Aster 的行内检测器补发。OSC 8 的显示标签通常不是 URL，仍完整交给 SwiftTerm。
  override func mouseDown(with event: NSEvent) {
    let previousMouseReporting = allowMouseReporting
    if paneModeState.inputDecision != .forwardToProcess { allowMouseReporting = false }
    defer { allowMouseReporting = previousMouseReporting }
    if case .none = linkReporting {
      super.mouseDown(with: event.removingCommandModifier() ?? event)
      return
    }
    if event.modifierFlags.contains(.command), customSchemeURL(at: event) != nil { return }
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if case .none = linkReporting {
      super.mouseUp(with: event.removingCommandModifier() ?? event)
      return
    }
    didForwardLinkInCurrentMouseUp = false
    currentLinkClickEvent = event
    defer { currentLinkClickEvent = nil }
    super.mouseUp(with: event)
    guard !didForwardLinkInCurrentMouseUp,
      event.modifierFlags.contains(.command),
      let link = customSchemeURL(at: event)
    else { return }
    onRequestOpenTarget?(link, .plainText)
  }

  override func mouseMoved(with event: NSEvent) {
    // SwiftTerm 的 mouseMoved 路径不读取 allowMouseReporting。模式锁定时直接忽略 hover
    // 报告，避免 Read-only、Vi 或 Hint 在用户移动指针时向 TUI 写入 CSI 序列。
    guard paneModeState.inputDecision == .forwardToProcess else { return }
    super.mouseMoved(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    // 滚动本身在 Read-only 中仍可用；临时关闭报告后，SwiftTerm 会走本地 scrollback
    // 分支，而不会把滚轮编码成前台 TUI 的按键或鼠标事件。
    let previousViewport = getTerminal().buffer.yDisp
    let previousMouseReporting = allowMouseReporting
    if paneModeState.inputDecision != .forwardToProcess { allowMouseReporting = false }
    defer { allowMouseReporting = previousMouseReporting }
    super.scrollWheel(with: event)
    if paneModeState.navigationMode == .hint,
      getTerminal().buffer.yDisp != previousViewport
    {
      // Hint 的屏幕坐标只对进入模式时的 viewport 有效。用户滚动后立即取消，不能让
      // 旧标签继续指向已经离开视口的 bufferRow。
      leaveHintMode()
      return
    }
    updatePaneModeHUD()
  }

  /// 选择变化时同步“选中即复制”。SwiftTerm 会在拖选、单词选择和整行选择后调用该
  /// 回调；空选区不会覆盖用户原剪贴板。
  override func selectionChanged(source: Terminal) {
    super.selectionChanged(source: source)
    guard copyOnSelect, !isApplyingModeSelection else { return }
    copyCurrentSelection(clearAfterCopy: false)
  }

  /// 所有复制入口共用同一转换，确保菜单、快捷键和右键行为一致。
  override func copy(_ sender: Any) {
    copyCurrentSelection(
      clearAfterCopy: TerminalSelectionPolicy.clearsAfterExplicitCopy(
        copyOnSelect: copyOnSelect,
        clearSelectionOnCopy: clearSelectionOnCopy
      ))
  }

  /// 普通粘贴读取剪贴板一次，先完成风险确认，再按终端协商状态决定是否使用括号模式。
  override func paste(_ sender: Any) {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    pasteText(text)
  }

  @objc func undo(_ sender: Any?) {
    _ = sendNaturalEditing(.undo)
  }

  @objc func movePromptToBeginningOfLine(_ sender: Any?) {
    _ = sendNaturalEditing(.moveToBeginningOfLine)
  }

  @objc func movePromptToEndOfLine(_ sender: Any?) {
    _ = sendNaturalEditing(.moveToEndOfLine)
  }

  @objc func movePromptWordLeft(_ sender: Any?) {
    _ = sendNaturalEditing(.moveWordLeft)
  }

  @objc func movePromptWordRight(_ sender: Any?) {
    _ = sendNaturalEditing(.moveWordRight)
  }

  @objc func deletePromptToBeginningOfLine(_ sender: Any?) {
    _ = sendNaturalEditing(.deleteToBeginningOfLine)
  }

  @objc func deletePromptToEndOfLine(_ sender: Any?) {
    _ = sendNaturalEditing(.deleteToEndOfLine)
  }

  @objc func deletePromptWordLeft(_ sender: Any?) {
    _ = sendNaturalEditing(.deleteWordLeft)
  }

  @objc func deletePromptWordRight(_ sender: Any?) {
    _ = sendNaturalEditing(.deleteWordRight)
  }

  @objc func extendSelectionLeft(_ sender: Any?) {
    _ = extendSelection(.left)
  }

  @objc func extendSelectionRight(_ sender: Any?) {
    _ = extendSelection(.right)
  }

  @objc func extendSelectionUp(_ sender: Any?) {
    _ = extendSelection(.up)
  }

  @objc func extendSelectionDown(_ sender: Any?) {
    _ = extendSelection(.down)
  }

  @objc func extendRectangularSelectionLeft(_ sender: Any?) {
    _ = extendSelection(.left, rectangular: true)
  }

  @objc func extendRectangularSelectionRight(_ sender: Any?) {
    _ = extendSelection(.right, rectangular: true)
  }

  @objc func extendRectangularSelectionUp(_ sender: Any?) {
    _ = extendSelection(.up, rectangular: true)
  }

  @objc func extendRectangularSelectionDown(_ sender: Any?) {
    _ = extendSelection(.down, rectangular: true)
  }

  /// Shift+Page Up/Down 与 Shift+Home/End 通过原生菜单进入这些 responder 动作。
  /// 普通屏移动 scrollback；alternate screen 的分页仍由 SwiftTerm 发给前台 TUI。
  @objc func scrollTerminalPageUp(_ sender: Any?) {
    pageUp()
  }

  @objc func scrollTerminalPageDown(_ sender: Any?) {
    pageDown()
  }

  @objc func scrollTerminalToTop(_ sender: Any?) {
    scrollToTop()
  }

  @objc func scrollTerminalToBottom(_ sender: Any?) {
    scrollToBottom()
  }

  /// 注册 OSC 133 FTCS 处理器。重复调用保持幂等，避免主题刷新或测试装配覆盖状态。
  func installShellIntegrationHandler() {
    guard !shellIntegrationHandlerInstalled else { return }
    shellIntegrationHandlerInstalled = true
    getTerminal().registerOscHandler(code: 133) { [weak self] bytes in
      guard bytes.count <= 32,
        let payload = String(bytes: bytes, encoding: .ascii),
        let event = ShellIntegrationEvent(payload: payload),
        let self
      else { return }
      let cursor = self.getTerminal().cursorAbsolutePosition
      self.shellCommandTimeline.receive(
        event,
        at: TerminalGridPoint(column: cursor.col, row: cursor.row)
      )
      self.onShellIntegrationEvent?(event)
      self.onShellIntegrationStateChange?(self.shellCommandTimeline)
    }
    getTerminal().registerOscHandler(code: 6_973) { [weak self] bytes in
      guard bytes.count <= 8_192,
        let payload = String(bytes: bytes, encoding: .ascii),
        let report = ShellAliasReport(payload: payload)
      else { return }
      self?.onShellAliases?(report.names)
    }
  }

  /// 以非消费 observer 接收通知和进度 OSC，保留 SwiftTerm 已有的进度条渲染。
  func installActivityHandlers() {
    guard !activityHandlersInstalled else { return }
    activityHandlersInstalled = true
    let terminal = getTerminal()
    // Otty 将 OSC 9;4 state 4 定义为无操作；让 SwiftTerm 消费但不显示暂停态，
    // 避免它覆盖当前进度条。Aster 的 observer 同样不发布该状态。
    terminal.ignoresPausedProgressReports = true
    terminal.registerOscObserver(code: 9) { [weak self] bytes in
      guard bytes.count <= TerminalNotificationParser.maximumChunkBytes,
        let payload = String(bytes: bytes, encoding: .utf8), let self
      else { return }
      if payload == "4" || payload.hasPrefix("4;") {
        if let progress = TerminalProgressParser.parseOSC9(payload) {
          if case .finished = progress {
            // state 5 是 Aster/Otty 完成扩展，不在 SwiftTerm 上游枚举中，需主动清除
            // 已有的 state 1/2/3 进度条，不能等待 15 秒兜底计时器。
            self.clearProgressReport()
          }
          self.onTerminalProgress?(progress)
        }
      } else if let notification = TerminalNotificationParser.parseOSC9(payload) {
        self.onTerminalNotification?(notification)
      }
    }
    terminal.registerOscObserver(code: 777) { [weak self] bytes in
      guard bytes.count <= TerminalNotificationParser.maximumChunkBytes,
        let payload = String(bytes: bytes, encoding: .utf8),
        let notification = TerminalNotificationParser.parseOSC777(payload)
      else { return }
      self?.onTerminalNotification?(notification)
    }
    terminal.registerOscObserver(code: 99) { [weak self] bytes in
      guard bytes.count <= TerminalNotificationParser.maximumChunkBytes,
        let payload = String(bytes: bytes, encoding: .utf8), let self
      else { return }
      switch self.kittyNotificationAssembler.consume(payload) {
      case .notification(let notification): self.onTerminalNotification?(notification)
      case .response(let response): self.onTerminalProtocolResponse?(response)
      case nil: break
      }
    }
    terminal.registerOscHandler(code: 6_974) { [weak self] bytes in
      guard bytes.count <= AgentTerminalDirective.maximumPayloadBytes,
        let payload = String(bytes: bytes, encoding: .ascii)
      else { return }
      if let directive = TerminalBadgeDirective(payload: payload) {
        self?.onTerminalBadgeDirective?(directive)
      } else if let directive = AgentTerminalDirective(payload: payload) {
        self?.onAgentTerminalDirective?(directive)
      }
    }
  }

  /// OSC 0/1/2 处理器在关闭权限时仍消费序列，但不修改 SwiftTerm 或 Aster 标题状态。
  func installTitleHandlers() {
    guard !titleHandlersInstalled else { return }
    titleHandlersInstalled = true
    let terminal = getTerminal()
    for code in 0...2 {
      terminal.registerOscHandler(code: code) { [weak terminal, weak self] bytes in
        guard self?.titleShellControlled == true else { return }
        let text = String(bytes: bytes, encoding: .utf8) ?? ""
        switch code {
        case 0:
          terminal?.setIconTitle(text: text)
          terminal?.setTitle(text: text)
        case 1:
          terminal?.setIconTitle(text: text)
        case 2:
          terminal?.setTitle(text: text)
        default:
          break
        }
      }
    }
  }

  /// Command+Page Up：首次从当前光标向上找最近命令，连续调用严格前进到上一锚点。
  @objc func scrollToPreviousCommand(_ sender: Any?) {
    let terminal = getTerminal()
    let baseline = shellNavigationAbsoluteRow.map { $0 - 1 }
      ?? terminal.cursorAbsolutePosition.row
    guard let mark = shellCommandTimeline.previousCommand(beforeOrAt: baseline),
      let row = terminal.bufferRow(forAbsoluteRow: mark.promptStart.row)
    else { return }
    scrollTo(row: row)
    shellNavigationAbsoluteRow = mark.promptStart.row
  }

  /// Command+Page Down：从当前命令锚点向后移动；未导航时从视口顶部寻找下一条。
  @objc func scrollToNextCommand(_ sender: Any?) {
    let terminal = getTerminal()
    let baseline = shellNavigationAbsoluteRow ?? terminal.displayAbsoluteRow
    guard let mark = shellCommandTimeline.nextCommand(after: baseline),
      let row = terminal.bufferRow(forAbsoluteRow: mark.promptStart.row)
    else { return }
    scrollTo(row: row)
    shellNavigationAbsoluteRow = mark.promptStart.row
  }

  @objc func cut(_ sender: Any?) {
    // 先无损复制，再尝试删除。删除策略拒绝任何无法精确映射到当前提示符的选区。
    copyCurrentSelection(clearAfterCopy: false)
    _ = deletePromptSelectionIfSafe()
  }

  /// 删除当前提示符内可精确映射的单行 ASCII 选区。返回 false 时不发送任何字节、
  /// 不清空选区，Cut 因而自然退化为纯复制。
  @discardableResult
  func deletePromptSelectionIfSafe() -> Bool {
    guard permitsUserInputAction() else { return false }
    let terminal = getTerminal()
    guard !terminal.isCurrentBufferAlternate,
      let inputStart = shellCommandTimeline.currentInputStart,
      let selection = selectedBufferRange,
      let selectedText = getSelection()
    else { return false }
    let trimmed = terminal.buffer.totalLinesTrimmed
    let start = TerminalGridPoint(
      column: selection.start.col,
      row: trimmed + selection.start.row
    )
    let end = TerminalGridPoint(
      column: selection.end.col,
      row: trimmed + selection.end.row
    )
    let cursor = terminal.cursorAbsolutePosition
    guard let plan = PromptSelectionDeletionPolicy.plan(
      inputStart: inputStart,
      cursor: TerminalGridPoint(column: cursor.col, row: cursor.row),
      selectionStart: start,
      selectionEnd: end,
      selectedText: selectedText,
      rectangular: selection.rectangular,
      commandRunning: shellCommandTimeline.isCommandRunning
    ) else { return false }

    var bytes: [UInt8] = []
    if plan.horizontalMovement != 0 {
      let direction = plan.horizontalMovement < 0 ? "D" : "C"
      bytes.append(contentsOf: "\u{1B}[\(abs(plan.horizontalMovement))\(direction)".utf8)
    }
    bytes.append(contentsOf: repeatElement(UInt8(127), count: plan.deleteCount))
    send(data: bytes[...])
    selectNone()
    return true
  }

  /// 供菜单变体复用的窄入口。返回 false 表示空内容、保护取消或没有可写入的数据。
  @discardableResult
  func pasteText(_ text: String, forceBracketed: Bool = false) -> Bool {
    guard !text.isEmpty, permitsUserInputAction() else { return false }
    let terminal = getTerminal()
    let analysis = PasteRiskAnalyzer.analyze(text)
    if PasteProtectionPolicy.requiresConfirmation(
      for: analysis,
      protectionEnabled: pasteProtectionEnabled,
      isAlternateScreen: terminal.isCurrentBufferAlternate,
      isBracketedPasteMode: terminal.bracketedPasteMode,
      treatsBracketedPasteAsSafe: pasteBracketedSafe
    ), !onConfirmPaste(analysis) {
      return false
    }
    let bytes = PasteTransmissionEncoder.encode(
      text,
      bracketed: forceBracketed || terminal.bracketedPasteMode
    )
    send(data: bytes[...])
    return true
  }

  /// 将应用内文本写入当前前台程序的输入框，但不确认提交。编码按目标是否协商过
  /// bracketed paste 决定：Claude Code / Codex 这类 TUI 打开输入框时会 DECSET 2004，
  /// 此时整段文本必须作为一个粘贴块投递，否则输入框把它按逐键解释，`/`、`@`、
  /// 方向键和候选列表会吃掉大部分内容，用户看到的就是“输入框没有变化”。未协商的
  /// 目标仍发裸 UTF-8 —— 对它们发 `CSI 200~` 同样会被当作乱码丢弃。
  @discardableResult
  func typePromptText(_ text: String) -> Bool {
    guard !text.isEmpty, permitsUserInputAction() else { return false }
    let bytes = PasteTransmissionEncoder.encode(
      text, bracketed: getTerminal().bracketedPasteMode)
    send(data: bytes[...])
    return true
  }

  /// 将应用内 Prompt Queue 的用户文本写入当前 CLI 输入框并确认。队列语义要求它在
  /// 同一个当前 CLI 中执行，因此先复用普通键入门禁，再单独发送 Return。
  @discardableResult
  func submitPromptQueueText(_ text: String) -> Bool {
    guard typePromptText(text) else { return false }
    // Return 必须与文本分批到达：TUI 要一次事件循环才能把粘贴块并入输入框，同批
    // 到达的 CR 会被算进粘贴内容变成换行，表现为「只多了一行、没有提交」。
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.promptSubmitReturnDelay)
      guard let self, process.running else { return }
      send(data: [UInt8(13)][...])
    }
    return true
  }

  /// 粘贴块与 Return 之间的间隔。取值只需覆盖 TUI 的一帧重绘，过长会让用户察觉到
  /// 队列项“发出去但没提交”的中间态。
  private static let promptSubmitReturnDelay = Duration.milliseconds(60)

  @objc func pasteSelection(_ sender: Any?) {
    guard let selection = getSelection() else { return }
    pasteText(selection)
  }

  @objc func pasteEscapingSpecialCharacters(_ sender: Any?) {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    pasteText(ShellPasteEscaper.escape(text))
  }

  @objc func pasteBracketed(_ sender: Any?) {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    pasteText(text, forceBracketed: true)
  }

  @objc func pasteFileBase64Encoded(_ sender: Any?) {
    guard permitsUserInputAction() else { return }
    let panel = NSOpenPanel()
    panel.title = "选择要以 Base64 粘贴的文件"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let path = panel.url?.path else { return }
    do {
      pasteText(try TerminalFilePasteEncoder.encodeBase64(path: path))
    } catch {
      Self.presentFilePasteError(error)
    }
  }

  @objc func pasteAndContinueInComposer(_ sender: Any?) {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    onPasteIntoComposer?(text)
  }

  @objc func sendSelectionToChat(_ sender: Any?) {
    guard selectionActive else { return }
    onSendSelectionToChat?()
  }

  /// 右键菜单补齐复制、粘贴与 Paste As。动作走 responder 自身，不依赖主菜单焦点。
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu(title: "终端")
    let copyItem = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
    copyItem.target = self
    copyItem.isEnabled = selectionActive
    menu.addItem(copyItem)
    let sendToChatItem = NSMenuItem(
      title: "发送选区到 Chat",
      action: #selector(sendSelectionToChat(_:)),
      keyEquivalent: ""
    )
    sendToChatItem.target = self
    sendToChatItem.isEnabled = selectionActive && onSendSelectionToChat != nil
    menu.addItem(sendToChatItem)
    menu.addItem(.separator())
    let pasteItem = NSMenuItem(title: "粘贴", action: #selector(paste(_:)), keyEquivalent: "")
    pasteItem.target = self
    menu.addItem(pasteItem)

    let pasteAsItem = NSMenuItem(title: "粘贴为", action: nil, keyEquivalent: "")
    let pasteAsMenu = NSMenu(title: "粘贴为")
    pasteAsMenu.addItem(
      targetedMenuItem("粘贴选区", #selector(pasteSelection(_:)), enabled: selectionActive)
    )
    pasteAsMenu.addItem(
      targetedMenuItem("粘贴 Base64 编码文件…", #selector(pasteFileBase64Encoded(_:)))
    )
    pasteAsMenu.addItem(
      targetedMenuItem("转义特殊字符后粘贴", #selector(pasteEscapingSpecialCharacters(_:)))
    )
    pasteAsMenu.addItem(targetedMenuItem("括号粘贴", #selector(pasteBracketed(_:))))
    pasteAsMenu.addItem(
      targetedMenuItem(
        "粘贴并在 Composer 中继续",
        #selector(pasteAndContinueInComposer(_:)),
        enabled: onPasteIntoComposer != nil
      ))
    pasteAsItem.submenu = pasteAsMenu
    menu.addItem(pasteAsItem)
    return menu
  }

  /// SwiftTerm 对未知 selector 默认返回 false；显式声明 Paste As 的可用条件，确保主菜单
  /// 通过 responder chain 定位到终端后不会把已实现动作全部置灰。
  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(undo(_:)),
      #selector(movePromptToBeginningOfLine(_:)), #selector(movePromptToEndOfLine(_:)),
      #selector(movePromptWordLeft(_:)), #selector(movePromptWordRight(_:)),
      #selector(deletePromptToBeginningOfLine(_:)), #selector(deletePromptToEndOfLine(_:)),
      #selector(deletePromptWordLeft(_:)), #selector(deletePromptWordRight(_:)):
      return TerminalInputPolicy.usesNaturalTextEditing(
        isAlternateScreen: getTerminal().isCurrentBufferAlternate,
        hasEnhancedKeyboardProtocol: !getTerminal().keyboardEnhancementFlags.isEmpty
      )
    case #selector(extendSelectionLeft(_:)), #selector(extendSelectionRight(_:)),
      #selector(extendSelectionUp(_:)), #selector(extendSelectionDown(_:)),
      #selector(extendRectangularSelectionLeft(_:)),
      #selector(extendRectangularSelectionRight(_:)),
      #selector(extendRectangularSelectionUp(_:)), #selector(extendRectangularSelectionDown(_:)):
      return shiftArrowSelectionEnabled
    case #selector(scrollTerminalPageUp(_:)), #selector(scrollTerminalPageDown(_:)),
      #selector(scrollTerminalToTop(_:)), #selector(scrollTerminalToBottom(_:)):
      return true
    case #selector(scrollToPreviousCommand(_:)), #selector(scrollToNextCommand(_:)):
      return !shellCommandTimeline.marks.isEmpty
    case #selector(toggleReadOnly(_:)):
      if let menuItem = item as? NSMenuItem {
        menuItem.state = paneModeState.readOnly ? .on : .off
      }
      return true
    case #selector(enterViMode(_:)), #selector(enterMarkMode(_:)), #selector(openHintMode(_:)):
      return true
    case #selector(toggleViKeyHints(_:)):
      if case .vi = paneModeState.navigationMode { return true }
      return false
    case #selector(cut(_:)):
      return selectionActive
    case #selector(pasteSelection(_:)):
      return selectionActive
    case #selector(pasteFileBase64Encoded(_:)):
      return true
    case #selector(pasteEscapingSpecialCharacters(_:)), #selector(pasteBracketed(_:)):
      return NSPasteboard.general.string(forType: .string) != nil
    case #selector(pasteAndContinueInComposer(_:)):
      return onPasteIntoComposer != nil
    case #selector(sendSelectionToChat(_:)):
      return selectionActive && onSendSelectionToChat != nil
    default:
      return super.validateUserInterfaceItem(item)
    }
  }

  private func targetedMenuItem(
    _ title: String,
    _ action: Selector,
    enabled: Bool = true
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    return item
  }

  @discardableResult
  private func sendNaturalEditing(_ action: NaturalTextEditingAction) -> Bool {
    guard permitsUserInputAction() else { return false }
    let terminal = getTerminal()
    guard
      TerminalInputPolicy.usesNaturalTextEditing(
        isAlternateScreen: terminal.isCurrentBufferAlternate,
        hasEnhancedKeyboardProtocol: !terminal.keyboardEnhancementFlags.isEmpty
      )
    else { return false }
    let bytes = TerminalInputEncoder.encode(action)
    send(data: bytes[...])
    return true
  }

  /// 菜单动作在编码前先调用此门禁，避免 Read-only 仍弹出粘贴确认或文件选择器。
  /// 键盘和 IME 的最终兜底仍是 `send(source: TerminalView, ...)`，两层共同覆盖入口。
  private func permitsUserInputAction() -> Bool {
    switch paneModeState.inputDecision {
    case .forwardToProcess:
      return true
    case .consumeLocally:
      return false
    case .rejectWithFeedback:
      onInputRejected()
      return false
    }
  }

  /// 将领域层的可持久化枚举映射到 vendored SwiftTerm 的运行时滚动模式。
  /// 映射集中在 AppKit 边界，AsterCore 不依赖终端渲染实现。
  func applyScrollConfiguration(_ controls: ControlConfiguration) {
    smoothScrollEnabled = controls.smoothScrolling
    switch controls.resolvedScrollPastLastLine {
    case .disabled: scrollPastLastLineMode = .disabled
    case .lastLineWithContent: scrollPastLastLineMode = .lastLineWithContent
    case .lastLineInMiddle: scrollPastLastLineMode = .lastLineInMiddle
    case .cursorLine: scrollPastLastLineMode = .cursorLine
    }
    switch controls.resolvedScrollPastFirstLine {
    case .disabled: scrollPastFirstLineMode = .disabled
    case .sameAsLastLine: scrollPastFirstLineMode = .sameAsLastLine
    case .firstLineWithContent: scrollPastFirstLineMode = .firstLineWithContent
    case .firstLineInMiddle: scrollPastFirstLineMode = .firstLineInMiddle
    }
    reconcileScrollConfiguration()
  }

  private func copyCurrentSelection(clearAfterCopy: Bool) {
    guard var text = getSelection(), !text.isEmpty else { return }
    if trimTrailingSpacesOnCopy {
      text = TerminalClipboardText.trimmingTrailingWhitespace(in: text)
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    if clearAfterCopy { selectNone() }
  }

  private static func presentPasteConfirmation(_ analysis: PasteAnalysis) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "粘贴的内容可能立即执行命令"
    let reasons = analysis.risks
      .map { risk -> String in
        switch risk {
        case .multipleLines: "包含多行"
        case .trailingNewline: "末尾包含换行"
        case .privilegeEscalation: "包含 sudo 或 su"
        case .controlCharacters: "包含不可见控制字符"
        }
      }
      .sorted()
      .joined(separator: "、")
    alert.informativeText = "检测到：\(reasons)\n\n\(analysis.preview())"
    alert.addButton(withTitle: "仍然粘贴")
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func presentFilePasteError(_ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "无法粘贴该文件"
    switch error {
    case TerminalFilePasteError.fileTooLarge:
      alert.informativeText = "文件超过 8 MiB 限制。"
    case TerminalFilePasteError.unsupportedFile:
      alert.informativeText = "只能读取普通文件，不能读取目录、管道、socket 或设备。"
    default:
      alert.informativeText = "文件不可读或在读取期间发生变化。"
    }
    alert.addButton(withTitle: "好")
    alert.runModal()
  }

  /// 通过公开的终端行和单元格尺寸把点击点映射为字符偏移。前缀转换跳过宽字符的
  /// 占位 cell，因此中文/emoji 出现在 URL 前面时仍能命中正确字符。
  private func customSchemeURL(at event: NSEvent) -> String? {
    guard let location = gridLocation(for: event),
      let clickedLine = location.terminal.getLine(row: location.row),
      let context = logicalLineContext(around: location.row, terminal: location.terminal)
    else { return nil }
    let prefix = clickedLine.translateToString(
      trimRight: true,
      startCol: 0,
      endCol: location.column + 1,
      skipNullCellsFollowingWide: true
    )
    guard !prefix.isEmpty else { return nil }
    guard
      let link = InlineURLDetector.url(
        inPhysicalLines: context.lines,
        clickedLine: location.row - context.startRow,
        atCharacterOffset: prefix.count - 1,
        finalBoundaryMayContinue: context.finalBoundaryMayContinue
      ),
      let separator = link.firstIndex(of: ":")
    else { return nil }
    let scheme = String(link[..<separator]).lowercased()
    return linkSchemePolicy.detects(scheme) ? link : nil
  }

  /// SwiftTerm 没有公开 `BufferLine.isWrapped`。其软换行行一定占用右侧最后一个 cell，
  /// 因此在可见区内向两侧收集连续满行，最多 8 行/4096 字节；末行仍满且没有后继
  /// 可收集时标记为可能截断，交给检测器拒绝。
  private func logicalLineContext(
    around clickedRow: Int,
    terminal: Terminal
  ) -> (lines: [String], startRow: Int, finalBoundaryMayContinue: Bool)? {
    let lastColumn = terminal.cols - 1
    let maximumRows = 8
    var startRow = clickedRow
    while startRow > 0, clickedRow - startRow + 1 < maximumRows,
      terminal.getLine(row: startRow - 1)?.hasContent(index: lastColumn) == true
    {
      startRow -= 1
    }

    var endRow = clickedRow
    while endRow < terminal.rows - 1, endRow - startRow + 1 < maximumRows,
      terminal.getLine(row: endRow)?.hasContent(index: lastColumn) == true
    {
      endRow += 1
    }

    var lines: [String] = []
    for row in startRow...endRow {
      guard let line = terminal.getLine(row: row) else { return nil }
      lines.append(
        line.translateToString(trimRight: true, skipNullCellsFollowingWide: true))
    }
    let finalBoundaryMayContinue =
      terminal.getLine(row: endRow)?
      .hasContent(index: lastColumn) == true
    return (lines, startRow, finalBoundaryMayContinue)
  }

  private func gridLocation(
    for event: NSEvent
  ) -> (terminal: Terminal, row: Int, column: Int)? {
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point) else { return nil }
    let terminal = getTerminal()
    guard terminal.cols > 0, terminal.rows > 0,
      let pixelSize = cellSizeInPixels(source: terminal)
    else { return nil }
    let scale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
    let cellWidth = max(CGFloat(pixelSize.width) / scale, 1)
    let cellHeight = max(CGFloat(pixelSize.height) / scale, 1)
    let visualColumn = min(max(Int(point.x / cellWidth), 0), terminal.cols - 1)
    let row = min(max(Int((bounds.height - point.y) / cellHeight), 0), terminal.rows - 1)
    let bufferRow = row + terminal.buffer.yDisp
    let column = logicalColumn(forVisualColumn: visualColumn, bufferRow: bufferRow)
    return (terminal, row, column)
  }

  private func explicitLinkPayload(at event: NSEvent) -> String? {
    guard let location = gridLocation(for: event) else { return nil }
    if let payload = location.terminal.getCharData(col: location.column, row: location.row)?
      .getPayload() as? String
    {
      return payload
    }
    // 宽字符的第二个 cell 是空占位，OSC 8 payload 保存在前一个基础 cell。
    guard location.column > 0 else { return nil }
    return location.terminal.getCharData(col: location.column - 1, row: location.row)?
      .getPayload() as? String
  }

  /// 隐藏 SwiftTerm 的 overlay 滚动条。
  ///
  /// 它是一条 5.5pt 的灰色 `NSScroller`，贴在终端右边缘、随滚动闪现又消失，看起来
  /// 像界面里多出来一块灰斑，还会盖住右侧文字。SwiftTerm 在 scroller 隐藏时会把
  /// `reservedScrollerWidth` 归零，终端网格自动收回这几个点的宽度，不会留下空隙。
  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    if let scroller = subview as? NSScroller { scroller.isHidden = true }
  }

  override func cursorStyleChanged(source: Terminal, newStyle: SwiftTerm.CursorStyle) {
    if preferredCursorStyle == nil {
      programCursorStyle = newStyle
      super.cursorStyleChanged(source: source, newStyle: newStyle)
      if !isWindowActive {
        Task { @MainActor [weak self] in self?.applyEffectiveCursorStyle() }
      }
      return
    }
    guard let effective = effectiveCursorStyle, newStyle != effective else {
      super.cursorStyleChanged(source: source, newStyle: newStyle)
      return
    }
    // `Terminal.setCursorStyle` 是「先回调、后写 options」的顺序，在回调内改 options
    // 会被紧随其后的赋值覆盖，因此纠正必须排到本次调用返回之后再执行。
    Task { @MainActor [weak self] in
      self?.applyEffectiveCursorStyle()
    }
  }

  /// 把终端选项与 caret 视图对齐到当前应生效的样式（同时触发 Metal 路径重绘）。
  private func applyEffectiveCursorStyle() {
    guard let style = effectiveCursorStyle else { return }
    let terminal = getTerminal()
    terminal.options.cursorStyle = style
    super.cursorStyleChanged(source: terminal, newStyle: style)
  }
}

extension NSEvent {
  /// SwiftTerm 在 `linkReporting = .none` 时仍会用 Command 修饰符执行链接点击查询。
  /// 仅移除它用于链接激活的 Command 位；SwiftTerm 的终端鼠标协议只编码 Shift、
  /// Option 和 Control，因此 TUI 收到的按下/释放序列保持一致。
  fileprivate func removingCommandModifier() -> NSEvent? {
    guard modifierFlags.contains(.command) else { return self }
    return NSEvent.mouseEvent(
      with: type,
      location: locationInWindow,
      modifierFlags: modifierFlags.subtracting(.command),
      timestamp: timestamp,
      windowNumber: windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: clickCount,
      pressure: pressure
    )
  }

  /// Rebuilds a keyboard event with the opposite arrow key while preserving timestamp and
  /// modifier semantics. SwiftTerm reads the hardware keyCode to honor application-cursor mode.
  fileprivate func replacingArrowKeyCode(_ keyCode: UInt16) -> NSEvent? {
    let functionKey = keyCode == 123 ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey
    let arrowCharacters = String(Character(UnicodeScalar(UInt32(functionKey))!))
    return NSEvent.keyEvent(
      with: type,
      location: locationInWindow,
      modifierFlags: modifierFlags,
      timestamp: timestamp,
      windowNumber: windowNumber,
      context: nil,
      characters: arrowCharacters,
      charactersIgnoringModifiers: arrowCharacters,
      isARepeat: isARepeat,
      keyCode: keyCode
    )
  }
}

extension SwiftTerm.CursorStyle {
  /// 同一形状的不闪烁变体。
  var nonBlinking: SwiftTerm.CursorStyle {
    switch self {
    case .blinkBlock, .steadyBlock: .steadyBlock
    case .blinkHollowBlock, .steadyHollowBlock: .steadyHollowBlock
    case .blinkUnderline, .steadyUnderline: .steadyUnderline
    case .blinkBar, .steadyBar: .steadyBar
    }
  }
}

/// 一个由 SwiftTerm 完整 VT/xterm 网格承载的本地登录 Shell。
///
/// Session 强持有 `LocalProcessTerminalView`，因此在标签切换或 AppKit 重排视图时，
/// PTY、滚动历史和全屏 TUI 状态不会丢失。AppKit 视图只通过这里暴露的窄接口被
/// 工作区操作，避免其它页面直接依赖 SwiftTerm 的进程实现。
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
  let id = UUID()
  let workingDirectory: String
  /// Outline 页只关心命令时间线结构变化；使用专用事件避免把高频终端输出提升为
  /// `objectWillChange`，也让已打开的大纲能在命令完成后局部更新。
  let outlineChanged = PassthroughSubject<Void, Never>()

  @Published private(set) var isRunning = false
  @Published private(set) var currentWorkingDirectory: String
  /// false 表示最近 OSC 7 指向其它主机；相对文件不能继续复用旧本机 CWD。
  @Published private(set) var currentWorkingDirectoryIsLocal = true
  @Published private(set) var terminalTitle = "Shell"
  @Published private(set) var terminalIconTitle = ""
  @Published private(set) var exitCode: Int32?
  @Published private(set) var startupError: String?
  /// Shell Integration 已观察到至少一个合法 OSC 133 标记；用于停用进程轮询回退。
  @Published private(set) var shellIntegrationDetected = false
  /// 最近一条完整命令的退出状态。nil 表示尚无完整记录或 Shell 未提供状态。
  @Published private(set) var lastCommandExitStatus: Int?
  /// 是否有前台命令正在运行且近期有输出（区别于 `isRunning` 的 shell 存活）。
  /// 由 PTY 前台进程组 + 终端缓冲活跃度轮询驱动，只在状态翻转时发布，
  /// 是侧栏运行中 spinner 的唯一业务状态源。
  @Published private(set) var hasRunningCommand = false
  /// OSC 9;4 与 shell 自动进度的统一状态，供标签和 Dock 聚合，不持久化运行态。
  @Published private(set) var progressState = TerminalProgressState.clear
  /// 交互提示在输出尾部静默约 1.5 秒后置位；任意用户输入立即清除。
  @Published private(set) var awaitingInput = false
  /// 成功完成后短暂显示 checkmark，随后退化为未读完成圆点。
  @Published private(set) var showsCompletedFlash = false
  @Published private(set) var explicitBadge: TerminalBadgeState?
  /// 当前前台命令可明确识别为受支持 Agent 时发布 provider 与折叠状态。识别仅来自
  /// 用户提交命令的首个 token；不会扫描任意输出或把相似进程名误判为 Agent。
  @Published private(set) var activeAgentProvider: AgentProvider?
  @Published private(set) var activeAgentSessionID: String?
  @Published private(set) var agentTaskState = AgentTaskState.idle
  @Published private(set) var agentTaskCompletionUnread = false
  /// Hook 是否已成为该 Pane 的权威状态源。Prompt Queue 的自动派发只接受 hook 结论：
  /// 输出探针推断出来的 idle 只说明屏幕安静了一会儿，据此写入会打断运行中的 TUI。
  var hasAuthoritativeAgentLifecycle: Bool { agentLifecycleIsAuthoritative }
  /// 当前前台命令的展示名:优先 Agent provider 名,否则取已提交命令的首个 token;
  /// 没有前台命令时为 nil。供 Open Quickly「当前」页显示运行中的命令(如 kimi)。
  var foregroundCommandName: String? {
    guard hasRunningCommand else { return nil }
    if let activeAgentProvider { return activeAgentProvider.commandName }
    guard let submittedCommand else { return nil }
    let executable = ShellCommandTokenizer.tokenize(submittedCommand).tokens.first ?? ""
    return executable.isEmpty ? nil : (executable as NSString).lastPathComponent
  }
  /// Hook 状态一旦到达即成为当前 Agent 命令的权威来源；否则保留前台进程与输出
  /// 探针回退，未安装集成的 Agent 仍能显示基本 processing 状态。
  private var agentLifecycleIsAuthoritative = false
  private var agentLifecycleSequence: UInt64 = 0
  private var agentStateReducer = AgentTaskStateReducer()

  private var foregroundPollTask: Task<Void, Never>?
  // 输出活跃度探针：可见屏幕内容哈希。Claude Code 等 TUI 思考时在原位重绘状态行
  // （光标与滚动位置都不变，只有单元格内容变化），必须按内容而非光标位置探测，
  // 否则 spinner 会时有时无。
  private var lastScreenHash = 0
  private var lastActivityAt = Date.distantPast
  /// 设置关闭或 Pane 失焦时立即释放；PTY 模式由输出、输入前检查与低频兜底轮询采样。
  private var automaticSecureInputEnabled = true
  private weak var preferences: AppPreferences?
  private var submittedCommand: String?
  private var submittedCommandOrigin = WorkflowRecipeCommandOrigin.shellIntegration
  private var pendingCommandOrigin: WorkflowRecipeCommandOrigin?
  private(set) var recipeCommandCandidates: [WorkflowRecipeCommandCandidate] = []
  private var activityOutputTail = ""
  private var awaitingInputTask: Task<Void, Never>?
  private var completedFlashTask: Task<Void, Never>?
  private var progressExpiryTask: Task<Void, Never>?

  private var terminalView: AsterTerminalView?
  private var targetOpenCoordinator: TerminalTargetOpenCoordinator?
  private var autocompleteController: TerminalAutocompleteController?
  /// OSC 0/1/2 的独立通道回调。Tab 领域状态负责固定名称、前缀与持久化。
  var onTitleUpdate: ((Int, String) -> Void)?
  /// Vi `/` 或 `?` 请求显示现有查找栏；工作区拥有展示状态，Session 只保存方向。
  var onRequestFind: (() -> Void)?
  var onCommandFinished: (() -> Void)?
  var onPasteIntoComposer: ((String) -> Void)? {
    didSet { terminalView?.onPasteIntoComposer = onPasteIntoComposer }
  }
  var onSendSelectionToChat: (() -> Void)? {
    didSet { terminalView?.onSendSelectionToChat = onSendSelectionToChat }
  }
  private var pendingViSearchDirection: TerminalViSearchDirection?
  private var lastFindTerm = ""
  private var lastFindWasPrevious = false
  private var readOnly = false
  /// SwiftTerm 视图一旦启动就保持在同一个 AppKit 容器中。工作区刷新只移动该容器，
  /// 不直接反复把 Metal-backed 终端视图从 superview 拆下，避免分屏后网格停止绘制。
  private var terminalHostView: NSView?

  /// SwiftTerm 的进程对象是运行状态的权威来源。`isRunning` 负责触发 AppKit 刷新，
  /// 但分屏恢复期间回调与视图挂载顺序可能让缓存短暂过期，状态栏必须读取真实值。
  var statusIsRunning: Bool {
    terminalView?.process.running ?? isRunning
  }

  /// 当前 Pane 的 Shell PID。仅用于只读进程/端口检查，不保存到工作区快照。
  var processIdentifier: Int32? {
    guard let process = terminalView?.process, process.running, process.shellPid > 0 else {
      return nil
    }
    return process.shellPid
  }

  /// CLI 写入 SSH/sudo/su Pane 需要第二个显式权限。判断只使用当前 Shell Integration
  /// 命令首 token 与远端 OSC 7 状态，不扫描终端输出，避免提示文字造成误判。
  var isSensitiveAutomationSession: Bool {
    if !currentWorkingDirectoryIsLocal { return true }
    guard let command = submittedCommand else { return false }
    let executable = ShellCommandTokenizer.tokenize(command).tokens.first.map {
      URL(fileURLWithPath: $0).lastPathComponent
    }
    return ["ssh", "mosh", "sudo", "su"].contains(executable)
  }

  /// 标签层消费的 Agent 专属徽章。若用户关闭某类徽章，返回 nil 让聚合器忽略
  /// Agent 的长寿命前台进程，而不是回退成普通 shell spinner。
  var agentActivityBadge: TerminalBadgeState? {
    guard activeAgentProvider != nil, let agents = preferences?.configuration.agents else {
      return nil
    }
    switch agentTaskState {
    case .processing:
      return agents.badgeProcessing ? .running(percent: nil) : TerminalBadgeState.none
    case .awaitingInput:
      return agents.badgeAwaitingInput ? .awaitingInput : TerminalBadgeState.none
    case .idle:
      return agents.badgeTaskComplete && agentTaskCompletionUnread
        ? .finished : TerminalBadgeState.none
    }
  }

  init(workingDirectory: String) {
    self.workingDirectory = workingDirectory
    currentWorkingDirectory = workingDirectory
    super.init()
  }

  /// 返回长期存活的终端视图；首次调用时才创建 PTY，确保 AppKit 窗口已完成初始化。
  func makeTerminalView(preferences: AppPreferences) -> LocalProcessTerminalView {
    self.preferences = preferences
    if let terminalView {
      apply(preferences: preferences, to: terminalView)
      return terminalView
    }

    let view = AsterTerminalView(frame: .zero)
    view.processDelegate = self
    view.onObservedTitleUpdate = { [weak self] code, title in
      Task { @MainActor [weak self] in self?.handleTitleOSC(code: code, text: title) }
    }
    let targetOpenCoordinator = TerminalTargetOpenCoordinator(preferences: preferences)
    self.targetOpenCoordinator = targetOpenCoordinator
    view.onRequestOpenTarget = { [weak self] rawValue, source in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.targetOpenCoordinator?.open(
          rawValue,
          source: source,
          currentDirectory: self.currentWorkingDirectoryIsLocal
            ? self.currentWorkingDirectory : ""
        )
      }
    }
    view.onResolveHintCopyTarget = { [weak self] rawValue, source in
      self?.resolvedHintCopyTarget(rawValue, source: source)
    }
    view.setReadOnly(readOnly)
    view.onRequestViSearch = { [weak self] direction in
      self?.pendingViSearchDirection = direction
      self?.onRequestFind?()
    }
    view.onRepeatViSearch = { [weak self] reverse in
      self?.repeatLastFind(reverse: reverse)
    }
    view.onPaneModeActivated = { [weak self] in
      self?.autocompleteController?.dismissForPaneMode()
    }
    view.onPasteIntoComposer = onPasteIntoComposer
    view.onSendSelectionToChat = onSendSelectionToChat
    view.onTerminalIO = { [weak self] in self?.refreshAutomaticSecureInput() }
    view.onTerminalOutputActivity = { [weak self] line in self?.receiveActivityOutput(line) }
    view.onTerminalUserInput = { [weak self] in self?.handleTerminalUserInput() }
    view.onAgentTerminalDirective = { [weak self] directive in
      self?.handleAgentTerminalDirective(directive)
    }
    view.onShellIntegrationStateChange = { [weak self] timeline in
      self?.handleShellIntegrationTimeline(timeline)
    }
    if let service = AutocompleteService.shared {
      let autocomplete = TerminalAutocompleteController(
        service: service,
        sessionIdentifier: id.uuidString,
        controls: { [weak preferences] in
          preferences?.configuration.controls ?? ControlConfiguration()
        },
        currentDirectory: { [weak self] in
          guard let self, self.currentWorkingDirectoryIsLocal else { return "" }
          return self.currentWorkingDirectory
        }
      )
      autocomplete.attach(to: view)
      autocomplete.onCommandSubmitted = { [weak self] command in
        guard let self else { return }
        self.submittedCommand = command
        self.submittedCommandOrigin = self.pendingCommandOrigin ?? .shellIntegration
        self.pendingCommandOrigin = nil
      }
      view.onAutocompleteInput = { [weak autocomplete] in autocomplete?.receiveInput($0) }
      view.onAutocompleteOutput = { [weak autocomplete] in autocomplete?.receiveOutput($0) }
      view.onShellIntegrationEvent = { [weak self, weak autocomplete] event in
        self?.handleShellIntegrationEvent(event)
        autocomplete?.receive(event)
      }
      view.onShellAliases = { [weak autocomplete] in autocomplete?.receiveAliases($0) }
      view.onAutocompleteKeyDown = { [weak autocomplete] in autocomplete?.handleKeyDown($0) ?? false }
      autocompleteController = autocomplete
    } else {
      view.onShellIntegrationEvent = { [weak self] event in
        self?.handleShellIntegrationEvent(event)
      }
    }
    view.autoresizingMask = [.width, .height]
    view.allowMouseReporting = preferences.allowMouseReporting
    view.optionAsMetaKey = preferences.optionAsMeta
    view.linkHighlightMode = .hoverWithModifier
    apply(preferences: preferences, to: view)
    // SwiftTerm 默认只把 OSC 0/2 作为同一个窗口标题回调，且丢弃 macOS 上的 OSC 1。
    // 注册专用处理器保留协议通道，才能让短标签名与窗口标题独立演进。处理器负责
    // 回写 SwiftTerm 自身标题状态；工作区事件由原始字节观察器按顺序统一上送，避免
    // delegate 与自定义 handler 的调度先后打乱 XTWINOPS 恢复和后续 OSC。
    let terminal = view.getTerminal()
    view.installShellIntegrationHandler()
    view.installActivityHandlers()
    view.onTerminalProgress = { [weak self] progress in self?.handleTerminalProgress(progress) }
    view.onTerminalNotification = { [weak self] notification in
      self?.post(notification, category: .application)
    }
    view.onTerminalBadgeDirective = { [weak self] directive in
      switch directive {
      case .set(let badge): self?.explicitBadge = badge
      case .clear: self?.explicitBadge = nil
      }
    }
    view.onTerminalProtocolResponse = { [weak view] response in
      view?.process.send(data: Array(response.utf8)[...])
    }
    view.installTitleHandlers()
    let clipboardCoordinator = OSC52ClipboardCoordinator(
      access: { [weak preferences] operation in
        guard let controls = preferences?.configuration.controls else { return .deny }
        switch operation {
        case .read: return controls.resolvedClipboardReadAccess
        case .write: return controls.resolvedClipboardWriteAccess
        }
      }
    )
    terminal.registerOscHandler(code: 52) { [weak view, clipboardCoordinator] bytes in
      guard let response = clipboardCoordinator.handle(bytes) else { return }
      // OSC 52 读取响应属于协议回包，不是用户输入；直接写 PTY，避免污染输入活跃度。
      view?.process.send(data: response[...])
    }

    let inheritedEnvironment = ProcessInfo.processInfo.environment
    var shell = inheritedEnvironment["SHELL"] ?? "/bin/zsh"
    if !FileManager.default.isExecutableFile(atPath: shell) {
      appendStartupWarning("配置的 Shell 不可执行：\(shell)。已回退到 /bin/zsh。")
      shell = "/bin/zsh"
    }
    let resourcesDirectory = AsterResourceLocations.resourcesDirectory()?.path
    let launchEnvironment = TerminalLaunchEnvironmentBuilder.make(
      inherited: inheritedEnvironment,
      configuredTerm: preferences.terminalIdentity,
      shellPath: shell,
      shellIntegrationEnabled: preferences.configuration.shell.shellIntegration,
      paneIdentifier: id.uuidString,
      version: AsterResourceLocations.productVersion(),
      resourcesDirectory: resourcesDirectory,
      terminfoEntryExists: SystemTerminfoChecker.entryExists
    )
    if let warning = launchEnvironment.resolution.warning {
      appendStartupWarning(warning)
    }
    terminal.options.termName = launchEnvironment.resolution.term
    terminal.programIdentity = launchEnvironment.programIdentity
    let entries = launchEnvironment.environment
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    var launchDirectory = currentWorkingDirectory
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: launchDirectory, isDirectory: &isDirectory)
      || !isDirectory.boolValue
    {
      launchDirectory = FileManager.default.homeDirectoryForCurrentUser.path
      currentWorkingDirectory = launchDirectory
      appendStartupWarning("原工作目录不可用，已回退到主目录。")
    }
    view.startProcess(
      executable: shell,
      args: Self.launchArguments(forShell: shell),
      environment: entries,
      currentDirectory: launchDirectory
    )

    terminalView = view
    isRunning = view.process?.running == true
    if !isRunning, startupError == nil {
      startupError = "无法创建本地终端进程。"
    }
    if isRunning { startForegroundPolling() }
    return view
  }

  /// 周期比较 PTY 前台进程组与 shell 自身 pgid：不一致即有命令在前台运行。
  /// 再叠加终端缓冲活跃度（光标/滚动位置变化 = 有输出）：前台命令长时间无输出
  /// （如等待交互输入的 TUI）时停止 spinner。轮询本身不发布任何事件，
  /// 只有 `hasRunningCommand` 翻转时才触发 UI 刷新。
  private func startForegroundPolling() {
    foregroundPollTask?.cancel()
    foregroundPollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self else { return }
        guard let process = self.terminalView?.process, process.running, process.childfd >= 0 else {
          // shell 已退出：清状态并结束轮询，避免空转任务泄漏。
          if self.hasRunningCommand { self.hasRunningCommand = false }
          SecureInputCoordinator.shared.releaseAutomaticRequest(for: self.id)
          return
        }
        self.updateAutomaticSecureInput(process: process)
        // 一旦 Shell 提供 FTCS，C/D 是命令生命周期的权威来源。轮询继续负责安全输入，
        // 但不再用前台进程组覆盖精确状态，避免 TUI 子进程或短命令造成闪烁。
        if self.shellIntegrationDetected { continue }
        let foreground = tcgetpgrp(process.childfd)
        let running = foreground > 0 && foreground != process.shellPid
        // 仅在有前台命令时才计算屏幕哈希（每秒一次、只扫可见行，成本可忽略）。
        if running, let terminal = self.terminalView?.getTerminal() {
          var hasher = Hasher()
          let buffer = terminal.buffer
          hasher.combine(buffer.x)
          hasher.combine(buffer.y)
          hasher.combine(buffer.yDisp)
          for row in 0..<terminal.rows {
            if let line = terminal.getLine(row: row) {
              hasher.combine(line.translateToString(trimRight: true))
            }
          }
          let hash = hasher.finalize()
          if hash != self.lastScreenHash {
            self.lastScreenHash = hash
            self.lastActivityAt = Date()
          }
        }
        // 5 秒静默窗口：TUI 工作时至少每秒重绘一次状态行不会触边；真正等待输入的
        // 静止界面在窗口过后停转。命令退出时 running 立即为 false，不受窗口影响。
        let active = running && Date().timeIntervalSince(self.lastActivityAt) < 5
        if self.hasRunningCommand != active { self.hasRunningCommand = active }
      }
    }
  }

  /// 返回长期存活的 AppKit 容器。容器和终端的父子关系在 Session 生命周期内保持不变，
  /// 标签切换、主题刷新或递归分屏只会重新安放最外层容器。
  func makeTerminalHost(preferences: AppPreferences) -> NSView {
    let terminal = makeTerminalView(preferences: preferences)
    if let terminalHostView {
      terminalHostView.layer?.backgroundColor = preferences.terminalBackgroundColor.cgColor
      return terminalHostView
    }
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = preferences.terminalBackgroundColor.cgColor
    host.addSubview(terminal)
    terminal.pinEdges(to: host)
    terminalHostView = host
    return host
  }

  func apply(preferences: AppPreferences) {
    guard let terminalView else { return }
    apply(preferences: preferences, to: terminalView)
  }

  /// 将命令直接写入活动 PTY，供 Recipe、命令面板和自动化入口使用。
  func send(_ command: String) {
    guard let terminalView, terminalView.process.running else { return }
    let bytes = Array((command + "\n").utf8)
    // Recipe 和命令面板也是用户输入入口；必须经过视图才能应用清选区、回到底部、
    // 输入活跃度和安全键盘采样，不能直接绕过到 LocalProcess。
    terminalView.send(data: bytes[...])
  }

  @discardableResult
  func sendRecipeCommand(_ command: String) -> Bool {
    guard terminalView?.process.running == true else { return false }
    pendingCommandOrigin = .recipeReplay
    send(command)
    return true
  }

  /// 把文本原样写入 PTY（不带回车）：用于把命令预填到提示符，执行与否由用户确认。
  func typeText(_ text: String) {
    guard let terminalView, terminalView.process.running else { return }
    let bytes = Array(text.utf8)
    terminalView.send(data: bytes[...])
  }

  /// IPC send-text/send-keys 的原始用户输入入口。仍经 `AsterTerminalView.send`，因此
  /// Read-only、Vi/Hint 本地模式、选择清理与输入活跃度规则不会被自动化绕过。
  @discardableResult
  func sendAutomationBytes(_ bytes: [UInt8]) -> Bool {
    guard let terminalView, terminalView.process.running, !bytes.isEmpty,
      bytes.count <= WorkflowCLIInputDecoder.maximumBytes
    else { return false }
    terminalView.send(data: bytes[...])
    return true
  }

  var selectedTextForAgentContext: String? {
    terminalView?.getSelection()
  }

  /// 外部拖入的文本与普通粘贴共享风险分析、确认、bracketed paste 和只读门禁。
  @discardableResult
  func pasteDroppedText(_ text: String) -> Bool {
    terminalView?.pasteText(text) ?? false
  }

  /// 把提示词以 bracketed paste 写入终端输入行但不回车，供 Open Quickly「当前」页
  /// 复用历史 prompt；粘贴保护与只读门禁仍由终端视图统一执行。
  @discardableResult
  func pastePromptText(_ text: String) -> Bool {
    terminalView?.pasteText(text, forceBracketed: true) ?? false
  }

  /// 以普通键入方式预填 Agent 输入框，不带 Return。该入口只供 Prompt Queue 与
  /// “发送到聊天”使用，避免影响 Open Quickly 的既有安全粘贴。
  @discardableResult
  func typePromptText(_ text: String) -> Bool {
    terminalView?.typePromptText(text) ?? false
  }

  /// 当前阻止 Prompt 写入前台程序的原因，可写入时为 nil。失败提示必须能落到具体
  /// 动作上：只说“写入失败”，用户无从判断该解锁 Pane、退出 Vi 还是等终端就绪。
  var promptWriteBlocker: String? {
    guard let terminalView else { return "终端视图尚未就绪" }
    guard terminalView.process.running else { return "终端进程已退出" }
    if terminalView.isReadOnly { return "Pane 处于只读模式" }
    if terminalView.navigationMode != .normal { return "Pane 处于 Vi/Hint 模式" }
    return nil
  }

  /// Composer 使用 bracketed paste 一次写入多行内容，再单独发送 Return。这样 Agent
  /// TUI 能把多行当作一个 prompt；粘贴保护和 Read-only 仍由终端视图统一执行。
  @discardableResult
  func submitComposerText(_ text: String) -> Bool {
    guard let terminalView, terminalView.process.running,
      terminalView.pasteText(text, forceBracketed: true)
    else { return false }
    terminalView.send(data: [UInt8(13)][...])
    return true
  }

  /// Prompt Queue 的内容由用户在 Aster 内亲自编辑，不是来自剪贴板；因此按真实键入的
  /// UTF-8 字节写入后立即发送 Return，而不强制插入 bracketed-paste 控制序列。部分
  /// Codex/Claude TUI 未协商该模式时会忽略强制序列，导致看似发送成功但输入框无变化。
  @discardableResult
  func submitPromptQueueText(_ text: String) -> Bool {
    terminalView?.submitPromptQueueText(text) ?? false
  }

  func interrupt() {
    guard let terminalView, terminalView.process.running else { return }
    let controlC = [UInt8(3)]
    terminalView.send(data: controlC[...])
  }

  func focus() {
    guard let terminalView, let window = terminalView.window else { return }
    window.makeFirstResponder(terminalView)
    refreshAutomaticSecureInput()
  }

  /// 在完整滚动缓冲区内查找并选中下一处匹配文本。
  @discardableResult
  func findNext(
    _ term: String,
    previous: Bool = false,
    caseSensitive: Bool = false,
    regularExpression: Bool = false
  ) -> Bool {
    guard let terminalView, !term.isEmpty else { return false }
    let resolvedPrevious: Bool
    if previous {
      resolvedPrevious = true
      pendingViSearchDirection = nil
    } else if let pendingViSearchDirection {
      resolvedPrevious = pendingViSearchDirection == .backward
      self.pendingViSearchDirection = nil
    } else {
      resolvedPrevious = false
    }
    let options = SearchOptions(caseSensitive: caseSensitive, regex: regularExpression)
    let found = resolvedPrevious
      ? terminalView.findPrevious(term, options: options)
      : terminalView.findNext(term, options: options)
    if found {
      lastFindTerm = term
      lastFindWasPrevious = resolvedPrevious
    }
    return found
  }

  /// 当前选中匹配与总匹配数，供查找栏显示 `N / M`。总数在 SwiftTerm 内部有界，
  /// 不会因为频繁输入搜索词而扫描或分配无界结果数组。
  func findMatchSummary(
    _ term: String,
    caseSensitive: Bool = false,
    regularExpression: Bool = false
  ) -> (index: Int, total: Int) {
    guard let terminalView, !term.isEmpty else { return (0, 0) }
    return terminalView.searchMatchSummary(
      term,
      options: SearchOptions(caseSensitive: caseSensitive, regex: regularExpression)
    )
  }

  func clearFind() {
    terminalView?.clearSearch()
    lastFindTerm = ""
    pendingViSearchDirection = nil
  }

  func textSnapshot() -> TerminalTextSnapshot {
    terminalView?.boundedTextSnapshot() ?? .init(firstAbsoluteRow: 0, lines: [])
  }

  func commandOutlineEntries() -> [TerminalCommandOutlineEntry] {
    terminalView?.commandOutlineEntries() ?? []
  }

  @discardableResult
  func revealAbsoluteRow(_ row: Int) -> Bool {
    terminalView?.revealAbsoluteRow(row) ?? false
  }

  private func repeatLastFind(reverse: Bool) {
    guard let terminalView, !lastFindTerm.isEmpty else { return }
    let previous = reverse ? !lastFindWasPrevious : lastFindWasPrevious
    _ = previous
      ? terminalView.findPrevious(lastFindTerm)
      : terminalView.findNext(lastFindTerm)
  }

  func setReadOnly(_ value: Bool) {
    readOnly = value
    terminalView?.setReadOnly(value)
  }

  func toggleReadOnly() { setReadOnly(!readOnly) }
  func enterViMode() { terminalView?.enterViMode(nil) }
  func enterMarkMode() { terminalView?.enterMarkMode(nil) }
  func openHintMode() { terminalView?.openHintMode(nil) }

  /// 立即读取由 OSC 7 报告的工作目录。没有集成标记时保留最近一次可靠值。
  func resolvedCurrentWorkingDirectory() -> String {
    currentWorkingDirectory
  }

  /// 将 SwiftTerm 的 OSC 7 目录值转换为本地绝对路径。Shell 通常上报
  /// `file://localhost/path`，也允许直接上报路径；返回空串表示值不可用。
  static func normalizeReportedWorkingDirectory(_ reportedValue: String) -> String {
    guard !reportedValue.isEmpty else { return "" }
    if let url = URL(string: reportedValue), url.isFileURL {
      guard isLocalFileURLHost(url.host) else { return "" }
      return url.path.removingPercentEncoding ?? url.path
    }
    return reportedValue.removingPercentEncoding ?? reportedValue
  }

  /// Hint 的 Shift 动作只复制规范化目标，不执行安全确认或系统打开。文件路径保留可选
  /// 行列后缀，使复制结果既是绝对路径，也能继续交给编辑器或其它终端工具定位。
  private func resolvedHintCopyTarget(
    _ rawValue: String,
    source: DetectedTargetSource
  ) -> String? {
    guard let preferences else { return nil }
    let currentDirectory = currentWorkingDirectoryIsLocal ? currentWorkingDirectory : ""
    guard let target = try? TargetResolver().resolve(
      rawValue,
      currentDirectory: currentDirectory,
      source: source,
      schemePolicy: preferences.configuration.controls.resolvedLinkSchemePolicy
    ) else { return nil }
    switch target {
    case .url(let target):
      return target.url.absoluteString
    case .file(let file):
      if let line = file.line, let column = file.column {
        return "\(file.path):\(line):\(column)"
      }
      if let line = file.line { return "\(file.path):\(line)" }
      return file.path
    }
  }

  private static func isLocalFileURLHost(_ host: String?) -> Bool {
    guard let host, !host.isEmpty else { return true }
    let normalized = host.lowercased()
    let machine = ProcessInfo.processInfo.hostName.lowercased()
    let shortMachine = machine.split(separator: ".").first.map(String.init) ?? machine
    return ["localhost", "127.0.0.1", "::1", machine, shortMachine].contains(normalized)
  }

  /// 同步窗口活动状态：非活动窗口停止光标闪烁。
  func setWindowActive(_ active: Bool) {
    terminalView?.setWindowActive(active)
    if active {
      refreshAutomaticSecureInput()
    } else {
      SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
    }
  }

  /// 停止当前 Shell。关闭 Pane 时先给予 750ms 正常退出窗口；应用即将终止时必须
  /// 立即结束进程组，因为主事件循环不会继续存活到延迟升级任务执行。
  func stop(immediately: Bool = false) {
    guard let view = terminalView else {
      isRunning = false
      return
    }
    terminalView = nil
    terminalHostView = nil
    targetOpenCoordinator = nil
    autocompleteController = nil
    isRunning = false
    foregroundPollTask?.cancel()
    foregroundPollTask = nil
    awaitingInputTask?.cancel()
    completedFlashTask?.cancel()
    progressExpiryTask?.cancel()
    SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)

    // SwiftTerm 1.15 的 `terminate()` 会在发送信号后立即取消进程监视器，且自然退出
    // 后保留旧 PID。托管器只接受仍运行的 View，并在 Session 释放后继续负责升级
    // 信号及等待 monitor 回收，避免僵尸进程和 PID 复用后的误杀。
    TerminalRetirementCoordinator.shared.retire(view, immediately: immediately)
  }

  private func apply(preferences: AppPreferences, to view: AsterTerminalView) {
    self.preferences = preferences
    let fonts = preferences.terminalFontVariants
    view.setFonts(
      normal: fonts.normal,
      bold: fonts.bold,
      italic: fonts.italic,
      boldItalic: fonts.boldItalic
    )
    view.lineSpacing = CGFloat(preferences.configuration.appearance.lineHeight)
    view.fontSmoothing = preferences.configuration.appearance.resolvedFontSmoothing
    view.bidirectionalTextEnabled = preferences.configuration.appearance.resolvedBidirectionalText
    view.ligatureMode = switch preferences.configuration.appearance.resolvedLigatureLevel {
    case .none: .none
    case .standard: .standard
    case .discretionary: .discretionary
    }
    view.boldStyleMode = swiftTermFontStyleMode(
      preferences.configuration.appearance.resolvedBoldRendering)
    view.italicStyleMode = swiftTermFontStyleMode(
      preferences.configuration.appearance.resolvedItalicRendering)
    view.underlineStyleEnabled = preferences.configuration.appearance.resolvedUnderlineRendering
    view.smoothCursorMovementEnabled =
      preferences.configuration.appearance.resolvedCursorAnimation == .smooth
    view.animatedTextBlinkEnabled =
      preferences.configuration.appearance.resolvedBlinkRenderingPolicy == .animated
    view.getTerminal().options.widenedEastAsianAmbiguousBlocks = swiftTermAmbiguousWidthBlocks(
      preferences.configuration.appearance.resolvedWidenedEastAsianAmbiguousBlocks)
    view.nativeForegroundColor = preferences.terminalForegroundColor
    view.nativeBackgroundColor = preferences.terminalBackgroundColor
    view.caretColor = preferences.cursorColor
    view.caretTextColor = preferences.cursorTextColor
    view.selectedTextForegroundColor = preferences.selectionForegroundColor
    view.selectedTextBackgroundColor = preferences.selectionColor
    view.optionAsMetaKey = preferences.optionAsMeta
    view.allowMouseReporting = preferences.allowMouseReporting
    view.linkReporting =
      preferences.configuration.controls.resolvedLinkDetectionEnabled
      ? .implicit : .none
    view.linkSchemePolicy = preferences.configuration.controls.resolvedLinkSchemePolicy
    view.copyOnSelect = preferences.configuration.controls.copyOnSelect
    view.trimTrailingSpacesOnCopy = preferences.configuration.controls.trimTrailingSpaces
    view.shiftArrowSelectionEnabled =
      preferences.configuration.controls.resolvedShiftArrowSelection
    view.clearSelectionOnTyping =
      preferences.configuration.controls.resolvedClearSelectionOnTyping
    view.clearSelectionOnCopy = preferences.configuration.controls.resolvedClearSelectionOnCopy
    view.applyScrollConfiguration(preferences.configuration.controls)
    view.pasteProtectionEnabled = preferences.configuration.controls.pasteProtection
    view.pasteBracketedSafe = preferences.configuration.controls.resolvedPasteBracketedSafe
    view.terminalBellEnabled = preferences.configuration.shell.terminalBell
    view.titleShellControlled = preferences.configuration.shell.resolvedTitleShellControlled
    view.getTerminal().allowTitleReport = preferences.configuration.shell.resolvedTitleReport
    automaticSecureInputEnabled = preferences.configuration.controls.secureInputAutomatically
    if automaticSecureInputEnabled {
      refreshAutomaticSecureInput()
    } else {
      SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
    }
    view.installColors(
      preferences.ansiColors.map {
        SwiftTerm.Color(
          red: UInt16($0.red) * 257,
          green: UInt16($0.green) * 257,
          blue: UInt16($0.blue) * 257
        )
      })
    let blinkMode = preferences.configuration.appearance.resolvedCursorBlinkMode
    let cursorStyle = swiftTermCursorStyle(
      preferences.configuration.appearance.cursorStyle.rawValue,
      blinks: blinkMode.initiallyBlinks
    )
    view.configureCursor(initialStyle: cursorStyle, pinsProgramControl: blinkMode.pinsProgramControl)
    view.needsDisplay = true
  }

  private func refreshAutomaticSecureInput() {
    guard let process = terminalView?.process, process.running, process.childfd >= 0 else {
      SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
      return
    }
    updateAutomaticSecureInput(process: process)
  }

  /// 从 PTY termios 读取 ECHO 与 ICANON，而不是猜测屏幕上的 “Password:” 文本。密码式
  /// 输入通常保留 canonical 模式并关闭回显；Vim/less 等 raw-mode TUI 同时关闭
  /// ICANON，必须排除，否则会长期占用系统级 Secure Event Input。
  private func updateAutomaticSecureInput(process: LocalProcess) {
    var attributes = termios()
    guard tcgetattr(process.childfd, &attributes) == 0 else {
      SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
      return
    }
    let echoEnabled = (attributes.c_lflag & tcflag_t(ECHO)) != 0
    let canonicalMode = (attributes.c_lflag & tcflag_t(ICANON)) != 0
    let terminalFocused =
      terminalView?.window?.isKeyWindow == true
      && terminalView?.window?.firstResponder === terminalView
    let required = TerminalSecureInputPolicy.requiresAutomaticProtection(
      enabled: automaticSecureInputEnabled,
      terminalFocused: terminalFocused,
      terminalEchoEnabled: echoEnabled,
      terminalCanonicalMode: canonicalMode
    )
    SecureInputCoordinator.shared.setAutomaticRequest(for: id, active: required)
  }

  private func handleTitleOSC(code: Int, text: String) {
    var state = TerminalTitleState(
      programWindowTitle: terminalTitle == "Shell" ? "" : terminalTitle,
      programIconName: terminalIconTitle,
      fallback: "Shell"
    )
    state.applyOSC(code: code, text: text)
    terminalTitle = state.programWindowTitle.isEmpty ? "Shell" : state.programWindowTitle
    terminalIconTitle = state.programIconName
    onTitleUpdate?(code, text)
  }

  private func handleShellIntegrationTimeline(_ timeline: ShellCommandTimeline) {
    if shellIntegrationDetected != timeline.integrationDetected {
      shellIntegrationDetected = timeline.integrationDetected
    }
    if hasRunningCommand != timeline.isCommandRunning {
      hasRunningCommand = timeline.isCommandRunning
    }
    if lastCommandExitStatus != timeline.latestExitStatus {
      lastCommandExitStatus = timeline.latestExitStatus
    }
    outlineChanged.send()
    updateAgentTaskState()
  }

  private func handleShellIntegrationEvent(_ event: ShellIntegrationEvent) {
    switch event {
    case .promptStart, .inputStart:
      break
    case .commandStart:
      clearAwaitingInput()
      completedFlashTask?.cancel()
      showsCompletedFlash = false
      activityOutputTail = ""
      if let command = submittedCommand {
        let executable = ShellCommandTokenizer.tokenize(command).tokens.first ?? ""
        activeAgentProvider = AgentProvider.detect(executablePath: executable)
      } else {
        activeAgentProvider = nil
      }
      agentLifecycleIsAuthoritative = false
      activeAgentSessionID = nil
      agentLifecycleSequence = 0
      agentStateReducer = AgentTaskStateReducer()
      updateAgentTaskState()
      guard let command = submittedCommand,
        let shell = preferences?.configuration.shell,
        AutomaticProgressMatcher(prefixes: shell.resolvedAutoProgressCommands).matches(command)
      else { return }
      progressState = .indeterminate
    case .commandFinished(let exitStatus):
      defer { onCommandFinished?() }
      clearAwaitingInput()
      agentTaskState = .idle
      activeAgentProvider = nil
      activeAgentSessionID = nil
      agentTaskCompletionUnread = false
      agentLifecycleIsAuthoritative = false
      agentLifecycleSequence = 0
      agentStateReducer = AgentTaskStateReducer()
      if let command = submittedCommand, !command.isEmpty,
        command.utf8.count <= WorkflowRecipeTOML.maximumCommandBytes,
        !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      {
        recipeCommandCandidates.append(.init(text: command, origin: submittedCommandOrigin))
        if recipeCommandCandidates.count > WorkflowRecipeTOML.maximumCommands {
          recipeCommandCandidates.removeFirst(
            recipeCommandCandidates.count - WorkflowRecipeTOML.maximumCommands)
        }
      }
      submittedCommandOrigin = .shellIntegration
      guard let status = exitStatus else {
        progressState = .clear
        submittedCommand = nil
        return
      }
      // OSC 9;4;5 已携带完成语义时不重复通知；否则由 OSC 133 形成完成状态。
      if case .finished = progressState {
        submittedCommand = nil
        return
      }
      progressState = .finished(exitCode: status, watched: false)
      if status == 0 { showCompletedFlash() }
      notifyForCompletion(exitCode: status, watched: false)
      submittedCommand = nil
    }
  }

  private func handleTerminalProgress(_ progress: TerminalProgressState) {
    let previous = progressState
    progressState = progress
    clearAwaitingInput()
    progressExpiryTask?.cancel()
    if progress.isWorking {
      progressExpiryTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self, self.progressState == progress else { return }
        self.progressState = .clear
      }
    }
    guard previous != progress else { return }
    switch progress {
    case let .finished(exitCode, watched, notificationSuppressed):
      if exitCode == 0 { showCompletedFlash() }
      if !notificationSuppressed {
        notifyForCompletion(exitCode: exitCode, watched: watched)
      }
    case .error:
      notifyForCompletion(exitCode: 1, watched: false)
    case .clear, .determinate, .indeterminate:
      break
    }
  }

  private func notifyForCompletion(exitCode: Int, watched: Bool) {
    guard let shell = preferences?.configuration.shell else { return }
    if exitCode != 0, shell.resolvedSoundOnErrorExit { NSSound.beep() }
    let enabled = watched
      ? shell.resolvedNotifyOnWatchFinish
      : (exitCode == 0 ? shell.notifyOnFinish : shell.notifyOnError)
    guard enabled else { return }
    let title = exitCode == 0 ? "命令已完成" : "命令执行失败"
    let command = submittedCommand ?? ""
    let body = !command.isEmpty
      ? command
      : (exitCode == 0 ? "终端任务已结束。" : "退出状态：\(exitCode)")
    post(
      TerminalNotification(title: title, body: body, urgency: exitCode == 0 ? .normal : .critical),
      category: exitCode == 0 ? .commandFinish : .errorExit
    )
  }

  private func post(
    _ notification: TerminalNotification,
    category: TerminalNotificationCategory
  ) {
    guard let shell = preferences?.configuration.shell else { return }
    let focused = terminalView?.window?.isKeyWindow == true
      && terminalView?.window?.firstResponder === terminalView
    let scopedNotification = TerminalNotification(
      identifier: notification.identifier.map { "\(id.uuidString).\($0)" },
      title: notification.title,
      body: notification.body,
      urgency: notification.urgency
    )
    TerminalNotificationService.shared.post(
      scopedNotification,
      category: category,
      configuration: shell,
      sourceTabIsFocused: focused
    )
  }

  private func receiveActivityOutput(_ visibleCursorLine: String) {
    activityOutputTail = String(visibleCursorLine.suffix(4_096))
    awaitingInputTask?.cancel()
    awaitingInputTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(1_500))
      guard !Task.isCancelled, let self,
        self.hasRunningCommand || self.progressState.isWorking
      else { return }
      let detected = AwaitingInputPromptDetector.matches(self.activityOutputTail)
      if self.awaitingInput != detected {
        self.awaitingInput = detected
        self.updateAgentTaskState()
      }
    }
  }

  private func clearAwaitingInput() {
    awaitingInputTask?.cancel()
    awaitingInputTask = nil
    if awaitingInput { awaitingInput = false }
    updateAgentTaskState()
  }

  private func handleTerminalUserInput() {
    if agentTaskCompletionUnread { agentTaskCompletionUnread = false }
    // Hook 成为权威来源后，清理启发式标记不足以改变 reducer 状态；用户输入必须映射
    // 为同一事件流中的 inputSubmitted，才能从 awaiting-input 恢复 processing。
    if agentLifecycleIsAuthoritative, agentStateReducer.state == .awaitingInput {
      consumeAgentTaskStateSignal(.inputSubmitted)
    }
    clearAwaitingInput()
  }

  /// Hook 指令与本地用户提交共享同一单调序列，避免其中任一路径绕过 reducer 的乱序
  /// 保护，导致后续合法状态被误判为陈旧事件。
  private func consumeAgentTaskStateSignal(_ signal: AgentTaskStateSignal) {
    agentLifecycleSequence &+= 1
    _ = agentStateReducer.consume(.init(
      sequence: agentLifecycleSequence,
      signal: signal
    ))
  }

  private func updateAgentTaskState() {
    guard activeAgentProvider != nil else {
      if agentTaskState != .idle { agentTaskState = .idle }
      return
    }
    if agentLifecycleIsAuthoritative {
      if agentTaskState != agentStateReducer.state { agentTaskState = agentStateReducer.state }
      return
    }
    let next = AgentTaskState.fold(
      processing: hasRunningCommand || progressState.isWorking,
      awaitingInput: awaitingInput
    )
    if agentTaskState != next { agentTaskState = next }
  }

  private func handleAgentTerminalDirective(_ directive: AgentTerminalDirective) {
    // 已由 shell command 精确识别 provider 时，拒绝其它 provider 向同一 PTY 注入状态；
    // wrapper 命令无法识别时则允许首个合法 hook 建立关联。
    if let activeAgentProvider, activeAgentProvider != directive.provider { return }
    activeAgentProvider = directive.provider
    if let sessionID = directive.sessionID { activeAgentSessionID = sessionID }
    agentLifecycleIsAuthoritative = true
    let previous = agentStateReducer.state
    consumeAgentTaskStateSignal(directive.signal)
    if directive.signal == .awaitingInput {
      awaitingInput = true
    } else if awaitingInput {
      awaitingInput = false
    }
    switch directive.signal {
    case .processing, .inputSubmitted:
      agentTaskCompletionUnread = false
    case .awaitingInput:
      if previous != .awaitingInput,
        preferences?.configuration.agents.notifyAwaitingInput == true
      {
        post(
          TerminalNotification(
            title: "Agent 等待输入",
            body: "\(directive.provider.commandName) 正在等待确认或输入。"
          ),
          // Agent lifecycle hook 是 Aster 自身的任务状态，不应受 Shell Controlled
          // 对应用 OSC 通知的开关误伤；沿用命令完成分类获得独立的声音/前台策略。
          category: .commandFinish
        )
      }
    case .idle:
      if previous == .processing || previous == .awaitingInput {
        agentTaskCompletionUnread = true
        if preferences?.configuration.agents.notifyTaskComplete == true {
          post(
            TerminalNotification(
              title: "Agent 任务已完成",
              body: "\(directive.provider.commandName) 已结束当前任务。"
            ),
            category: .commandFinish
          )
        }
      }
    }
    updateAgentTaskState()
  }

  private func showCompletedFlash() {
    completedFlashTask?.cancel()
    showsCompletedFlash = true
    completedFlashTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.showsCompletedFlash = false
    }
  }

  private func appendStartupWarning(_ warning: String) {
    guard !warning.isEmpty else { return }
    if let startupError, !startupError.isEmpty {
      self.startupError = startupError + "\n" + warning
    } else {
      startupError = warning
    }
  }

  private func swiftTermCursorStyle(_ style: String, blinks: Bool) -> SwiftTerm.CursorStyle {
    switch style {
    case "bar": blinks ? .blinkBar : .steadyBar
    case "underline": blinks ? .blinkUnderline : .steadyUnderline
    case "hollowBlock": blinks ? .blinkHollowBlock : .steadyHollowBlock
    default: blinks ? .blinkBlock : .steadyBlock
    }
  }

  private func swiftTermFontStyleMode(
    _ mode: AsterCore.TerminalTextStyleRendering
  ) -> SwiftTerm.TerminalFontStyleMode {
    switch mode {
    case .automatic: .automatic
    case .disabled: .disabled
    case .primaryFontOnly: .primaryFontOnly
    case .synthetic: .synthetic
    }
  }

  /// AsterCore 持久化稳定字符串，SwiftTerm 只接收紧凑 OptionSet；转换集中在交付边界，
  /// 避免终端引擎反向依赖应用配置领域。
  private func swiftTermAmbiguousWidthBlocks(
    _ blocks: Set<AsterCore.EastAsianAmbiguousBlock>
  ) -> SwiftTerm.EastAsianAmbiguousWidthBlocks {
    var result: SwiftTerm.EastAsianAmbiguousWidthBlocks = []
    for block in blocks {
      switch block {
      case .enclosedAlphanumerics: result.insert(.enclosedAlphanumerics)
      case .numberForms: result.insert(.numberForms)
      case .arrows: result.insert(.arrows)
      case .mathematicalOperators: result.insert(.mathematicalOperators)
      case .miscellaneousTechnical: result.insert(.miscellaneousTechnical)
      case .geometricShapes: result.insert(.geometricShapes)
      case .miscellaneousSymbols: result.insert(.miscellaneousSymbols)
      case .dingbats: result.insert(.dingbats)
      default: break
      }
    }
    return result
  }

  private static func launchArguments(forShell shell: String) -> [String] {
    switch URL(fileURLWithPath: shell).lastPathComponent {
    case "bash": ["--login", "-i"]
    case "fish": ["--login", "--interactive"]
    default: ["-l", "-i"]
    }
  }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
  nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

  nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    Task { @MainActor [weak self] in
      guard (source as? AsterTerminalView)?.titleShellControlled == true else { return }
      // 去重：运行中的命令（尤其 TUI 与带 starship 的 shell）会高频重发相同标题，
      // 不去重会让整棵工作区视图树以接近每帧的频率重建，点击都无法完成。
      var state = TerminalTitleState(fallback: "Shell")
      state.applyOSC(code: 2, text: title)
      let next = state.programWindowTitle.isEmpty ? "Shell" : state.programWindowTitle
      guard let self else { return }
      if self.terminalTitle != next { self.terminalTitle = next }
      // 该路径也承接 XTWINOPS 标题栈恢复；必须上送给 Tab，不能只更新 Session。
      self.onTitleUpdate?(2, title)
    }
  }

  nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    guard let directory, !directory.isEmpty else { return }
    Task { @MainActor [weak self] in
      let normalized = Self.normalizeReportedWorkingDirectory(directory)
      guard let self else { return }
      guard !normalized.isEmpty else {
        self.currentWorkingDirectoryIsLocal = false
        return
      }
      self.currentWorkingDirectoryIsLocal = true
      guard self.currentWorkingDirectory != normalized else { return }
      self.currentWorkingDirectory = normalized
    }
  }

  nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
    Task { @MainActor [weak self] in
      // SwiftTerm 在 PTY 读端出现瞬时 EOF 时可能给出无退出码通知；若本地进程仍在
      // 运行，该事件不是最终终止，不能把活跃分屏错误标成 session ended。
      if let localView = source as? LocalProcessTerminalView, localView.process.running {
        return
      }
      self?.exitCode = exitCode
      self?.isRunning = false
      if let self { SecureInputCoordinator.shared.releaseAutomaticRequest(for: self.id) }
      TerminalRetirementCoordinator.shared.complete(source)
    }
  }
}
