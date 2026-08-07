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
  /// 所有链接打开请求必须先进入 Aster 的解析与授权层，禁止调用 SwiftTerm 默认的
  /// `NSWorkspace.open` 路径绕过 scheme、可执行文件和特殊文件检查。
  var onRequestOpenTarget: ((String, DetectedTargetSource) -> Void)?
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
  private(set) var shellCommandTimeline = ShellCommandTimeline()
  private var shellNavigationAbsoluteRow: Int?
  private var shellIntegrationHandlerInstalled = false

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

  override func keyDown(with event: NSEvent) {
    // macOS keyCode 51 is the backward Delete/Backspace key. Only consume it when OSC 133
    // proves the selection belongs to the current editable prompt; otherwise preserve TUI input.
    if event.keyCode == 51, deletePromptSelectionIfSafe() { return }
    super.keyDown(with: event)
  }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    onTerminalIO?()
    // 先让 SwiftTerm 完成渲染和内部标题栈操作，再按 PTY 字节顺序重放本分片的全部
    // 标题事件。重放排在 SwiftTerm 错误、缺失或提前入队的 macOS delegate 回调之后，
    // 因此工作区最终状态既符合协议语义，也保留恢复后紧随的新 OSC 更新。
    let safeBytes = oscStreamLimiter.consume(slice)
    if !safeBytes.isEmpty {
      shellNavigationAbsoluteRow = nil
      super.dataReceived(slice: safeBytes[...])
      // Otty 的滚动语义：任何新输出都回到底部；用户输入则由 SwiftTerm 的 send 路径
      // 同步复位。alternate screen 没有 scrollback，此调用只清理可能残留的视觉偏移。
      scrollToBottom()
    }
    for update in titleStackObserver.consume(safeBytes) {
      onObservedTitleUpdate?(update.code, update.title)
    }
  }

  override func send(source: TerminalView, data: ArraySlice<UInt8>) {
    shellNavigationAbsoluteRow = nil
    onTerminalIO?()
    onEncodedInput?(data)
    super.send(source: source, data: data)
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

  /// 选择变化时同步“选中即复制”。SwiftTerm 会在拖选、单词选择和整行选择后调用该
  /// 回调；空选区不会覆盖用户原剪贴板。
  override func selectionChanged(source: Terminal) {
    super.selectionChanged(source: source)
    guard copyOnSelect else { return }
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
      self.onShellIntegrationStateChange?(self.shellCommandTimeline)
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
    guard !text.isEmpty else { return false }
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

  /// 右键菜单补齐复制、粘贴与 Paste As。动作走 responder 自身，不依赖主菜单焦点。
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu(title: "终端")
    let copyItem = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
    copyItem.target = self
    copyItem.isEnabled = selectionActive
    menu.addItem(copyItem)
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
    let column = min(max(Int(point.x / cellWidth), 0), terminal.cols - 1)
    let row = min(max(Int((bounds.height - point.y) / cellHeight), 0), terminal.rows - 1)
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

  private var foregroundPollTask: Task<Void, Never>?
  // 输出活跃度探针：可见屏幕内容哈希。Claude Code 等 TUI 思考时在原位重绘状态行
  // （光标与滚动位置都不变，只有单元格内容变化），必须按内容而非光标位置探测，
  // 否则 spinner 会时有时无。
  private var lastScreenHash = 0
  private var lastActivityAt = Date.distantPast
  /// 设置关闭或 Pane 失焦时立即释放；PTY 模式由输出、输入前检查与低频兜底轮询采样。
  private var automaticSecureInputEnabled = true

  private var terminalView: AsterTerminalView?
  private var targetOpenCoordinator: TerminalTargetOpenCoordinator?
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
    view.onTerminalIO = { [weak self] in self?.refreshAutomaticSecureInput() }
    view.onShellIntegrationStateChange = { [weak self] timeline in
      self?.handleShellIntegrationTimeline(timeline)
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

  /// 把文本原样写入 PTY（不带回车）：用于把命令预填到提示符，执行与否由用户确认。
  func typeText(_ text: String) {
    guard let terminalView, terminalView.process.running else { return }
    let bytes = Array(text.utf8)
    terminalView.send(data: bytes[...])
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
      guard isLocalFileURLHost(url.host) else { return "" }
      return url.path.removingPercentEncoding ?? url.path
    }
    return reportedValue.removingPercentEncoding ?? reportedValue
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
    isRunning = false
    foregroundPollTask?.cancel()
    foregroundPollTask = nil
    SecureInputCoordinator.shared.releaseAutomaticRequest(for: id)

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
    let cursorStyle = swiftTermCursorStyle(
      preferences.configuration.appearance.cursorStyle.rawValue,
      blinks: preferences.configuration.appearance.cursorBlink
    )
    // 设置配置值即完成下发：`preferredCursorStyle` 的 didSet 会按窗口活动状态算出
    // 实际样式（失焦时取不闪烁变体），再同步 terminal 选项与 caret 视图。
    view.preferredCursorStyle = cursorStyle
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
