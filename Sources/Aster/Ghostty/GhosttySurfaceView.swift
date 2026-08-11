import AppKit
import AsterCore
@preconcurrency import GhosttyKit
import QuartzCore

/// Aster 的 libghostty Adapter：一个长期存活的 Metal surface 与其本地 Shell。
///
/// 调用方只处理会话语义；PTY、VT parser、滚动缓冲和绘制都由 libghostty 持有。
/// surface configuration 中的 C 指针由本实例保留到销毁，避免异步 Shell 创建越界读取。
@MainActor
final class GhosttySurfaceView: NSView {
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
  func applyWorkingDirectory(_ path: String) { onWorkingDirectoryChange?(path) }
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

  func handleOpenURL(_ value: String) { onOpenURL?(value) }

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
    DispatchQueue.main.async { [weak self] in self?.onPTYWrite?(bytes[...]) }
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
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingAreaToken = area
  }

  func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
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
