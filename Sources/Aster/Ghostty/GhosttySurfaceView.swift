import AppKit
import AsterCore
@preconcurrency import GhosttyKit
import QuartzCore
import os

/// Aster 的 libghostty Adapter：一个长期存活的 Metal surface 与其本地 Shell。
///
/// 调用方只处理会话语义；PTY、VT parser、滚动缓冲和绘制都由 libghostty 持有。
/// surface configuration 中的 C 指针由本实例保留到销毁，避免异步 Shell 创建越界读取。
@MainActor
final class GhosttySurfaceView: NSView {
  nonisolated let pictureInPictureFrames = GhosttyPictureInPictureFrames()
  nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

  var onTitleChange: ((String) -> Void)?
  var onWorkingDirectoryChange: ((String) -> Void)?
  var onProcessExit: ((Int32?) -> Void)?
  var onCommandFinished: ((Int?) -> Void)?
  var onProgress: ((GhosttyProgress) -> Void)?
  var onSearchStateChange: (() -> Void)?
  var onOpenURL: ((String) -> Void)?
  var onSecureInputChange: ((Bool) -> Void)?
  var onBell: (() -> Void)?
  var onNotification: ((String, String) -> Void)?
  var onReadOnlyChange: ((Bool) -> Void)?
  var onUserInput: (() -> Void)?
  var onRequestFocus: (() -> Void)?
  var onPasteIntoComposer: ((String) -> Void)?
  var onSendSelectionToChat: (() -> Void)?
  var onAuthorizeClipboard: ((GhosttyClipboardOperation) -> Bool)?
  var onSurfaceCreated: ((Bool) -> Void)?
  /// 原始 PTY observer 只暴露当前回调的字节副本；业务层不得把它视作可修改 parser。
  var onPTYRead: ((ArraySlice<UInt8>) -> Void)?
  var onPTYWrite: ((ArraySlice<UInt8>) -> Void)?
  var onOSC: ((Int, [UInt8], ghostty_aster_buffer_point_s) -> Void)?
  var onAutocompleteKeyDown: ((NSEvent) -> Bool)?
  var onRequestViSearch: ((TerminalViSearchDirection) -> Void)?
  var onRepeatViSearch: ((Bool) -> Void)?
  var onPaneModeActivated: (() -> Void)?
  var onRequestOpenTarget: ((String, DetectedTargetSource) -> Void)?
  var onResolveHintCopyTarget: ((String, DetectedTargetSource) -> String?)?

