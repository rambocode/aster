import AppKit
import AsterCore
import Combine
import Darwin
import Foundation
import SwiftTerm
@preconcurrency import GhosttyKit

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

/// 终端 Outline 的只读投影。滚动锚点不再存在时仍保留运行态中已经读取的命令正文，
/// 但明确禁用 Jump，避免把旧的绝对行号误解释为当前缓冲区的位置。
struct TerminalCommandOutlineEntry: Equatable {
  let title: String
  let absoluteRow: Int
  let exitStatus: Int?
  let finishedAt: Date?
  let isRunning: Bool
  let isJumpAvailable: Bool
}

/// 全局搜索使用的终端文本快照。`firstAbsoluteRow` 保留 SwiftTerm 的单调行号，搜索
/// 结果可在输出继续增长后尽可能稳定地跳回原位置。
struct TerminalTextSnapshot: Equatable {
  let firstAbsoluteRow: Int
  let lines: [String]
}

/// 一个终端 Pane 的进程生命周期。该状态不持久化：恢复工作区时始终创建新的本地 PTY，
/// 不能复用旧 PID、文件描述符或结束状态。
enum TerminalSessionLifecycleState: Equatable {
  case notStarted
  case starting
  case running
  case ended(TerminalProcessTermination)
  case startFailed
  case stopping
}

extension TerminalSessionLifecycleState {
  fileprivate var diagnosticReason: String {
    switch self {
    case .notStarted: "not_started"
    case .starting: "starting"
    case .running: "running"
    case .ended(.exited(let code)): code == 0 ? "exit_zero" : "exit_nonzero"
    case .ended(.signaled): "signal"
    case .ended(.ioFailure): "io_failure"
    case .startFailed: "start_failed"
    case .stopping: "stopping"
    }
  }
}

