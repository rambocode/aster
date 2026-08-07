import AppKit
import AsterCore
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

/// SwiftTerm 视图子类：把设置里的光标形状当作唯一真值，屏蔽程序端的 DECSCUSR 改写。
///
/// Claude Code、vim、fzf 等 TUI 会主动发送 `CSI Ps SP q` 把光标改成方块或下划线；
/// SwiftTerm 默认接受该请求并覆盖 `terminal.options.cursorStyle`（Metal 渲染路径直接
/// 读这个值），用户在设置里选的竖条因此一进这些程序就失效。这里拦截样式变更回调，
/// 只放行与配置一致的样式。
final class AsterTerminalView: LocalProcessTerminalView {
  /// SwiftTerm 在 macOS 的标题回调存在缺失和顺序差异；此回调按 PTY 原始顺序校正。
  var onObservedTitleUpdate: ((Int, String) -> Void)?
  private var titleStackObserver = TerminalTitleStackObserver()

  /// 用户配置的光标形状；nil 表示配置尚未下发，此时保持 SwiftTerm 默认行为。
  var preferredCursorStyle: SwiftTerm.CursorStyle? {
    didSet { applyEffectiveCursorStyle() }
  }
  /// 窗口是否持有键盘焦点。非活动窗口停止光标闪烁（形状不变），与系统终端一致：
  /// 同屏多个窗口时只有正在输入的那个在闪。SwiftTerm 的 `caretView.focused` 只切换
  /// 实心/空心，闪烁完全由 `CursorStyle` 的 blink 变体决定，所以必须换样式。
  private var isWindowActive = true