  private let workingDirectory: String
  private let environment: [String: String]
  /// 代替登录 Shell 直接运行的命令（libghostty `command`，经 `/bin/sh -c` 语义解释）。
  /// 详情面板的自定义 TUI 视图用它把 lazydocker 之类程序直接跑在面板里；nil 走默认 Shell。
  var command: String?
  /// 命令退出后保持 surface 不销毁，让用户看到程序的最后输出。
  var waitAfterCommand = false
  private var configurationText: String
  nonisolated(unsafe) private var configStrings: [UnsafeMutablePointer<CChar>] = []
  private var environmentVariables: [ghostty_env_var_s] = []
  private var pendingSurfaceCreation = false
  private var isDestroyed = false
  private var didReportExit = false
  private var isFocused = false
  private var isWindowActive = true
  private var isPaneActive = true
  private var secureInputEnabled = false
  private var trackingAreaToken: NSTrackingArea?
  /// Ghostty 已在自己的 IO 线程解析和绘制；Aster 的语义 observer 仍经有界总线进入
  /// 主线程，避免大输出为 Autocomplete/活动检测制造无界 DispatchQueue backlog。
  nonisolated(unsafe) private var outputMessageBus: TerminalOutputMessageBus!
  private(set) var readOnly = false
  var searchTotal = 0
  var searchSelected = 0
  var searchNeedle = ""
  var focusFollowsMouse = false
  var pasteProtectionEnabled = true
  var pasteBracketedSafe = true
  /// 链接预览开关（controls.showLinkPreviews）：按住 Command 悬停链接时在底部展示完整路径或 URL。
  var linkPreviewEnabled = true {
    didSet { if !linkPreviewEnabled { removeLinkPreview() } }
  }
  /// 宿主侧预览文本格式化器：命中检测仍用 Ghostty 报告的原始链接，仅展示时展开相对路径。
  var linkPreviewFormatter: ((String) -> String)?
  private(set) var linkPreviewBadge: GhosttyLinkPreviewBadge?
  var linkPreviewText: String? { linkPreviewBadge?.textField.stringValue }
  /// 当前预览来源:true 为 Ghostty 原生 mouse_over_link(OSC 8),false 为 Aster 侧文字识别。
  /// 原生的清除信号(空 URL)不得抹掉 Aster 侧刚显示的路径预览。
  private(set) var linkPreviewIsNative = false
  /// 终端目标识别总开关（controls.linkDetectionEnabled）：关闭后不画下划线、不预览、不响应点击。
  var linkDetectionEnabled = true {
    didSet { if !linkDetectionEnabled { handleCommandModifierChange(pressed: false) } }
  }
  /// 普通文字 URL 的 scheme 识别范围（controls.linkSchemes）。
  var linkSchemePolicy: LinkSchemePolicy = .all
  /// 路径候选存在性校验：由 Session 按当前可信 CWD 解析并 stat；nil 时所有路径视为不存在。
  var linkPathValidator: ((String) -> Bool)?
  /// Command 下划线颜色，跟随终端主题前景色。
  var linkUnderlineColor: NSColor = .textColor {
    didSet { applyLinkUnderlineColor() }
  }
  var linkUnderlineOverlay: GhosttyLinkUnderlineOverlay?
  var linkUnderlinesActive = false
  /// 最近一次键盘/鼠标事件观测到的 Command 状态；不用全局 `NSEvent.modifierFlags`，
  /// 以便测试用合成事件驱动，也避免其它窗口的按键状态串入。
  var linkCommandHeld = false
  var linkUnderlineRefreshScheduled = false
  var linkPathExistenceCache: [String: Bool] = [:]
  var lastLinkHoverLocation: NSPoint?
  var commandClickOrigin: NSPoint?
  /// 原生 open_url 每回流一次加一；Aster 侧 Command 点击据此避免对同一次点击重复打开。
  var nativeOpenURLSequence = 0
  var lastGhosttyMouseShape = GHOSTTY_MOUSE_SHAPE_TEXT
  var linkHoverCursorActive = false

  var markedTextRange = NSRange(location: NSNotFound, length: 0)
  var selectedTextRange = NSRange(location: NSNotFound, length: 0)
  var keyTextAccumulator: [String] = []
  var currentKeyEvent: NSEvent?
  var ghosttyPaneModeState = TerminalPaneModeState()
  var ghosttyViEngine: TerminalViEngine?
  var ghosttyNavigationSnapshot: TerminalNavigationSnapshot?
  var ghosttyModeFirstScreenRow = 0
  var ghosttyModeColumns = 1
  var ghosttyHintTargets: [GhosttyHintTarget] = []
  var ghosttyHintMatcher = TerminalHintMatcher(labels: [])
  var ghosttyShowsViKeyHints = true
  lazy var ghosttyModeHUD = TerminalPaneModeHUD(frame: bounds)

