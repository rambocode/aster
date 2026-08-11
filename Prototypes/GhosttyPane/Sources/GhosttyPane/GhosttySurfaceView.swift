// AppKit surface bridge adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit
import GhosttyKit
import QuartzCore

/// One Metal-backed libghostty surface and its login shell.
///
/// The prototype deliberately keeps this view independent from Aster's `TerminalSession`.
/// It proves that Ghostty can own PTY reading, VT state and rendering inside the same AppKit
/// hierarchy before the product pays the cost of mapping Aster-specific terminal semantics.
final class GhosttySurfaceView: NSView {
  nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

  var onTitleChange: ((String) -> Void)?
  var onWorkingDirectoryChange: ((String) -> Void)?
  var onProcessExit: (() -> Void)?

  private let workingDirectory: String
  private let command: String?
  private var configStrings: [UnsafeMutablePointer<CChar>] = []
  private var pendingSurfaceCreation = false
  private var isDestroyed = false
  private var didReportExit = false
  private var isFocused = false
  private var trackingAreaToken: NSTrackingArea?

  var markedTextRange = NSRange(location: NSNotFound, length: 0)
  var selectedTextRange = NSRange(location: NSNotFound, length: 0)
  var keyTextAccumulator: [String] = []
  var currentKeyEvent: NSEvent?

  init(workingDirectory: String, command: String? = nil) {
    self.workingDirectory = workingDirectory
    self.command = command
    super.init(frame: .zero)
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("libghostty terminal prototype")
    rebuildTrackingArea()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  deinit {
    // `destroySurface` is normally called by the window delegate. This safety net
    // covers startup failure or an unexpected host teardown without leaking C state.
    if let surface { ghostty_surface_free(surface) }
    for pointer in configStrings { free(pointer) }
  }

  // MARK: - Callback entry points

  func renderNow() {
    guard let surface else { return }
    ghostty_surface_draw(surface)
  }

  func applyTitle(_ title: String) {
    onTitleChange?(title)
  }

  func applyWorkingDirectory(_ path: String) {
    onWorkingDirectoryChange?(path)
  }

  func handleProcessExit() {
    guard !didReportExit else { return }
    didReportExit = true
    onProcessExit?()
  }

  // MARK: - Surface lifecycle

  func createSurface() {
    guard !isDestroyed, surface == nil, let app = GhosttyApp.shared.app else { return }
    let pixelSize = convertToBacking(bounds).size
    guard pixelSize.width > 0, pixelSize.height > 0 else {
      pendingSurfaceCreation = true
      return
    }
    pendingSurfaceCreation = false

    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
    )
    config.userdata = Unmanaged.passUnretained(self).toOpaque()
    config.scale_factor = Double(
      window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)

    // libghostty may retain pointer-backed surface configuration while creating the
    // shell, so heap storage lives with the view and is released only after the surface.
    for pointer in configStrings { free(pointer) }
    configStrings = []
    if let directory = strdup(workingDirectory) {
      configStrings.append(directory)
      config.working_directory = UnsafePointer(directory)
    }
    if let command, let commandPointer = strdup(command) {
      configStrings.append(commandPointer)
      config.command = UnsafePointer(commandPointer)
      config.wait_after_command = false
    } else {
      config.command = nil
    }

    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    surface = ghostty_surface_new(app, &config)
    guard let surface else {
      pendingSurfaceCreation = true
      return
    }

    ghostty_surface_set_color_scheme(
      surface,
      dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    )
    if let screen = window?.screen ?? NSScreen.main,
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    {
      ghostty_surface_set_display_id(surface, displayID)
    }
    ghostty_surface_set_focus(surface, isFocused)
    updateSurfaceGeometry()
  }

  /// Permanently retires the surface. It is idempotent because process-exit and window-close
  /// callbacks can race at the host boundary, while libghostty must be freed exactly once.
  func destroySurface() {
    guard !isDestroyed else { return }
    isDestroyed = true
    if let surface { ghostty_surface_free(surface) }
    surface = nil
    for pointer in configStrings { free(pointer) }
    configStrings = []
    onTitleChange = nil
    onWorkingDirectoryChange = nil
    onProcessExit = nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    if surface == nil {
      createSurface()
    } else {
      updateSurfaceGeometry()
    }
    window.makeFirstResponder(self)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if pendingSurfaceCreation { createSurface() }
    updateSurfaceGeometry()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateSurfaceGeometry()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    guard let surface else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ghostty_surface_set_color_scheme(
      surface,
      dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    )
  }

  private func updateSurfaceGeometry() {
    guard let surface, window != nil else { return }
    let pixelSize = convertToBacking(bounds).size
    guard pixelSize.width > 0, pixelSize.height > 0 else { return }
    let scale = Double(window?.backingScaleFactor ?? 2)

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
      if let surface { ghostty_surface_set_focus(surface, true) }
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned {
      isFocused = false
      if let surface { ghostty_surface_set_focus(surface, false) }
    }
    return resigned
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
}