  /// 实际下发给 SwiftTerm 的样式：窗口失焦时取同形状的不闪烁变体。
  private var effectiveCursorStyle: SwiftTerm.CursorStyle? {
    guard let preferredCursorStyle else { return nil }
    return isWindowActive ? preferredCursorStyle : preferredCursorStyle.nonBlinking
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

  override func dataReceived(slice: ArraySlice<UInt8>) {
    // 先让 SwiftTerm 完成渲染和内部标题栈操作，再按 PTY 字节顺序重放本分片的全部
    // 标题事件。重放排在 SwiftTerm 错误、缺失或提前入队的 macOS delegate 回调之后，
    // 因此工作区最终状态既符合协议语义，也保留恢复后紧随的新 OSC 更新。
    super.dataReceived(slice: slice)
    for update in titleStackObserver.consume(slice) {
      onObservedTitleUpdate?(update.code, update.title)
    }
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

extension SwiftTerm.CursorStyle {
  /// 同一形状的不闪烁变体。
  var nonBlinking: SwiftTerm.CursorStyle {
    switch self {
    case .blinkBlock, .steadyBlock: .steadyBlock
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

  @Published private(set) var isRunning = false
  @Published private(set) var currentWorkingDirectory: String
  @Published private(set) var terminalTitle = "Shell"
  @Published private(set) var terminalIconTitle = ""
  @Published private(set) var exitCode: Int32?
  @Published private(set) var startupError: String?
  /// 是否有前台命令正在运行且近期有输出（区别于 `isRunning` 的 shell 存活）。
  /// 由 PTY 前台进程组 + 终端缓冲活跃度轮询驱动，只在状态翻转时发布，
  /// 是侧栏运行中 spinner 的唯一业务状态源。
  @Published private(set) var hasRunningCommand = false

  private var foregroundPollTask: Task<Void, Never>?
  // 输出活跃度探针：可见屏幕内容哈希。Claude Code 等 TUI 思考时在原位重绘状态行
  // （光标与滚动位置都不变，只有单元格内容变化），必须按内容而非光标位置探测，
  // 否则 spinner 会时有时无。
  private var lastScreenHash = 0
  private var lastActivityAt = Date.distantPast

  private var terminalView: AsterTerminalView?
  /// OSC 0/1/2 的独立通道回调。Tab 领域状态负责固定名称、前缀与持久化。
  var onTitleUpdate: ((Int, String) -> Void)?
  /// SwiftTerm 视图一旦启动就保持在同一个 AppKit 容器中。工作区刷新只移动该容器，
  /// 不直接反复把 Metal-backed 终端视图从 superview 拆下，避免分屏后网格停止绘制。
  private var terminalHostView: NSView?

  /// SwiftTerm 的进程对象是运行状态的权威来源。`isRunning` 负责触发 AppKit 刷新，
  /// 但分屏恢复期间回调与视图挂载顺序可能让缓存短暂过期，状态栏必须读取真实值。
  var statusIsRunning: Bool {
    terminalView?.process.running ?? isRunning
  }

  init(workingDirectory: String) {
    self.workingDirectory = workingDirectory
    currentWorkingDirectory = workingDirectory
    super.init()
  }

  /// 返回长期存活的终端视图；首次调用时才创建 PTY，确保 AppKit 窗口已完成初始化。
  func makeTerminalView(preferences: AppPreferences) -> LocalProcessTerminalView {
    if let terminalView {
      apply(preferences: preferences, to: terminalView)
      return terminalView
    }

    let view = AsterTerminalView(frame: .zero)
    view.processDelegate = self
    view.onObservedTitleUpdate = { [weak self] code, title in
      Task { @MainActor [weak self] in self?.handleTitleOSC(code: code, text: title) }
    }
    view.autoresizingMask = [.width, .height]
    view.allowMouseReporting = preferences.allowMouseReporting
    view.optionAsMetaKey = preferences.optionAsMeta
    view.linkReporting = .implicit
    view.linkHighlightMode = .hoverWithModifier
    apply(preferences: preferences, to: view)
    // SwiftTerm 默认只把 OSC 0/2 作为同一个窗口标题回调，且丢弃 macOS 上的 OSC 1。
    // 注册专用处理器保留协议通道，才能让短标签名与窗口标题独立演进。处理器负责
    // 回写 SwiftTerm 自身标题状态；工作区事件由原始字节观察器按顺序统一上送，避免
    // delegate 与自定义 handler 的调度先后打乱 XTWINOPS 恢复和后续 OSC。
    let terminal = view.getTerminal()
    for code in 0...2 {
      terminal.registerOscHandler(code: code) { [weak terminal] bytes in
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
        // 领域标题事件由 `AsterTerminalView.dataReceived` 的字节流观察器统一按原始顺序
        // 上送。这里不单独通知，避免同一 PTY 分片内恢复与后续 OSC 的顺序被打乱。
      }
    }

    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = preferences.terminalIdentity
    environment["COLORTERM"] = "truecolor"
    environment["ASTER_SESSION_ID"] = id.uuidString
    let entries = environment.map { "\($0.key)=\($0.value)" }
    var shell = environment["SHELL"] ?? "/bin/zsh"
    if !FileManager.default.isExecutableFile(atPath: shell) {
      startupError = "配置的 Shell 不可执行：\(shell)。已回退到 /bin/zsh。"
      shell = "/bin/zsh"
    }
    var launchDirectory = currentWorkingDirectory
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: launchDirectory, isDirectory: &isDirectory)
      || !isDirectory.boolValue
    {
      launchDirectory = FileManager.default.homeDirectoryForCurrentUser.path
      currentWorkingDirectory = launchDirectory
      startupError = "原工作目录不可用，已回退到主目录。"
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
          return
        }
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
    guard let process = terminalView?.process, process.running else { return }
    let bytes = Array((command + "\n").utf8)
    process.send(data: bytes[...])
  }

  /// 把文本原样写入 PTY（不带回车）：用于把命令预填到提示符，执行与否由用户确认。
  func typeText(_ text: String) {
    guard let process = terminalView?.process, process.running else { return }
    let bytes = Array(text.utf8)
    process.send(data: bytes[...])
  }

  func interrupt() {
    guard let process = terminalView?.process, process.running else { return }
    let controlC = [UInt8(3)]
    process.send(data: controlC[...])
  }

  func focus() {
    guard let terminalView, let window = terminalView.window else { return }
    window.makeFirstResponder(terminalView)
  }

  /// 在完整滚动缓冲区内查找并选中下一处匹配文本。
  @discardableResult
  func findNext(_ term: String, previous: Bool = false) -> Bool {
    guard let terminalView, !term.isEmpty else { return false }
    return previous ? terminalView.findPrevious(term) : terminalView.findNext(term)
  }

  /// 立即读取由 OSC 7 报告的工作目录。没有集成标记时保留最近一次可靠值。
  func resolvedCurrentWorkingDirectory() -> String {
    currentWorkingDirectory
  }

  /// 将 SwiftTerm 的 OSC 7 目录值转换为本地绝对路径。Shell 通常上报
  /// `file://localhost/path`，也允许直接上报路径；返回空串表示值不可用。
  static func normalizeReportedWorkingDirectory(_ reportedValue: String) -> String {
    guard !reportedValue.isEmpty else { return "" }
    if let url = URL(string: reportedValue), url.isFileURL {
      return url.path.removingPercentEncoding ?? url.path
    }
    return reportedValue.removingPercentEncoding ?? reportedValue
  }

  /// 同步窗口活动状态：非活动窗口停止光标闪烁。
  func setWindowActive(_ active: Bool) {
    terminalView?.setWindowActive(active)
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
    isRunning = false

    // SwiftTerm 1.15 的 `terminate()` 会在发送信号后立即取消进程监视器，且自然退出
    // 后保留旧 PID。托管器只接受仍运行的 View，并在 Session 释放后继续负责升级
    // 信号及等待 monitor 回收，避免僵尸进程和 PID 复用后的误杀。
    TerminalRetirementCoordinator.shared.retire(view, immediately: immediately)
  }

  private func apply(preferences: AppPreferences, to view: AsterTerminalView) {
    view.font = preferences.terminalFont
    view.nativeForegroundColor = preferences.terminalForegroundColor
    view.nativeBackgroundColor = preferences.terminalBackgroundColor
    view.caretColor = preferences.cursorColor
    view.caretTextColor = preferences.cursorTextColor
    view.selectedTextForegroundColor = preferences.selectionForegroundColor
    view.selectedTextBackgroundColor = preferences.selectionColor
    view.optionAsMetaKey = preferences.optionAsMeta
    view.allowMouseReporting = preferences.allowMouseReporting
    view.installColors(
      preferences.ansiColors.map {
        SwiftTerm.Color(
          red: UInt16($0.red) * 257,
          green: UInt16($0.green) * 257,
          blue: UInt16($0.blue) * 257
        )
      })
    let cursorStyle = swiftTermCursorStyle(
      preferences.configuration.appearance.cursorStyle.rawValue,
      blinks: preferences.configuration.appearance.cursorBlink
    )
    // 设置配置值即完成下发：`preferredCursorStyle` 的 didSet 会按窗口活动状态算出
    // 实际样式（失焦时取不闪烁变体），再同步 terminal 选项与 caret 视图。
    view.preferredCursorStyle = cursorStyle
    view.needsDisplay = true
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

  private func swiftTermCursorStyle(_ style: String, blinks: Bool) -> SwiftTerm.CursorStyle {
    switch style {
    case "bar": blinks ? .blinkBar : .steadyBar
    case "underline": blinks ? .blinkUnderline : .steadyUnderline
    default: blinks ? .blinkBlock : .steadyBlock
    }
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
      guard let self, !normalized.isEmpty, self.currentWorkingDirectory != normalized else { return }
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
      TerminalRetirementCoordinator.shared.complete(source)
    }
  }
}