  init(
    workingDirectory: String,
    environment: [String: String],
    configurationText: String
  ) {
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.configurationText = configurationText
    super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    outputMessageBus = TerminalOutputMessageBus { [weak self] bytes in
      self?.consumeObservedPTYRead(bytes)
    }
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("Aster Terminal")
    rebuildTrackingArea()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  deinit {
    if let surface { ghostty_surface_free(surface) }
    for pointer in configStrings { free(pointer) }
  }

  var isProcessRunning: Bool {
    guard let surface else { return false }
    return !ghostty_surface_process_exited(surface)
  }

  var foregroundProcessIdentifier: Int32? {
    guard let surface else { return nil }
    let pid = ghostty_surface_foreground_pid(surface)
    return pid > 0 && pid <= UInt64(Int32.max) ? Int32(pid) : nil
  }

  func renderNow() {
    guard let surface else { return }
    ghostty_surface_draw(surface)
  }

  func applyTitle(_ title: String) { onTitleChange?(title) }
  func applyWorkingDirectory(_ path: String) {
    onWorkingDirectoryChange?(path)
    invalidateLinkTargetCache()
  }
  func handleCommandFinished(exitCode: Int?) { onCommandFinished?(exitCode) }
  func handleProgress(_ progress: GhosttyProgress) { onProgress?(progress) }

  func handleSearchStart(needle: String?) {
    searchNeedle = needle ?? ""
    onSearchStateChange?()
  }

  func handleSearchEnd() {
    searchNeedle = ""
    searchTotal = 0
    searchSelected = 0
    onSearchStateChange?()
  }

  func handleSearchTotal(_ total: Int?) {
    searchTotal = max(0, total ?? 0)
    onSearchStateChange?()
  }

  func handleSearchSelected(_ selected: Int?) {
    searchSelected = max(0, selected ?? 0)
    onSearchStateChange?()
  }

  func handleOpenURL(_ value: String) {
    nativeOpenURLSequence &+= 1
    onOpenURL?(value)
  }

  /// Ghostty 的 mouse_over_link action：按住 Command 悬停 OSC 8 链接时携带 URL，空字符串表示离开链接。
  func handleMouseOverLink(_ url: String) {
    guard linkPreviewEnabled, !url.isEmpty else {
      // 原生空信号只能清除原生来源的预览，避免与 Aster 侧路径预览互相覆盖；
      // 清除后立刻按最近指针位置补一次 Aster 侧识别，让同一位置的文字目标接管预览。
      if linkPreviewIsNative {
        removeLinkPreview()
        refreshCommandHoverPreview()
      }
      return
    }
    showLinkPreview(url, native: true)
  }

  /// 在终端左下角展示预览徽章；徽章不参与命中测试，指针事件继续到达终端。
  func showLinkPreview(_ url: String, native: Bool) {
    guard linkPreviewEnabled else { return }
    linkPreviewIsNative = native
    let displayValue = linkPreviewFormatter?(url) ?? url
    let badge: GhosttyLinkPreviewBadge
    if let existing = linkPreviewBadge {
      badge = existing
    } else {
      badge = GhosttyLinkPreviewBadge(frame: .zero)
      badge.autoresizingMask = [.maxXMargin, .maxYMargin]
      addSubview(badge)
      linkPreviewBadge = badge
    }
    badge.update(
      text: displayValue,
      maximumWidth: max(1, bounds.width - GhosttyLinkPreviewBadge.horizontalInset * 2)
    )
    badge.frame.origin = CGPoint(x: GhosttyLinkPreviewBadge.horizontalInset, y: 0)
  }

  /// 分屏或侧栏改变终端尺寸时保持底部内边距与宽度上限。
  func layoutLinkPreviewBadge() {
    guard let badge = linkPreviewBadge else { return }
    badge.update(
      text: badge.textField.stringValue,
      maximumWidth: max(1, bounds.width - GhosttyLinkPreviewBadge.horizontalInset * 2)
    )
    badge.frame.origin = CGPoint(x: GhosttyLinkPreviewBadge.horizontalInset, y: 0)
  }

  /// 幂等移除预览徽章。
  func removeLinkPreview() {
    if let badge = linkPreviewBadge {
      badge.removeFromSuperview()
      linkPreviewBadge = nil
    }
  }

  func handleSecureInput(_ mode: ghostty_action_secure_input_e) {
    switch mode {
    case GHOSTTY_SECURE_INPUT_ON: secureInputEnabled = true
    case GHOSTTY_SECURE_INPUT_OFF: secureInputEnabled = false
    case GHOSTTY_SECURE_INPUT_TOGGLE: secureInputEnabled.toggle()
    default: return
    }
    onSecureInputChange?(secureInputEnabled)
  }

  func handleBell() { onBell?() }
  func handleNotification(title: String, body: String) { onNotification?(title, body) }

  nonisolated func enqueuePTYRead(_ bytes: [UInt8]) {
    outputMessageBus.enqueue(bytes[...])
  }

  nonisolated func enqueuePTYWrite(_ bytes: [UInt8]) {
    // 输入与 OSC 必须共享交付顺序。独立 main.async 会越过等待 RunLoop idle 的
    // prompt A/B barrier，使先收到的输入随后被 beginPrompt 清空。
    outputMessageBus.enqueueBarrier { [weak self] in self?.onPTYWrite?(bytes[...]) }
  }

  nonisolated func enqueueOSC(
    code: UInt32,
    payload: [UInt8],
    point: ghostty_aster_buffer_point_s
  ) {
    outputMessageBus.enqueueBarrier { [weak self] in
      self?.onOSC?(Int(code), payload, point)
    }
  }

  func handleReadOnly(_ enabled: Bool) {
    readOnly = enabled
    onReadOnlyChange?(enabled)
  }

  /// 退出 action 与 close callback 可能同时到达；Session 只接收一次最终状态。
  func handleProcessExit(code: Int32?) {
    guard !didReportExit else { return }
    didReportExit = true
    onProcessExit?(code)
  }

  func authorizeClipboard(_ operation: GhosttyClipboardOperation) -> Bool {
    onAuthorizeClipboard?(operation) ?? false
  }

  func readSystemClipboard() -> String? {
    NSPasteboard.general.string(forType: .string)
  }

  func writeSystemClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  /// 偏好变化由 app config 广播；surface 自己重刷以确保新主题立即生效。
  func updateConfiguration(_ text: String) {
    guard text != configurationText else { return }
    configurationText = text
    guard GhosttyApp.shared.prepare(configurationText: text), let surface else { return }
    // app update 会把同一配置广播给所有 surface；这里请求一次立即重绘，避免
    // 偏好面板关闭前仍显示上一帧配色。
    ghostty_surface_refresh(surface)
  }

  // MARK: - Surface lifecycle

  func createSurface() {
    guard !isDestroyed, surface == nil else { return }
    // macOS Ghostty surface 创建需要 NSView 已进入真实窗口；工作区先组装离屏视图树时
    // 只记录待创建，不能把正常的 AppKit 挂载顺序误报成启动失败。
    guard window != nil else {
      pendingSurfaceCreation = true
      return
    }
    guard GhosttyApp.shared.prepare(configurationText: configurationText),
      let app = GhosttyApp.shared.app
    else {
      onSurfaceCreated?(false)
      return
    }
    let pixelSize = convertToBacking(bounds).size
    guard pixelSize.width > 0, pixelSize.height > 0 else {
      pendingSurfaceCreation = true
      return
    }
    pendingSurfaceCreation = false

    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
    config.userdata = Unmanaged.passUnretained(self).toOpaque()
    config.scale_factor = Double(
      window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    // Aster 的 Pane 由宿主工作区管理，不使用 Ghostty 自己的 split/window 路由；默认
    // window context 与独立 embedded surface 的生命周期契约一致。
    config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
    config.aster_pty_read_cb = { userdata, bytes, count in
      GhosttyApp.shared.callbacks.ptyRead(userdata: userdata, bytes: bytes, count: count)
    }
    config.aster_pty_write_cb = { userdata, bytes, count in
      GhosttyApp.shared.callbacks.ptyWrite(userdata: userdata, bytes: bytes, count: count)
    }
    config.aster_osc_cb = { userdata, code, payload, count, point in
      GhosttyApp.shared.callbacks.osc(
        userdata: userdata, code: code, payload: payload, count: count, point: point)
    }

    for pointer in configStrings { free(pointer) }
    configStrings = []
    environmentVariables = []
    if let pointer = strdup(workingDirectory) {
      configStrings.append(pointer)
      config.working_directory = UnsafePointer(pointer)
    }
    if let command, !command.isEmpty, let pointer = strdup(command) {
      configStrings.append(pointer)
      config.command = UnsafePointer(pointer)
      config.wait_after_command = waitAfterCommand
    }
    for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
      guard let keyPointer = strdup(key), let valuePointer = strdup(value) else { continue }
      configStrings.append(keyPointer)
      configStrings.append(valuePointer)
      environmentVariables.append(
        ghostty_env_var_s(
          key: UnsafePointer(keyPointer), value: UnsafePointer(valuePointer)))
    }

    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ghostty_app_set_color_scheme(
      app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    if environmentVariables.isEmpty {
      surface = ghostty_surface_new(app, &config)
    } else {
      surface = environmentVariables.withUnsafeMutableBufferPointer { variables in
        config.env_vars = variables.baseAddress
        config.env_var_count = variables.count
        return ghostty_surface_new(app, &config)
      }
    }
    guard let surface else {
      pendingSurfaceCreation = true
      onSurfaceCreated?(false)
      return
    }

    ghostty_surface_set_color_scheme(
      surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    if let screen = window?.screen ?? NSScreen.main,
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    {
      ghostty_surface_set_display_id(surface, displayID)
    }
    updateFocusState()
    updateSurfaceGeometry()
    onSurfaceCreated?(true)
  }

  /// 永久销毁 surface。libghostty 自己持有 PTY monitor，free 后负责关闭 child 和回收资源。
  func destroySurface() {
    guard !isDestroyed else { return }
    isDestroyed = true
    if let surface { ghostty_surface_free(surface) }
    surface = nil
    for pointer in configStrings { free(pointer) }
    configStrings = []
    environmentVariables = []
    onSecureInputChange?(false)
    clearCallbacks()
  }

  private func clearCallbacks() {
    onTitleChange = nil
    onWorkingDirectoryChange = nil
    onProcessExit = nil
    onCommandFinished = nil
    onProgress = nil
    onSearchStateChange = nil
    onOpenURL = nil
    onSecureInputChange = nil
    onBell = nil
    onNotification = nil
    onReadOnlyChange = nil
    onUserInput = nil
    onRequestFocus = nil
    onPasteIntoComposer = nil
    onSendSelectionToChat = nil
    onAuthorizeClipboard = nil
    onSurfaceCreated = nil
    onPTYRead = nil
    onPTYWrite = nil
    onOSC = nil
    onAutocompleteKeyDown = nil
    onRequestViSearch = nil
    onRepeatViSearch = nil
    onPaneModeActivated = nil
    onRequestOpenTarget = nil
    onResolveHintCopyTarget = nil
    linkPreviewFormatter = nil
    linkPathValidator = nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil, surface == nil { createSurface() } else { updateSurfaceGeometry() }
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = frame.size != newSize
    super.setFrameSize(newSize)
    if changed { handleGhosttyGeometryChange() }
    if pendingSurfaceCreation { createSurface() }
    updateSurfaceGeometry()
  }

  override func layout() {
    super.layout()
    layoutGhosttyModeHUD()
    layoutLinkPreviewBadge()
    scheduleLinkUnderlineRefresh()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateSurfaceGeometry()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    guard let surface, let app = GhosttyApp.shared.app else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let scheme = dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    ghostty_app_set_color_scheme(app, scheme)
    ghostty_surface_set_color_scheme(surface, scheme)
    ghostty_surface_refresh(surface)
  }

  private func updateSurfaceGeometry() {
    guard let surface else { return }
    let pixelSize = convertToBacking(bounds).size
    guard pixelSize.width > 0, pixelSize.height > 0 else { return }
    let scale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    if let layer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.contentsScale = CGFloat(scale)
      CATransaction.commit()
    }
    ghostty_surface_set_content_scale(surface, scale, scale)
    ghostty_surface_set_size(surface, UInt32(pixelSize.width), UInt32(pixelSize.height))
  }

  // MARK: - Focus and pointer tracking

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      isFocused = true
      updateFocusState()
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned {
      isFocused = false
      updateFocusState()
    }
    return resigned
  }

  func setWindowActive(_ active: Bool) {
    isWindowActive = active
    updateFocusState()
  }

  func setPaneActive(_ active: Bool) {
    isPaneActive = active
    updateFocusState()
  }

  private func updateFocusState() {
    guard let surface else { return }
    ghostty_surface_set_focus(surface, isFocused && isWindowActive && isPaneActive)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    rebuildTrackingArea()
  }

  private func rebuildTrackingArea() {
    if let trackingAreaToken { removeTrackingArea(trackingAreaToken) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingAreaToken = area
  }

  /// Ghostty 请求的指针形状。Aster 侧 Command 悬停目标时只记录不应用，避免手形被
  /// 文本 I-beam 抢回；悬停结束后再恢复这里记录的形状。
  func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
    lastGhosttyMouseShape = shape
    guard !linkHoverCursorActive else { return }
    switch shape {
    case GHOSTTY_MOUSE_SHAPE_TEXT: NSCursor.iBeam.set()
    case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: NSCursor.crosshair.set()
    case GHOSTTY_MOUSE_SHAPE_GRAB: NSCursor.openHand.set()
    case GHOSTTY_MOUSE_SHAPE_GRABBING: NSCursor.closedHand.set()
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
      NSCursor.operationNotAllowed.set()
    case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE,
      GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
      NSCursor.resizeLeftRight.set()
    case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE,
      GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
      NSCursor.resizeUpDown.set()
    default: NSCursor.arrow.set()
    }
  }
}

/// 链接预览徽章：按住 Command 悬停链接时钉在终端左下角展示完整路径或 URL。
/// 与 SwiftTerm 回归路径的 `TerminalLinkPreviewBadge` 保持同一视觉规格。
final class GhosttyLinkPreviewBadge: NSView {
  static let horizontalInset: CGFloat = 16
  static let height: CGFloat = 52
  static let cornerRadius: CGFloat = 12
  private static let horizontalTextPadding: CGFloat = 20
  private let label = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    // Ghostty 的 CAMetalLayer 是手工 addSublayer 加到 surface view 的 backing layer 上,
    // 与子视图 layer 属同级;显式抬高 zPosition,保证徽章始终绘制在终端画面之上。
    layer?.zPosition = 1_000
    layer?.cornerRadius = Self.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true