/// SwiftTerm 视图子类：实现 Otty 的 `Default` / `Always` 光标优先级。
/// `Default` 只给出初始状态，之后接受 DECSCUSR / DEC mode 12；`Always` 把用户设置
/// 作为最终真值，并在 SwiftTerm 回调返回后纠正程序端写入。
final class AsterTerminalView: LocalProcessTerminalView {
  /// PTY 回调先落在专用串行队列，再经有界消息总线分批回到主线程。终端网格和 AppKit
  /// 子视图仍只在主线程变更；后台线程只复制并排队原始字节，避免跨线程读写 UI 状态。
  private let outputQueue = DispatchQueue(
    label: "io.aster.terminal.output",
    qos: .userInitiated
  )
  /// 在视图构造的主线程创建。之后后台 PTY 回调只读取该不可变引用并入队，不会触碰
  /// `AsterTerminalView` 的其它状态。
  private var outputMessageBus: TerminalOutputMessageBus!
  /// 观察 SwiftTerm 网格尺寸真正变化的测试 seam。生产环境保持 nil；测试用它区分
  /// 一次合法终态 reflow 与 Panel 过渡导致的重复 resize，不保存终端内容或尺寸历史。
  var onGridSizeChange: ((Int, Int) -> Void)?
  /// SwiftTerm 在 macOS 的标题回调存在缺失和顺序差异；此回调按 PTY 原始顺序校正。
  var onObservedTitleUpdate: ((Int, String) -> Void)?
  /// 所有链接打开请求必须先进入 Aster 的解析与授权层，禁止调用 SwiftTerm 默认的
  /// `NSWorkspace.open` 路径绕过 scheme、可执行文件和特殊文件检查。
  var onRequestOpenTarget: ((String, DetectedTargetSource) -> Void)?
  /// Focus-follows-mouse 只请求本 Pane 成为 first responder；工作区现有 responder 观察器
  /// 继续负责更新活动 Pane，避免终端视图越过 WorkspaceModel 直接改选择状态。
  var onRequestFocus: (() -> Void)?
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
  var selectionBackspaceDeletes = true
  var rightClickAction = TerminalRightClickAction.contextMenu
  var mouseHideWhileTyping = false
  var focusFollowsMouse = false
  var linkClickOverMouseMode = true
  var cursorClickToMove = true
  private var pendingCursorMovePosition: Position?
  /// Otty 默认由 Shift+Arrow 驱动原生选区；关闭时菜单快捷键失效，事件回到 TUI。
  var shiftArrowSelectionEnabled = true
  var pasteProtectionEnabled = true
  var pasteBracketedSafe = true
  /// 交互式截屏期间强持有进程，并阻止用户重复启动多个系统选区。进程结束后只在主线程
  /// 校验目标并插入路径；后台 termination handler 不触碰 AppKit 或终端状态。
  private var screenshotCaptureProcess: Process?
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
  var onResumeProtocol: ((String) -> Void)?
  var onAutocompleteKeyDown: ((NSEvent) -> Bool)?
  /// 进度与通知观察器只镜像状态，不覆盖 SwiftTerm 自己的 OSC 9;4 顶部进度条。
  var onTerminalProgress: ((TerminalProgressState) -> Void)?
  var onTerminalNotification: ((TerminalNotification) -> Void)?
  var onTerminalBadgeDirective: ((TerminalBadgeDirective) -> Void)?
  var onAgentTerminalDirective: ((AgentTerminalDirective) -> Void)?
  var onAgentUsageDirective: ((AgentUsageDirective) -> Void)?
  /// Kitty capability query 必须直接回到 PTY，不能经过用户输入和补全跟踪器。
  var onTerminalProtocolResponse: ((String) -> Void)?
  var terminalBellEnabled = true
  var titleShellControlled = true
  var terminalBellHandler: () -> Void = { NSSound.beep() }
  private(set) var shellCommandTimeline = ShellCommandTimeline()
  /// OSC 133 mark 不携带命令正文；首次可见时从网格取得后仅随有界时间线保存在内存，
  /// 让被 scrollback 裁剪的命令仍可复制，绝不写入磁盘或学习历史。
  private var commandOutlineTitles: [Int: String] = [:]
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

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect, processDispatchQueue: outputQueue)
    // Aster 自己按 Pane/窗口焦点暂停闪烁，并始终保留用户选择的光标几何。SwiftTerm
    // 默认会把任何失焦光标替换成空心方块，这会覆盖“竖线/下划线”等外观设置。
    caretViewTracksFocus = false
    outputMessageBus = makeOutputMessageBus()
  }

  required init?(coder: NSCoder) {
    // 运行时全部以代码创建终端视图；保留 coder 路径以满足 AppKit 解码契约。该路径
    // 没有可注入的父类队列参数，因此仍使用默认队列，但输出处理同样经过消息总线。
    super.init(coder: coder)
    caretViewTracksFocus = false
    outputMessageBus = makeOutputMessageBus()
  }

  /// 把 UI 消费闭包集中在构造期创建，避免首次 PTY 输出在后台触发 lazy 属性初始化。
  private func makeOutputMessageBus() -> TerminalOutputMessageBus {
    TerminalOutputMessageBus { [weak self] bytes in
      self?.consumeTerminalOutput(bytes[...])
    }
  }

  /// 将主题的视觉令牌直接写到当前终端视图。这个边界刻意放在 View 上：工作区整树
  /// 重排时，旧 Pane 可能仍在一次 AppKit 事务内可见，但对应 Session 已经不在当前
  /// layout 的遍历结果里；控制器仍可对屏幕上的真实对象补发同一套颜色，避免左右
  /// Pane 在主题实时预览期间短暂或永久停留在不同主题。
  func applyThemePalette(_ preferences: AppPreferences) {
    nativeForegroundColor = preferences.terminalForegroundColor
    let backgroundOpacity = min(max(
      preferences.compatibilityNumber(forKey: "advanced.backgroundOpacity", default: 1),
      0
    ), 1)
    let canvasBackground = preferences.terminalCanvasBackgroundColor.withAlphaComponent(
      preferences.terminalCanvasBackgroundColor.alphaComponent * backgroundOpacity
    )
    nativeBackgroundColor = canvasBackground
    // SwiftTerm 只在初次尺寸初始化时把 native 背景同步到 NSView backing layer。
    // 主题实时切换若只改 `nativeBackgroundColor`，透明主题会露出该 layer 留下的旧黑底，
    // 直到 Pane 再次获得焦点触发重绘。这里同步 layer，确保所有可见 Pane 立即呈现
    // 完全相同的 RGBA 背景。
    layer?.backgroundColor = canvasBackground.cgColor
    caretColor = preferences.cursorColor
    caretTextColor = preferences.cursorTextColor
    selectedTextForegroundColor = preferences.selectionForegroundColor
    selectedTextBackgroundColor = preferences.selectionColor
    installColors(
      preferences.ansiColors.map {
        SwiftTerm.Color(
          red: UInt16($0.red) * 257,
          green: UInt16($0.green) * 257,
          blue: UInt16($0.blue) * 257
        )
      })
    needsDisplay = true
  }

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
  /// `Default` 只允许 DECSCUSR / DEC mode 12 改变闪烁，不允许程序覆盖外观设置中的
  /// 方块/竖线/下划线几何；`Always` 连闪烁状态也固定为用户值。
  private var pinsProgramCursorBlinking = true
  /// 窗口和当前 Pane 都处于活动状态时才允许闪烁。Aster 禁用 SwiftTerm 的通用失焦
  /// 空心方块后，必须用稳定 Pane ID 独立管理活动状态，避免后台 Pane 继续闪烁。
  private var isWindowActive = true
  private var isPaneActive = true
  /// Codex/Claude 等 Agent 正在输出时暂停输入框光标闪烁；等待用户输入或任务结束后恢复
  /// 配置行为。只改变 blink 位，绝不改变用户选择的光标形状。
  private var isCursorBlinkSuppressed = false

  /// 实际下发给 SwiftTerm 的样式：程序请求只贡献 blink 位；失焦或 Agent 正在处理时
  /// 再取同形状的不闪烁变体。
  private var effectiveCursorStyle: SwiftTerm.CursorStyle? {
    let style: SwiftTerm.CursorStyle
    if let preferredCursorStyle {
      let blinks = pinsProgramCursorBlinking
        ? preferredCursorStyle.isBlinking
        : (programCursorStyle?.isBlinking ?? preferredCursorStyle.isBlinking)
      style = preferredCursorStyle.withBlinking(blinks)
    } else if let programCursorStyle {
      style = programCursorStyle
    } else {
      return nil
    }
    let allowsBlinking = isWindowActive && isPaneActive && !isCursorBlinkSuppressed
    return allowsBlinking ? style : style.nonBlinking
  }

  func configureCursor(initialStyle: SwiftTerm.CursorStyle, pinsProgramBlinking: Bool) {
    pinsProgramCursorBlinking = pinsProgramBlinking
    programCursorStyle = initialStyle
    // 光标形状始终来自用户配置；Default / Always 的差异只作用于 blink 位。
    preferredCursorStyle = initialStyle
    applyEffectiveCursorStyle()
  }

  func setWindowActive(_ active: Bool) {
    guard isWindowActive != active else { return }
    isWindowActive = active
    applyEffectiveCursorStyle()
  }

  func setPaneActive(_ active: Bool) {
    guard isPaneActive != active else { return }
    isPaneActive = active
    applyEffectiveCursorStyle()
  }

  func setCursorBlinkSuppressed(_ suppressed: Bool) {
    guard isCursorBlinkSuppressed != suppressed else { return }
    isCursorBlinkSuppressed = suppressed
    applyEffectiveCursorStyle()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // 从可见标签移除后按非活动处理；重新挂入 key window 时恢复。Pane 内部焦点由
    // Workspace 的稳定 activePaneID 管理，避免依赖 SwiftTerm 不开放的 responder seam。
    setWindowActive(window?.isKeyWindow ?? false)
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
    if mouseHideWhileTyping { NSCursor.setHiddenUntilMouseMoves(true) }
    if handleBidirectionalArrow(event) { return }
    if onAutocompleteKeyDown?(event) == true { return }
    // macOS keyCode 51 is the backward Delete/Backspace key. Only consume it when OSC 133
    // proves the selection belongs to the current editable prompt; otherwise preserve TUI input.
    if selectionBackspaceDeletes, event.keyCode == 51, deletePromptSelectionIfSafe() { return }
    super.keyDown(with: event)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    if focusFollowsMouse { onRequestFocus?() }
  }

  override func rightMouseDown(with event: NSEvent) {
    // Otty 保留 Control + 右键作为逃生入口；即使用户把普通右键设为复制或忽略，
    // 仍能访问完整终端菜单。
    if event.modifierFlags.contains(.control) || rightClickAction == .contextMenu {
      super.rightMouseDown(with: event)
      return
    }
    switch rightClickAction {
    case .contextMenu: super.rightMouseDown(with: event)
    case .copy: copy(self)
    case .paste: paste(self)
    case .copyOrPaste: selectionActive ? copy(self) : paste(self)
    case .ignore: break
    }
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

  /// `LocalProcess` 在 `outputQueue` 调用此入口。这里只执行消息入队；所有 SwiftTerm
  /// 解析、OSC 回调和视图更新都由 `consumeTerminalOutput(_:)` 在主线程串行完成。
  override func dataReceived(slice: ArraySlice<UInt8>) {
    // 直接调用是测试与少量 AppKit fixture 的同步 seam；真实 PTY 已由专用输出队列
    // 投递，因此不会走此分支，也不会重新把持续流式输出压回主线程。
    if Thread.isMainThread {
      consumeTerminalOutput(slice)
      return
    }
    outputMessageBus.enqueue(slice)
  }

  /// 主线程消费者：保留原始输出处理顺序，但每次只接收消息总线限定的一小批字节。
  private func consumeTerminalOutput(_ slice: ArraySlice<UInt8>) {
    precondition(Thread.isMainThread)
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
      if paneModeState.navigationMode == .normal, !canScroll || scrollPosition >= 1 {
        // 视口已在底部才跟随新输出（同时清理越界像素偏移）；用户上滚检查历史时，
        // 持续输出不得把 viewport 拉回底部，用户输入仍经 SwiftTerm send 路径复位。
        // Vi/Mark 模式则始终固定用户正在检查的 viewport。
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

  /// PTY EOF 与最后一批输出可能同时抵达。退出事件经同一消息总线延后交付，确保终端
  /// 缓冲区先显示尾部文本，再让 Session 切换为已结束状态。
  override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
    outputMessageBus.finish { [weak self] in
      self?.forwardProcessTermination(source, exitCode: exitCode)
    }
  }

  private func forwardProcessTermination(_ source: LocalProcess, exitCode: Int32?) {
    super.processTerminated(source, exitCode: exitCode)
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
    // 退出检查模式即回到实时输出（tmux copy-mode 语义）。普通输出不再无条件吸底，
    // 因此这里必须显式复位，否则冻结期间累积的输出会让视口停在历史位置。
    scrollToBottom()
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
  /// 通过行锚点跳转，但标题保持有界，且不会把输出区误当成命令正文。裁剪后保留已缓存
  /// 标题供复制，并以 `isJumpAvailable` 让调用方显示准确原因。
  func commandOutlineEntries(maximumItems: Int = 1_000) -> [TerminalCommandOutlineEntry] {
    let terminal = getTerminal()
    let range = terminal.scrollInvariantLineRange
    let limit = max(0, min(maximumItems, 5_000))
    var trackedRows = Set(shellCommandTimeline.marks.map { $0.inputStart.row })
    if let running = shellCommandTimeline.runningCommand { trackedRows.insert(running.inputStart.row) }
    commandOutlineTitles = commandOutlineTitles.filter { trackedRows.contains($0.key) }
    func entry(
      promptStart: TerminalGridPoint,
      inputStart: TerminalGridPoint,
      exitStatus: Int?,
      finishedAt: Date?,
      isRunning: Bool
    ) -> TerminalCommandOutlineEntry? {
      let title: String
      let isJumpAvailable: Bool
      if range.contains(inputStart.row), let line = terminal.getScrollInvariantLine(row: inputStart.row) {
        let upperColumn = min(terminal.cols, max(inputStart.column, 0))
        let text = line.translateToString(trimRight: true)
        // OSC 133 的列是网格列；常见命令提示符为 ASCII，按 Character 裁切即可得到
        // 准确标题。宽字符提示符存在歧义时保留整行，比丢失命令正文更可诊断。
        if text.unicodeScalars.allSatisfy({ $0.isASCII }), upperColumn <= text.count {
          title = String(text.dropFirst(upperColumn))
        } else {
          title = text
        }
        isJumpAvailable = true
      } else if let cached = commandOutlineTitles[inputStart.row] {
        title = cached
        isJumpAvailable = false
      } else {
        return nil
      }
      let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
      let bounded = normalized.isEmpty ? "命令" : String(normalized.prefix(240))
      commandOutlineTitles[inputStart.row] = bounded
      return TerminalCommandOutlineEntry(
        title: bounded,
        absoluteRow: promptStart.row,
        exitStatus: exitStatus,
        finishedAt: finishedAt,
        isRunning: isRunning,
        isJumpAvailable: isJumpAvailable
      )
    }
    var result = shellCommandTimeline.marks.suffix(limit).compactMap { mark in
      entry(
        promptStart: mark.promptStart,
        inputStart: mark.inputStart,
        exitStatus: mark.exitStatus,
        finishedAt: mark.finishedAt,
        isRunning: false
      )
    }
    if let running = shellCommandTimeline.runningCommand,
      let runningEntry = entry(
        promptStart: running.promptStart,
        inputStart: running.inputStart,
        exitStatus: nil,
        finishedAt: nil,
        isRunning: true
      )
    {
      result.append(runningEntry)
    }
    return Array(result.suffix(limit))
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
    pendingCursorMovePosition = cursorClickToMove
      && event.type == .leftMouseDown
      && !isMouseButtonReportingActive
      && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
      ? calculateMouseHit(with: event).grid : nil
    let previousMouseReporting = allowMouseReporting
    if paneModeState.inputDecision != .forwardToProcess { allowMouseReporting = false }
    defer { allowMouseReporting = previousMouseReporting }
    if case .none = linkReporting {
      super.mouseDown(with: event.removingCommandModifier() ?? event)
      return
    }
    if event.modifierFlags.contains(.command), customSchemeURL(at: event) != nil,
      linkClickOverMouseMode || !isMouseButtonReportingActive
    { return }
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      if let position = pendingCursorMovePosition { movePromptCursor(to: position) }
      pendingCursorMovePosition = nil
    }
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
      linkClickOverMouseMode || !isMouseButtonReportingActive,
      let link = customSchemeURL(at: event)
    else { return }
    onRequestOpenTarget?(link, .plainText)
  }

  /// 单击只在 OSC 133 证明当前行是可编辑提示符时转换为左右方向键。选区、宽字符、
  /// alternate screen 和运行中命令均拒绝处理，避免向 TUI 或不可靠 Shell 状态注入按键。
  private func movePromptCursor(to position: Position) {
    guard cursorClickToMove, !selectionActive, permitsUserInputAction() else { return }
    let terminal = getTerminal()
    guard !terminal.isCurrentBufferAlternate,
      !shellCommandTimeline.isCommandRunning,
      let inputStart = shellCommandTimeline.currentInputStart,
      let line = terminal.getLine(row: position.row)
    else { return }
    let absoluteRow = terminal.buffer.totalLinesTrimmed + position.row
    let cursor = terminal.cursorAbsolutePosition
    guard absoluteRow == inputStart.row, absoluteRow == cursor.row else { return }
    let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
    guard text.unicodeScalars.allSatisfy(\.isASCII) else { return }
    let lastColumn = max(inputStart.column, text.utf8.count)
    let targetColumn = min(max(position.col, inputStart.column), lastColumn)
    let delta = targetColumn - cursor.col
    guard delta != 0 else { return }
    let suffix = delta < 0 ? "D" : "C"
    send(data: Array("\u{1B}[\(abs(delta))\(suffix)".utf8)[...])
  }

  override func mouseMoved(with event: NSEvent) {
    // SwiftTerm 的 mouseMoved 路径不读取 allowMouseReporting。模式锁定时直接忽略 hover
    // 报告，避免 Read-only、Vi 或 Hint 在用户移动指针时向 TUI 写入 CSI 序列。
    guard paneModeState.inputDecision == .forwardToProcess else {
      NSCursor.iBeam.set()
      return
    }
    super.mouseMoved(with: event)
    // SwiftTerm 覆盖标准 URL、文件路径和 OSC 8；Aster 的扩展检测器还支持任意合法
    // `scheme://`。只有该目标会实际由本地点击处理时才覆盖为手形，避免 TUI 接管鼠标
    // 或用户关闭链接检测后仍给出可点击的错误暗示。
    if linkUsesAsterPointingHand(for: event) { NSCursor.pointingHand.set() }
  }

  override func cursorUpdate(with event: NSEvent) {
    super.cursorUpdate(with: event)
    if linkUsesAsterPointingHand(for: event) { NSCursor.pointingHand.set() }
  }

  private func linkUsesAsterPointingHand(for event: NSEvent) -> Bool {
    guard event.modifierFlags.contains(.command),
      linkClickOverMouseMode || !isMouseButtonReportingActive,
      customSchemeURL(at: event) != nil
    else { return false }
    if case .none = linkReporting { return false }
    return true
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

  /// Continuity Camera 通过 responder chain 询问谁能接收图片。只有当前终端仍可写时
  /// 才声明接收，避免系统完成手机拍摄后才发现 Pane 已经只读或进程已经退出。
  override func validRequestor(
    forSendType sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Any? {
    if let returnType,
      TerminalImportedFileStore.supports(returnType),
      acceptsUserInput
    {
      return self
    }
    return super.validRequestor(forSendType: sendType, returnType: returnType)
  }

  /// AppKit 在 iPhone/iPad 捕获完成后调用该 responder 方法。图片先保存成私有临时文件，
  /// 再以单个 POSIX Shell 参数插入；失败不会把半截路径或原始二进制写进 PTY。
  @objc(readSelectionFromPasteboard:)
  func readSelection(from pasteboard: NSPasteboard) -> Bool {
    guard permitsUserInputAction() else { return false }
    for type in TerminalImportedFileStore.supportedPasteboardTypes {
      guard let data = pasteboard.data(forType: type) else { continue }
      do {
        let file = try TerminalImportedFileStore.save(data, type: type)
        guard insertPathsIntoCurrentInput([file]) else {
          try? FileManager.default.removeItem(at: file)
          return false
        }
        return true
      } catch {
        Self.presentImportError(error, title: "无法插入手机内容")
        return false
      }
    }
    return false
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
    // OSC 88 终端恢复协议:载荷原样交给 Session 解析(query/restart=/clear)。
    getTerminal().registerOscHandler(code: 88) { [weak self] bytes in
      guard bytes.count <= TerminalResumeProtocol.maximumPayloadBytes else { return }
      self?.onResumeProtocol?(String(decoding: bytes, as: UTF8.self))
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
      } else if let directive = AgentUsageDirective(payload: payload) {
        self?.onAgentUsageDirective?(directive)
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

  /// 选择一个或多个文件/目录，并把每个绝对路径分别编码为 Shell 参数。该动作只预填，
  /// 不发送 Return；即使用户选择可执行文件，也不会绕过终端里的最终人工确认。
  @objc func insertFilePath(_ sender: Any?) {
    guard permitsUserInputAction() else { return }
    let panel = NSOpenPanel()
    panel.title = "插入文件路径"
    panel.prompt = "插入"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    _ = insertPathsIntoCurrentInput(panel.urls)
  }

  /// 文件选择、系统截屏和 Continuity Camera 统一经过 Codex/Claude TUI 的输入框交付
  /// 语义：整段路径按目标协商的 bracketed-paste 模式预填，但绝不附加 Return。
  @discardableResult
  func insertPathsIntoCurrentInput(_ urls: [URL]) -> Bool {
    guard !urls.isEmpty else { return false }
    let escapedPaths = urls.map { ShellPasteEscaper.escape($0.path) }.joined(separator: " ")
    return typePromptText(escapedPaths)
  }

  /// 调用 macOS 自带的交互式截屏 UI。`-o` 排除鼠标指针，`-t png` 固定输出格式；
  /// 截屏完成后仍复验普通文件、大小和权限，不能只根据子进程退出码信任目标。
  @objc func insertScreenshot(_ sender: Any?) {
    guard permitsUserInputAction(), screenshotCaptureProcess == nil else { return }
    let destination: URL
    do {
      destination = try TerminalImportedFileStore.makeScreenshotDestination()
    } catch {
      Self.presentImportError(error, title: "无法开始截屏")
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-o", "-t", "png", destination.path]
    process.terminationHandler = { [weak self] finishedProcess in
      DispatchQueue.main.async { [weak self] in
        self?.finishScreenshotCapture(finishedProcess, destination: destination)
      }
    }
    do {
      try process.run()
      screenshotCaptureProcess = process
    } catch {
      try? FileManager.default.removeItem(at: destination)
      Self.presentImportError(error, title: "无法开始截屏")
    }
  }

  private func finishScreenshotCapture(_ process: Process, destination: URL) {
    guard screenshotCaptureProcess === process else { return }
    screenshotCaptureProcess = nil
    guard process.terminationStatus == 0 else {
      // 用户按 Esc 取消是正常结果，不弹错误；系统工具可能已经创建空文件，顺手清理。
      try? FileManager.default.removeItem(at: destination)
      return
    }
    do {
      try TerminalImportedFileStore.validateCapturedFile(at: destination)
      guard insertPathsIntoCurrentInput([destination]) else {
        try? FileManager.default.removeItem(at: destination)
        return
      }
    } catch {
      try? FileManager.default.removeItem(at: destination)
      Self.presentImportError(error, title: "无法插入截屏")
    }
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
    case #selector(insertFilePath(_:)):
      return acceptsUserInput
    case #selector(insertScreenshot(_:)):
      return acceptsUserInput && screenshotCaptureProcess == nil
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
  private var acceptsUserInput: Bool {
    if case .forwardToProcess = paneModeState.inputDecision { return true }
    return false
  }

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

  private static func presentImportError(_ error: Error, title: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    switch error {
    case TerminalImportError.emptyData, TerminalImportError.invalidCapturedFile:
      alert.informativeText = "系统没有返回可用的图片文件。"
    case TerminalImportError.fileTooLarge:
      alert.informativeText = "图片超过 32 MiB 限制。"
    case TerminalImportError.unsupportedType:
      alert.informativeText = "仅支持 PNG、JPEG、HEIC、TIFF 或 PDF。"
    default:
      alert.informativeText = "无法创建或读取临时文件。"
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
    programCursorStyle = newStyle
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
  var isBlinking: Bool {
    switch self {
    case .blinkBlock, .blinkHollowBlock, .blinkUnderline, .blinkBar: true
    case .steadyBlock, .steadyHollowBlock, .steadyUnderline, .steadyBar: false
    }
  }

  /// 保留方块、空心方块、下划线或竖线几何，只替换闪烁位。
  func withBlinking(_ blinking: Bool) -> SwiftTerm.CursorStyle {
    switch self {
    case .blinkBlock, .steadyBlock: blinking ? .blinkBlock : .steadyBlock
    case .blinkHollowBlock, .steadyHollowBlock:
      blinking ? .blinkHollowBlock : .steadyHollowBlock
    case .blinkUnderline, .steadyUnderline: blinking ? .blinkUnderline : .steadyUnderline
    case .blinkBar, .steadyBar: blinking ? .blinkBar : .steadyBar
    }
  }

  /// 同一形状的不闪烁变体。
  var nonBlinking: SwiftTerm.CursorStyle {
    withBlinking(false)
  }
}

/// Ghostty Shell Integration 标记的幂等键。
///
/// Otty 等宿主可能在子 Shell 中继承并再次注入同一条 OSC 133。只有 payload 与
/// Ghostty 稳定缓冲坐标同时相同才视为重复，避免吞掉同一屏幕行上的不同事件。
private struct GhosttyShellMarkerSignature: Equatable {
  let payload: String
  let column: UInt32
  let pageSerial: UInt64
  let pageRow: UInt32
}

/// 一个由 libghostty 完整 PTY/VT/Metal 内核承载的本地登录 Shell。
///
/// Session 强持有 `GhosttySurfaceView`，因此在标签切换或 AppKit 重排视图时，
/// PTY、滚动历史和全屏 TUI 状态不会丢失。AppKit 视图只通过这里暴露的窄接口被
/// 工作区操作。迁移期保留的 `makeTerminalView` 只供 SwiftTerm Adapter 独立回归测试，
/// 产品视图树一律从 `makeTerminalHost` 创建 Ghostty surface。
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
  let id = UUID()
  let workingDirectory: String
  /// 控制协议上下文的惰性提供者：由 Tab 在装配 runtime 时注入，PTY 启动时才求值，
  /// 因此短 ID 分配（AsterControlBridge）可以晚于 Session 创建。
  var controlContextProvider: (() -> TerminalControlContext?)?
  /// Outline 页只关心命令时间线结构变化；使用专用事件避免把高频终端输出提升为
  /// `objectWillChange`，也让已打开的大纲能在命令完成后局部更新。
  let outlineChanged = PassthroughSubject<Void, Never>()
  /// Session Recording 状态的专用变更通道。记录状态会随命令、隐身切换频繁变化，
  /// 走 `objectWillChange` 会把整棵 Pane 树拖进 `refresh()`（CLAUDE.md AppKit 规则 #6）。
  let recordingStateChanged = PassthroughSubject<RecordingMode, Never>()

  @Published private(set) var isRunning = false
  @Published private(set) var currentWorkingDirectory: String
  /// false 表示最近 OSC 7 指向其它主机；相对文件不能继续复用旧本机 CWD。
  @Published private(set) var currentWorkingDirectoryIsLocal = true
  /// 当前 Pane 由已提交 SSH 命令解析出的最终服务器端点。它只属于运行态，不进入
  /// Workspace 快照；连接失败、返回本地 Shell 或 Pane 结束时立即清除。
  @Published private(set) var sshRemoteEndpoint: SSHResolvedEndpoint?
  @Published private(set) var terminalTitle = "Shell"
  @Published private(set) var terminalIconTitle = ""
  @Published private(set) var lifecycleState = TerminalSessionLifecycleState.notStarted
  @Published private(set) var exitCode: Int32?
  @Published private(set) var startupError: String?
  /// Shell Integration 已观察到至少一个合法 OSC 133 标记；用于停用进程轮询回退。
  @Published private(set) var shellIntegrationDetected = false
  /// 最近一条完整命令的退出状态。nil 表示尚无完整记录或 Shell 未提供状态。
  @Published private(set) var lastCommandExitStatus: Int?
  /// 是否有前台命令正在运行且近期有输出（区别于 `isRunning` 的 shell 存活）。
  /// 由 PTY 前台进程组 + 终端缓冲活跃度轮询驱动，只在状态翻转时发布，
  /// 是普通命令侧栏 spinner 的业务状态源。Agent 另以 lifecycle hook 或有界
  /// 输入/输出活动判定 processing，避免长寿命 TUI 空闲时一直旋转。
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
  /// 当前 Agent 的用量快照（5h / 周 / 会话上下文占比）。刻意不并入 TerminalTabItem 的
  /// objectWillChange 聚合：statusLine 每次刷新都会重发，视图层按 Pane 订阅做原地更新。
  @Published private(set) var agentUsage: AgentUsageSnapshot?
  /// Codex 用量来自 rollout 文件，绑定 session 后监听；provider 结束时停止。
  private var codexUsageMonitor: CodexUsageFileMonitor?
  private var codexUsageMonitorSessionID: String?
  /// Codex rollout 的根目录来源；测试注入临时 home。
  var agentUsageHomeDirectory = FileManager.default.homeDirectoryForCurrentUser
  /// Claude statusLine 包装器写入的用量文件仓库；测试注入临时目录。必须在创建终端视图前设置。
  var agentUsageFileStore: AgentUsageFileStore = .shared
  /// 订阅用量文件的时刻：早于它的文件是上次运行遗留的，忽略。
  private var agentUsageSubscribedAt: Date?
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
  /// 未安装 lifecycle hook 时，长寿命 Agent TUI 的前台进程不能等同于正在
  /// 生成。只在命令启动、用户输入或 PTY 输出后保持短暂 processing；连续静默
  /// 后回到 idle。一旦 hook 到达，权威 lifecycle 始终优先且不受超时影响。
  private var fallbackAgentActivityIsProcessing = false
  private var fallbackAgentIdleTask: Task<Void, Never>?

  // MARK: Agent 屏幕检测（移植 herdr）
  /// 已编译清单的来源；默认进程单例，测试可注入独立仓库。
  private let agentDetectionManifestStore: AgentDetectionManifestStore
  /// 轮询节奏；生产 300ms / 3s 宽限，测试注入短值。
  private let agentScreenDetectionTiming: AgentScreenDetectionMonitor.Timing
  /// 有清单 provider 在前台时运行；hook 覆盖完整生命周期（fullLifecycleHooks）后停止。
  private var agentScreenMonitor: AgentScreenDetectionMonitor?
  /// 屏幕检测最近发布的状态；nil 表示尚未发布（启动宽限内或未启动）。
  /// 控制 API 用非 nil 判断 `detection == .screen`。
  private(set) var screenDetectionPublished: AgentScreenDetectionPublisher.PublishedState?
  /// 本轮 Agent 是否真的观察到过工作证据：hook 的 processing/awaitingInput，或屏幕
  /// 检测发布的 working/blocked。启动宽限把状态暂定为 processing 不算证据；没有证据
  /// 就回到 idle（Claude 启动时 SessionStart hook 直接发 idle、或只是打开了输入框）
  /// 不能当作「任务完成」置未读或通知。随 provider 生命周期重置。
  private var agentHasWorkEvidence = false
  /// 终端标题 / 进度 OSC 的原文，独立于 Shell Controlled 标题开关，只喂给检测引擎。
  private(set) var agentOSCTitle = ""
  private(set) var agentOSCProgress = ""
  /// PTY 每收到一段非空输出就 +1；idle 且序号未变时轮询跳过读屏。
  private(set) var detectionContentSequence: UInt64 = 0
  /// 测试 seam：注入假屏幕来源，绕过 Ghostty 读屏。生产恒为 nil。
  var agentScreenDetectionSourceOverride: AgentScreenDetectionMonitor.Source?
  /// 诊断 seam：屏幕检测轮询是否在运行。
  var isAgentScreenMonitorRunning: Bool { agentScreenMonitor?.isRunning == true }
  /// provider 只由标题补识别得出（弱证据）。命令结束、标题不再匹配且没有 hook /
  /// 屏幕 working·blocked 证据时要撤销，避免普通 shell 标题把 Pane 永久标成 Agent。
  private var agentProviderIsTitleEvidenceOnly = false

  private var foregroundPollTask: Task<Void, Never>?
  /// 诊断 seam：true 仅表示尚未取得权威 Shell Integration、仍需周期探测前台进程。
  /// UI 不依赖该值；回归测试用它防止 Ghostty 已有 OSC 133 时重新引入空闲轮询。
  var isUsingForegroundPollingFallback: Bool { foregroundPollTask != nil }
  // 输出活跃度探针：可见屏幕内容哈希。Claude Code 等 TUI 思考时在原位重绘状态行
  // （光标与滚动位置都不变，只有单元格内容变化），必须按内容而非光标位置探测，
  // 否则 spinner 会时有时无。
  private var lastScreenHash = 0
  private var lastActivityAt = Date.distantPast
  /// 设置关闭或 Pane 失焦时立即释放；PTY 模式由输出、输入前检查与低频兜底轮询采样。
  private var automaticSecureInputEnabled = true
  private weak var preferences: AppPreferences?
  private var submittedCommand: String?
  /// 程序通过 OSC 88 声明的重启命令;Shell 退出时清空。
  private var resumeProtocolCommand: String?
  private var pendingRestoredCommand: WorkspacePaneRestoreCommand?
  /// OSC 133 缺席时的兜底投递任务(用户 zsh 集成只在 tmux 注入,普通会话收不到 promptStart)。
  private var restoreFallbackTask: Task<Void, Never>?
  private var submittedCommandOrigin = WorkflowRecipeCommandOrigin.shellIntegration
  private var pendingCommandOrigin: WorkflowRecipeCommandOrigin?
  /// `ssh -G` 在后台解析；generation 阻止超时/取消前启动的旧结果覆盖更新会话。
  private var sshResolutionTask: Task<Void, Never>?
  private var sshResolutionGeneration: UInt64 = 0
  private(set) var recipeCommandCandidates: [WorkflowRecipeCommandCandidate] = []
  private var activityOutputTail = ""
  private var awaitingInputTask: Task<Void, Never>?
  /// 工作区恢复时待重连的 Agent 会话。真正的 resume 命令在 shell 首个 prompt 出现时
  /// 才发送（此时 PTY 与 rc 都已就绪）；用户在此之前的任何输入都会取消重连。
  private var pendingRestoredAgentResume: (provider: AgentProvider, sessionID: String)?
  /// 诊断 seam：恢复重连是否仍在等待首个 prompt。仅供测试观察，UI 不消费。
  var hasPendingRestoredAgentResume: Bool { pendingRestoredAgentResume != nil }
  var hasPendingRestoredCommand: Bool { pendingRestoredCommand != nil }
  private var completedFlashTask: Task<Void, Never>?
  private var progressExpiryTask: Task<Void, Never>?
  /// 生产固定使用 5 秒静默窗口；构造参数让回归测试可用虚拟的短窗口
  /// 验证完整 PTY 链路，而不在测试套件中真实等待数秒。
  private let fallbackAgentIdleDelay: Duration
  /// 通知交付属于应用基础设施边界；默认使用真实系统服务，测试可注入记录器验证
  /// lifecycle 到通知请求的转换，而不申请权限或写入用户通知中心。
  private let notificationPoster: any TerminalNotificationPosting
  /// 结构化诊断只记录 Session UUID、进程代次、结束类型和数值状态。命令、输出、路径、
  /// 环境与本地化错误均不进入日志；测试可注入独立目录验证真实生命周期事件。
  private let diagnostics: DiagnosticsCenter
  /// OpenSSH 配置解析边界。生产使用有界后台进程；测试注入纯闭包验证提交链路，
  /// 不读取开发机的 ~/.ssh/config。
  private let sshEndpointResolver: @Sendable (SSHCommandInvocation) async -> SSHResolvedEndpoint?

  private var terminalView: AsterTerminalView?
  /// 产品主引擎。与上面的 SwiftTerm 回归实例互斥；生产入口不会创建旧实例。
  private var ghosttyView: GhosttySurfaceView?
  /// PiP 只读取已有 surface 的渲染帧，不创建第二个 PTY，也不移动终端宿主。
  var pictureInPictureSurface: GhosttySurfaceView? { ghosttyView }
  /// Ghostty 的 page anchor 由扩展 ABI 保持稳定；领域 timeline 中的 row 是当前 Session
  /// 分配的不透明 token，只用于排序和查表，不能直接当 retained-screen row 使用。
  private var ghosttyShellCommandTimeline = ShellCommandTimeline()
  private var ghosttyBufferAnchors: [Int: ghostty_aster_buffer_point_s] = [:]
  private var ghosttyNextAnchorToken = 1
  private var ghosttyCommandOutlineTitles: [Int: String] = [:]
  private var ghosttyKittyNotificationAssembler = KittyNotificationAssembler()
  /// 嵌套终端可能让父、子 shell integration 同时写出同一标记。仅对完全相同的
  /// payload 与稳定 cell 锚点做幂等化，避免重复完成通知；任意位置变化仍保留。
  private var lastGhosttyShellMarker: GhosttyShellMarkerSignature?
  /// 首次 surface 创建后的前台进程组即登录 Shell；后续不同值表示前台命令。
  private var ghosttyShellProcessIdentifier: Int32?
  private var targetOpenCoordinator: TerminalTargetOpenCoordinator?
  private var autocompleteController: TerminalAutocompleteController?
  /// Session Recording 的注入点。nil 或记录层故障都不影响终端本职；
  /// Session 只转发已有状态，绝不为记录层做额外解析。
  weak var eventRecorder: (any TerminalEventRecording)?
  /// 本 Session 当前的记录状态（只读）。没有接入记录层时恒为 `.off`。
  var recordingMode: RecordingMode {
    eventRecorder?.recordingMode(for: id) ?? .off
  }
  /// 是否真的在落盘。`recordingMode == .on` 但目录被排除时这里仍为 false。
  var isRecordingToDisk: Bool {
    eventRecorder?.isRecording(id: id) ?? false
  }

  /// 切换本 Session 的临时隐身。只影响当前 Session，不改全局设置；
  /// UI 通过 `recordingStateChanged` 获知结果，不触发工作区重建。
  func setRecordingIncognito(_ incognito: Bool) {
    eventRecorder?.setIncognito(incognito, for: id)
    recordingStateChanged.send(recordingMode)
  }
  /// OSC 0/1/2 的独立通道回调。Tab 领域状态负责固定名称、前缀与持久化。
  var onTitleUpdate: ((Int, String) -> Void)?
  /// Vi `/` 或 `?` 请求显示现有查找栏；工作区拥有展示状态，Session 只保存方向。
  var onRequestFind: (() -> Void)?
  var onRequestPaneFocus: (() -> Void)?
  /// 终端链接选择“在 Aster 中打开”时，由所属 WorkspaceTab 注入 Pane 创建动作。
  /// 返回 false 表示当前目标不属于 Aster 内部 Pane 能力，协调器会安全回退系统应用。
  var onRequestOpenInAster: ((URL, Bool) -> Bool)?
  var onCommandFinished: (() -> Void)?
  var onPasteIntoComposer: ((String) -> Void)? {
    didSet {
      terminalView?.onPasteIntoComposer = onPasteIntoComposer
      ghosttyView?.onPasteIntoComposer = onPasteIntoComposer
    }
  }
  var onSendSelectionToChat: (() -> Void)? {
    didSet {
      terminalView?.onSendSelectionToChat = onSendSelectionToChat
      ghosttyView?.onSendSelectionToChat = onSendSelectionToChat
    }
  }
  private var pendingViSearchDirection: TerminalViSearchDirection?
  private var lastFindTerm = ""
  private var lastFindWasPrevious = false
  private var readOnly = false
  private var processGeneration = 0
  private var processStartedAt: Date?
  /// 主动关闭 Pane/应用时，旧 View 的迟到回调属于预期退休，不能再把它标成异常终止。
  private var intentionallyRetiredViews: Set<ObjectIdentifier> = []
  /// SwiftTerm 视图一旦启动就保持在同一个 AppKit 容器中。工作区刷新只移动该容器，
  /// 不直接反复把 Metal-backed 终端视图从 superview 拆下，避免分屏后网格停止绘制。
  private var terminalHostView: NSView?

  /// SwiftTerm 的进程对象是运行状态的权威来源。`isRunning` 负责触发 AppKit 刷新，
  /// 但分屏恢复期间回调与视图挂载顺序可能让缓存短暂过期，状态栏必须读取真实值。
  var statusIsRunning: Bool {
    ghosttyView?.isProcessRunning ?? terminalView?.process.running ?? isRunning
  }

  /// 关闭确认用的即时判断:PTY 前台进程组不是登录 Shell 本身,就视为有命令在运行。
  /// 不复用 `hasRunningCommand`——那是给 spinner 用的,带 5 秒静默降级,`sleep` 这类无输出
  /// 命令会被判成空闲。
  var hasForegroundCommand: Bool {
    if let ghosttyView {
      guard ghosttyView.isProcessRunning, let foreground = ghosttyView.foregroundProcessIdentifier
      else { return false }
      return foreground != (ghosttyShellProcessIdentifier ?? foreground)
    }
    guard let process = terminalView?.process, process.running, process.childfd >= 0 else { return false }
    let foreground = tcgetpgrp(process.childfd)
    return foreground > 0 && foreground != process.shellPid
  }

  var canRestart: Bool {
    switch lifecycleState {
    case .ended, .startFailed: true
    case .notStarted, .starting, .running, .stopping: false
    }
  }

  /// 当前 Pane 的 Shell PID。仅用于只读进程/端口检查，不保存到工作区快照。
  var processIdentifier: Int32? {
    if ghosttyView != nil {
      // 前台 PID 会在子命令运行时变化；Info/端口检查需要稳定的登录 Shell 根节点。
      return ghosttyShellProcessIdentifier ?? ghosttyView?.foregroundProcessIdentifier
    }
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

  init(
    workingDirectory: String,
    fallbackAgentIdleDelay: Duration = .seconds(5),
    notificationPoster: any TerminalNotificationPosting = TerminalNotificationService.shared,
    diagnostics: DiagnosticsCenter = .shared,
    agentDetectionManifestStore: AgentDetectionManifestStore = .shared,
    agentScreenDetectionTiming: AgentScreenDetectionMonitor.Timing = .production,
    sshEndpointResolver: @escaping @Sendable (SSHCommandInvocation) async -> SSHResolvedEndpoint? = {
      await SSHHostResolutionService.resolve($0)
    }
  ) {
    self.workingDirectory = workingDirectory
    currentWorkingDirectory = workingDirectory
    self.fallbackAgentIdleDelay = fallbackAgentIdleDelay
    self.notificationPoster = notificationPoster
    self.diagnostics = diagnostics
    self.agentDetectionManifestStore = agentDetectionManifestStore
    self.agentScreenDetectionTiming = agentScreenDetectionTiming
    self.sshEndpointResolver = sshEndpointResolver
    super.init()
  }

  /// makeTerminalView 的调用计数；随诊断上报,用于区分缓存命中与全新 PTY 创建路径。
  private var terminalViewRequestCount = 0
  /// 创建过程是否在途；重入时用于捕获调用栈定位触发方。
  private var terminalViewCreationInFlight = false

  /// 返回长期存活的终端视图；首次调用时才创建 PTY，确保 AppKit 窗口已完成初始化。
  func makeTerminalView(preferences: AppPreferences) -> LocalProcessTerminalView {
    self.preferences = preferences
    terminalViewRequestCount += 1
    if let terminalView {
      apply(preferences: preferences, to: terminalView)
      return terminalView
    }
    if terminalViewCreationInFlight {
      // 重入 = 同一 Session 将启动两个 PTY。仅记录符号栈(不含用户数据)供定位。
      var frames: [String: String] = ["request": "\(terminalViewRequestCount)"]
      for (index, frame) in Thread.callStackSymbols.dropFirst().prefix(16).enumerated() {
        let symbol = frame.split(separator: " ", omittingEmptySubsequences: true)
          .dropFirst(3).first.map(String.init) ?? "?"
        frames[String(format: "s%02d", index)] = String(symbol.prefix(250))
      }
      diagnostics.record(
        "terminal.view_creation_reentered",
        level: .fault,
        category: .terminal,
        attributes: processDiagnosticAttributes(extra: frames)
      )
    }
    terminalViewCreationInFlight = true
    defer { terminalViewCreationInFlight = false }
    diagnostics.record(
      "terminal.view_creation_requested",
      level: .debug,
      category: .terminal,
      attributes: processDiagnosticAttributes(extra: [
        "request": "\(terminalViewRequestCount)"
      ])
    )

    prepareForProcessLaunch()
    processGeneration += 1
    let view = AsterTerminalView(frame: .zero)
    // 立即登记:创建过程一旦被重入(历史上 terminfo 探测泵 runloop 曾让排队的
    // 工作区刷新插进这里),重入方走上面的缓存分支拿到同一实例,而不是为同一
    // Session 再启动一个 PTY。startShell 稍后再次赋值属于幂等操作。
    terminalView = view
    view.processDelegate = self
    view.onObservedTitleUpdate = { [weak self] code, title in
      Task { @MainActor [weak self] in self?.handleTitleOSC(code: code, text: title) }
    }
    let targetOpenCoordinator = TerminalTargetOpenCoordinator(
      preferences: preferences,
      openInAster: { [weak self] url, isDirectory in
        self?.onRequestOpenInAster?(url, isDirectory) ?? false
      }
    )
    self.targetOpenCoordinator = targetOpenCoordinator
    view.linkPreviewFormatter = { [weak self] rawValue in
      guard let self else { return rawValue }
      return targetOpenCoordinator.previewText(
        rawValue,
        currentDirectory: self.currentWorkingDirectoryIsLocal
          ? self.currentWorkingDirectory : ""
      )
    }
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
    view.onRequestFocus = { [weak self, weak view] in
      self?.onRequestPaneFocus?()
      guard let view, view.window?.firstResponder !== view else { return }
      view.window?.makeFirstResponder(view)
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
    view.onTerminalOutputActivity = { [weak self] line in
      self?.detectionContentSequence &+= 1
      self?.receiveActivityOutput(line)
    }
    view.onTerminalUserInput = { [weak self] in self?.handleTerminalUserInput() }
    view.onAgentTerminalDirective = { [weak self] directive in
      self?.handleAgentTerminalDirective(directive)
    }
    view.onAgentUsageDirective = { [weak self] directive in
      self?.handleAgentUsageDirective(directive)
    }
    subscribeAgentUsageFiles()
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
        self?.recordSubmittedCommand(command)
      }
      view.onAutocompleteInput = { [weak autocomplete] in autocomplete?.receiveInput($0) }
      view.onAutocompleteOutput = { [weak autocomplete] in autocomplete?.receiveOutput($0) }
      view.onShellIntegrationEvent = { [weak self, weak autocomplete] event in
        self?.handleShellIntegrationEvent(event)
        autocomplete?.receive(event)
      }
      view.onShellAliases = { [weak autocomplete] in autocomplete?.receiveAliases($0) }
      view.onResumeProtocol = { [weak self] in self?.handleResumeProtocol(payload: $0) }
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
    var shell = preferences.compatibilityString(
      forKey: "general.shell",
      default: inheritedEnvironment["SHELL"] ?? "/bin/zsh"
    )
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
      engineTerminfoDirectory: AsterResourceLocations.engineTerminfoDirectory()?.path,
      controlContext: controlContextProvider?(),
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
    // SSH/mosh 会把 Pane 标为远端；重新启动的是本地登录 Shell，不能把远端 OSC 7 路径
    // 当成本机目录。优先复用最近可靠的本地目录，否则回到 Pane 的原始工作目录。
    var launchDirectory = currentWorkingDirectoryIsLocal ? currentWorkingDirectory : workingDirectory
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: launchDirectory, isDirectory: &isDirectory)
      || !isDirectory.boolValue
    {
      launchDirectory = FileManager.default.homeDirectoryForCurrentUser.path
      currentWorkingDirectory = launchDirectory
      appendStartupWarning("原工作目录不可用，已回退到主目录。")
    }
    currentWorkingDirectory = launchDirectory
    currentWorkingDirectoryIsLocal = true
    // 先登记当前 View，再启动 PTY。极短命 Shell 可能在 `startProcess` 返回前退出；其
    // 回调必须能按对象身份归属到本代，不能被误判为已被替换的迟到旧回调。
    terminalView = view
    processStartedAt = Date()
    view.startProcess(
      executable: shell,
      args: Self.launchArguments(forShell: shell),
      environment: entries,
      currentDirectory: launchDirectory
    )

    isRunning = view.process.running
    if !isRunning {
      lifecycleState = .startFailed
      if startupError == nil { startupError = "无法创建本地终端进程。" }
      // PTY 启动失败只记录稳定状态，不记录 Shell 路径、工作目录或环境变量。
      diagnostics.record(
        "terminal.process_start_failed",
        level: .error,
        category: .terminal,
        attributes: processDiagnosticAttributes(launch: processGeneration == 1 ? "initial" : "restart")
      )
    } else {
      lifecycleState = .running
      diagnostics.record(
        "terminal.process_started",
        level: .info,
        category: .terminal,
        attributes: processDiagnosticAttributes(launch: processGeneration == 1 ? "initial" : "restart")
      )
    }
    if isRunning {
      startForegroundPolling()
      scheduleRestoreFallbackIfNeeded()
    }
    return view
  }

  /// 产品入口使用的 Ghostty surface。创建、环境、权限与生命周期 wiring 全部集中在
  /// Session seam 内，工作区不会接触 libghostty C interface。
  private func makeGhosttyTerminalView(preferences: AppPreferences) -> GhosttySurfaceView {
    self.preferences = preferences
    if let ghosttyView {
      applyLinkDetectionSettings(preferences, to: ghosttyView)
      ghosttyView.updateConfiguration(GhosttyConfiguration.make(preferences: preferences))
      return ghosttyView
    }

    prepareForProcessLaunch()
    processGeneration += 1
    let inheritedEnvironment = ProcessInfo.processInfo.environment
    var shell = preferences.compatibilityString(
      forKey: "general.shell",
      default: inheritedEnvironment["SHELL"] ?? "/bin/zsh"
    )
    if !FileManager.default.isExecutableFile(atPath: shell) {
      appendStartupWarning("配置的 Shell 不可执行，已回退到 /bin/zsh。")
      shell = "/bin/zsh"
    }
    let resourcesDirectory = AsterResourceLocations.resourcesDirectory()?.path
    let launchEnvironment = TerminalLaunchEnvironmentBuilder.make(
      inherited: inheritedEnvironment,
      configuredTerm: preferences.terminalIdentity,
      shellPath: shell,
      // Ghostty 自己注入与其 parser 匹配的 OSC 133 integration；重复注入 Aster
      // SwiftTerm 脚本会重复发 marker，并且无法通过 libghostty 的 raw-byte seam 观察。
      shellIntegrationEnabled: false,
      paneIdentifier: id.uuidString,
      version: AsterResourceLocations.productVersion(),
      resourcesDirectory: resourcesDirectory,
      engineTerminfoDirectory: AsterResourceLocations.engineTerminfoDirectory()?.path,
      controlContext: controlContextProvider?(),
      terminfoEntryExists: SystemTerminfoChecker.entryExists
    )
    if let warning = launchEnvironment.resolution.warning { appendStartupWarning(warning) }
    var environment = launchEnvironment.environment
    environment["SHELL"] = shell

    var launchDirectory = currentWorkingDirectoryIsLocal ? currentWorkingDirectory : workingDirectory
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: launchDirectory, isDirectory: &isDirectory)
      || !isDirectory.boolValue
    {
      launchDirectory = FileManager.default.homeDirectoryForCurrentUser.path
      appendStartupWarning("原工作目录不可用，已回退到主目录。")
    }
    currentWorkingDirectory = launchDirectory
    currentWorkingDirectoryIsLocal = true

    let view = GhosttySurfaceView(
      workingDirectory: launchDirectory,
      environment: environment,
      configurationText: GhosttyConfiguration.make(preferences: preferences)
    )
    // 先登记再创建 surface；极短命命令的退出 callback 可能在 createSurface 返回前到达。
    ghosttyView = view
    processStartedAt = Date()
    automaticSecureInputEnabled = preferences.configuration.controls.secureInputAutomatically

    let targetOpenCoordinator = TerminalTargetOpenCoordinator(
      preferences: preferences,
      openInAster: { [weak self] url, isDirectory in
        self?.onRequestOpenInAster?(url, isDirectory) ?? false
      }
    )
    self.targetOpenCoordinator = targetOpenCoordinator
    let clipboardCoordinator = OSC52ClipboardCoordinator(
      access: { [weak preferences] operation in
        guard let controls = preferences?.configuration.controls else { return .deny }
        switch operation {
        case .read: return controls.resolvedClipboardReadAccess
        case .write: return controls.resolvedClipboardWriteAccess
        }
      }
    )

    // 标题也从任意 OSC observer 进入，保留 0/1/2 的原始 code；Ghostty 的 set_title
    // action 会把 0/2 合并成窗口标题，不能作为 Aster 标签/图标标题的精确来源。
    view.onTitleChange = nil
    view.onWorkingDirectoryChange = { [weak self] reported in
      self?.applyReportedWorkingDirectory(reported)
    }
    view.onProcessExit = { [weak self, weak view] code in
      guard let self, let view, view === self.ghosttyView else { return }
      self.handleGhosttyProcessExit(code: code)
    }
    // 命令生命周期统一从非消费 OSC 133 observer 进入；不再同时消费 Ghostty 的
    // command_finished action，避免一个 D marker 触发两次学习、通知和 Outline 更新。
    view.onCommandFinished = nil
    view.onProgress = { [weak self] progress in
      guard let self else { return }
      switch progress {
      case .clear: self.handleTerminalProgress(.clear)
      case .indeterminate: self.handleTerminalProgress(.indeterminate)
      case .determinate(let percent):
        self.handleTerminalProgress(.determinate(percent: min(max(percent, 0), 100)))
      case .error(let percent):
        self.handleTerminalProgress(.error(percent: percent.map { min(max($0, 0), 100) }))
      case .paused:
        break
      }
    }
    // 链接预览与 SwiftTerm 路径同源：命中检测用 Ghostty 报告的原始链接，展示前经
    // TerminalTargetOpenCoordinator 依据可靠 OSC 7 CWD 展开相对路径。
    applyLinkDetectionSettings(preferences, to: view)
    view.linkPreviewFormatter = { [weak self] rawValue in
      guard let self else { return rawValue }
      return targetOpenCoordinator.previewText(
        rawValue,
        currentDirectory: self.currentWorkingDirectoryIsLocal
          ? self.currentWorkingDirectory : ""
      )
    }
    // 裸相对路径与普通单词无法靠语法区分，按当前可信本地 CWD stat 后才画下划线。
    view.linkPathValidator = { [weak self] rawValue in
      guard let self, let coordinator = self.targetOpenCoordinator else { return false }
      return coordinator.fileTargetExists(
        rawValue,
        currentDirectory: self.currentWorkingDirectoryIsLocal
          ? self.currentWorkingDirectory : ""
      )
    }
    view.onOpenURL = { [weak self] rawValue in
      guard let self else { return }
      self.targetOpenCoordinator?.open(
        rawValue,
        source: .osc8,
        currentDirectory: self.currentWorkingDirectoryIsLocal
          ? self.currentWorkingDirectory : ""
      )
    }
    view.onSecureInputChange = { [weak self, weak view] requested in
      guard let self else { return }
      let focused = view?.window?.isKeyWindow == true && view?.window?.firstResponder === view
      SecureInputCoordinator.shared.setAutomaticRequest(
        for: self.id,
        active: self.automaticSecureInputEnabled && requested && focused
      )
    }
    view.onBell = { [weak preferences] in
      if preferences?.configuration.shell.terminalBell == true { NSSound.beep() }
    }
    view.onNotification = { [weak self] title, body in
      self?.post(
        TerminalNotification(title: title.isEmpty ? "Aster" : title, body: body),
        category: .application
      )
    }
    view.onReadOnlyChange = { [weak self] enabled in self?.readOnly = enabled }
    view.onUserInput = { [weak self] in self?.handleTerminalUserInput() }
    view.onPTYRead = { [weak self, weak view] bytes in
      guard let self, let view else { return }
      if !bytes.isEmpty { self.detectionContentSequence &+= 1 }
      self.autocompleteController?.receiveOutput(bytes)
      // 记录层是 PTY 字节的并列消费者：只做拷贝转发，解析在后台管线完成。
      self.eventRecorder?.receivePTYOutput(id: self.id, bytes: bytes)
      if let line = view.readText(includeScrollback: false, maximumLines: 1) {
        self.receiveActivityOutput(line)
      }
    }
    view.onPTYWrite = { [weak self] bytes in
      self?.autocompleteController?.receiveInput(bytes)
    }
    view.onOSC = { [weak self, weak view] code, payload, point in
      guard let self, let view else { return }
      self.handleGhosttyOSC(code: code, payload: payload, point: point, view: view)
    }
    view.onRequestFocus = { [weak self] in self?.onRequestPaneFocus?() }
    view.onRequestOpenTarget = { [weak self] rawValue, source in
      guard let self else { return }
      self.targetOpenCoordinator?.open(
        rawValue,
        source: source,
        currentDirectory: self.currentWorkingDirectoryIsLocal
          ? self.currentWorkingDirectory : ""
      )
    }
    view.onResolveHintCopyTarget = { [weak self] rawValue, source in
      self?.resolvedHintCopyTarget(rawValue, source: source)
    }
    view.onRequestViSearch = { [weak self] direction in
      self?.pendingViSearchDirection = direction
      self?.onRequestFind?()
    }
    view.onRepeatViSearch = { [weak self] reverse in self?.repeatLastFind(reverse: reverse) }
    view.onPaneModeActivated = { [weak self] in
      self?.autocompleteController?.dismissForPaneMode()
    }
    view.focusFollowsMouse = preferences.configuration.controls.focusFollowsMouse
    view.pasteProtectionEnabled = preferences.configuration.controls.pasteProtection
    view.pasteBracketedSafe = preferences.configuration.controls.resolvedPasteBracketedSafe
    view.onPasteIntoComposer = onPasteIntoComposer
    view.onSendSelectionToChat = onSendSelectionToChat
    view.onAuthorizeClipboard = { operation in
      switch operation {
      case .read: clipboardCoordinator.allows(.read)
      case .write: clipboardCoordinator.allows(.write)
      }
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
        self?.recordSubmittedCommand(command)
      }
      view.onAutocompleteKeyDown = { [weak autocomplete] event in
        autocomplete?.handleKeyDown(event) ?? false
      }
      autocompleteController = autocomplete
    }
    view.onSurfaceCreated = { [weak self, weak view] created in
      guard let self, let view, view === self.ghosttyView else { return }
      if created {
        self.isRunning = view.isProcessRunning
        self.lifecycleState = self.isRunning ? .running : .startFailed
        self.ghosttyShellProcessIdentifier = view.foregroundProcessIdentifier
        if self.isRunning {
          // 记录层按 Session UUID 幂等；surface 重启复用同一 Session 继续记录。
          self.eventRecorder?.sessionStarted(
            id: self.id,
            projectPath: self.workingDirectory,
            shell: ProcessInfo.processInfo.environment["SHELL"]
          )
          self.recordingStateChanged.send(self.recordingMode)
          self.diagnostics.record(
            "terminal.process_started",
            level: .info,
            category: .terminal,
            attributes: self.processDiagnosticAttributes(
              launch: self.processGeneration == 1 ? "initial" : "restart")
          )
          self.startForegroundPolling()
          self.scheduleRestoreFallbackIfNeeded()
        }
      } else {
        self.isRunning = false
        self.lifecycleState = .startFailed
        self.startupError = GhosttyApp.shared.startupError ?? "无法创建 Ghostty terminal surface。"
        self.diagnostics.record(
          "terminal.process_start_failed",
          level: .error,
          category: .terminal,
          attributes: self.processDiagnosticAttributes(
            launch: self.processGeneration == 1 ? "initial" : "restart")
        )
      }
    }
    view.setReadOnly(readOnly)
    view.createSurface()
    return view
  }

  private func handleGhosttyOSC(
    code: Int,
    payload: [UInt8],
    point: ghostty_aster_buffer_point_s,
    view: GhosttySurfaceView
  ) {
    switch code {
    case 0...2:
      // 检测引擎要的是程序写出的标题原文（Claude 的 ✳/盲文前缀、Codex 的 Action
      // Required），必须在 Shell Controlled 开关之前记录，开关只管窗口标题的显示。
      receiveAgentOSCTitle(String(decoding: payload, as: UTF8.self))
      guard preferences?.configuration.shell.resolvedTitleShellControlled == true else { return }
      handleTitleOSC(code: code, text: String(decoding: payload, as: UTF8.self))
    case 9:
      guard payload.count <= TerminalNotificationParser.maximumChunkBytes else { return }
      let value = String(decoding: payload, as: UTF8.self)
      receiveAgentOSCProgress(value)
      // Ghostty 已处理标准 state 0...4；Aster/Otty 的 state 5 扩展只从 observer 补入。
      if let progress = TerminalProgressParser.parseOSC9(value), case .finished = progress {
        handleTerminalProgress(progress)
      }
    case 99:
      guard payload.count <= TerminalNotificationParser.maximumChunkBytes else { return }
      switch ghosttyKittyNotificationAssembler.consume(String(decoding: payload, as: UTF8.self)) {
      case .notification(let notification): post(notification, category: .application)
      case .response(let response): _ = view.sendProtocolBytes(Array(response.utf8))
      case nil: break
      }
    case 133:
      guard payload.count <= 32,
        let value = String(bytes: payload, encoding: .ascii),
        let event = ShellIntegrationEvent(payload: value)
      else { return }
      let signature = GhosttyShellMarkerSignature(
        payload: value,
        column: point.column,
        pageSerial: point.page_serial,
        pageRow: point.page_row
      )
      guard signature != lastGhosttyShellMarker else { return }
      lastGhosttyShellMarker = signature
      let token = recordGhosttyAnchor(point)
      ghosttyShellCommandTimeline.receive(
        event,
        at: TerminalGridPoint(column: Int(point.column), row: token)
      )
      autocompleteController?.receive(event)
      handleShellIntegrationEvent(event)
      handleShellIntegrationTimeline(ghosttyShellCommandTimeline)
    case 88:
      guard payload.count <= TerminalResumeProtocol.maximumPayloadBytes else { return }
      handleResumeProtocol(payload: String(decoding: payload, as: UTF8.self))
    case 6_973:
      guard payload.count <= 8_192,
        let value = String(bytes: payload, encoding: .ascii),
        let report = ShellAliasReport(payload: value)
      else { return }
      autocompleteController?.receiveAliases(report.names)
    case 6_974:
      guard payload.count <= AgentTerminalDirective.maximumPayloadBytes,
        let value = String(bytes: payload, encoding: .ascii)
      else { return }
      if let directive = TerminalBadgeDirective(payload: value) {
        switch directive {
        case .set(let badge): explicitBadge = badge
        case .clear: explicitBadge = nil
        }
      } else if let directive = AgentTerminalDirective(payload: value) {
        handleAgentTerminalDirective(directive)
      } else if let directive = AgentUsageDirective(payload: value) {
        handleAgentUsageDirective(directive)
      }
    default:
      break
    }
  }

  /// 为每个 OSC 133 位置分配严格单调 token。实际定位始终通过 page anchor 解析，
  /// token 仅满足现有 ShellCommandTimeline 的顺序比较与 Outline 公共接口。
  private func recordGhosttyAnchor(_ point: ghostty_aster_buffer_point_s) -> Int {
    let token = ghosttyNextAnchorToken
    ghosttyNextAnchorToken &+= 1
    ghosttyBufferAnchors[token] = point
    if ghosttyBufferAnchors.count > 4_000 {
      let retained = Set(ghosttyShellCommandTimeline.marks.flatMap {
        [$0.promptStart.row, $0.inputStart.row, $0.outputStart.row, $0.outputEnd.row]
      })
      ghosttyBufferAnchors = ghosttyBufferAnchors.filter {
        retained.contains($0.key) || $0.key >= token - 16
      }
    }
    return token
  }

  private func handleGhosttyProcessExit(code: Int32?) {
    clearSSHRemoteEndpoint()
    eventRecorder?.sessionEnded(id: id, exitCode: code)
    let termination = TerminalProcessTermination(rawWaitStatus: code.map { $0 << 8 })
    lifecycleState = .ended(termination)
    exitCode = code ?? termination.shellExitCode
    isRunning = false
    hasRunningCommand = false
    awaitingInput = false
    stopAgentScreenMonitor()
    activeAgentProvider = nil
    activeAgentSessionID = nil
    clearAgentUsage()
    agentTaskState = .idle
    clearFallbackAgentActivity()
    foregroundPollTask?.cancel()
    foregroundPollTask = nil
    awaitingInputTask?.cancel()
    awaitingInputTask = nil
    SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
    diagnostics.record(
      "terminal.process_terminated",
      level: termination.isUnexpected ? .error : .notice,
      category: .terminal,
      attributes: terminationDiagnosticAttributes(termination, rawWaitStatus: code.map { $0 << 8 })
    )
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
        if let ghosttyView = self.ghosttyView {
          guard ghosttyView.isProcessRunning else {
            if self.hasRunningCommand { self.hasRunningCommand = false }
            SecureInputCoordinator.shared.releaseAutomaticRequest(for: self.id)
            return
          }
          let foreground = ghosttyView.foregroundProcessIdentifier
          if self.ghosttyShellProcessIdentifier == nil {
            self.ghosttyShellProcessIdentifier = foreground
          }
          let running = foreground != nil && foreground != self.ghosttyShellProcessIdentifier
          if running, !self.hasRunningCommand {
            self.handleShellIntegrationEvent(.commandStart)
          }
          if self.hasRunningCommand != running {
            self.hasRunningCommand = running
            self.updateAgentTaskState()
          }
          continue
        }
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
    let terminal = makeGhosttyTerminalView(preferences: preferences)
    if let terminalHostView {
      terminalHostView.layer?.backgroundColor = preferences.terminalCanvasBackgroundColor.cgColor
      if terminal.superview !== terminalHostView {
        // 视图树刷新若留下旧终端而当前代 View 未重新挂入，用户会同时看到“不能输入、
        // 字号不更新”。每次构建 Pane 都校验唯一绑定并原位修复，不创建第二个 PTY。
        attachTerminal(terminal, to: terminalHostView)
        diagnostics.record(
          "terminal.view_binding_repaired",
          level: .warning,
          category: .terminal,
          attributes: processDiagnosticAttributes()
        )
      }
      return terminalHostView
    }
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = preferences.terminalCanvasBackgroundColor.cgColor
    attachTerminal(terminal, to: host)
    terminalHostView = host
    return host
  }

  /// 丢弃已结束的 Ghostty surface，使用同一 Session、Pane ID 和最近可靠本地目录创建
  /// 全新 PTY。旧 surface 不原地复用，避免迟到 callback 穿过进程代次。
  @discardableResult
  func restart() -> Bool {
    guard canRestart, !statusIsRunning else { return false }
    guard let preferences else {
      diagnostics.record(
        "terminal.process_restart_failed",
        level: .error,
        category: .terminal,
        attributes: processDiagnosticAttributes(extra: ["reason": "preferences_unavailable"])
      )
      return false
    }

    let previousReason = lifecycleState.diagnosticReason
    diagnostics.record(
      "terminal.process_restart_requested",
      level: .notice,
      category: .terminal,
      attributes: processDiagnosticAttributes(extra: ["previous_reason": previousReason])
    )

    if let previousGhostty = ghosttyView {
      previousGhostty.removeFromSuperview()
      previousGhostty.destroySurface()
      ghosttyView = nil
      ghosttyShellProcessIdentifier = nil
    }
    if let previousView = terminalView {
      previousView.processDelegate = nil
      previousView.removeFromSuperview()
      TerminalRetirementCoordinator.shared.complete(previousView)
      terminalView = nil
    }
    targetOpenCoordinator = nil
    autocompleteController = nil

    let replacement = makeGhosttyTerminalView(preferences: preferences)
    if let terminalHostView {
      attachTerminal(replacement, to: terminalHostView)
    }
    if statusIsRunning { focus() }
    return statusIsRunning
  }

  private func attachTerminal(_ terminal: NSView, to host: NSView) {
    guard terminal.superview !== host else { return }
    terminal.removeFromSuperview()
    if let firstSubview = host.subviews.first {
      host.addSubview(terminal, positioned: .below, relativeTo: firstSubview)
    } else {
      host.addSubview(terminal)
    }
    terminal.pinEdges(to: host)
  }

  func apply(preferences: AppPreferences) {
    self.preferences = preferences
    if let ghosttyView {
      let controls = preferences.configuration.controls
      ghosttyView.focusFollowsMouse = controls.focusFollowsMouse
      ghosttyView.pasteProtectionEnabled = controls.pasteProtection
      ghosttyView.pasteBracketedSafe = controls.resolvedPasteBracketedSafe
      applyLinkDetectionSettings(preferences, to: ghosttyView)
      ghosttyView.updateConfiguration(GhosttyConfiguration.make(preferences: preferences))
      automaticSecureInputEnabled = controls.secureInputAutomatically
    }
    if let terminalView { apply(preferences: preferences, to: terminalView) }
  }

  /// 把链接识别相关设置（总开关、scheme 策略、预览开关、下划线颜色）同步到 Ghostty 视图。
  private func applyLinkDetectionSettings(_ preferences: AppPreferences, to view: GhosttySurfaceView) {
    let controls = preferences.configuration.controls
    view.linkDetectionEnabled = controls.resolvedLinkDetectionEnabled
    view.linkSchemePolicy = controls.resolvedLinkSchemePolicy
    view.linkPreviewEnabled = controls.showLinkPreviews
    view.linkUnderlineColor = NSColor(preferences.activeTheme.palette.foreground)
  }

  /// 将命令直接写入活动 PTY，供 Recipe、命令面板和自动化入口使用。
  func send(_ command: String) {
    recordSubmittedCommand(command)
    if let ghosttyView {
      _ = ghosttyView.typeText(command + "\n")
      return
    }
    guard let terminalView, terminalView.process.running else { return }
    let bytes = Array((command + "\n").utf8)
    // Recipe 和命令面板也是用户输入入口；必须经过视图才能应用清选区、回到底部、
    // 输入活跃度和安全键盘采样，不能直接绕过到 LocalProcess。
    terminalView.send(data: bytes[...])
  }

  @discardableResult
  func sendRecipeCommand(_ command: String) -> Bool {
    guard statusIsRunning else { return false }
    pendingCommandOrigin = .recipeReplay
    send(command)
    return true
  }

  /// 把文本原样写入 PTY（不带回车）：用于把命令预填到提示符，执行与否由用户确认。
  func typeText(_ text: String) {
    if let ghosttyView {
      _ = ghosttyView.typeText(text)
      return
    }
    guard let terminalView, terminalView.process.running else { return }
    let bytes = Array(text.utf8)
    terminalView.send(data: bytes[...])
  }

  /// Shell 菜单「清屏」：Ghostty 走内建 clear_screen binding（同时清除滚动历史锚点语义
  /// 由引擎处理）；SwiftTerm 回归路径退化为向 PTY 发送 Ctrl+L，由前台程序自行重绘。
  func clearScreen() {
    if let ghosttyView {
      _ = ghosttyView.performBindingAction("clear_screen")
      return
    }
    typeText("\u{0C}")
  }

  /// IPC send-text/send-keys 的原始用户输入入口。仍经 `AsterTerminalView.send`，因此
  /// Read-only、Vi/Hint 本地模式、选择清理与输入活跃度规则不会被自动化绕过。
  @discardableResult
  func sendAutomationBytes(_ bytes: [UInt8]) -> Bool {
    if let ghosttyView {
      guard !bytes.isEmpty, bytes.count <= WorkflowCLIInputDecoder.maximumBytes else { return false }
      return ghosttyView.sendBytes(bytes)
    }
    guard let terminalView, terminalView.process.running, !bytes.isEmpty,
      bytes.count <= WorkflowCLIInputDecoder.maximumBytes
    else { return false }
    terminalView.send(data: bytes[...])
    return true
  }

  var selectedTextForAgentContext: String? {
    ghosttyView?.readSelection() ?? terminalView?.getSelection()
  }

  /// 外部拖入的文本与普通粘贴共享风险分析、确认、bracketed paste 和只读门禁。
  @discardableResult
  func pasteDroppedText(_ text: String) -> Bool {
    ghosttyView?.pasteText(text) ?? terminalView?.pasteText(text) ?? false
  }

  /// 把提示词以 bracketed paste 写入终端输入行但不回车，供 Open Quickly「当前」页
  /// 复用历史 prompt；粘贴保护与只读门禁仍由终端视图统一执行。
  @discardableResult
  func pastePromptText(_ text: String) -> Bool {
    ghosttyView?.pasteText(text) ?? terminalView?.pasteText(text, forceBracketed: true) ?? false
  }

  /// 以普通键入方式预填 Agent 输入框，不带 Return。该入口只供 Prompt Queue 与
  /// “发送到聊天”使用，避免影响 Open Quickly 的既有安全粘贴。
  @discardableResult
  func typePromptText(_ text: String) -> Bool {
    ghosttyView?.pasteText(text) ?? terminalView?.typePromptText(text) ?? false
  }

  /// 当前阻止 Prompt 写入前台程序的原因，可写入时为 nil。失败提示必须能落到具体
  /// 动作上：只说“写入失败”，用户无从判断该解锁 Pane、退出 Vi 还是等终端就绪。
  var promptWriteBlocker: String? {
    if let ghosttyView {
      guard ghosttyView.isProcessRunning else { return "终端进程已退出" }
      return ghosttyView.readOnly ? "Pane 处于只读模式" : nil
    }
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
    if let ghosttyView {
      guard ghosttyView.pasteText(text) else { return false }
      return ghosttyView.typeText("\n")
    }
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
    if let ghosttyView {
      guard ghosttyView.pasteText(text) else { return false }
      return ghosttyView.typeText("\n")
    }
    return terminalView?.submitPromptQueueText(text) ?? false
  }

  func interrupt() {
    if let ghosttyView {
      ghosttyView.sendInterrupt()
      return
    }
    guard let terminalView, terminalView.process.running else { return }
    let controlC = [UInt8(3)]
    terminalView.send(data: controlC[...])
  }

  /// 判断给定终端视图是否由本会话持有；工作区 `refresh()` 恢复 first responder
  /// 前用它校验归属，避免把键盘焦点还给已不是活动 Pane 的旧终端。
  func owns(_ view: AsterTerminalView) -> Bool {
    terminalView === view
  }

  func owns(_ view: GhosttySurfaceView) -> Bool {
    ghosttyView === view
  }

  /// 最近一次 `focus()` 失败的原因，供工作区层诊断记录；成功时为 nil。
  private(set) var focusFailureReason: String?

  /// 把键盘焦点交给本会话的终端视图；返回是否成功，失败原因写入
  /// `focusFailureReason`（视图未创建 / 未上屏 / 系统拒绝交接）。
  @discardableResult
  func focus() -> Bool {
    if let ghosttyView {
      guard let window = ghosttyView.window else {
        focusFailureReason = "view_detached"
        return false
      }
      guard window.makeFirstResponder(ghosttyView) else {
        focusFailureReason = "responder_refused"
        return false
      }
      focusFailureReason = nil
      return true
    }
    guard let terminalView else {
      focusFailureReason = "no_view"
      return false
    }
    guard let window = terminalView.window else {
      focusFailureReason = "view_detached"
      return false
    }
    guard window.makeFirstResponder(terminalView) else {
      focusFailureReason = "responder_refused"
      return false
    }
    focusFailureReason = nil
    refreshAutomaticSecureInput()
    return true
  }

  /// 在完整滚动缓冲区内查找并选中下一处匹配文本。
  @discardableResult
  func findNext(
    _ term: String,
    previous: Bool = false,
    caseSensitive: Bool = false,
    regularExpression: Bool = false
  ) -> Bool {
    guard !term.isEmpty else { return false }
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
    let found: Bool
    if let ghosttyView {
      found = ghosttyView.find(
        term,
        previous: resolvedPrevious,
        caseSensitive: caseSensitive,
        regularExpression: regularExpression
      )
    } else if let terminalView {
      let options = SearchOptions(caseSensitive: caseSensitive, regex: regularExpression)
      found = resolvedPrevious
        ? terminalView.findPrevious(term, options: options)
        : terminalView.findNext(term, options: options)
    } else {
      return false
    }
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
    guard !term.isEmpty else { return (0, 0) }
    if let ghosttyView {
      guard ghosttyView.searchNeedle == term else {
        return (0, 0)
      }
      return (ghosttyView.searchSelected, ghosttyView.searchTotal)
    }
    guard let terminalView else { return (0, 0) }
    return terminalView.searchMatchSummary(
      term,
      options: SearchOptions(caseSensitive: caseSensitive, regex: regularExpression)
    )
  }

  func clearFind() {
    ghosttyView?.clearSearch()
    terminalView?.clearSearch()
    lastFindTerm = ""
    pendingViSearchDirection = nil
  }

  /// 控制协议 `agent.focus`：用户（或代表用户的 agent）已经看过完成结果，清掉「完成未读」。
  /// CLI 读屏刻意不调用它——只读操作不应改变徽章。
  func markAgentCompletionSeen() {
    if agentTaskCompletionUnread { agentTaskCompletionUnread = false }
  }

  /// 控制协议读屏：visible 只取当前视口，recent 含回滚；行数上限由调用方裁剪。
  /// Ghostty 路径直接读引擎；SwiftTerm 回归路径退化为有界快照。
  func readControlText(includeScrollback: Bool, maximumLines: Int) -> String? {
    if let ghosttyView {
      return ghosttyView.readText(includeScrollback: includeScrollback, maximumLines: maximumLines)
    }
    guard let terminalView else { return nil }
    let lines = terminalView.boundedTextSnapshot().lines
    return lines.suffix(maximumLines).joined(separator: "\n")
  }

  func textSnapshot() -> TerminalTextSnapshot {
    if let text = ghosttyView?.readText(includeScrollback: true, maximumLines: 10_000) {
      return .init(firstAbsoluteRow: 0, lines: text.components(separatedBy: "\n"))
    }
    return terminalView?.boundedTextSnapshot() ?? .init(firstAbsoluteRow: 0, lines: [])
  }

  func commandOutlineEntries() -> [TerminalCommandOutlineEntry] {
    if let ghosttyView { return ghosttyCommandOutlineEntries(view: ghosttyView) }
    return terminalView?.commandOutlineEntries() ?? []
  }

  @discardableResult
  func revealAbsoluteRow(_ row: Int) -> Bool {
    if let ghosttyView {
      guard let anchor = ghosttyBufferAnchors[row] else {
        return ghosttyView.revealScreenRow(row)
      }
      return ghosttyView.reveal(anchor)
    }
    return terminalView?.revealAbsoluteRow(row) ?? false
  }

  private func ghosttyCommandOutlineEntries(
    view: GhosttySurfaceView,
    maximumItems: Int = 1_000
  ) -> [TerminalCommandOutlineEntry] {
    let limit = max(0, min(maximumItems, 5_000))
    var tracked = Set(ghosttyShellCommandTimeline.marks.map { $0.inputStart.row })
    if let running = ghosttyShellCommandTimeline.runningCommand {
      tracked.insert(running.inputStart.row)
    }
    ghosttyCommandOutlineTitles = ghosttyCommandOutlineTitles.filter { tracked.contains($0.key) }

    func entry(
      promptStart: TerminalGridPoint,
      inputStart: TerminalGridPoint,
      exitStatus: Int?,
      finishedAt: Date?,
      isRunning: Bool
    ) -> TerminalCommandOutlineEntry? {
      let title: String
      let jumpAvailable: Bool
      if let inputAnchor = ghosttyBufferAnchors[inputStart.row],
        let text = view.readLine(at: inputAnchor, startingAt: UInt32(inputStart.column))
      {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        title = normalized.isEmpty ? "命令" : String(normalized.prefix(240))
        ghosttyCommandOutlineTitles[inputStart.row] = title
        jumpAvailable = ghosttyBufferAnchors[promptStart.row]
          .flatMap { view.resolveBufferPoint($0) } != nil
      } else if let cached = ghosttyCommandOutlineTitles[inputStart.row] {
        title = cached
        jumpAvailable = false
      } else {
        return nil
      }
      return TerminalCommandOutlineEntry(
        title: title,
        absoluteRow: promptStart.row,
        exitStatus: exitStatus,
        finishedAt: finishedAt,
        isRunning: isRunning,
        isJumpAvailable: jumpAvailable
      )
    }

    var result = ghosttyShellCommandTimeline.marks.suffix(limit).compactMap { mark in
      entry(
        promptStart: mark.promptStart,
        inputStart: mark.inputStart,
        exitStatus: mark.exitStatus,
        finishedAt: mark.finishedAt,
        isRunning: false
      )
    }
    if let running = ghosttyShellCommandTimeline.runningCommand,
      let runningEntry = entry(
        promptStart: running.promptStart,
        inputStart: running.inputStart,
        exitStatus: nil,
        finishedAt: nil,
        isRunning: true
      )
    {
      result.append(runningEntry)
    }
    return result
  }

  private func repeatLastFind(reverse: Bool) {
    guard !lastFindTerm.isEmpty else { return }
    let previous = reverse ? !lastFindWasPrevious : lastFindWasPrevious
    if let ghosttyView {
      _ = ghosttyView.find(lastFindTerm, previous: previous)
    } else if let terminalView {
      _ = previous
        ? terminalView.findPrevious(lastFindTerm)
        : terminalView.findNext(lastFindTerm)
    }
  }

  func setReadOnly(_ value: Bool) {
    readOnly = value
    ghosttyView?.setReadOnly(value)
    terminalView?.setReadOnly(value)
  }

  func toggleReadOnly() { setReadOnly(!readOnly) }
  func enterViMode() {
    if let ghosttyView { ghosttyView.enterViMode(); return }
    terminalView?.enterViMode(nil)
  }
  func enterMarkMode() {
    if let ghosttyView { ghosttyView.enterMarkMode(); return }
    terminalView?.enterMarkMode(nil)
  }
  func openHintMode() {
    if let ghosttyView { ghosttyView.openHintMode(); return }
    terminalView?.openHintMode(nil)
  }

  /// 立即读取由 OSC 7 报告的工作目录。没有集成标记时保留最近一次可靠值。
  func resolvedCurrentWorkingDirectory() -> String {
    currentWorkingDirectory
  }

  /// 统一登记用户已经提交的命令。SSH 分组解析与 Agent/Recipe 生命周期消费同一份
  /// 本地输入真值，不扫描终端输出，也不会把远端提示文字误判成连接命令。
  private func recordSubmittedCommand(_ command: String) {
    submittedCommand = command
    submittedCommandOrigin = pendingCommandOrigin ?? .shellIntegration
    pendingCommandOrigin = nil
    guard let invocation = SSHCommandInvocation.parse(command) else { return }

    sshResolutionGeneration &+= 1
    let generation = sshResolutionGeneration
    let resolver = sshEndpointResolver
    sshResolutionTask?.cancel()
    sshResolutionTask = Task { @MainActor [weak self] in
      let endpoint = await resolver(invocation)
      guard !Task.isCancelled, let self, self.sshResolutionGeneration == generation else { return }
      self.sshRemoteEndpoint = endpoint
      self.sshResolutionTask = nil
    }
  }

  /// 清除远端投影并使所有在途解析结果失效。分组变化由 `@Published` 定向触发侧栏
  /// 重建，不改变终端标题、PTY 或持久化 Workspace。
  private func clearSSHRemoteEndpoint() {
    sshResolutionGeneration &+= 1
    sshResolutionTask?.cancel()
    sshResolutionTask = nil
    if sshRemoteEndpoint != nil { sshRemoteEndpoint = nil }
  }

  /// 统一处理 Ghostty/SwiftTerm 的 OSC 7。远端 URL 无法转成本地路径时只切换来源标记；
  /// 之后第一次重新收到可信本地目录，说明 SSH 已返回本地 Shell，应撤销远端分组。
  private func applyReportedWorkingDirectory(_ reportedValue: String) {
    let normalized = Self.normalizeReportedWorkingDirectory(reportedValue)
    guard !normalized.isEmpty else {
      currentWorkingDirectoryIsLocal = false
      return
    }
    let returnedFromRemote = !currentWorkingDirectoryIsLocal
    currentWorkingDirectoryIsLocal = true
    if returnedFromRemote { clearSSHRemoteEndpoint() }
    if currentWorkingDirectory != normalized { currentWorkingDirectory = normalized }
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
    ghosttyView?.setWindowActive(active)
    terminalView?.setWindowActive(active)
    if active {
      refreshAutomaticSecureInput()
    } else {
      SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
    }
  }

  /// 同步分屏领域焦点。SwiftTerm 的 responder 失焦样式固定为空心方块，Aster 改由
  /// activePaneID 控制同形状光标的闪烁状态，Pane 切换不会覆盖用户外观设置。
  func setPaneActive(_ active: Bool) {
    ghosttyView?.setPaneActive(active)
    terminalView?.setPaneActive(active)
  }

  /// 停止当前 Shell。关闭 Pane 时先给予 750ms 正常退出窗口；应用即将终止时必须
  /// 立即结束进程组，因为主事件循环不会继续存活到延迟升级任务执行。
  func stop(immediately: Bool = false) {
    clearSSHRemoteEndpoint()
    // Pane 关闭：停掉用量监听并删掉本 pane 的用量文件。
    clearAgentUsage()
    if agentUsageSubscribedAt != nil {
      agentUsageFileStore.unsubscribe(paneID: id)
      agentUsageSubscribedAt = nil
    }
    // 用户关闭 Pane/标签不会经过 GHOSTTY 的 child-exited 回调（destroySurface 直接
    // 释放并清空回调）。必须在拆 surface 前显式闭合记录会话，否则 sessions 行永远
    // 停在 active，挂在会话结束链上的 Memory 提炼永远不会发生。记录层按 id 幂等，
    // shell 自行退出（exit/Ctrl-D）后的重复调用是 no-op；主动关闭没有退出码。
    eventRecorder?.sessionEnded(id: id, exitCode: nil)
    lifecycleState = .stopping
    if let ghostty = ghosttyView {
      diagnostics.record(
        "terminal.process_stop_requested",
        level: .debug,
        category: .terminal,
        attributes: processDiagnosticAttributes(extra: [
          "mode": immediately ? "immediate" : "graceful"
        ])
      )
      ghosttyView = nil
      ghosttyShellProcessIdentifier = nil
      terminalHostView = nil
      targetOpenCoordinator = nil
      autocompleteController = nil
      isRunning = false
      foregroundPollTask?.cancel()
      foregroundPollTask = nil
      stopAgentScreenMonitor()
      clearFallbackAgentActivity()
      awaitingInputTask?.cancel()
      completedFlashTask?.cancel()
      progressExpiryTask?.cancel()
      SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
      ghostty.destroySurface()
      return
    }
    guard let view = terminalView else {
      isRunning = false
      return
    }
    intentionallyRetiredViews.insert(ObjectIdentifier(view))
    diagnostics.record(
      "terminal.process_stop_requested",
      level: .debug,
      category: .terminal,
      attributes: processDiagnosticAttributes(extra: [
        "mode": immediately ? "immediate" : "graceful"
      ])
    )
    terminalView = nil
    terminalHostView = nil
    targetOpenCoordinator = nil
    autocompleteController = nil
    isRunning = false
    foregroundPollTask?.cancel()
    foregroundPollTask = nil
    stopAgentScreenMonitor()
    clearFallbackAgentActivity()
    awaitingInputTask?.cancel()
    completedFlashTask?.cancel()
    progressExpiryTask?.cancel()
    SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)

    // SwiftTerm 1.15 的 `terminate()` 会在发送信号后立即取消进程监视器，且自然退出
    // 后保留旧 PID。托管器只接受仍运行的 View，并在 Session 释放后继续负责升级
    // 信号及等待 monitor 回收，避免僵尸进程和 PID 复用后的误杀。
    TerminalRetirementCoordinator.shared.retire(view, immediately: immediately)
  }

  /// 新进程不能继承上一代 Shell/TUI 的瞬态状态。Pane 的稳定身份、只读开关、回调和
  /// 最近可靠目录保留；进程、命令、Agent、搜索与通知状态全部重新初始化。
  private func prepareForProcessLaunch() {
    clearSSHRemoteEndpoint()
    lifecycleState = .starting
    isRunning = false
    exitCode = nil
    startupError = nil
    terminalTitle = "Shell"
    terminalIconTitle = ""
    shellIntegrationDetected = false
    lastCommandExitStatus = nil
    hasRunningCommand = false
    progressState = .clear
    awaitingInput = false
    showsCompletedFlash = false
    explicitBadge = nil
    activeAgentProvider = nil
    activeAgentSessionID = nil
    clearAgentUsage()
    agentTaskState = .idle
    agentTaskCompletionUnread = false
    agentLifecycleIsAuthoritative = false
    agentProviderIsTitleEvidenceOnly = false
    agentHasWorkEvidence = false
    stopAgentScreenMonitor()
    agentOSCTitle = ""
    agentOSCProgress = ""
    clearFallbackAgentActivity()
    agentLifecycleSequence = 0
    agentStateReducer = AgentTaskStateReducer()
    submittedCommand = nil
    resumeProtocolCommand = nil
    pendingCommandOrigin = nil
    recipeCommandCandidates.removeAll(keepingCapacity: true)
    activityOutputTail = ""
    pendingViSearchDirection = nil
    lastFindTerm = ""
    lastFindWasPrevious = false
    lastScreenHash = 0
    lastActivityAt = .distantPast
    ghosttyShellProcessIdentifier = nil
    ghosttyShellCommandTimeline = ShellCommandTimeline()
    ghosttyBufferAnchors.removeAll(keepingCapacity: false)
    ghosttyCommandOutlineTitles.removeAll(keepingCapacity: false)
    ghosttyNextAnchorToken = 1
    ghosttyKittyNotificationAssembler = KittyNotificationAssembler()
    lastGhosttyShellMarker = nil
    processStartedAt = nil
    foregroundPollTask?.cancel()
    foregroundPollTask = nil
    awaitingInputTask?.cancel()
    awaitingInputTask = nil
    completedFlashTask?.cancel()
    completedFlashTask = nil
    progressExpiryTask?.cancel()
    progressExpiryTask = nil
    SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
  }

  /// 诊断关联值均为有界、非内容型元数据。额外字段只能由本文件的固定调用点提供，且仍
  /// 会经过 DiagnosticsCenter 的敏感键过滤，禁止把命令、路径或环境透传进来。
  private func processDiagnosticAttributes(
    launch: String? = nil,
    extra: [String: String] = [:]
  ) -> [String: String] {
    var attributes = [
      "session_id": id.uuidString.lowercased(),
      "generation": "\(processGeneration)",
      "state": lifecycleState.diagnosticReason,
    ]
    if let launch { attributes["launch"] = launch }
    if let processStartedAt {
      let milliseconds = max(0, Int(Date().timeIntervalSince(processStartedAt) * 1_000))
      attributes["uptime_ms"] = "\(milliseconds)"
    }
    for (key, value) in extra { attributes[key] = value }
    return attributes
  }

  private func terminationDiagnosticAttributes(
    _ termination: TerminalProcessTermination,
    rawWaitStatus: Int32?
  ) -> [String: String] {
    var extra: [String: String] = [:]
    if let rawWaitStatus { extra["raw_wait_status"] = "\(rawWaitStatus)" }
    switch termination {
    case .exited(let code):
      extra["outcome"] = "exited"
      extra["exit_code"] = "\(code)"
    case .signaled(let signal, let coreDumped):
      extra["outcome"] = "signaled"
      extra["signal"] = "\(signal)"
      extra["core_dumped"] = coreDumped ? "true" : "false"
    case .ioFailure:
      extra["outcome"] = "io_failure"
    }
    return processDiagnosticAttributes(extra: extra)
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
    view.applyThemePalette(preferences)
    let controls = preferences.configuration.controls
    let optionMode = controls.resolvedOptionAsMetaMode
    view.optionAsMetaKey = optionMode != .off
    view.optionAsMetaKeyCodes = switch optionMode {
    case .off: []
    case .both: [58, 61]
    case .left: [58]
    case .right: [61]
    }
    view.vtKeypadApplicationModeAllowed = controls.resolvedVTKeypadAppAllowed
    view.allowMouseReporting = preferences.allowMouseReporting
    view.mouseReportingBypassModifiers = switch controls.resolvedBypassMouseReporting {
    case .none: []
    case .shift: [.shift]
    case .control: [.control]
    case .option: [.option]
    case .controlShift: [.control, .shift]
    case .command: [.command]
    }
    view.rightClickAction = controls.resolvedRightClickAction
    view.mouseHideWhileTyping = controls.resolvedMouseHideWhileTyping
    view.focusFollowsMouse = controls.focusFollowsMouse
    view.linkClickOverMouseMode = controls.resolvedLinkClickOverMouseMode
    view.linkActivationOverMouseReporting = controls.resolvedLinkClickOverMouseMode
    view.cursorClickToMove = controls.resolvedCursorClickToMove
    view.selectionBackspaceDeletes = controls.resolvedSelectionBackspaceDeletes
    view.linkReporting =
      preferences.configuration.controls.resolvedLinkDetectionEnabled
      ? .implicit : .none
    view.linkSchemePolicy = preferences.configuration.controls.resolvedLinkSchemePolicy
    view.linkPreviewEnabled = controls.showLinkPreviews
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
    let scrollback = Int(min(max(
      preferences.compatibilityNumber(forKey: "advanced.scrollbackLines", default: 10_000),
      1_000
    ), 1_000_000))
    if view.getTerminal().options.scrollback != scrollback {
      view.changeScrollback(scrollback)
    }
    automaticSecureInputEnabled = preferences.configuration.controls.secureInputAutomatically
    if automaticSecureInputEnabled {
      refreshAutomaticSecureInput()
    } else {
      SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)
    }
    let blinkMode = preferences.configuration.appearance.resolvedCursorBlinkMode
    let cursorStyle = swiftTermCursorStyle(
      preferences.configuration.appearance.cursorStyle.rawValue,
      blinks: blinkMode.initiallyBlinks
    )
    view.configureCursor(
      initialStyle: cursorStyle,
      pinsProgramBlinking: blinkMode.pinsProgramControl
    )
    view.needsDisplay = true
  }

  private func refreshAutomaticSecureInput() {
    // Ghostty 会以 SECURE_INPUT action 明确上报应用模式；没有公开 PTY fd 可读取
    // termios，因此不能套用 SwiftTerm 的 tcgetattr fallback。
    if ghosttyView != nil { return }
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
    detectAgentProviderFromTitle(text)
    onTitleUpdate?(code, text)
  }

  /// 从程序标题补识别 Agent（不依赖 hook 与命令首词，例如经 wrapper 启动时）。
  /// 只在有前台命令运行且尚无 provider 时补识别；纯提示符下的标题（`mike@mac: ~/src/agent`）
  /// 绝不识别。标题得到的 provider 是弱证据：标题变得不匹配且没有 hook / 屏幕 working·blocked
  /// 证据时撤销，命令结束时随 commandFinished 一起清掉。
  private func detectAgentProviderFromTitle(_ title: String) {
    let detected = Self.agentProvider(fromTitle: title)
    if let activeAgentProvider {
      guard agentProviderIsTitleEvidenceOnly, detected != activeAgentProvider,
        !agentLifecycleIsAuthoritative, !agentHasWorkEvidence
      else { return }
      clearTitleEvidenceAgentProvider()
      return
    }
    guard hasRunningCommand, let detected else { return }
    activeAgentProvider = detected
    agentProviderIsTitleEvidenceOnly = true
    syncAgentScreenMonitor()
    if agentScreenMonitor == nil { markFallbackAgentActivity() }
  }

  /// 撤销仅凭标题得出的 provider：停读屏、清回退探针、回到普通命令状态。
  private func clearTitleEvidenceAgentProvider() {
    stopAgentScreenMonitor()
    clearFallbackAgentActivity()
    activeAgentProvider = nil
    clearAgentUsage()
    agentProviderIsTitleEvidenceOnly = false
    agentHasWorkEvidence = false
    updateAgentTaskState()
  }

  /// 标题里过于通用、会撞上普通 shell 标题（`ssh pi`、`man amp`、`cd ~/muse`）的别名；
  /// 这些 provider 只靠 commandStart 首 token 与 hook 识别。
  nonisolated private static let titleDetectionExcludedAliases: Set<String> = [
    "agent", "pi", "amp", "omp", "muse", "maki", "cline", "kilo", "droid", "cursor",
  ]

  /// 标题 → provider 的纯函数。Claude 的 ✳ / 盲文 / 半圆 spinner 前缀直接判 Claude；
  /// 其余要求去空白后的小写标题**以别名开头**，且别名之后是结尾、空格、`:` 或 `—`
  /// （`codex-helper`、`codex.py` 都不算）。
  nonisolated static func agentProvider(fromTitle title: String) -> AgentProvider? {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.unicodeScalars.first else { return nil }
    // ✳ U+2733；盲文 U+2800–U+28FF；半圆 spinner U+25D0–U+25D3（Claude 2.1.228+）。
    if first.value == 0x2733 || (0x2800...0x28FF).contains(first.value)
      || (0x25D0...0x25D3).contains(first.value)
    {
      return .claudeCode
    }
    let lowered = trimmed.lowercased()
    for provider in AgentProvider.allCases {
      for alias in provider.executableAliases
      where !titleDetectionExcludedAliases.contains(alias) && lowered.hasPrefix(alias) {
        let rest = lowered.dropFirst(alias.count)
        if rest.isEmpty { return provider }
        if let next = rest.first, next == " " || next == ":" || next == "—" { return provider }
      }
    }
    return nil
  }

  private func handleShellIntegrationTimeline(_ timeline: ShellCommandTimeline) {
    if shellIntegrationDetected != timeline.integrationDetected {
      shellIntegrationDetected = timeline.integrationDetected
    }
    if timeline.integrationDetected, ghosttyView != nil {
      // Ghostty 的 OSC observer 已提供精确 C/D 生命周期，surface 退出也有独立 callback；
      // 此后继续每秒读取前台 PID 只会制造与 Pane 数量线性增长的空闲唤醒。SwiftTerm
      // 仍保留任务，因为它还承担无 I/O 时自动 Secure Input 的低频兜底采样。
      foregroundPollTask?.cancel()
      foregroundPollTask = nil
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
    case .promptStart:
      // shell 就绪的权威信号：恢复的 Agent 会话在首个 prompt 处重连。
      deliverRestoredAgentResumeIfNeeded()
    case .inputStart:
      break
    case .commandStart:
      eventRecorder?.commandStarted(
        id: id,
        command: submittedCommand,
        workingDirectory: currentWorkingDirectoryIsLocal ? currentWorkingDirectory : ""
      )
      clearAwaitingInput()
      // 上一条命令的终态（finished/error）不能带进新命令：否则 commandFinished 里
      // 「OSC 9;4;5 已报完成」的 guard 会被旧值误触发，progressState 永远停在第一条
      // 命令的结果，标签会显示「退出码 0 却是红色 error」的矛盾徽章，完成通知与
      // completed flash 也不再触发。进行中的 determinate/indeterminate 必须保留，
      // 避免打断 OSC 9;4 已经开始的进度条。
      switch progressState {
      case .finished, .error: progressState = .clear
      case .clear, .determinate, .indeterminate: break
      }
      completedFlashTask?.cancel()
      showsCompletedFlash = false
      activityOutputTail = ""
      if let command = submittedCommand {
        let executable = ShellCommandTokenizer.tokenize(command).tokens.first ?? ""
        activeAgentProvider = AgentProvider.detect(executablePath: executable)
      } else {
        activeAgentProvider = nil
      }
      clearAgentUsage()
      agentProviderIsTitleEvidenceOnly = false
      agentHasWorkEvidence = false
      agentLifecycleIsAuthoritative = false
      activeAgentSessionID = nil
      agentLifecycleSequence = 0
      agentStateReducer = AgentTaskStateReducer()
      clearFallbackAgentActivity()
      // 有清单的 provider 优先走屏幕检测；monitor 启动后 5s 静默兜底自动禁用。
      syncAgentScreenMonitor()
      if activeAgentProvider != nil, agentScreenMonitor == nil {
        markFallbackAgentActivity()
      } else {
        updateAgentTaskState()
      }
      guard let command = submittedCommand,
        let shell = preferences?.configuration.shell,
        AutomaticProgressMatcher(prefixes: shell.resolvedAutoProgressCommands).matches(command)
      else { return }
      progressState = .indeterminate
    case .commandFinished(let exitStatus):
      // 必须在本分支尾部把 submittedCommand 置 nil 之前上报。
      eventRecorder?.commandFinished(
        id: id, command: submittedCommand, exitStatus: exitStatus)
      defer {
        // 顶层 SSH 失败或退出时仍处于本地目录；远端 Shell 的嵌套命令完成时 OSC 7
        // 已把来源标为远端，不得把同一连接的服务器分组清掉。
        if currentWorkingDirectoryIsLocal { clearSSHRemoteEndpoint() }
        onCommandFinished?()
      }
      clearAwaitingInput()
      stopAgentScreenMonitor()
      agentTaskState = .idle
      activeAgentProvider = nil
      clearAgentUsage()
      agentProviderIsTitleEvidenceOnly = false
      agentHasWorkEvidence = false
      activeAgentSessionID = nil
      agentTaskCompletionUnread = false
      agentLifecycleIsAuthoritative = false
      clearFallbackAgentActivity()
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
      // 只可能匹配「本条命令内 OSC 9;4;5 已携带完成语义」：commandStart 已经清掉了
      // 上一条命令留下的终态，因此这里不重复通知；否则由 OSC 133 形成完成状态。
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
    let focused = if let ghosttyView {
      ghosttyView.window?.isKeyWindow == true
        && ghosttyView.window?.firstResponder === ghosttyView
    } else {
      terminalView?.window?.isKeyWindow == true
        && terminalView?.window?.firstResponder === terminalView
    }
    let scopedNotification = TerminalNotification(
      identifier: notification.identifier.map { "\(id.uuidString).\($0)" },
      title: notification.title,
      body: notification.body,
      urgency: notification.urgency
    )
    notificationPoster.post(
      scopedNotification,
      category: category,
      configuration: shell,
      sourceTabIsFocused: focused
    )
  }

  private func receiveActivityOutput(_ visibleCursorLine: String) {
    let tail = String(visibleCursorLine.suffix(4_096))
    // Agent TUI 空闲时也会周期性重绘（光标、提示条），但光标行内容不变；只有内容
    // 真正变化才算「在处理」，否则回退探针会在 5s 静默与重绘之间来回抖动。
    let changed = tail != activityOutputTail
    activityOutputTail = tail
    if changed { markFallbackAgentActivity() }
    awaitingInputTask?.cancel()
    awaitingInputTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(1_500))
      // 屏幕检测在跑即说明前台就是 Agent，不再依赖 hasRunningCommand（SwiftTerm 的
      // 前台轮询在没有真实 OSC 133 时会把它清掉）。
      guard !Task.isCancelled, let self,
        self.hasRunningCommand || self.progressState.isWorking || self.agentScreenMonitor != nil,
        // 有清单的 Agent 由屏幕检测判定阻塞表单，通用提示词启发式只在清单未命中
        // 任何规则（兜底 idle）时补位，避免与规则结论打架。
        self.agentScreenMonitor == nil || self.screenDetectionPublished?.isFallbackIdle == true
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
    // 用户先动手就不再自动重连；重连命令晚到会打断用户正在输入的内容。
    cancelRestoredAgentResume()
    if agentTaskCompletionUnread { agentTaskCompletionUnread = false }
    // Hook 成为权威来源后，清理启发式标记不足以改变 reducer 状态；用户输入必须映射
    // 为同一事件流中的 inputSubmitted，才能从 awaiting-input 恢复 processing。
    if agentLifecycleIsAuthoritative, agentStateReducer.state == .awaitingInput {
      consumeAgentTaskStateSignal(.inputSubmitted)
    }
    clearAwaitingInput()
    markFallbackAgentActivity()
  }

  /// 无 hook 时以输入/输出活动作为「正在处理」的有界回退证据。
  /// 5 秒与旧 SwiftTerm 可见缓冲静默窗口保持一致；权威 hook 在此期间
  /// 到达时会取消任务，防止真正的静默推理被误报 idle。
  private func markFallbackAgentActivity() {
    // 屏幕检测在跑时，静默/活动探针不再有发言权：清单能区分「思考中」与「停在输入框」。
    guard activeAgentProvider != nil, !agentLifecycleIsAuthoritative, agentScreenMonitor == nil
    else { return }
    fallbackAgentIdleTask?.cancel()
    if !fallbackAgentActivityIsProcessing {
      fallbackAgentActivityIsProcessing = true
      updateAgentTaskState()
    }
    let idleDelay = fallbackAgentIdleDelay
    fallbackAgentIdleTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: idleDelay)
      // 不再要求 hasRunningCommand：shell 集成没报命令开始时（例如从标题识别出的
      // Agent），静默 5s 同样应回到 idle，否则动画永远停不下来。
      guard !Task.isCancelled, let self,
        self.activeAgentProvider != nil,
        !self.agentLifecycleIsAuthoritative
      else { return }
      self.fallbackAgentActivityIsProcessing = false
      self.fallbackAgentIdleTask = nil
      self.updateAgentTaskState()
    }
  }

  /// 清理只属于非权威回退的活动状态；调用方负责在终止、换代或
  /// hook 接管后发布它自身的最终 lifecycle，避免这个 helper 产生中间态通知。
  private func clearFallbackAgentActivity() {
    fallbackAgentIdleTask?.cancel()
    fallbackAgentIdleTask = nil
    fallbackAgentActivityIsProcessing = false
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

  /// 任务状态的证据来源。只有 hook 与屏幕检测的结论足以触发通知与未读标记；
  /// 活动探针只说明屏幕安静了一会儿，据此通知会在每次静默时骚扰用户。
  private enum AgentTaskStateSource {
    case hook, screen, heuristic
  }

  /// 三路证据仲裁（对应计划 A6）：
  /// 1. hook 权威：以 reducer 为准；partial hook（非 fullLifecycleHooks）时屏幕上的
  ///    阻塞表单可把 processing 覆盖为 awaiting-input（claude/codex 的权限提示没有 hook）。
  /// 2. 屏幕检测在跑：启动宽限内视为 processing；之后 working→processing、
  ///    blocked→awaitingInput、idle→idle、unknown→保持上一状态。
  /// 3. 其余（无清单 provider、SwiftTerm 回归、开关关闭）：旧的活动探针折叠。
  private func updateAgentTaskState() {
    let previous = agentTaskState
    let next: AgentTaskState
    let source: AgentTaskStateSource
    if let provider = activeAgentProvider {
      if agentLifecycleIsAuthoritative {
        var state = agentStateReducer.state
        let overridesHook =
          preferences?.configuration.agents.resolvedScreenDetectionOverridesHook ?? true
        if !provider.capabilities.contains(.fullLifecycleHooks),
          overridesHook,
          state != .awaitingInput,
          screenDetectionPublished?.visibleBlocker == true
        {
          state = .awaitingInput
        }
        next = state
        source = .hook
      } else if let monitor = agentScreenMonitor {
        source = .screen
        if monitor.isInStartupGrace {
          next = .processing
        } else {
          switch screenDetectionPublished?.state {
          case .working: next = .processing
          case .blocked: next = .awaitingInput
          case .idle:
            // 清单没覆盖到的提示（例如某个 `[y/N]`）会落到兜底 idle；这种 idle 允许旧的
            // 等待输入启发式补位。规则命中的 idle 仍以规则为准。
            next = (screenDetectionPublished?.isFallbackIdle == true && awaitingInput)
              ? .awaitingInput : .idle
          case .unknown, nil: next = previous
          }
        }
      } else {
        next = AgentTaskState.fold(
          processing: fallbackAgentActivityIsProcessing || progressState.isWorking,
          awaitingInput: awaitingInput
        )
        source = .heuristic
      }
    } else {
      next = .idle
      source = .heuristic
    }
    if agentTaskState != next { agentTaskState = next }
    if let provider = activeAgentProvider {
      publishAgentTaskTransition(from: previous, to: next, provider: provider, source: source)
    }
    // Agent 仍在生成内容时，固定显示不闪烁的用户光标；进入 awaiting-input / idle 后
    // 恢复设置中的 blink 模式。普通 Shell/TUI 不受该领域状态影响。
    terminalView?.setCursorBlinkSuppressed(activeAgentProvider != nil && next == .processing)
  }

  /// 状态转换的副作用：未读完成标记与系统通知。hook 路径与屏幕路径共用，
  /// 只在状态真的变化时触发；启发式来源不产生通知。
  private func publishAgentTaskTransition(
    from previous: AgentTaskState,
    to next: AgentTaskState,
    provider: AgentProvider,
    source: AgentTaskStateSource
  ) {
    guard previous != next else { return }
    switch next {
    case .processing:
      agentTaskCompletionUnread = false
    case .awaitingInput:
      guard source != .heuristic,
        preferences?.configuration.agents.notifyAwaitingInput == true
      else { return }
      post(
        TerminalNotification(
          title: "Agent 等待输入",
          body: "\(provider.commandName) 正在等待确认或输入。"
        ),
        // Agent lifecycle 是 Aster 自身的任务状态，不应受 Shell Controlled
        // 对应用 OSC 通知的开关误伤；沿用命令完成分类获得独立的声音/前台策略。
        category: .commandFinish
      )
    case .idle:
      guard source != .heuristic, previous == .processing || previous == .awaitingInput
      else { return }
      guard agentHasWorkEvidence else { return }
      agentTaskCompletionUnread = true
      guard preferences?.configuration.agents.notifyTaskComplete == true else { return }
      post(
        TerminalNotification(
          title: "Agent 任务已完成",
          body: "\(provider.commandName) 已结束当前任务。"
        ),
        category: .commandFinish
      )
    }
  }

  // MARK: - 屏幕检测接线

  /// 记录程序写出的标题原文（OSC 0/1/2），供 `osc_title` 区域的规则使用。
  func receiveAgentOSCTitle(_ title: String) {
    guard title.utf8.count <= 4_096 else { return }
    agentOSCTitle = title
  }

  /// 记录 OSC 9 原文（`9;4;3;…` 之类的进度序列），供 `osc_progress` 区域的规则使用。
  /// herdr 存的是 `9;` 之后的部分，因此这里去掉可能存在的 `9;` 前缀。
  func receiveAgentOSCProgress(_ value: String) {
    guard value.utf8.count <= 256 else { return }
    agentOSCProgress = value.hasPrefix("9;") ? String(value.dropFirst(2)) : value
  }

  /// 按当前 provider / hook 权威性 / 设置决定屏幕检测轮询该开、该停还是该换清单。
  private func syncAgentScreenMonitor() {
    guard let provider = activeAgentProvider,
      let manifestID = provider.detectionManifestID,
      preferences?.configuration.agents.resolvedScreenDetectionEnabled ?? true,
      // 完整生命周期 hook 权威后读屏没有增量信息，停掉轮询省 CPU。
      !(agentLifecycleIsAuthoritative && provider.capabilities.contains(.fullLifecycleHooks))
    else {
      stopAgentScreenMonitor()
      return
    }
    if let monitor = agentScreenMonitor, monitor.manifest.manifest.id == manifestID { return }
    stopAgentScreenMonitor()
    guard let compiled = agentDetectionManifestStore.manifest(for: manifestID),
      let source = makeAgentScreenDetectionSource()
    else { return }
    // 新前台 Agent 不能继承上一进程的 OSC 标题/进度证据。
    agentOSCTitle = ""
    agentOSCProgress = ""
    let monitor = AgentScreenDetectionMonitor(
      manifest: compiled, source: source, timing: agentScreenDetectionTiming)
    // 回调存回 monitor 自身，闭包必须弱捕获 monitor，否则形成保留环，每次启动 Agent 漏一个。
    monitor.onPublish = { [weak self, weak monitor] state in
      guard let self, let monitor, self.agentScreenMonitor === monitor else { return }
      self.screenDetectionPublished = state
      if state.state == .working || state.state == .blocked {
        self.agentHasWorkEvidence = true
      }
      self.updateAgentTaskState()
    }
    monitor.onStartupGraceEnded = { [weak self, weak monitor] in
      guard let self, let monitor, self.agentScreenMonitor === monitor else { return }
      self.updateAgentTaskState()
    }
    agentScreenMonitor = monitor
    screenDetectionPublished = nil
    monitor.start()
    updateAgentTaskState()
  }

  private func stopAgentScreenMonitor() {
    agentScreenMonitor?.stop()
    agentScreenMonitor = nil
    screenDetectionPublished = nil
  }

  /// 读屏来源：测试注入优先；生产用 Ghostty 活动屏幕。SwiftTerm 回归路径不支持读屏，
  /// 返回 nil 让调用方退回旧的活动探针。
  private func makeAgentScreenDetectionSource() -> AgentScreenDetectionMonitor.Source? {
    if let override = agentScreenDetectionSourceOverride { return override }
    guard ghosttyView != nil else { return nil }
    return AgentScreenDetectionMonitor.Source(
      readScreen: { [weak self] in self?.ghosttyView?.readAgentDetectionText() },
      oscTitle: { [weak self] in self?.agentOSCTitle ?? "" },
      oscProgress: { [weak self] in self?.agentOSCProgress ?? "" },
      contentSequence: { [weak self] in self?.detectionContentSequence ?? 0 },
      processExited: { false }
    )
  }

  /// 调试入口：对当前屏幕做一次完整解释。没有 provider / 清单 / 可读屏幕时返回 nil。
  func explainAgentDetection() -> AgentDetectionExplain? {
    if let monitor = agentScreenMonitor { return monitor.explainNow() }
    guard let provider = activeAgentProvider,
      let manifestID = provider.detectionManifestID,
      let compiled = agentDetectionManifestStore.manifest(for: manifestID),
      let source = makeAgentScreenDetectionSource(),
      let screen = source.readScreen()
    else { return nil }
    return compiled.explain(
      AgentDetectionInput(screen: screen, oscTitle: agentOSCTitle, oscProgress: agentOSCProgress))
  }

  /// 登记一个待重连的 Agent 会话（来自工作区恢复快照）。这里只记录身份不发送命令；
  /// 开关检查延后到发送时刻，设置变化因此总是取最新值。
  func scheduleRestoredAgentResume(provider: AgentProvider, sessionID: String) {
    pendingRestoredAgentResume = (provider, sessionID)
    scheduleRestoreFallbackIfNeeded()
  }

  /// 登记快照里的恢复命令(复用器附着 / OSC 88 声明 / 前台进程)。是否发送在首个
  /// prompt 时按当时的设置决定。
  func scheduleRestoredCommand(_ record: WorkspacePaneRestoreCommand) {
    pendingRestoredCommand = record
    scheduleRestoreFallbackIfNeeded()
  }

  /// 快照阶段挑出本 Pane 的恢复命令:有 OSC 88 声明优先;否则看前台命令是否是复用器或
  /// 普通进程。没有前台命令(Shell 空闲)时什么都不记。
  func restoreCommandForSnapshot(paneID: UUID) -> WorkspacePaneRestoreCommand? {
    SessionRestorePlanner.snapshotCommand(
      paneID: paneID,
      foregroundCommand: hasForegroundCommand ? submittedCommand : nil,
      resumeProtocolCommand: resumeProtocolCommand
    )
  }

  /// 处理 OSC 88:query 立即回包;声明/清除只改内存状态,由快照持久化。
  private func handleResumeProtocol(payload: String) {
    guard let directive = TerminalResumeProtocol.parse(payload) else { return }
    switch directive {
    case .query: sendProtocolResponse(TerminalResumeProtocol.supportedResponse)
    case .declare(let command): resumeProtocolCommand = command
    case .clear: resumeProtocolCommand = nil
    }
  }

  /// 把协议应答原样写回 PTY(不经过用户输入路径,不记录为提交命令)。
  private func sendProtocolResponse(_ text: String) {
    if let ghosttyView {
      _ = ghosttyView.sendProtocolBytes(Array(text.utf8))
    } else {
      terminalView?.send(txt: text)
    }
  }

  /// 首个 prompt 处发送恢复命令。Agent 原生 resume 优先;两者都消费 pending,只发一次。
  private func deliverRestoredCommandIfNeeded() {
    guard let record = pendingRestoredCommand else { return }
    pendingRestoredCommand = nil
    guard let shell = preferences?.configuration.shell,
      SessionRestorePlanner.shouldRestore(record, shell: shell)
    else { return }
    send(record.command)
  }

  /// 用户在 prompt 出现前接管终端（输入任何内容）时放弃自动重连。
  func cancelRestoredAgentResume() {
    pendingRestoredAgentResume = nil
    pendingRestoredCommand = nil
    restoreFallbackTask?.cancel()
    restoreFallbackTask = nil
  }

  /// 进程就绪后启动兜底计时。tmux 内会先收到 OSC 133 promptStart 精确投递,把 pending
  /// 清空,兜底自然空转;普通 zsh(集成未注入)收不到标记,靠这里在固定延时后投递。
  /// 延时期间用户输入会经 `cancelRestoredAgentResume` 取消本任务。
  private func scheduleRestoreFallbackIfNeeded() {
    guard pendingRestoredCommand != nil || pendingRestoredAgentResume != nil,
      restoreFallbackTask == nil
    else { return }
    restoreFallbackTask = Task { @MainActor [weak self] in
      // 等首个 prompt 落地。用户 zsh 集成只在 tmux 注入,普通会话收不到 OSC 133 promptStart;
      // 即便有集成,首个 prompt 也可能早于恢复命令登记(竞态),promptStart 消费时 pending 还没设。
      // 两种情况都靠这里在固定延时后补发;promptStart 若已消费,pending 为空,兜底自然空转。
      try? await Task.sleep(for: .milliseconds(1_500))
      guard let self, !Task.isCancelled else { return }
      self.restoreFallbackTask = nil
      guard self.pendingRestoredCommand != nil || self.pendingRestoredAgentResume != nil else { return }
      self.deliverRestoredAgentResumeIfNeeded()
    }
  }

  /// 由 shell 首个 prompt 触发：检查「恢复时重连会话」开关后把原生 resume 命令写入
  /// PTY。无论是否发送，pending 都会被消费——后续 prompt 不能再触发第二次。
  private func deliverRestoredAgentResumeIfNeeded() {
    guard let pending = pendingRestoredAgentResume else {
      deliverRestoredCommandIfNeeded()
      return
    }
    pendingRestoredAgentResume = nil
    pendingRestoredCommand = nil
    guard let agents = preferences?.configuration.agents, agents.resumeSessions,
      let command = Self.restoredAgentResumeCommand(
        provider: pending.provider,
        sessionID: pending.sessionID,
        agents: agents
      )
    else { return }
    send(command)
  }

  /// 构造恢复重连的 shell 命令：沿用用户自定义启动前缀，参数按 POSIX 单引号编码。
  /// 纯函数便于单测；session ID 非法（超长、含 NUL）时返回 nil 而不是发送坏命令。
  nonisolated static func restoredAgentResumeCommand(
    provider: AgentProvider,
    sessionID: String,
    agents: AgentConfiguration
  ) -> String? {
    let components = agents.launchComponents(for: provider)
    guard let executable = components.first,
      let prefix = try? AgentLaunchPrefix(
        executable: executable,
        arguments: Array(components.dropFirst())
      ),
      let plan = try? AgentSessionCommandPlanner.plan(
        .resume,
        sessionID: sessionID,
        configuration: AgentSessionConfiguration(provider: provider),
        launchPrefix: prefix
      )
    else { return nil }
    return AgentShellCommandEncoder.encode(plan)
  }

  private func handleAgentTerminalDirective(_ directive: AgentTerminalDirective) {
    // 已由 shell command 精确识别 provider 时，拒绝其它 provider 向同一 PTY 注入状态；
    // wrapper 命令无法识别时则允许首个合法 hook 建立关联。
    if let activeAgentProvider, activeAgentProvider != directive.provider { return }
    activeAgentProvider = directive.provider
    agentProviderIsTitleEvidenceOnly = false
    if let sessionID = directive.sessionID { activeAgentSessionID = sessionID }
    syncCodexUsageMonitor()
    agentLifecycleIsAuthoritative = true
    clearFallbackAgentActivity()
    eventRecorder?.agentChanged(
      id: id,
      provider: directive.provider.rawValue,
      agentSessionID: activeAgentSessionID
    )
    consumeAgentTaskStateSignal(directive.signal)
    if directive.signal == .processing || directive.signal == .awaitingInput {
      agentHasWorkEvidence = true
    }
    if directive.signal == .awaitingInput {
      awaitingInput = true
    } else if awaitingInput {
      awaitingInput = false
    }
    // hook 首达：fullLifecycleHooks provider 停掉读屏；partial provider 继续扫，
    // 只消费屏幕上的阻塞表单。通知与未读标记统一由 updateAgentTaskState 的转换发布。
    syncAgentScreenMonitor()
    updateAgentTaskState()
  }

  /// statusLine 包装器上报的用量：与 lifecycle 同一守门，已识别 provider 时拒绝其它
  /// provider 注入；尚未识别时据此建立身份（wrapper 命令让 commandStart 认不出 claude）。
  private func handleAgentUsageDirective(_ directive: AgentUsageDirective) {
    if let activeAgentProvider, activeAgentProvider != directive.provider { return }
    if activeAgentProvider == nil {
      activeAgentProvider = directive.provider
      agentProviderIsTitleEvidenceOnly = false
      syncAgentScreenMonitor()
    }
    let snapshot = directive.snapshot()
    if agentUsage != snapshot { agentUsage = snapshot }
  }

  /// 订阅本 pane 的用量文件（Claude statusLine 包装器按 pane UUID 写入）。只在第一次创建终端
  /// 视图时订阅；重启进程复用同一 pane UUID，订阅保持。
  private func subscribeAgentUsageFiles() {
    guard agentUsageSubscribedAt == nil else { return }
    let subscribedAt = Date()
    agentUsageSubscribedAt = subscribedAt
    agentUsageFileStore.subscribe(paneID: id) { [weak self] update in
      guard let self else { return }
      // Aster 崩溃后遗留的旧文件：mtime 早于本次订阅，不能把一个新 shell pane 标成 Claude。
      guard update.modifiedAt >= subscribedAt - 1 else { return }
      self.handleAgentUsageDirective(update.directive)
    }
  }

  /// Codex 绑定 session 后监听其 rollout；session 变化时重建，非 Codex 或无 session 时停止。
  private func syncCodexUsageMonitor() {
    guard activeAgentProvider == .codex, let sessionID = activeAgentSessionID else {
      stopCodexUsageMonitor()
      return
    }
    guard codexUsageMonitorSessionID != sessionID else { return }
    stopCodexUsageMonitor()
    codexUsageMonitorSessionID = sessionID
    let monitor = CodexUsageFileMonitor(
      agentSessionID: sessionID,
      homeDirectory: agentUsageHomeDirectory
    ) { [weak self] snapshot in
      guard let self, self.activeAgentProvider == .codex else { return }
      if self.agentUsage != snapshot { self.agentUsage = snapshot }
    }
    codexUsageMonitor = monitor
    monitor.start()
  }

  private func stopCodexUsageMonitor() {
    codexUsageMonitor?.stop()
    codexUsageMonitor = nil
    codexUsageMonitorSessionID = nil
  }

  /// provider 生命周期结束：停掉 Codex 监听、删掉本 pane 的用量文件并让用量条消失。
  private func clearAgentUsage() {
    stopCodexUsageMonitor()
    if agentUsageSubscribedAt != nil { agentUsageFileStore.remove(paneID: id) }
    if agentUsage != nil { agentUsage = nil }
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
      self?.applyReportedWorkingDirectory(directory)
    }
  }

  nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
    Task { @MainActor [weak self] in
      defer { TerminalRetirementCoordinator.shared.complete(source) }
      guard let self else { return }
      // SwiftTerm 在 PTY 读端出现瞬时 EOF 时可能给出无退出码通知；若本地进程仍在
      // 运行，该事件不是最终终止，不能把活跃分屏错误标成 session ended。
      if let localView = source as? LocalProcessTerminalView, localView.process.running {
        self.diagnostics.record(
          "terminal.transient_termination_ignored",
          level: .warning,
          category: .terminal,
          attributes: self.processDiagnosticAttributes()
        )
        return
      }

      let sourceIdentifier = ObjectIdentifier(source)
      if self.intentionallyRetiredViews.remove(sourceIdentifier) != nil {
        return
      }
      // 新进程已经替换旧 View 时，旧输出总线或 monitor 的迟到通知只能被记录并忽略。
      // 不做对象身份门禁会把刚重启成功的新 PTY 再次标成结束，形成原问题中的僵尸 Tab。
      guard source === self.terminalView else {
        self.diagnostics.record(
          "terminal.stale_termination_ignored",
          level: .warning,
          category: .terminal,
          attributes: self.processDiagnosticAttributes()
        )
        return
      }

      let termination = TerminalProcessTermination(rawWaitStatus: exitCode)
      self.lifecycleState = .ended(termination)
      self.exitCode = termination.shellExitCode
      self.isRunning = false
      self.hasRunningCommand = false
      self.awaitingInput = false
      self.stopAgentScreenMonitor()
      self.activeAgentProvider = nil
      self.activeAgentSessionID = nil
      self.clearAgentUsage()
      self.agentTaskState = .idle
      self.clearFallbackAgentActivity()
      self.clearSSHRemoteEndpoint()
      self.foregroundPollTask?.cancel()
      self.foregroundPollTask = nil
      self.awaitingInputTask?.cancel()
      self.awaitingInputTask = nil
      SecureInputCoordinator.shared.releaseAutomaticRequest(for: self.id)
      self.diagnostics.record(
        "terminal.process_terminated",
        level: termination.isUnexpected ? .error : .notice,
        category: .terminal,
        attributes: self.terminationDiagnosticAttributes(termination, rawWaitStatus: exitCode)
      )
    }
  }
}