    label.isBezeled = false
    label.drawsBackground = false
    label.isEditable = false
    label.isSelectable = false
    label.usesSingleLineMode = true
    label.maximumNumberOfLines = 1
    label.lineBreakMode = .byTruncatingMiddle
    label.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    addSubview(label)
    updateAppearanceColors()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// 依据文本宽度自适应徽章尺寸，超出可用宽度时中间截断。
  func update(text: String, maximumWidth: CGFloat) {
    label.stringValue = text
    label.toolTip = text
    let measuredWidth = ceil(
      (text as NSString).size(withAttributes: [.font: label.font!]).width
    )
    let availableWidth = max(1, maximumWidth)
    let idealWidth = max(80, measuredWidth + Self.horizontalTextPadding * 2)
    frame.size = CGSize(width: min(availableWidth, idealWidth), height: Self.height)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  override func layout() {
    super.layout()
    let labelHeight = min(bounds.height, max(1, ceil(label.intrinsicContentSize.height)))
    label.frame = CGRect(
      x: Self.horizontalTextPadding,
      y: floor((bounds.height - labelHeight) / 2),
      width: max(0, bounds.width - Self.horizontalTextPadding * 2),
      height: labelHeight
    )
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearanceColors()
  }

  /// 徽章只是视觉反馈；指针事件必须继续到达终端。
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// 与系统外观联动的高对比配色，深浅色分别取反底色保证可读性。
  private func updateAppearanceColors() {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if isDark {
      layer?.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
      label.textColor = NSColor.black.withAlphaComponent(0.90)
    } else {
      layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
      label.textColor = NSColor.white.withAlphaComponent(0.96)
    }
  }

  var textField: NSTextField { label }
}
