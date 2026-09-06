import AppKit
import AsterCore
@preconcurrency import GhosttyKit
import SwiftTerm
import Testing
import WebKit

@testable import Aster

@MainActor
private final class MutableTestValue<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

@Test("终端视图区分 OSC 8 显式链接与普通文字链接")
@MainActor
func terminalViewReportsDetectedLinkSource() {
  let view = AsterTerminalView(frame: .zero)

  #expect(
    view.detectedSource(
      for: "codex://session/123",
      payload: "id=docs;codex://session/123"
    ) == .osc8)
  #expect(
    view.detectedSource(
      for: "codex://session/123",
      payload: "id=other;codex://session/different"
    ) == .plainText)
  #expect(view.detectedSource(for: "codex://session/123", payload: nil) == .plainText)
}

@Test("目标打开协调器记住 OSC 8 非标准 scheme 的始终允许选择")
@MainActor
func targetOpenCoordinatorRemembersExplicitSchemePermission() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.controls.detectAllLinkSchemes = false
  var opened: [URL] = []
  var confirmations: [TargetSecurityReason] = []
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    inspectFile: { _ in .missing },
    openURL: { opened.append($0); return true },
    confirm: { reason in confirmations.append(reason); return .always },
    reportError: { message in Issue.record("不应报告错误：\(message)") }
  )

  let didOpen = coordinator.open(
    "codex://session/123",
    source: .osc8,
    currentDirectory: "/tmp"
  )

  #expect(didOpen)
  #expect(confirmations == [.nonStandardScheme("codex")])
  #expect(opened == [URL(string: "codex://session/123")!])
  #expect(preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes == ["codex"])
}

@Test("链接选择 Aster 时进入受限 Web Pane 而不调用系统浏览器")
@MainActor
func targetOpenCoordinatorRoutesWebLinksInternally() {
  let preferences = AppPreferences(defaults: isolatedDefaults())
  preferences.configuration.controls.linkOpenWith = .aster
  var internalURLs: [URL] = []
  var systemOpenCount = 0
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    openURL: { _ in systemOpenCount += 1; return true },
    openInAster: { url, isDirectory in
      #expect(!isDirectory)
      internalURLs.append(url)
      return true
    },
    confirm: { reason in
      #expect(reason == .externalLink("example.com"))
      return .always
    },
    reportError: { message in Issue.record("不应报告错误：\(message)") }
  )

  #expect(coordinator.open("https://example.com/docs", source: .plainText, currentDirectory: "/tmp"))
  #expect(internalURLs == [URL(string: "https://example.com/docs")!])
  #expect(systemOpenCount == 0)
  #expect(preferences.configuration.controls.resolvedAllowedExternalLinkHosts == ["example.com"])
  #expect(WebPaneURLPolicy.allowedURL(from: "https://example.com/docs") != nil)
  #expect(WebPaneURLPolicy.allowedURL(from: "file:///tmp/secret") == nil)
  #expect(WebPaneURLPolicy.allowedURL(from: "javascript:alert(1)") == nil)
}

@Test("Command 点击 .app、可执行文件与二进制文件直接走系统打开，目录与文本进 Aster")
@MainActor
func targetOpenCoordinatorRoutesLocalFilesByKind() {
  let preferences = AppPreferences(defaults: isolatedDefaults())
  preferences.configuration.controls.fileOpenWith = .aster
  preferences.configuration.controls.folderOpenWith = .aster
  preferences.configuration.controls.allowedExecutableFileSignatures = ["sig"]
  let kind = MutableTestValue(TargetFileKind.applicationBundle)
  let isText = MutableTestValue(true)
  var systemOpened: [URL] = []
  var internalOpened: [(URL, Bool)] = []
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    inspectFile: { _ in kind.value },
    isTextFile: { _ in isText.value },
    openURL: { systemOpened.append($0); return true },
    openInAster: { url, isDirectory in internalOpened.append((url, isDirectory)); return true },
    executableSignature: { _ in "sig" },
    confirm: { _ in Issue.record("已授权签名不应再确认"); return .cancel },
    reportError: { message in Issue.record("不应报告错误：\(message)") }
  )

  // .app bundle：不进右侧 Pane，直接系统打开。
  #expect(coordinator.open("/tmp/Aster.app", source: .plainText, currentDirectory: "/tmp"))
  #expect(systemOpened.map(\.path) == ["/tmp/Aster.app"])
  #expect(internalOpened.isEmpty)

  // 可执行文件同样只走系统。
  kind.value = .regular(executable: true)
  #expect(coordinator.open("/tmp/tool", source: .plainText, currentDirectory: "/tmp"))
  #expect(systemOpened.count == 2)
  #expect(internalOpened.isEmpty)

  // 二进制普通文件交给系统默认应用。
  kind.value = .regular(executable: false)
  isText.value = false
  #expect(coordinator.open("/tmp/photo.png", source: .plainText, currentDirectory: "/tmp"))
  #expect(systemOpened.count == 3)
  #expect(internalOpened.isEmpty)

  // 文本文件进 Aster 编辑器。
  isText.value = true
  #expect(coordinator.open("/tmp/notes.md", source: .plainText, currentDirectory: "/tmp"))
  #expect(systemOpened.count == 3)
  #expect(internalOpened.map { $0.0.path } == ["/tmp/notes.md"])
  #expect(internalOpened.last?.1 == false)

  // 目录进 Aster 文件浏览器。
  kind.value = .directory
  #expect(coordinator.open("/tmp/src", source: .plainText, currentDirectory: "/tmp"))
  #expect(internalOpened.last?.0.path == "/tmp/src")
  #expect(internalOpened.last?.1 == true)
  #expect(systemOpened.count == 3)
}

@Test("文本探测按 NUL 字节与 UTF-8 合法性区分文本和二进制")
func targetFileInspectorDetectsText() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-text-probe-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let text = directory.appendingPathComponent("a.md")
  try "# 标题\nhello\n".write(to: text, atomically: true, encoding: .utf8)
  let binary = directory.appendingPathComponent("b.bin")
  try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A]).write(to: binary)
  let empty = directory.appendingPathComponent("c.txt")
  try Data().write(to: empty)
  #expect(TargetFileInspector.isProbablyText(atPath: text.path))
  #expect(!TargetFileInspector.isProbablyText(atPath: binary.path))
  #expect(TargetFileInspector.isProbablyText(atPath: empty.path))
  #expect(!TargetFileInspector.isProbablyText(atPath: directory.appendingPathComponent("missing").path))
}

@Test("可执行文件授权绑定文件身份且替换后重新确认")
@MainActor
func targetOpenCoordinatorInvalidatesChangedExecutablePermission() {
  let preferences = AppPreferences(defaults: isolatedDefaults())
  preferences.configuration.controls.fileOpenWith = .defaultApplication
  let signature = MutableTestValue("signature-v1")
  var confirmationCount = 0
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    inspectFile: { _ in .regular(executable: true) },
    openURL: { _ in true },
    executableSignature: { _ in signature.value },
    confirm: { reason in
      #expect(reason == .executableFile("/tmp/tool"))
      confirmationCount += 1
      return .always
    },
    reportError: { message in Issue.record("不应报告错误：\(message)") }
  )

  #expect(coordinator.open("/tmp/tool", source: .plainText, currentDirectory: "/tmp"))
  #expect(coordinator.open("/tmp/tool", source: .plainText, currentDirectory: "/tmp"))
  #expect(confirmationCount == 1)
  signature.value = "signature-v2"
  #expect(coordinator.open("/tmp/tool", source: .plainText, currentDirectory: "/tmp"))
  #expect(confirmationCount == 2)
}

@Test("目标打开协调器拒绝未检测 scheme 和特殊文件且不调用系统打开")
@MainActor
func targetOpenCoordinatorRejectsUndetectedAndSpecialTargets() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.controls.detectAllLinkSchemes = false
  var openCount = 0
  var errors: [String] = []
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    inspectFile: { _ in .namedPipe },
    openURL: { _ in openCount += 1; return true },
    confirm: { _ in Issue.record("拒绝目标不应请求确认"); return .once },
    reportError: { errors.append($0) }
  )

  let customOpened = coordinator.open(
    "ssh://host.example",
    source: .plainText,
    currentDirectory: "/tmp"
  )
  let pipeOpened = coordinator.open(
    "/tmp/events.pipe",
    source: .plainText,
    currentDirectory: "/tmp"
  )

  #expect(!customOpened)
  #expect(!pipeOpened)
  #expect(openCount == 0)
  #expect(errors.count == 2)
}

@Test("系统打开失败时不持久化始终允许选择")
@MainActor
func targetOpenCoordinatorDoesNotRememberFailedOpen() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  var errors: [String] = []
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    openURL: { _ in false },
    confirm: { _ in .always },
    reportError: { errors.append($0) }
  )

  let didOpen = coordinator.open(
    "codex://session/failed",
    source: .plainText,
    currentDirectory: "/tmp"
  )

  #expect(!didOpen)
  #expect(preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes.isEmpty)
  #expect(errors.count == 1)
}

@Test("配置导入保留检测设置但剥离本机安全授权")
@MainActor
func configurationImportStripsSecurityPermissions() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  var imported = AsterConfiguration.default
  imported.controls.detectAllLinkSchemes = false
  imported.controls.customLinkSchemes = ["codex"]
  imported.controls.allowedNonStandardLinkSchemes = ["codex"]
  imported.controls.allowedExternalLinkHosts = ["example.com"]
  imported.controls.allowedExecutableFileSignatures = ["signature-v1"]
  imported.controls.clipboardReadAccess = .allow
  imported.controls.clipboardWriteAccess = .deny

  preferences.importConfiguration(imported)

  #expect(preferences.configuration.controls.resolvedLinkSchemePolicy == .custom(["codex"]))
  #expect(preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes.isEmpty)
  #expect(preferences.configuration.controls.resolvedAllowedExternalLinkHosts.isEmpty)
  #expect(preferences.configuration.controls.resolvedAllowedExecutableFileSignatures.isEmpty)
  #expect(preferences.configuration.controls.resolvedClipboardReadAccess == .ask)
  #expect(preferences.configuration.controls.resolvedClipboardWriteAccess == .deny)
}

@MainActor
private func isolatedDefaults() -> UserDefaults {
  let suite = "AsterTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Test("主工作区由纯 AppKit 视图控制器构成")
@MainActor
func workspaceUsesOnlyNativeAppKitViews() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  model.splitSelectedTab(.right)
  let controller = WorkspaceViewController(model: model, preferences: preferences)

  controller.loadViewIfNeeded()

  #expect(controller.view is NSVisualEffectView)
  #expect(controller.view.descendants.contains { String(describing: type(of: $0)).contains("NSHosting") } == false)
  #expect(controller.view.descendants.contains { $0 is NSSplitView } == true)
}

@Test("产品终端宿主使用 Ghostty 视图且配置可初始化")
@MainActor
func terminalHostUsesGhosttySurface() throws {
  _ = NSApplication.shared
  let preferences = AppPreferences(defaults: isolatedDefaults())
  let session = TerminalSession(workingDirectory: "/tmp")
  defer { session.stop(immediately: true) }

  let host = session.makeTerminalHost(preferences: preferences)
  let views = [host] + host.descendants
  _ = try #require(views.compactMap { $0 as? GhosttySurfaceView }.first)

  #expect(
    GhosttyApp.shared.prepare(
      configurationText: GhosttyConfiguration.make(preferences: preferences)))
  #expect(GhosttyApp.shared.isReady)
  #expect(GhosttyApp.shared.startupError == nil)
  #expect(GhosttyApp.shared.configurationDiagnostics.isEmpty)
  #expect(!views.contains { $0 is AsterTerminalView })
}

@Test("Ghostty 扩展 ABI 恢复搜索、OSC、Outline 与本地导航模式")
@MainActor
func ghosttyExtensionCapabilitiesWorkOnRealSurface() async throws {
  _ = NSApplication.shared
  let preferences = AppPreferences(defaults: isolatedDefaults())
  preferences.configuration.controls.autocompleteOnDeviceLearning = false
  let session = TerminalSession(workingDirectory: "/tmp")
  defer { session.stop(immediately: true) }
  let host = session.makeTerminalHost(preferences: preferences)
  let view = try #require(([host] + host.descendants).compactMap { $0 as? GhosttySurfaceView }.first)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  host.frame = window.contentView?.bounds ?? .zero
  host.autoresizingMask = [.width, .height]
  window.contentView?.addSubview(host)
  window.layoutIfNeeded()
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  view.createSurface()

  #expect(GhosttyApp.shared.startupError == nil)
  #expect(view.window === window)
  #expect(view.bounds.width > 0 && view.bounds.height > 0)
  #expect(view.surface != nil)

  for _ in 0..<100 where !view.isProcessRunning {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(view.isProcessRunning)

  // 在保留 Session 原处理链的同时记录真实 C callback，避免只凭 Swift 接口存在就
  // 推断 ABI 已接通。PTY payload 与 OSC point 都必须来自正在运行的 Ghostty surface。
  var observedRead: [UInt8] = []
  var observedWrite: [UInt8] = []
  var observedOSC: [(code: Int, payload: String, point: ghostty_aster_buffer_point_s)] = []
  var observedGhosttyTitles: [String] = []
  let sessionPTYRead = view.onPTYRead
  let sessionPTYWrite = view.onPTYWrite
  let sessionOSC = view.onOSC
  let sessionTitle = view.onTitleChange
  view.onPTYRead = { bytes in
    observedRead.append(contentsOf: bytes)
    sessionPTYRead?(bytes)
  }
  view.onPTYWrite = { bytes in
    observedWrite.append(contentsOf: bytes)
    sessionPTYWrite?(bytes)
  }
  view.onOSC = { code, payload, point in
    observedOSC.append((code, String(decoding: payload, as: UTF8.self), point))
    sessionOSC?(code, payload, point)
  }
  view.onTitleChange = { title in
    observedGhosttyTitles.append(title)
    sessionTitle?(title)
  }

  #expect(view.typeText(
    "ZSH_AUTOSUGGEST_STRATEGY=(); printf '__GHOSTTY_UPPER__ __ghostty_upper__ __DIRECTION__ __DIRECTION__ https://example.com\\n'\n"))
  for _ in 0..<150
  where view.readText(includeScrollback: true)?.contains("https://example.com") != true {
    try await Task.sleep(for: .milliseconds(20))
  }
  let observedInput = String(decoding: observedWrite, as: UTF8.self)
  let observedOutput = String(decoding: observedRead, as: UTF8.self)
  #expect(observedInput.contains("__GHOSTTY_UPPER__"))
  #expect(observedOutput.contains("__GHOSTTY_UPPER__"))

  // 777 是 Ghostty/Aster 都不消费的任意扩展号。observer 必须收到完整 payload，
  // 而同一 PTY 分片中 OSC 前后的普通文本仍须继续经过 Ghostty parser 并进入网格。
  #expect(view.typeText(
    "printf '__OSC_PREFIX__\\033]777;aster-observer\\007__OSC_SUFFIX__\\n'\n"))
  for _ in 0..<150 where !observedOSC.contains(where: {
    $0.code == 777 && $0.payload == "aster-observer"
  }) {
    try await Task.sleep(for: .milliseconds(20))
  }
  let arbitraryOSCEvents = observedOSC.filter {
    $0.code == 777 && $0.payload == "aster-observer"
  }
  let arbitraryOSC = try #require(arbitraryOSCEvents.last)
  for _ in 0..<150 where view.readText(includeScrollback: true)?.contains(
    "__OSC_PREFIX____OSC_SUFFIX__") != true
  {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(view.readText(includeScrollback: true)?.contains(
    "__OSC_PREFIX____OSC_SUFFIX__") == true)
  let resolvedArbitraryPoint = try #require(view.resolveBufferPoint(arbitraryOSC.point))
  #expect(resolvedArbitraryPoint.page_serial == arbitraryOSC.point.page_serial)
  #expect(resolvedArbitraryPoint.page_row == arbitraryOSC.point.page_row)
  #expect(view.readLine(at: arbitraryOSC.point, startingAt: 0)?.contains(
    "__OSC_PREFIX____OSC_SUFFIX__") == true)
  let surface = try #require(view.surface)
  var exactSelection = ghostty_aster_buffer_range_s(
    start: arbitraryOSC.point,
    end: arbitraryOSC.point,
    rectangle: false
  )
  #expect(ghostty_aster_surface_set_selection(surface, &exactSelection))
  var selectionRoundTrip = ghostty_aster_buffer_range_s()
  #expect(ghostty_aster_surface_get_selection(surface, &selectionRoundTrip))
  #expect(selectionRoundTrip.start.page_serial == arbitraryOSC.point.page_serial)
  #expect(selectionRoundTrip.start.page_row == arbitraryOSC.point.page_row)
  #expect(selectionRoundTrip.start.column == arbitraryOSC.point.column)
  ghostty_aster_surface_clear_selection(surface)

  // OSC 2 同时覆盖 observer 与 Ghostty 自己的 set-title action。若 observer 消费了
  // 原流，底层 parser 就不会再产生 `onTitleChange`。
  #expect(view.typeText("printf '\\033]2;aster-core-title\\007'\n"))
  for _ in 0..<100 where !observedOSC.contains(where: {
    $0.code == 2 && $0.payload == "aster-core-title"
  }) || !observedGhosttyTitles.contains("aster-core-title") {
    try await Task.sleep(for: .milliseconds(20))
  }
  let observedTitleOSC = observedOSC.contains {
    $0.code == 2 && $0.payload == "aster-core-title"
  }
  #expect(observedTitleOSC)
  #expect(observedGhosttyTitles.contains("aster-core-title"))

  // 真实 Shell Integration 的 OSC 133 B 激活 tracker；PTY write/read 回调分别推进
  // 本地输入和回显，最终应在 Ghostty caret 旁显示内置 git spec 的 inline suggestion。
  for _ in 0..<150 where observedOSC.last(where: { $0.code == 133 })?.payload != "B" {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(observedOSC.last(where: { $0.code == 133 })?.payload == "B")
  #expect(session.shellIntegrationDetected)
  #expect(!session.isUsingForegroundPollingFallback)
  #expect(AutocompleteService.shared != nil)
  #expect(view.descendants.contains {
    String(describing: type(of: $0)).contains("TerminalAutocompleteOverlayView")
  })
  #expect(view.typeText("git chec"))
  for _ in 0..<150 where !view.descendants.compactMap({ $0 as? NSTextField }).contains(where: {
    !$0.isHidden && $0.stringValue == "kout"
  }) {
    try await Task.sleep(for: .milliseconds(20))
  }
  let autocompleteVisible = view.descendants.compactMap { $0 as? NSTextField }.contains {
    !$0.isHidden && $0.stringValue == "kout"
  }
  #expect(autocompleteVisible)
  let autocompleteOverlay = try #require(
    view.descendants.first {
      String(describing: type(of: $0)).contains("TerminalAutocompleteOverlayView")
    }
  )
  let inlineSuggestion = try #require(
    autocompleteOverlay.subviews.compactMap { $0 as? NSTextField }.first
  )
  let quickLookFontPointer = try #require(ghostty_surface_quicklook_font(surface))
  let terminalFont = Unmanaged<NSFont>.fromOpaque(quickLookFontPointer).takeRetainedValue()
  let inlineFont = try #require(inlineSuggestion.font)
  // Inline suggestion 是覆盖在 Ghostty Metal 字形旁的 AppKit 文本；必须消费 surface
  // 当前实际字体，固定的系统等宽字体即使字号相同也会因 descent/leading 不同而错开基线。
  #expect(inlineFont.fontName == terminalFont.fontName)
  #expect(abs(inlineFont.pointSize - terminalFont.pointSize) < 0.01)
  var imeX = 0.0
  var imeY = 0.0
  var imeWidth = 0.0
  var imeHeight = 0.0
  ghostty_surface_ime_point(surface, &imeX, &imeY, &imeWidth, &imeHeight)
  let imeLocalFrame = NSRect(
    x: imeX,
    y: view.bounds.height - imeY - imeHeight,
    width: imeWidth,
    height: imeHeight
  )
  let bufferInfo = try #require(view.bufferInfo())
  let surfaceSize = ghostty_surface_size(surface)
  let cellHeight = CGFloat(surfaceSize.cell_height_px) / window.backingScaleFactor
  let cursorViewportRow = Int(clamping: bufferInfo.cursor.screen_row)
    - Int(clamping: bufferInfo.viewport_top)
  let cursorCellMinY = view.bounds.maxY - CGFloat(cursorViewportRow + 1) * cellHeight
  let naturalBaselineFromBottom =
    inlineSuggestion.frame.height - inlineSuggestion.firstBaselineOffsetFromTop
  let centeredBaselineFromBottom =
    naturalBaselineFromBottom + (cellHeight - inlineSuggestion.frame.height) / 2
  let alignedBaselineFromBottom =
    (centeredBaselineFromBottom * window.backingScaleFactor).rounded()
    / window.backingScaleFactor
  let inlineBaselineY = inlineSuggestion.frame.minY + naturalBaselineFromBottom
  // IME x 是 cell 中点；横向减半格后才是建议的起点。纵向必须锚定当前
  // cursor 网格行，不能使用为系统候选窗预留到下一行的 IME y 坐标。文字自身还要在
  // cell 内垂直居中，才能跟随 Ghostty 的 adjust-cell-height 基线调整。
  let cellWidth = CGFloat(surfaceSize.cell_width_px) / window.backingScaleFactor
  #expect(abs(inlineSuggestion.frame.minX - (imeLocalFrame.minX - cellWidth / 2)) < 0.75)
  #expect(abs(inlineSuggestion.frame.minY - cursorCellMinY) < 0.75)
  #expect(abs(inlineBaselineY - (cursorCellMinY + alignedBaselineFromBottom)) < 0.01)
  #expect(view.sendBytes([0x15]))  // Ctrl-U：清空未提交的 `git chec`，继续后续 ABI 验收。
  try await Task.sleep(for: .milliseconds(100))

  #expect(view.bufferInfo() != nil)
  #expect(view.find("__ghostty_upper__", previous: false, caseSensitive: true))
  let sensitiveTotal = view.searchTotal
  view.clearSearch()
  #expect(view.find("__ghostty_upper__", previous: false, caseSensitive: false))
  #expect(view.searchTotal > sensitiveTotal)
  view.clearSearch()
  #expect(view.find("__GHOSTTY_[A-Z]+__", previous: false, caseSensitive: true,
    regularExpression: true))
  #expect(!view.find("[", previous: false, regularExpression: true))
  view.clearSearch()
  #expect(view.find("__DIRECTION__", previous: false, caseSensitive: true))
  #expect(view.searchSelected == 1)
  #expect(view.searchTotal >= 2)
  #expect(view.find("__DIRECTION__", previous: false, caseSensitive: true))
  #expect(view.searchSelected == 2)
  #expect(view.find("__DIRECTION__", previous: true, caseSensitive: true))
  #expect(view.searchSelected == 1)

  let escape = try #require(NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    characters: "\u{1B}",
    charactersIgnoringModifiers: "\u{1B}",
    isARepeat: false,
    keyCode: 53
  ))
  view.enterViMode()
  #expect(view.navigationMode == .vi(.vi))
  view.keyDown(with: escape)
  #expect(view.navigationMode == .normal)
  view.enterMarkMode()
  #expect(view.navigationMode == .vi(.mark))
  var selection = ghostty_aster_buffer_range_s()
  #expect(ghostty_aster_surface_get_selection(surface, &selection))
  view.keyDown(with: escape)
  #expect(view.navigationMode == .normal)
  view.openHintMode()
  #expect(view.navigationMode == .hint)
  #expect(view.hintTargetCount > 0)
  view.keyDown(with: escape)

  #expect(view.typeText("printf '\\033]6974;Badge=error\\007'\n"))
  for _ in 0..<100 where session.explicitBadge != .error {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.explicitBadge == .error)

  #expect(view.typeText("echo __GHOSTTY_OUTLINE__\n"))
  for _ in 0..<150 where !session.commandOutlineEntries().contains(where: {
    $0.title.contains("__GHOSTTY_OUTLINE__")
  }) {
    try await Task.sleep(for: .milliseconds(20))
  }
  let outline = try #require(session.commandOutlineEntries().last(where: {
    $0.title.contains("__GHOSTTY_OUTLINE__")
  }))
  #expect(outline.isJumpAvailable)
  #expect(session.revealAbsoluteRow(outline.absoluteRow))
  let stablePointAfterFurtherOutput = try #require(view.resolveBufferPoint(arbitraryOSC.point))
  #expect(stablePointAfterFurtherOutput.page_serial == arbitraryOSC.point.page_serial)
  #expect(stablePointAfterFurtherOutput.page_row == arbitraryOSC.point.page_row)
}

@Test("设置页由单一 WebKit 宿主构成并保留九个分类")
@MainActor
func settingsUsesSingleWebKitHost() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)

  controller.loadViewIfNeeded()

  #expect(controller.sections.count == 9)
  #expect(controller.view is WKWebView)
  #expect(controller.view === controller.settingsWebViewForTesting)
}

@Test("Dock 右键菜单不添加应用自定义入口")
@MainActor
func dockMenuDoesNotAddApplicationSpecificItems() {
  let delegate = AsterAppDelegate()
  let applicationDelegate: any NSApplicationDelegate = delegate

  #expect(applicationDelegate.applicationDockMenu?(NSApplication.shared) == nil)
}

@Test("设置使用独立可缩放窗口且不改动主工作区")
@MainActor
func settingsUsesResizableIndependentWindow() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let workspaceWindow = makeTestWindow(
    content: workspace,
    size: NSSize(width: 1_180, height: 760)
  )
  let workspaceFrame = workspaceWindow.frame
  let workspaceRoot = try #require(workspace.view.subviews.first)
  let settings = SettingsViewController(preferences: preferences)
  let settingsWindowController = AsterSettingsWindowController(
    content: settings,
    appearance: preferences.preferredAppearance,
    defaults: defaults
  )
  let settingsWindow = try #require(settingsWindowController.window)

  #expect(settingsWindow !== workspaceWindow)
  #expect(settingsWindow.contentViewController === settings)
  #expect(settingsWindow.contentView?.frame.size == SettingsViewController.defaultContentSize)
  // `700 × 460pt` 是内容尺寸下限，宽高上界都放开供用户拖动。
  #expect(settingsWindow.minSize.width == settingsWindow.frame.width)
  #expect(settingsWindow.maxSize.width > settingsWindow.frame.width * 2)
  #expect(settingsWindow.minSize.height == settingsWindow.frame.height)
  #expect(settingsWindow.maxSize.height > settingsWindow.frame.height * 2)
  #expect(settingsWindow.styleMask.contains(.resizable))
  // 设置页由 WKWebView 填满内容区域；内容不得延伸进系统标题栏，否则 WebKit 会吞掉
  // 标题栏的 mouseDown，用户看得到窗口却无法拖动。
  #expect(!settingsWindow.styleMask.contains(.fullSizeContentView))
  #expect(settingsWindow.isMovable)
  #expect(settingsWindow.standardWindowButton(.miniaturizeButton)?.isEnabled == false)
  #expect(settingsWindow.isExcludedFromWindowsMenu)
  #expect(workspaceWindow.frame == workspaceFrame)
  #expect(workspace.view.subviews.contains { $0 === workspaceRoot })
  #expect(!workspaceRoot.isHidden)
  #expect(!workspace.children.contains { $0 is SettingsViewController })
  let visibleLabels = settings.view.descendants.compactMap {
    ($0 as? NSTextField)?.stringValue
  }
  #expect(!visibleLabels.contains("返回工作区"))
}

@Test("设置窗口打开时新增 Tab 与 Pane 立即刷新工作区")
@MainActor
func workspaceMutationsStayVisibleWhileSettingsAreOpen() async throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: ["/tmp/settings-live-workspace"]
  )
  defer {
    for tab in model.tabs { tab.stop(immediately: true) }
  }
  let preferences = AppPreferences(defaults: defaults)
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  workspace.loadViewIfNeeded()
  workspace.setSettingsPresentationActive(true)

  model.newTab(workingDirectory: "/tmp/settings-live-tab", hasContent: true)
  let addedTab = try #require(model.selectedTab)
  addedTab.split(
    direction: .right,
    kind: .editor,
    resourcePath: "/tmp/settings-live-pane.txt"
  )
  try await Task.sleep(for: .milliseconds(30))

  let tabIdentifier = "workspace-tab-row-\(addedTab.id.uuidString)"
  let visibleTabWhileOpen = workspace.view.descendants.contains {
    $0.identifier?.rawValue == tabIdentifier
  }
  let visiblePaneIDsWhileOpen = Set(
    workspace.view.descendants.compactMap { ($0 as? ActivePaneHostView)?.paneID }
  )
  #expect(visibleTabWhileOpen)
  #expect(visiblePaneIDsWhileOpen == Set(addedTab.layout.allPanes.map(\.id)))

  // 关闭设置不应承担刷新职责；保留这一步可直接区分“操作已执行但 UI 被延迟”的回归。
  workspace.setSettingsPresentationActive(false)
  #expect(workspace.view.descendants.contains { $0.identifier?.rawValue == tabIdentifier })
  #expect(
    Set(workspace.view.descendants.compactMap { ($0 as? ActivePaneHostView)?.paneID })
      == Set(addedTab.layout.allPanes.map(\.id))
  )
}

@Test("设置窗口打开时从明亮切换黑暗主题会实时刷新主工作区")
@MainActor
func themeSelectionRefreshesWorkspaceWhileSettingsStayOpen() async throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: ["/tmp/live-theme"])
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(
    content: workspace,
    size: NSSize(width: 1_180, height: 760)
  )
  window.contentView?.layoutSubtreeIfNeeded()
  workspace.setSettingsPresentationActive(true)

  let ayuDark = try #require(TerminalThemeCatalog.theme(named: "Ayu Dark"))
  preferences.selectTheme(ayuDark)
  // AppPreferences 在 will-change 阶段广播，工作区要等当前调用栈结束后读取新主题。
  try await Task.sleep(for: .milliseconds(30))
  window.contentView?.layoutSubtreeIfNeeded()

  #expect(preferences.appearance == .dark)
  #expect(preferences.activeTheme.id == ayuDark.id)
  let root = try #require(workspace.view as? ThemeVisualEffectView)
  #expect(root.appliedThemeTint == ayuDark.resolvedColor(forSlot: "interface.window"))
  let sidebar = try #require(
    workspace.view.descendants.first {
      $0.identifier?.rawValue == "workspace-sidebar"
    } as? ThemeVisualEffectView
  )
  #expect(sidebar.appliedThemeTint == ayuDark.resolvedColor(forSlot: "sidebar.background"))
}

@Test("设置窗口打开时切换标签栏布局会实时刷新主工作区")
@MainActor
func tabBarLayoutSelectionRefreshesWorkspaceWhileSettingsStayOpen() async throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: ["/tmp/live-layout"])
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .top
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(
    content: workspace,
    size: NSSize(width: 1_180, height: 760)
  )
  window.contentView?.layoutSubtreeIfNeeded()
  workspace.setSettingsPresentationActive(true)

  preferences.tabBarLayout = .vertical
  // AppPreferences 在 will-change 阶段广播，工作区要等当前调用栈结束后读取新布局。
  try await Task.sleep(for: .milliseconds(30))
  window.contentView?.layoutSubtreeIfNeeded()

  let hasSidebar = workspace.view.descendants.contains {
    $0.identifier?.rawValue == "workspace-sidebar"
  }
  let hasHorizontalTabbar = workspace.view.descendants.contains {
    $0.identifier?.rawValue == "workspace-tabbar"
  }
  #expect(hasSidebar, "设置打开期间切到垂直布局应立即出现侧栏标签")
  #expect(!hasHorizontalTabbar, "顶部标签栏应随布局切换立即移除")
}

@Test("顶部标签布局的标题带位于标签行上方且标签让开交通灯命中区")
@MainActor
func topTabBarPlacesTitleBandAboveTabsAndClearOfTrafficLights() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: ["/tmp/top-band"])
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .top
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  // 中央标题唯一且并入标签条顶部的标题带，内容区不再渲染第二份标题行。
  let tabbar = try #require(
    controller.view.descendants.first { $0.identifier?.rawValue == "workspace-tabbar" }
  )
  let titlebars = controller.view.descendants.filter {
    $0.identifier?.rawValue == "workspace-titlebar"
  }
  #expect(titlebars.count == 1)
  let titlebar = try #require(titlebars.first)
  #expect(titlebar.isDescendant(of: tabbar))

  // 标签按钮整体位于 28pt 标题带之下：顶缘不进入交通灯所在的窗口拖拽命中区。
  let tabButton = try #require(
    controller.view.descendants.compactMap { $0 as? TabRowButton }.first
  )
  let contentHeight = try #require(window.contentView?.frame.height)
  let tabRectInWindow = tabButton.convert(tabButton.bounds, to: nil)
  #expect(contentHeight - tabRectInWindow.maxY >= 27.5, "标签顶缘应让开 28pt 标题带")
  // 标签行必须绑定栈宽后从左缘起排；纵向栈按固有宽度排布时整行会浮到窗口中间。
  #expect(tabRectInWindow.minX <= 20, "标签应从窗口左缘起排（左对齐）")
  let titleRectInWindow = titlebar.convert(titlebar.bounds, to: nil)
  #expect(titleRectInWindow.minY >= tabRectInWindow.maxY - 0.5, "标题带应在标签行上方")

  // 横向标签条只保留「+」新建入口，不再提供命令面板图标。
  #expect(!tabbar.descendants.contains { ($0 as? NSButton)?.toolTip == "命令面板" })
  #expect(tabbar.descendants.contains { ($0 as? NSButton)?.toolTip == "新建标签页" })
}

@Test("底部标签布局不提供命令面板图标且标题留在内容区顶部")
@MainActor
func bottomTabBarDropsPaletteIconAndKeepsTitleAtContentTop() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: ["/tmp/bottom-band"])
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .bottom
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let tabbar = try #require(
    controller.view.descendants.first { $0.identifier?.rawValue == "workspace-tabbar" }
  )
  #expect(!tabbar.descendants.contains { ($0 as? NSButton)?.toolTip == "命令面板" })
  let titlebar = try #require(
    controller.view.descendants.first { $0.identifier?.rawValue == "workspace-titlebar" }
  )
  #expect(!titlebar.isDescendant(of: tabbar), "底部布局的标题行仍在内容区顶部")
}

@Test("菜单主题选择器实时预览且仅在确认后持久化")
@MainActor
func themeSwitcherPreviewsAndCommitsAsOneTransaction() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let ayu = try #require(preferences.themes(for: .light).first { $0.name == "Ayu Light" })
  let pink = try #require(preferences.themes(for: .light).first { $0.name == "Pink" })
  preferences.selectTheme(ayu)

  preferences.previewTheme(pink)
  #expect(preferences.activeTheme.name == "Pink")
  #expect(preferences.configuration.appearance.themeName == "Ayu Light")
  #expect(AppPreferences(defaults: defaults).activeTheme.name == "Ayu Light")
  preferences.cancelThemePreview()
  #expect(preferences.activeTheme.name == "Ayu Light")

  let cancelled = ThemeSwitcherViewController(preferences: preferences)
  cancelled.loadViewIfNeeded()
  #expect(cancelled.visibleThemeNames.count == 24)
  #expect(cancelled.visibleThemeNames.contains("Ayu Dark"))
  #expect(cancelled.selectedThemeName == "Ayu Light")
  let cancelledLightIndex = try #require(cancelled.visibleThemeNames.firstIndex(of: "Ayu Light"))
  let cancelledDarkIndex = try #require(cancelled.visibleThemeNames.firstIndex(of: "Ayu Dark"))
  cancelled.moveSelection(cancelledDarkIndex - cancelledLightIndex)
  let previewedName = try #require(cancelled.selectedThemeName)
  #expect(previewedName == "Ayu Dark")
  #expect(preferences.activeTheme.name == previewedName)
  cancelled.cancelPresentation()
  #expect(preferences.appearance == .light)
  #expect(preferences.activeTheme.name == "Ayu Light")

  let committed = ThemeSwitcherViewController(preferences: preferences)
  committed.loadViewIfNeeded()
  let lightIndex = try #require(committed.visibleThemeNames.firstIndex(of: "Ayu Light"))
  let darkIndex = try #require(committed.visibleThemeNames.firstIndex(of: "Ayu Dark"))
  committed.moveSelection(darkIndex - lightIndex)
  let committedName = try #require(committed.selectedThemeName)
  #expect(committedName == "Ayu Dark")
  #expect(preferences.activeTheme.name == "Ayu Dark")
  committed.commitSelection()
  #expect(preferences.appearance == .dark)
  #expect(preferences.configuration.appearance.darkThemeName == committedName)
  #expect(AppPreferences(defaults: defaults).activeTheme.name == committedName)
}

@Test("设置页保持原始 700×460pt 默认尺寸")
@MainActor
func settingsKeepsOriginalDefaultSize() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)

  controller.loadViewIfNeeded()

  #expect(controller.view.frame.size == NSSize(width: 700, height: 460))
}

@Test("垂直标签栏使用 Otty 的整行选中结构")
@MainActor
func verticalSidebarUsesFullWidthRows() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let tabButtons = controller.view.descendants.compactMap { view -> NSButton? in
    guard String(describing: type(of: view)).contains("TabRowButton") else { return nil }
    return view as? NSButton
  }
  #expect(tabButtons.count == 1)
  #expect((tabButtons.first?.frame.width ?? 0) >= 210)
  #expect(tabButtons.first?.enclosingScrollView == nil)
  #expect(controller.view.descendants.contains { $0 is TabActivitySpinnerView } == false)
  // 悬停动作区：「+ 新建 / 折叠」按钮放在侧栏顶部右侧，默认隐藏，指针进入对应
  // 感应区才淡入（2026-08 设计变更，替代旧的「标签栏不含按钮」断言）。两个按钮
  // 各自显隐，因此隐藏状态记在按钮自己身上，而不是共享的容器上。
  let hoverButtons = controller.view.descendants.compactMap { $0 as? NSButton }.filter {
    $0.toolTip == "新建标签页" || ($0.toolTip ?? "").hasPrefix("折叠标签栏")
  }
  #expect(hoverButtons.count == 2)
  #expect(hoverButtons.allSatisfy { $0.isHidden && $0.alphaValue == 0 })
  // 容器保持可见但不参与命中测试，隐藏按钮的位置仍然可以拖动窗口。
  let hoverContainer = try #require(hoverButtons.first?.superview)
  #expect(hoverContainer.isHidden == false)
  let hoverProbe = NSPoint(x: hoverContainer.frame.midX, y: hoverContainer.frame.midY)
  #expect(hoverContainer.hitTest(hoverProbe) == nil)
  #expect(controller.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("LOCAL") } == false)
}

@Test("侧栏标签行使用两侧留边的圆角底卡")
@MainActor
func verticalSidebarRowsUseInsetRoundedCard() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  let theme = try #require(TerminalThemeCatalog.theme(named: "One Light"))
  preferences.selectTheme(theme)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let row = try #require(
    controller.view.descendants.first {
      String(describing: type(of: $0)).contains("TabRowButton")
    })
  // 底卡是行内唯一带圆角 layer 的子视图；行本体保持透明并维持整行命中宽度。
  let card = try #require(row.subviews.first { ($0.layer?.cornerRadius ?? 0) > 0 })
  #expect(card.frame.minX == 8)
  #expect(card.frame.maxX == row.bounds.width - 8)
  #expect(card.frame.height < row.bounds.height)
  #expect((card.layer?.cornerRadius ?? 0) >= 8)
  #expect(row.layer?.backgroundColor?.alpha == 0)
}

@Test("Floating Card 的 Inspector 与终端共用容器，Sidebar 保留单边 padding")
@MainActor
func floatingCardKeepsInspectorInsideContainerAndUsesAsymmetricSidebarPadding() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let theme = try #require(TerminalThemeCatalog.theme(named: "Floating Card"))
  preferences.selectTheme(theme)
  preferences.tabBarLayout = .vertical
  preferences.sidebarTabGrouping = .project
  preferences.inspectorPresented = true
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: ["/tmp/floating-card"]
  )
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let container = try #require(
    controller.view.descendants.first {
      $0.identifier?.rawValue == "workspace-container"
    })
  let details = try #require(
    controller.view.descendants.first {
      $0.identifier?.rawValue == "workspace-details-panel"
    } as? ThemeSurfaceView)
  #expect(details.isDescendant(of: container))
  #expect(details.appliedThemeTint == theme.resolvedColor(forSlot: "container.background"))
  let outerSplit = try #require(
    controller.view.descendants.compactMap { $0 as? WorkspacePanelSplitView }
      .first { $0.panelRoles.contains(.sidebar) })
  #expect(outerSplit.themeDividerColor.alphaComponent == 0)

  let row = try #require(controller.view.descendants.compactMap { $0 as? TabRowButton }.first)
  let decoration = try #require(row.descendants.first {
    $0.identifier?.rawValue.hasPrefix("workspace-tab-background-") == true
  })
  #expect(abs(decoration.frame.minX - 8) < 0.5)
  #expect(abs(decoration.frame.maxX - row.bounds.maxX) < 0.5)

  let group = try #require(
    controller.view.descendants.first {
      $0.identifier?.rawValue == "sidebar-group-header"
    } as? NSTextField)
  #expect(
    HexColor(nsColor: group.textColor ?? .clear)
      == theme.resolvedColor(forSlot: "tab.foreground")
  )
}

@Test("暗色主题的 File Pane 工具栏使用 Container 表面")
@MainActor
func darkThemeFilePaneChromeUsesContainerSurface() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let theme = try #require(TerminalThemeCatalog.theme(named: "Tokyo Night"))
  preferences.selectTheme(theme)
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: ["/tmp/dark-file-pane"]
  )
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let toolbar = try #require(controller.view.descendants.first {
    $0.identifier?.rawValue == "file-pane-toolbar"
  })
  let rendered = toolbar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map {
    HexColor(nsColor: $0)
  }
  #expect(rendered == theme.resolvedColor(forSlot: "container.background"))
}

@Test("暗色工作区在自身 appearance 下解析 Pane layer 动态色")
@MainActor
func darkWorkspaceResolvesPaneLayerColorsInItsOwnAppearance() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let theme = try #require(TerminalThemeCatalog.theme(named: "Tokyo Night"))
  preferences.selectTheme(theme)
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: ["/tmp/dark-findbar"]
  )
  model.isFindPresented = true
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let findBar = try #require(controller.view.descendants.first {
    $0.identifier?.rawValue == "workspace-findbar"
  })
  let rendered = findBar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map {
    HexColor(nsColor: $0)
  }
  #expect(rendered == theme.resolvedColor(forSlot: "panel.surface"))
}

@Test("左侧标签悬停显示关闭按钮且可直接关闭后台标签")
@MainActor
func verticalSidebarHoverCloseClosesTargetTabWithoutSelectingIt() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: [NSHomeDirectory(), "/tmp"]
  )
  let preferences = AppPreferences(defaults: defaults)
  let selectedTabID = try #require(model.selectedTabID)
  let backgroundTab = try #require(model.tabs.first { $0.id != selectedTabID })
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let closeButton = try #require(
    controller.view.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "sidebar-tab-close-\(backgroundTab.id.uuidString)"
    })
  let tabRow = try #require(closeButton.superview?.superview as? NSButton)
  #expect(closeButton.isHidden)

  let hoverEvent = try #require(NSEvent.mouseEvent(
    with: .mouseMoved,
    location: tabRow.convert(
      NSPoint(x: tabRow.bounds.midX, y: tabRow.bounds.midY), to: nil),
    modifierFlags: [],
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    eventNumber: 1,
    clickCount: 0,
    pressure: 0
  ))
  tabRow.mouseEntered(with: hoverEvent)
  #expect(closeButton.isHidden == false)

  closeButton.performClick(nil)

  #expect(model.tabs.contains { $0.id == backgroundTab.id } == false)
  #expect(model.selectedTabID == selectedTabID)
}

@Test("左侧标签行首覆盖运行、等待、错误与空闲状态，选中行完成态回落到 Agent 图标")
@MainActor
func verticalSidebarActivityAccessoryTracksAllStates() async throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.agents.badgeProcessing = true
  preferences.configuration.agents.badgeAwaitingInput = true
  preferences.configuration.agents.badgeTaskComplete = true
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing)
  )
  try await Task.sleep(for: .milliseconds(50))
  #expect(try visibleTabAccessory(for: tab, in: controller) is TabActivitySpinnerView)
  let lifecycleRow = try tabRow(for: tab, in: controller)

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .awaitingInput)
  )
  try await Task.sleep(for: .milliseconds(50))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller) as? NSTextField)?.stringValue == "✋"
  )
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalUserInput?()
  try await Task.sleep(for: .milliseconds(50))
  #expect(try visibleTabAccessory(for: tab, in: controller) is TabActivitySpinnerView)
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle)
  )
  try await Task.sleep(for: .milliseconds(50))
  // 选中行正被注视，「未读 ●」让位给 Agent 静态图标（对齐 Otty）。
  #expect(try visibleTabAccessory(for: tab, in: controller) is NSImageView)
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalUserInput?()
  try await Task.sleep(for: .milliseconds(50))
  #expect((try visibleTabAccessory(for: tab, in: controller) as? NSTextField)?.stringValue != "●")
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalBadgeDirective?(.set(.completed))
  try await Task.sleep(for: .milliseconds(50))
  // 同上：选中行的「刚完成 ✓」也回落到 Agent 图标。
  #expect(try visibleTabAccessory(for: tab, in: controller) is NSImageView)
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalBadgeDirective?(.set(.error))
  try await Task.sleep(for: .milliseconds(50))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller) as? NSTextField)?.stringValue == "!"
  )
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalBadgeDirective?(.clear)
  try await Task.sleep(for: .milliseconds(50))
  // idle 时左侧槽显示 Agent 图标（codex → openai），不再是任何状态字符。
  let idleAccessory = try visibleTabAccessory(for: tab, in: controller)
  #expect(idleAccessory is NSImageView)
  #expect(!["✋", "●", "✓", "!"].contains((idleAccessory as? NSTextField)?.stringValue ?? ""))
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)
}

/// 普通命令（无 Agent、无显式徽章）只在失败时占用状态槽：成功收尾不画 ● / ✓，
/// 否则每跑一条脚本行前都多一个与用户无关的符号。
@Test("无 Agent 的普通命令只在失败时显示状态徽章")
@MainActor
func ordinaryCommandBadgeShowsOnlyFailure() async throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  terminalView.dataReceived(
    slice: Array(
      "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}true\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}".utf8)[...])
  try await Task.sleep(for: .milliseconds(80))

  // 标签级徽章确实进入了完成态；被拦掉的是视图层的渲染，不是聚合逻辑。
  #expect(session.activeAgentProvider == nil)
  #expect(session.lastCommandExitStatus == 0)
  #expect([TerminalBadgeState.completed, .finished].contains(tab.activityBadge))
  let successStates = visibleTabAccessoryStates(for: tab, in: controller)
  #expect(!successStates.contains("finished"))
  #expect(!successStates.contains("completed"))
  #expect(!successStates.contains("error"))
  #expect(!successStates.contains("awaiting-input"))

  terminalView.dataReceived(
    slice: Array(
      "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}false\r\n\u{1B}]133;C\u{7}\u{1B}]133;D;1\u{7}".utf8)[...])
  try await Task.sleep(for: .milliseconds(80))

  #expect(tab.activityBadge == .error)
  #expect(visibleTabAccessoryStates(for: tab, in: controller).contains("error"))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller) as? NSTextField)?.stringValue == "1"
  )
}

/// 收集当前可见状态槽的 state 名（`sidebar-tab-status-<id>-<state>` 的后缀）。断言
/// 「某状态不存在」必须看全部匹配视图，否则纵横两条标签栏里任意一条命中都会漏判。
@MainActor
private func visibleTabAccessoryStates(
  for tab: TerminalTabItem,
  in controller: WorkspaceViewController
) -> [String] {
  let prefix = "sidebar-tab-status-\(tab.id.uuidString)-"
  return controller.view.descendants.compactMap { view in
    guard let raw = view.identifier?.rawValue, raw.hasPrefix(prefix), !view.isHidden else {
      return nil
    }
    return String(raw.dropFirst(prefix.count))
  }
}

/// 状态附件按 `sidebar-tab-status-<id>-<state>` 标识查找（纵向行在标题左侧，横向在右侧），
/// 只读取当前可见附件，测试不依赖具体槽位布局，同时仍覆盖用户看到的状态变化。
@MainActor
private func visibleTabAccessory(
  for tab: TerminalTabItem,
  in controller: WorkspaceViewController
) throws -> NSView {
  let prefix = "sidebar-tab-status-\(tab.id.uuidString)-"
  return try #require(
    controller.view.descendants.first {
      ($0.identifier?.rawValue ?? "").hasPrefix(prefix) && !$0.isHidden
    }
  )
}

@MainActor
private func tabRow(
  for tab: TerminalTabItem,
  in controller: WorkspaceViewController
) throws -> TabRowButton {
  try #require(
    controller.view.descendants.compactMap { $0 as? TabRowButton }.first {
      $0.identifier?.rawValue == "workspace-tab-row-\(tab.id.uuidString)"
    }
  )
}

@Test("终端工作区不再渲染底部状态栏")
@MainActor
func terminalWorkspaceOmitsBottomStatusBar() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: [NSHomeDirectory()])
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.appearance.showStatusBar = true
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let labels = controller.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(labels.contains { $0.contains("●  workspace") } == false)
  #expect(labels.contains { $0.contains("UTF-8") } == false)

  let settings = SettingsViewController(preferences: preferences)
  settings.loadViewIfNeeded()
  let settingLabels = settings.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(settingLabels.contains("显示状态栏") == false)
}

@Test("折叠标签栏后顶部提供悬停恢复入口")
@MainActor
func collapsedTabBarOffersHoverRecovery() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  // 折叠标签栏：内容区顶部应叠加「+ 新建 / 展开」悬停动作区与点击穿透的悬停带。
  preferences.configuration.appearance.showTabBar = false
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let buttons = controller.view.descendants.compactMap { $0 as? NSButton }
  let addButton = try #require(buttons.first { $0.toolTip == "新建标签页" })
  let expandButton = try #require(buttons.first { $0.toolTip == "展开标签栏" })
  // 默认隐藏（悬停才淡入）；折叠态两个按钮共用同一条顶部悬停带，同时显隐。
  #expect(addButton.isHidden && addButton.alphaValue == 0)
  #expect(expandButton.isHidden && expandButton.alphaValue == 0)
  // 按钮行必须让开红绿灯遮挡区（实测约 103pt）。
  let row = try #require(addButton.superview)
  #expect(row === expandButton.superview)
  #expect(row.frame.minX >= 104)
  // 悬停带点击穿透：不拦截下方终端的点击与拖选。
  let strip = controller.view.descendants.first {
    String(describing: type(of: $0)).contains("ClickThroughStripView")
  }
  #expect(strip != nil)
  #expect(strip?.hitTest(.zero) == nil)
}

@Test("工作区中央标题与 Pane 共用同一背景面并在悬停时显示路径胶囊")
@MainActor
func workspaceTitlebarMatchesOttyChrome() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: ["/Users/mike/source/project/AsterTerminal"]
  )
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let glass = try #require(
    preferences.themes(for: .light).first { $0.name == "Glass Light" })
  preferences.selectTheme(glass)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let titlebar = controller.view.descendants.first {
    $0.identifier?.rawValue == "workspace-titlebar"
  }
  let titleButton = try #require(
    titlebar?.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "workspace-title-button"
    }
  )
  #expect(titlebar != nil)
  #expect(abs((titlebar?.frame.height ?? 0) - 28) < 0.5)
  let titlebarForeground = try #require(
    preferences.activeTheme.colorSlots.first { $0.id == "titlebar.foreground" }
  ).resolved
  // 标题只是中央 workspace 背景面上的内容，不能再建立一层独立 material；否则透明
  // 主题会在 28pt 高度处重复合成玻璃，和下面的 Pane 形成明显横向分割。
  #expect(titlebar is ThemeVisualEffectView == false)
  #expect(titlebar?.layer?.backgroundColor == NSColor.clear.cgColor)
  // `none` 是真实透明语义，不允许再用截图采样出的灰色替代。
  #expect(
    HexColor(nsColor: preferences.terminalCanvasBackgroundColor)
      == preferences.activeTheme.palette.windowBackground)
  #expect(HexColor(nsColor: titleButton.contentTintColor ?? .clear) == titlebarForeground)
  let explicitTitlebarBackground = preferences.activeTheme.style.titlebarBackground
    .map { NSColor($0).cgColor }
  #expect(
    titleButton.layer?.backgroundColor
      == (explicitTitlebarBackground ?? NSColor.clear.cgColor)
  )
  #expect(titleButton.title.contains("AsterTerminal"))
  #expect(titleButton.title.hasSuffix("⋯"))

  let hover = try #require(
    NSEvent.mouseEvent(
      // `NSEvent.mouseEvent` 只能构造鼠标按钮/移动事件；直接调用 mouseEntered 时使用
      // 同坐标的 mouseMoved 即可，避免 AppKit 因伪造 tracking 事件抛异常。
      with: .mouseMoved,
      location: titleButton.convert(
        NSPoint(x: titleButton.bounds.midX, y: titleButton.bounds.midY), to: nil),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 0,
      pressure: 0
    )
  )
  titleButton.mouseEntered(with: hover)
  #expect(titleButton.title.contains("AsterTerminal"))
  #expect(titleButton.title.hasSuffix("⋯"))
  #expect(titleButton.layer?.backgroundColor != NSColor.clear.cgColor)
  #expect(HexColor(nsColor: titleButton.contentTintColor ?? .clear) == titlebarForeground)
}

@Test("主题详情改色写回对应 Otty 配置，清空覆盖会移除个性化段")
@MainActor
func themeColorOverridesPersistToOttyThemeFile() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let sourceURL = directory.appendingPathComponent("ayu-light.astertheme")
  let original = "[meta]\nname = \"Ayu Light\"\n\n[terminal]\nbackground = \"#FCFCFC\"\n"
  try original.write(to: sourceURL, atomically: true, encoding: .utf8)

  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults, themesDirectoryURL: directory)
  let theme = try #require(TerminalThemeCatalog.theme(named: "Ayu Light"))
  preferences.setThemeColor(
    try #require(HexColor("#123456")), slotID: "sidebar.background", themeID: theme.id)

  let writtenURL = try #require(
    try preferences.writeThemeOverridesToLibraryFolder(themeID: theme.id))
  #expect(writtenURL == sourceURL)
  let personalized = try String(contentsOf: sourceURL, encoding: .utf8)
  #expect(personalized.hasPrefix(original.trimmingCharacters(in: .newlines)))
  #expect(personalized.contains(ThemeOverrideFileWriter.marker))
  #expect(personalized.contains("# aster-added: sidebar.background"))
  #expect(personalized.contains("background = \"#123456\""))

  preferences.clearThemeOverrides(themeID: theme.id)
  let resetURL = try #require(
    try preferences.writeThemeOverridesToLibraryFolder(themeID: theme.id))
  #expect(resetURL == sourceURL)
  #expect(
    try String(contentsOf: sourceURL, encoding: .utf8)
      == original.trimmingCharacters(in: .newlines) + "\n")
}

@Test("点击标题路径胶囊弹出可操作的工作区菜单")
@MainActor
func workspaceTitlePopoverExposesWorkingActions() throws {
  let defaults = isolatedDefaults()
  let directory = "/Users/mike/source/project/AsterTerminal"
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: [directory])
  let preferences = AppPreferences(defaults: defaults)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  defer { window.orderOut(nil) }
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()

  let titleButton = try #require(
    controller.view.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "workspace-title-button"
    }
  )
  titleButton.performClick(nil)
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))

  let popover = try #require(
    NSApp.windows.compactMap(\.contentView).first {
      $0.identifier?.rawValue == "workspace-title-popover"
        || $0.descendants.contains {
          $0.identifier?.rawValue == "workspace-title-popover"
        }
    }
  )
  let root = popover.identifier?.rawValue == "workspace-title-popover"
    ? popover
    : try #require(popover.descendants.first {
      $0.identifier?.rawValue == "workspace-title-popover"
    })
  let labels = root.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  let buttons = root.descendants.compactMap { $0 as? NSButton }
  #expect(labels.contains("WORKING DIRECTORY"))
  #expect(labels.contains((directory as NSString).abbreviatingWithTildeInPath + "/"))
  for identifier in [
    "workspace-title-copy-path", "workspace-title-reveal-finder", "workspace-title-open-in",
    "workspace-title-git", "workspace-title-notifications", "workspace-title-split",
    "workspace-title-find", "workspace-title-global-find", "workspace-title-jump",
    "workspace-title-palette",
  ] {
    #expect(buttons.contains { $0.identifier?.rawValue == identifier }, "缺少动作：\(identifier)")
  }

  let mode = try #require(root.descendants.compactMap { $0 as? NSSegmentedControl }.first)
  let field = try #require(root.descendants.compactMap { $0 as? NSTextField }.first {
    $0.identifier?.rawValue == "workspace-title-name-field"
  })
  mode.selectedSegment = 1
  _ = NSApp.sendAction(try #require(mode.action), to: mode.target, from: mode)
  field.stringValue = "dev: "
  _ = NSApp.sendAction(try #require(field.action), to: field.target, from: field)
  #expect(model.selectedTab?.tabTitleOverride == .prefix("dev: "))

  let reset = try #require(buttons.first {
    $0.identifier?.rawValue == "workspace-title-reset-name"
  })
  reset.performClick(nil)
  #expect(model.selectedTab?.tabTitleOverride == .automatic)

  let find = try #require(buttons.first { $0.identifier?.rawValue == "workspace-title-find" })
  find.performClick(nil)
  #expect(model.isFindPresented)
  let global = try #require(buttons.first {
    $0.identifier?.rawValue == "workspace-title-global-find"
  })
  global.performClick(nil)
  #expect(model.isGlobalFindPresented)
  let jump = try #require(buttons.first { $0.identifier?.rawValue == "workspace-title-jump" })
  jump.performClick(nil)
  #expect(model.isOpenQuicklyPresented)
  let palette = try #require(buttons.first {
    $0.identifier?.rawValue == "workspace-title-palette"
  })
  palette.performClick(nil)
  #expect(model.isPalettePresented)
}

@Test("TABS 标题使用截图一致的原生标签整理菜单按钮")
@MainActor
func sidebarProvidesNativeTabOrganizerMenu() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: [NSHomeDirectory()])
  let preferences = AppPreferences(defaults: defaults)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let organizer = try #require(controller.view.descendants.compactMap { $0 as? NSButton }.first {
    $0.toolTip == "整理标签"
  })
  #expect(String(describing: type(of: organizer)).contains("SidebarOptionsButton"))
  #expect(organizer.image?.accessibilityDescription == "整理标签")

  let menu = try #require(organizer.menu)
  #expect(
    menu.items.map(\.title) == [
      "GROUP", "No Grouping", "By Project", "By Date", "",
      "ORDER", "Created Time", "Updated Time", "",
      "DIVIDER", "Insert Divider", "Remove All Dividers",
    ]
  )
  #expect(menu.item(withTitle: "No Grouping")?.state == .on)
  #expect(menu.item(withTitle: "Created Time")?.state == .on)
  #expect(menu.item(withTitle: "By Project")?.image != nil)
  #expect(menu.item(withTitle: "Insert Divider")?.image != nil)
}

@Test("标签整理菜单会持久切换勾选项并管理分隔线")
@MainActor
func sidebarOrganizerMenuActionsUpdateListState() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: [NSHomeDirectory()])
  let preferences = AppPreferences(defaults: defaults)
  var controller = WorkspaceViewController(model: model, preferences: preferences)
  var window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  func rebuildWorkspace() {
    controller = WorkspaceViewController(model: model, preferences: preferences)
    window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  }

  func currentMenu() throws -> NSMenu {
    window.contentView?.layoutSubtreeIfNeeded()
    let button = try #require(controller.view.descendants.compactMap { $0 as? NSButton }.first {
      $0.toolTip == "整理标签"
    })
    return try #require(button.menu)
  }

  func perform(_ title: String, in menu: NSMenu) {
    let index = menu.indexOfItem(withTitle: title)
    #expect(index >= 0)
    guard index >= 0 else { return }
    let item = menu.items[index]
    let action = item.action
    #expect(action != nil)
    if let action {
      #expect(NSApp.sendAction(action, to: item.target, from: item))
    }
  }

  var menu = try currentMenu()
  perform("By Project", in: menu)
  #expect(preferences.sidebarTabGrouping == .project)
  rebuildWorkspace()
  menu = try currentMenu()
  #expect(menu.item(withTitle: "By Project")?.state == .on)
  #expect(menu.item(withTitle: "No Grouping")?.state == .off)

  perform("Updated Time", in: menu)
  #expect(preferences.sidebarTabOrder == .updatedTime)
  rebuildWorkspace()
  menu = try currentMenu()
  #expect(menu.item(withTitle: "Updated Time")?.state == .on)
  #expect(menu.item(withTitle: "Created Time")?.state == .off)

  perform("Insert Divider", in: menu)
  #expect(model.dividerAfterTabIDs.contains(model.selectedTabID!))
  rebuildWorkspace()
  #expect(controller.view.descendants.contains {
    $0.identifier?.rawValue == "sidebar-manual-divider"
  })

  let restoredPreferences = AppPreferences(defaults: defaults)
  #expect(restoredPreferences.sidebarTabGrouping == .project)
  #expect(restoredPreferences.sidebarTabOrder == .updatedTime)
  let restoredModel = AppModel(defaults: defaults)
  restoredModel.ensureInitialTab()
  #expect(restoredModel.dividerAfterTabIDs == model.dividerAfterTabIDs)

  menu = try currentMenu()
  perform("Remove All Dividers", in: menu)
  rebuildWorkspace()
  #expect(controller.view.descendants.contains {
    $0.identifier?.rawValue == "sidebar-manual-divider"
  } == false)
}

@Test("项目分组与时间排序会真实改变左侧标签列表")
@MainActor
func sidebarOrganizerAppliesGroupingAndOrdering() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: [NSHomeDirectory(), "/tmp"]
  )
  let preferences = AppPreferences(defaults: defaults)

  func makeController() -> WorkspaceViewController {
    let controller = WorkspaceViewController(model: model, preferences: preferences)
    let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()
    return controller
  }

  func primaryTabLabels(in controller: WorkspaceViewController) -> [String] {
    controller.view.descendants.compactMap { view -> NSButton? in
      guard String(describing: type(of: view)).contains("TabRowButton") else { return nil }
      return view as? NSButton
    }.compactMap { button in
      button.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first
    }
  }

  // 标签行选中与未选中都显示同一份 tab.title（目录稳定显示名），
  // 切换标签时主文案保持不变。
  preferences.sidebarTabGrouping = .none
  preferences.sidebarTabOrder = .createdTime
  var controller = makeController()
  #expect(primaryTabLabels(in: controller).first == "tmp")

  let oldestTab = try #require(model.tabs.first)
  model.select(oldestTab)
  preferences.sidebarTabOrder = .updatedTime
  controller = makeController()
  #expect(primaryTabLabels(in: controller).first == "mike")

  preferences.sidebarTabGrouping = .project
  controller = makeController()
  let groupHeaders = controller.view.descendants.compactMap { ($0 as? NSTextField) }.filter {
    $0.identifier?.rawValue == "sidebar-group-header"
  }.map(\.stringValue)
  // 项目分组只显示末级目录名；完整路径仍作为不可见 identity 防止同名目录并组。
  #expect(Set(groupHeaders) == Set(["~", "tmp"]))
  #expect(Set(primaryTabLabels(in: controller)) == Set(["~", "tmp"]))
}

/// 复现真机链路：点击整理菜单项后，同一个窗口（不重建控制器）必须经
/// objectWillChange → scheduleRefresh 自动刷新出分组标题；新建标签也不得
/// 把用户显式选择的时间排序偷偷改掉。
@Test("整理标签菜单点击后无需重建窗口即生效，且新建标签不重置排序")
@MainActor
func sidebarOrganizerMenuTakesEffectLiveAndOrderSurvivesNewTab() async throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: [NSHomeDirectory(), "/tmp"]
  )
  let preferences = AppPreferences(defaults: defaults)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  func organizerMenu() throws -> NSMenu {
    let button = try #require(controller.view.descendants.compactMap { $0 as? NSButton }.first {
      $0.toolTip == "整理标签"
    })
    return try #require(button.menu)
  }
  func groupHeaders() -> [String] {
    controller.view.descendants.compactMap { ($0 as? NSTextField) }.filter {
      $0.identifier?.rawValue == "sidebar-group-header"
    }.map(\.stringValue)
  }

  #expect(groupHeaders().isEmpty)
  var menu = try organizerMenu()
  let byProject = try #require(menu.item(withTitle: "By Project"))
  #expect(NSApp.sendAction(try #require(byProject.action), to: byProject.target, from: byProject))
  // scheduleRefresh 走主队列 async；让主 actor 排空队列后断言同一控制器已重建侧栏。
  try await Task.sleep(for: .milliseconds(80))
  #expect(Set(groupHeaders()) == Set(["~/", "/tmp/"]))

  menu = try organizerMenu()
  let updated = try #require(menu.item(withTitle: "Updated Time"))
  #expect(NSApp.sendAction(try #require(updated.action), to: updated.target, from: updated))
  try await Task.sleep(for: .milliseconds(80))
  #expect(preferences.sidebarTabOrder == .updatedTime)

  // 曾经 insertTab 会经 onTabOrderBecameManual 把排序改回 manual，导致设置一直“失效”。
  model.newTab(workingDirectory: "/tmp", hasContent: false)
  try await Task.sleep(for: .milliseconds(80))
  #expect(preferences.sidebarTabOrder == .updatedTime)
  #expect(AppPreferences(defaults: defaults).sidebarTabOrder == .updatedTime)

  // 设置窗口打开期间偏好通道会把结构刷新合并到关窗时；整理菜单是工作区直接交互，
  // 仍必须立即生效（真机上「点了没反应」的根因之一）。
  controller.setSettingsPresentationActive(true)
  menu = try organizerMenu()
  let noGrouping = try #require(menu.item(withTitle: "No Grouping"))
  #expect(NSApp.sendAction(try #require(noGrouping.action), to: noGrouping.target, from: noGrouping))
  try await Task.sleep(for: .milliseconds(80))
  #expect(groupHeaders().isEmpty)
  controller.setSettingsPresentationActive(false)
}

/// 旧版本会把 `aster.sidebar.tab-order.v1` 自动写成 manual（枚举值已删除）；
/// 载入时必须回落到默认 createdTime，而不是留下菜单里两项都不勾选的死状态。
@Test("历史遗留的 manual 排序值回落为按创建时间")
@MainActor
func legacyManualSidebarOrderFallsBackToCreatedTime() {
  let defaults = isolatedDefaults()
  defaults.set("manual", forKey: "aster.sidebar.tab-order.v1")
  #expect(AppPreferences(defaults: defaults).sidebarTabOrder == .createdTime)
}

@Test("OSC 7 文件 URL 会规范化为可恢复的本地目录")
@MainActor
func terminalNormalizesReportedWorkingDirectory() {
  #expect(
    TerminalSession.normalizeReportedWorkingDirectory(
      "file://localhost/Users/mike/source/project/dxtun"
    ) == "/Users/mike/source/project/dxtun"
  )
  #expect(TerminalSession.normalizeReportedWorkingDirectory("file:///tmp/Aster%20QA") == "/tmp/Aster QA")
  #expect(TerminalSession.normalizeReportedWorkingDirectory("/Users/mike") == "/Users/mike")
  #expect(
    TerminalSession.normalizeReportedWorkingDirectory("file://remote.example/home/mike") == "")
}

@Test("设置页从顶部开始并让导航与卡片占满可用宽度", .disabled("已迁移为网页布局，由 SettingsResponsivenessTests 覆盖"))
@MainActor
func settingsLayoutUsesTopAnchoredFullWidthRows() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  // setContentViewController 会把窗口收缩到控制器视图的 700×460 默认尺寸，
  // 断言按该尺寸（内容区 500pt、卡片约 448pt）计算。
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))

  window.contentView?.layoutSubtreeIfNeeded()

  let sidebarButtons = controller.view.descendants.compactMap { view -> NSButton? in
    guard String(describing: type(of: view)).contains("SettingsSidebarButton") else { return nil }
    return view as? NSButton
  }
  let contentScroll = try #require(controller.view.descendants.compactMap { $0 as? NSScrollView }.first)
  let cards = controller.view.descendants.filter {
    $0 is NSStackView
      && abs(($0.layer?.cornerRadius ?? 0) - SettingsMetrics.cardCornerRadius) < 0.1
  }
  let contentDocument = try #require(contentScroll.documentView)
  // 只在内容滚动区内找分组标题：侧栏按钮内部也有「通用」文本，会干扰顶部锚定断言。
  let sectionTitle = try #require(
    contentDocument.descendants.compactMap { $0 as? NSTextField }.first { $0.stringValue == "通用" }
  )
  let sectionTitleFrame = sectionTitle.convert(sectionTitle.bounds, to: controller.view)
  let contentDocumentType = String(describing: type(of: contentDocument))
  #expect(sidebarButtons.count == 9)
  #expect(sidebarButtons.allSatisfy { $0.frame.width >= 170 })
  #expect(contentScroll.documentView?.isFlipped == true)
  #expect(contentDocumentType.contains("FlippedDocumentView"))
  #expect((cards.first?.frame.width ?? 0) >= 430)
  // 顶部锚定：分组标题需位于窗口顶部约 70pt 内（460 - 自动内容内边距 - 26pt 边距）。
  #expect(sectionTitleFrame.maxY >= 390)
  // 卡片内不再画 1pt hairline 分隔线：行间只靠留白（Otty 风格视觉决策的回归锁）。
  let firstCard = try #require(cards.first as? NSStackView)
  #expect(firstCard.arrangedSubviews.allSatisfy { $0.frame.height > 1 })
}

@Test("外观设置的主题网格每行放四张等宽卡片", .disabled("已迁移为网页布局，由 SettingsResponsivenessTests 覆盖"))
@MainActor
func appearanceThemeGridUsesFourEqualColumns() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()

  let cards = controller.view.descendants.filter {
    String(describing: type(of: $0)).contains("ThemeCardButton")
  }
  #expect(cards.count >= 8)
  // 同一行的卡片共用一个父视图（等分行栈）；行内张数与宽度都要一致。
  let rows = Dictionary(grouping: cards) { ObjectIdentifier($0.superview ?? $0) }
  let fullRows = rows.values.filter { $0.count == 4 }
  #expect(fullRows.count >= 2)
  #expect(rows.values.allSatisfy { $0.count <= 4 })
  for row in fullRows {
    let widths = row.map(\.frame.width)
    // fillEqually 在宽度不能整除时会把余数分给个别列，允许 1pt 的取整差。
    #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1.0)
    // 700pt 窗口下内容区约 448pt，四等分后单卡仍需保持可读宽度。
    #expect((widths.first ?? 0) >= 84)
  }
}

@Test("设置页配色不跟随终端主题，卡片使用固定灰底", .disabled("已迁移为网页布局，由 SettingsResponsivenessTests 覆盖"))
@MainActor
func settingsChromeIgnoresTerminalTheme() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  window.contentView?.layoutSubtreeIfNeeded()

  func cardColors() -> [NSColor] {
    controller.view.descendants
      .filter { abs(($0.layer?.cornerRadius ?? 0) - SettingsMetrics.cardCornerRadius) < 0.1 }
      .compactMap { $0.layer?.backgroundColor }
      .map { NSColor(cgColor: $0) ?? .clear }
  }
  let before = cardColors()
  #expect(!before.isEmpty)

  // 浅色外观下卡片就是 #FAFAFA。
  let expected = SettingsTheme.card.usingColorSpace(.sRGB)
  controller.view.appearance = NSAppearance(named: .aqua)
  let sample = try #require(cardColors().first?.usingColorSpace(.sRGB))
  #expect(abs(sample.redComponent - (expected?.redComponent ?? 0)) < 0.01)

  // 把当前主题换成一套完全不同的配色，设置页的卡片底色不得跟着变。
  preferences.selectTheme(
    TerminalThemeCatalog.resolve(named: "Catppuccin Mocha", customThemes: [], mode: .dark))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(cardColors() == before)
}

@Test("色板改色写成覆盖层，内置主题不被复制成副本", .disabled("原生色板已由网页主题选择器替代"))
@MainActor
func themeSwatchColorPickWritesOverrideWithoutDuplicating() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  // `activeTheme` 在 appearance == .system 时会读 `NSApp.effectiveAppearance`，
  // 测试进程里必须先把 NSApplication 实例化，否则隐式解包直接崩。
  _ = NSApplication.shared
  let builtIn = preferences.activeTheme
  #expect(builtIn.isBuiltIn)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()

  let swatch = try #require(
    controller.view.descendants.first {
      $0.identifier?.rawValue == "theme-slot-interface.window"
    } as? NSControl)
  swatch.mouseDown(with: makeClickEvent(in: window))

  let picker = try #require(
    controller.presentedViewControllers?.compactMap { $0 as? InlineColorPickerViewController }
      .first)
  let hexField = try #require(
    picker.view.descendants.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "inline-color-picker-hex"
    })
  // 真实输入会先触发 textDidChange；取色器据此区分「用户敲的」与「程序回写的」。
  hexField.stringValue = "#123456"
  NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: hexField)
  NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: hexField)

  // 改色只写覆盖表：主题库里不该多出「副本」，内置主题也仍然是内置的。
  #expect(preferences.themeLibrary.customThemes.isEmpty)
  #expect(preferences.themeOverrides(for: builtIn.id)["interface.window"]?.displayString == "#123456")
  #expect(preferences.activeTheme.palette.interfaceWindowBackground?.displayString == "#123456")
  #expect(preferences.activeTheme.id == builtIn.id)
  // 回归锁：`updateTheme` 广播会触发整页重建，销毁 popover 锚点后取色目标被清空、
  // 后续改色全部丢失——表现就是「调完颜色关掉，值没设置上」。色板视图实例不变即
  // 说明取色期间没有重建。
  let swatchAfterPick = controller.view.descendants.first {
    $0.identifier?.rawValue == "theme-slot-interface.window"
  }
  #expect(swatchAfterPick === swatch)

  // 撤销覆盖后完整回到内置主题的原始配色。
  preferences.clearThemeOverrides(themeID: builtIn.id)
  #expect(
    preferences.activeTheme.palette.interfaceWindowBackground
      == builtIn.palette.interfaceWindowBackground)
}

@Test("主题详情渲染出可点可悬停的完整 token 色板", .disabled("原生主题详情已由网页主题选择器替代"))
@MainActor
func appearanceThemeDetailRendersFullColorSlotBoard() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()

  let expected = preferences.activeTheme.colorSlots
  let swatches = controller.view.descendants.filter {
    $0.identifier?.rawValue.hasPrefix("theme-slot-") == true
  }
  // 色板逐个渲染领域层给出的 token，不在界面里另立一套清单。
  #expect(swatches.count == expected.count)
  for slot in expected {
    let swatch = try #require(
      swatches.first { $0.identifier?.rawValue == "theme-slot-\(slot.id)" })
    // hover 提示带 token 名与色值，用户能照着改 .astertheme 文件。
    #expect(swatch.toolTip == slot.tooltip)
    #expect(swatch.toolTip?.contains(slot.id) == true)
  }
  // 分组名比普通行文案小两号，色块才是这块的主角。只在胶囊内部找，避免匹配到
  // 「光标」「选区」这类同名的分组小标题。
  let capsules = controller.view.descendants.filter {
    String(describing: type(of: $0)).contains("ThemeColorGroupCapsule")
  }
  #expect(capsules.count == ThemeColorGroup.allCases.count - 1)  // terminal 组画在顶部，不出胶囊
  let groupLabels = capsules.flatMap { $0.descendants.compactMap { $0 as? NSTextField } }
  #expect(groupLabels.count == capsules.count)
  #expect(groupLabels.allSatisfy { ($0.font?.pointSize ?? 0) == 10 })
  // 派生态必须能从 tooltip 区分出来，否则看不出「改 window 会不会连带变」。
  #expect(expected.contains { $0.isDerived })
  #expect(
    swatches.contains { $0.toolTip?.contains("跟随 Window 派生") == true })
}

@Test("设置页每个顶层区块在窄窗口与宽窗口下都保持左右边距", .disabled("已迁移为 CSS 响应式布局"))
@MainActor
func settingsTopLevelBlocksKeepInsetsAtEverySize() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))

  // 回归锁：以前只有 card / 分组标题有显式边距约束，其余顶层项（主题网格、主题详情、
  // 字体块、布局选择行）靠 NSStackView 的 .width 对齐。窗口放大后它们会缩成固有宽度
  // 并靠右，窄窗口下又会丢掉左边距——两种尺寸都要锁。
  for width in [700.0, 940.0, 1_400.0] as [CGFloat] {
    window.setContentSize(NSSize(width: width, height: 900))
    for section in SettingsViewController.Section.allCases {
      controller.showSection(section)
      window.contentView?.layoutSubtreeIfNeeded()
      let scroll = try #require(controller.view.descendants.compactMap { $0 as? NSScrollView }.first)
      let content = try #require(scroll.documentView?.subviews.first as? NSStackView)
      let expectedWidth = content.frame.width - content.edgeInsets.left - content.edgeInsets.right
      for item in content.arrangedSubviews {
        // 约束作用在 alignment rect 上：NSTextField 的 frame 比它每边宽 2pt，
        // 直接比 frame 会把正常的标题误判成越界。
        let box = item.alignmentRect(forFrame: item.frame)
        #expect(
          abs(box.minX - content.edgeInsets.left) < 0.5,
          "\(section.rawValue) @\(Int(width)) 顶层项左边距异常：\(box)")
        #expect(
          abs(box.width - expectedWidth) < 0.5,
          "\(section.rawValue) @\(Int(width)) 顶层项宽度异常：\(box)")
      }
    }
  }
}

@Test("设置页所有分类的卡片保持左右边距且占满内容宽度", .disabled("已迁移为 CSS 响应式布局"))
@MainActor
func settingsCardsKeepHorizontalInsetsAcrossSections() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))

  // 回归锁：长说明文字的单行固有宽度可能超过内容区可用宽度，NSStackView 的
  // .width 对齐 + edgeInsets 会把这种卡片丢到 x=0、宽度异常（系统集成卡片曾
  // 因此贴到内容区左边缘）。修复 = 对卡片施加显式 required 边距约束。
  for section in SettingsViewController.Section.allCases {
    controller.showSection(section)
    window.contentView?.layoutSubtreeIfNeeded()
    let scroll = try #require(controller.view.descendants.compactMap { $0 as? NSScrollView }.first)
    let content = try #require(scroll.documentView?.subviews.first as? NSStackView)
    let expectedWidth = content.frame.width - content.edgeInsets.left - content.edgeInsets.right
    let cards = content.arrangedSubviews.filter {
      $0 is NSStackView
        && abs(($0.layer?.cornerRadius ?? 0) - SettingsMetrics.cardCornerRadius) < 0.1
    }
    #expect(!cards.isEmpty)
    for card in cards {
      #expect(abs(card.frame.minX - content.edgeInsets.left) < 0.5, "\(section.rawValue) 页卡片左边距异常：\(card.frame)")
      #expect(abs(card.frame.width - expectedWidth) < 0.5, "\(section.rawValue) 页卡片宽度异常：\(card.frame)")
    }
  }
}

@Test("设置分类页由真实可交互控件构成而非只读文字", .disabled("交互控件现由网页清单生成"))
@MainActor
func settingsSectionsExposeInteractiveControls() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 940, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  // 每个分类页的最少开关/下拉数量来自字段接线映射表，防止页面回退成 infoRow 文案。
  let expectations: [(SettingsViewController.Section, Int, Int)] = [
    (.general, 2, 5),
    (.shell, 10, 0),
    (.controls, 9, 0),
    (.editor, 6, 0),
    (.agents, 10, 0),
    (.appearance, 6, 10),
    (.recipes, 0, 1),
  ]
  for (section, minSwitches, minPopups) in expectations {
    controller.showSection(section)
    let switches = controller.view.descendants.count(where: { $0 is NSSwitch })
    let popups = controller.view.descendants.count(where: { $0 is NSPopUpButton })
    #expect(switches >= minSwitches, "\(section) 页开关数不足：\(switches) < \(minSwitches)")
    #expect(popups >= minPopups, "\(section) 页下拉数不足：\(popups) < \(minPopups)")
  }
}

@Test("设置开关点击后就地更新且不重建当前页面", .disabled("网页桥写入由 SettingsResponsivenessTests 覆盖"))
@MainActor
func settingsSwitchUpdatesInPlaceWithoutRebuildingPage() async throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  window.contentView?.layoutSubtreeIfNeeded()
  let originalSwitch = try #require(
    controller.view.descendants.compactMap { $0 as? NSSwitch }.first)

  originalSwitch.performClick(nil)
  // 设置页的配置订阅通过主队列合并刷新。等待队列排空后再检查控件身份，才能捕获
  // “点击后整页重建并销毁正在播放切换动画的 NSSwitch”这一真实卡顿路径。
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async { continuation.resume() }
  }

  #expect(preferences.configuration.general.quitAfterLastWindowClosed)
  #expect(controller.view.descendants.contains { $0 === originalSwitch })
}

@Test("设置内容区字号小于左侧导航字号", .disabled("字体层级现由 settings.css 维护"))
@MainActor
func settingsContentTypographyIsSmallerThanSidebarNavigation() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()

  let labels = controller.view.descendants.compactMap { $0 as? NSTextField }
  let sidebarLabel = try #require(labels.first { $0.stringValue == "智能体" })
  let rowTitle = try #require(labels.first { $0.stringValue == "语言" })
  let rowDetail = try #require(labels.first { $0.stringValue == "界面显示语言" })

  #expect(rowTitle.font?.pointSize == SettingsMetrics.rowTitleSize)
  #expect(rowDetail.font?.pointSize == SettingsMetrics.rowDetailSize)
  #expect((rowTitle.font?.pointSize ?? .greatestFiniteMagnitude) < (sidebarLabel.font?.pointSize ?? 0))
  #expect((rowDetail.font?.pointSize ?? .greatestFiniteMagnitude) < (rowTitle.font?.pointSize ?? 0))
}

@Test("设置页新接线字段写入配置后可从 UserDefaults 恢复")
@MainActor
func settingsWiredFieldsPersistAcrossRelaunch() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.general.closeTabConfirmation = .never
  preferences.configuration.shell.terminalBell = false
  preferences.configuration.controls.focusFollowsMouse = true
  preferences.configuration.controls.detectAllLinkSchemes = false
  preferences.configuration.controls.customLinkSchemes = ["codex"]
  preferences.configuration.controls.allowedNonStandardLinkSchemes = ["codex"]
  preferences.configuration.controls.shiftArrowSelection = false
  preferences.configuration.controls.clearSelectionOnTyping = false
  preferences.configuration.controls.scrollPastLastLine = .lastLineInMiddle
  preferences.configuration.controls.scrollPastFirstLine = .firstLineWithContent
  preferences.configuration.editor.tabSize = 6
  preferences.configuration.agents.enabledAgents = ["claude"]
  // 屏幕检测两个开关缺省为 nil（解析为开启）；显式关闭后必须能持久化回来。
  #expect(preferences.configuration.agents.resolvedScreenDetectionEnabled)
  #expect(preferences.configuration.agents.resolvedScreenDetectionOverridesHook)
  preferences.configuration.agents.screenDetectionEnabled = false
  preferences.configuration.agents.screenDetectionOverridesHook = false
  preferences.configuration.appearance.lineHeight = 1.5
  preferences.configuration.recipeReplayMode = .skip

  let reloaded = AppPreferences(defaults: defaults)
  #expect(reloaded.configuration.general.closeTabConfirmation == .never)
  #expect(reloaded.configuration.shell.terminalBell == false)
  #expect(reloaded.configuration.controls.focusFollowsMouse == true)
  #expect(reloaded.configuration.controls.resolvedLinkSchemePolicy == .custom(["codex"]))
  #expect(reloaded.configuration.controls.resolvedAllowedNonStandardLinkSchemes == ["codex"])
  #expect(!reloaded.configuration.controls.resolvedShiftArrowSelection)
  #expect(!reloaded.configuration.controls.resolvedClearSelectionOnTyping)
  #expect(reloaded.configuration.controls.resolvedScrollPastLastLine == .lastLineInMiddle)
  #expect(reloaded.configuration.controls.resolvedScrollPastFirstLine == .firstLineWithContent)
  #expect(reloaded.configuration.editor.tabSize == 6)
  #expect(reloaded.configuration.agents.enabledAgents == ["claude"])
  #expect(!reloaded.configuration.agents.resolvedScreenDetectionEnabled)
  #expect(!reloaded.configuration.agents.resolvedScreenDetectionOverridesHook)
  #expect(reloaded.configuration.appearance.lineHeight == 1.5)
  #expect(reloaded.configuration.recipeReplayMode == .skip)

  // 越界值在重新加载时经 normalized() 钳回合法范围。
  preferences.configuration.editor.tabSize = 99
  #expect(AppPreferences(defaults: defaults).configuration.editor.tabSize == 8)
}

@Test("外观设置覆盖主题光标颜色并应用不透明度")
@MainActor
func appearanceCursorOverridesThemeAndAppliesOpacity() throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  preferences.configuration.appearance.cursorColorOverride = HexColor("#102030")!
  preferences.configuration.appearance.cursorTextColorOverride = HexColor("#F0E0D0")!
  preferences.configuration.appearance.cursorOpacity = 0.5

  let cursor = try #require(preferences.cursorColor.usingColorSpace(.sRGB))
  let cursorText = try #require(preferences.cursorTextColor.usingColorSpace(.sRGB))

  #expect(abs(cursor.redComponent - (16.0 / 255.0)) < 0.001)
  #expect(abs(cursor.alphaComponent - 0.5) < 0.001)
  #expect(abs(cursorText.redComponent - (240.0 / 255.0)) < 0.001)
  #expect(abs(cursorText.alphaComponent - 1) < 0.001)
}

@Test("主题容器把 Otty 材质映射为原生视觉效果")
@MainActor
func themeMaterialUsesNativeVisualEffectView() throws {
  let glass = try #require(TerminalThemeCatalog.theme(named: "Glass Light"))
  let view = ThemeVisualEffectView()

  view.apply(material: glass.palette.material, tint: glass.palette.panelBackground)

  #expect(view.material == .hudWindow)
  #expect(view.blendingMode == .behindWindow)
  #expect(view.state == .active)
}

@Test("透明主题实时覆盖终端自身的旧 backing layer 背景")
@MainActor
func transparentThemeRefreshesTerminalBackingLayer() throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let glass = try #require(
    preferences.themes(for: .light).first { $0.name == "Glass Light" })
  preferences.selectTheme(glass)

  let session = TerminalSession(workingDirectory: "/tmp")
  let view = session.makeTerminalView(preferences: preferences)
  view.wantsLayer = true
  // SwiftTerm 的尺寸初始化会把当时的 native 背景写进 backing layer；模拟一个在主题
  // 切换前已经形成的黑底，确保 apply 不只更新绘制色，也会清掉旧 layer。
  view.layer?.backgroundColor = NSColor.black.cgColor

  session.apply(preferences: preferences)

  let backing = try #require(view.layer?.backgroundColor)
  let backingColor = try #require(NSColor(cgColor: backing))
  #expect(HexColor(nsColor: backingColor) == preferences.activeTheme.palette.windowBackground)
  #expect(
    HexColor(nsColor: view.nativeBackgroundColor)
      == preferences.activeTheme.palette.windowBackground)
}

@Test("菜单主题切换会同步刷新每个已运行终端 Pane")
@MainActor
func themePreviewRefreshesEveryRunningTerminalPane() async throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let solarized = try #require(
    preferences.themes(for: .light).first { $0.name == "Solarized Light" })
  let april = try #require(
    preferences.themes(for: .light).first { $0.name == "April" })
  preferences.selectTheme(solarized)

  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  model.splitSelectedTab(.right)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  preferences.previewTheme(april)
  try await Task.sleep(for: .milliseconds(50))
  window.contentView?.layoutSubtreeIfNeeded()

  let terminals = controller.view.descendants.compactMap { $0 as? AsterTerminalView }
  #expect(terminals.count == 2)
  for terminal in terminals {
    #expect(HexColor(nsColor: terminal.nativeBackgroundColor) == april.palette.windowBackground)
    let backing = try #require(terminal.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
    #expect(HexColor(nsColor: backing) == april.palette.windowBackground)
  }
}

@Test("显示菜单字号命令会刷新已经运行的终端字体")
@MainActor
func displayFontCommandsRefreshExistingTerminalViews() async throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()
  let terminal = try #require(
    controller.view.descendants.compactMap { $0 as? AsterTerminalView }.first)
  let initialSize = terminal.font.pointSize

  preferences.adjustFontSize(by: 1)
  try await Task.sleep(for: .milliseconds(50))

  #expect(terminal.font.pointSize == initialSize + 1)
}

@Test("Shell 异常退出会显示可恢复状态并重启同一 Pane")
@MainActor
func abnormalShellExitShowsRecoveryInsteadOfZombiePane() async throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()
  let originalTerminal = try #require(
    controller.view.descendants.compactMap { $0 as? AsterTerminalView }.first)

  // 使用真实登录 Shell 退出路径，而不是直接改 Session 标志。该路径覆盖 PTY 尾部输出、
  // waitpid 状态转换、工作区刷新和用户最终看到的 Pane，能稳定抓住“旧画面仍在但无法
  // 输入，也没有任何结束提示”的僵尸终端缺陷。
  session.send("exit 7")
  for _ in 0..<100 where session.statusIsRunning {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(!session.statusIsRunning)

  let overlayIdentifier = "terminal-ended-overlay-\(session.id.uuidString)"
  var endedOverlay: NSView?
  for _ in 0..<50 {
    window.contentView?.layoutSubtreeIfNeeded()
    endedOverlay = controller.view.descendants.first {
      $0.identifier?.rawValue == overlayIdentifier
    }
    if endedOverlay != nil { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let overlay = try #require(endedOverlay)
  let labels = overlay.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(labels.contains { $0.contains("Shell 异常退出") })
  #expect(labels.contains { $0.contains("状态码 7") })

  let restartIdentifier = "terminal-restart-shell-\(session.id.uuidString)"
  let restart = try #require(
    overlay.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == restartIdentifier
    })
  restart.performClick(nil)
  for _ in 0..<100 where !session.statusIsRunning {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.statusIsRunning)
  for _ in 0..<50 {
    window.contentView?.layoutSubtreeIfNeeded()
    if controller.view.descendants.contains(where: {
      $0.identifier?.rawValue == overlayIdentifier
    }) == false { break }
    try await Task.sleep(for: .milliseconds(20))
  }

  let restartedTerminal = try #require(
    controller.view.descendants.compactMap { $0 as? AsterTerminalView }.first)
  #expect(restartedTerminal !== originalTerminal)
  #expect(controller.view.descendants.contains {
    $0.identifier?.rawValue == overlayIdentifier
  } == false)

  // 模拟上一代输出总线/进程 monitor 在新 PTY 已启动后才送达的迟到通知。该通知必须
  // 按 View 身份被忽略，否则刚恢复的终端会再次落入“屏幕存在但输入无效”的僵尸状态。
  session.processTerminated(source: originalTerminal, exitCode: 9)
  try await Task.sleep(for: .milliseconds(20))
  #expect(session.statusIsRunning)
  #expect(session.lifecycleState == .running)

  let sentinel = "ASTER_RESTARTED_\(UUID().uuidString.prefix(8))"
  session.send("printf '\(sentinel)\\n'")
  for _ in 0..<100 where !session.textSnapshot().lines.contains(where: { $0.contains(sentinel) }) {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.textSnapshot().lines.contains { $0.contains(sentinel) })
}

@Test("手动安全键盘输入在工作区标题栏显示状态胶囊")
@MainActor
func workspaceShowsSecureInputIndicator() async throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  let coordinator = SecureInputCoordinator(
    enableSystemProtection: { true },
    disableSystemProtection: { true }
  )
  model.ensureInitialTab()
  let controller = WorkspaceViewController(
    model: model,
    preferences: preferences,
    secureInputCoordinator: coordinator
  )
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  func currentIndicator() -> NSView? {
    controller.view.descendants.first {
      $0.identifier?.rawValue == "workspace-secure-input-indicator"
    }
  }
  #expect(try #require(currentIndicator()).isHidden)

  coordinator.setManualRequest(active: true)
  await Task.yield()
  let activeIndicator = try #require(currentIndicator())
  #expect(!activeIndicator.isHidden)
  #expect(activeIndicator.layer?.backgroundColor == SecureInputIndicatorView.secureBackgroundColor.cgColor)
  let indicatorLabels = activeIndicator.descendants.compactMap {
    ($0 as? NSTextField)?.stringValue
  }
  #expect(indicatorLabels.contains("SECURE INPUT"))

  coordinator.setManualRequest(active: false)
  await Task.yield()
  #expect(try #require(currentIndicator()).isHidden)
}

@Suite("全部 Otty 主题呈现矩阵", .serialized)
@MainActor
struct AllThemeRenderParityTests {
  @Test("九套明亮和十五套黑暗主题的参数逐项到达最终工作区对象")
  func everyBuiltInThemeReachesRenderedWorkspaceObjects() throws {
    _ = NSApplication.shared
    let themes = TerminalThemeCatalog.builtIns
    #expect(themes.filter { $0.mode == .light }.count == 9)
    #expect(themes.filter { $0.mode == .dark }.count == 15)
    #expect(themes.count == 24)

    for theme in themes {
      try verifyVerticalWorkspace(theme)
      try verifyHorizontalWorkspace(theme)
    }
  }

  /// 竖直布局覆盖截图里的 Window、Container、Sidebar、Titlebar、Tab，以及终端、
  /// ANSI、光标和选区。右侧详情面板与左侧标签栏必须消费同一组 Sidebar token。
  private func verifyVerticalWorkspace(_ theme: TerminalTheme) throws {
    let defaults = isolatedDefaults()
    let preferences = AppPreferences(defaults: defaults)
    preferences.appearance = theme.mode == .dark ? .dark : .light
    preferences.selectTheme(theme)
    preferences.tabBarLayout = .vertical
    let activeTheme = preferences.activeTheme
    let model = try makeNonTerminalTestModel(
      defaults: defaults,
      directories: ["/tmp/theme-matrix-first", "/tmp/theme-matrix-selected"]
    )
    let controller = WorkspaceViewController(model: model, preferences: preferences)
    let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()

    let root = try #require(controller.view as? ThemeVisualEffectView)
    let windowColor = try slot("interface.window", in: activeTheme)
    #expect(root.appliedThemeTint == windowColor, "\(theme.name) Window")

    let sidebar = try themedView("workspace-sidebar", in: controller)
    // 详情控制器位于 Container 内层 split；单独加载其稳定根视图，可以直接验证
    // Pane surface 的主题归属而不把显隐转场时序引入颜色测试。
    let detailsController = DetailsPanelViewController(model: model, preferences: preferences)
    detailsController.loadViewIfNeeded()
    let details = try #require(detailsController.view as? ThemeSurfaceView)
    let sidebarColor = try slot("sidebar.background", in: activeTheme)
    #expect(sidebar.appliedThemeTint == sidebarColor, "\(theme.name) Sidebar")
    let detailsColor = try slot("container.background", in: activeTheme)
    #expect(details.appliedThemeTint == detailsColor, "\(theme.name) Details Pane")
    #expect(sidebar.appliedThemeMaterial == activeTheme.style.sidebarMaterial ?? activeTheme.palette.material)
    let sidebarEyebrow = try slot("interface.tertiaryForeground", in: activeTheme)
    let sidebarTitle = try #require(
      identifiedView("workspace-sidebar-foreground", in: controller) as? NSTextField
    )
    #expect(HexColor(nsColor: sidebarTitle.textColor ?? .clear) == sidebarEyebrow)
    let split = try #require(
      controller.view.descendants.compactMap { $0 as? WorkspacePanelSplitView }.first
    )
    let sidebarBorder = try slot("sidebar.border", in: activeTheme)
    if activeTheme.style.sidebarBorderWidth == 0,
      activeTheme.style.sidebarBackground?.alpha == 0
    {
      #expect(split.themeDividerColor.alphaComponent == 0, "\(theme.name) Sidebar no border")
    } else {
      #expect(
        HexColor(nsColor: split.themeDividerColor) == sidebarBorder,
        "\(theme.name) Sidebar border"
      )
    }

    let titlebar = try identifiedView("workspace-titlebar", in: controller)
    // 中央标题只浮在统一 workspace surface 上，不再重复创建一层 Window material。
    #expect(titlebar is ThemeVisualEffectView == false, "\(theme.name) Titlebar shared surface")
    #expect(titlebar.layer?.backgroundColor == NSColor.clear.cgColor)
    let titleButton = try #require(
      identifiedView("workspace-title-button", in: controller) as? WorkspaceTitleButton
    )
    let titlebarForeground = try slot("titlebar.foreground", in: activeTheme)
    #expect(
      HexColor(nsColor: titleButton.contentTintColor ?? .clear) == titlebarForeground,
      "\(theme.name) Titlebar foreground"
    )

    let container = try identifiedView("workspace-container", in: controller)
    let containerColor = try slot("container.background", in: activeTheme)
    let containerBorder = try slot("container.border", in: activeTheme)
    #expect(layerColor(of: container) == containerColor, "\(theme.name) Container")
    #expect(layerBorderColor(of: container) == containerBorder, "\(theme.name) Container border")

    let tabs = controller.view.descendants.compactMap { $0 as? TabRowButton }
    #expect(tabs.count == 2)
    let selectedID = try #require(model.selectedTabID)
    let selectedTab = try #require(tabs.first { tab in
      tab.descendants.contains {
        $0.identifier?.rawValue == "workspace-tab-background-\(selectedID.uuidString)"
      }
    })
    let unselectedTab = try #require(tabs.first { $0 !== selectedTab })
    let tabBackground = try tabDecoration(in: selectedTab)
    let tabActiveBackground = try slot("tab.activeBackground", in: activeTheme)
    let tabActiveForeground = try slot("tab.activeForeground", in: activeTheme)
    let tabTint = try #require(selectedTab.contentTintColor)
    #expect(layerColor(of: tabBackground) == tabActiveBackground, "\(theme.name) Tab active")
    #expect(HexColor(nsColor: tabTint) == tabActiveForeground, "\(theme.name) Tab foreground")
    let tabForeground = try slot("tab.foreground", in: activeTheme)
    #expect(
      HexColor(nsColor: unselectedTab.contentTintColor ?? .clear) == tabForeground,
      "\(theme.name) Tab resting foreground"
    )
    let tabActiveBorder = try slot("tab.activeBorderColor", in: activeTheme)
    #expect(
      layerBorderColor(of: tabBackground) == tabActiveBorder,
      "\(theme.name) Tab active border"
    )
    let expectedBorderWidth = CGFloat(activeTheme.style.tab.activeBorderWidth)
    #expect(
      tabBackground.layer?.borderWidth == expectedBorderWidth, "\(theme.name) Tab border width")
    unselectedTab.mouseEntered(with: makeClickEvent(in: window))
    let tabHoverBackground = try slot("tab.hoverBackground", in: activeTheme)
    let hoveredDecoration = try tabDecoration(in: unselectedTab)
    #expect(
      layerColor(of: hoveredDecoration) == tabHoverBackground,
      "\(theme.name) Tab hover"
    )
    unselectedTab.mouseExited(with: makeClickEvent(in: window))

    try verifyRuntimeRoles(activeTheme)

    // TerminalSession.apply 读取原始 alpha 的 canvas；脱离材质的浮层读取预合成
    // background。两条路径都纳入矩阵，避免 Glass 终端被错误画成截图采样灰色。
    #expect(HexColor(nsColor: preferences.terminalForegroundColor) == activeTheme.palette.foreground)
    #expect(HexColor(nsColor: preferences.terminalBackgroundColor) == activeTheme.palette.renderedTerminalBackground)
    #expect(
      HexColor(nsColor: preferences.terminalCanvasBackgroundColor)
        == activeTheme.palette.windowBackground)
    #expect(HexColor(nsColor: preferences.cursorColor) == activeTheme.palette.cursor)
    let cursorForeground = try slot("cursor.foreground", in: activeTheme)
    let selectionBackground = try slot("selection.background", in: activeTheme)
    let selectionForeground = try slot("selection.foreground", in: activeTheme)
    #expect(HexColor(nsColor: preferences.cursorTextColor) == cursorForeground)
    #expect(HexColor(nsColor: preferences.selectionColor) == selectionBackground)
    #expect(HexColor(nsColor: preferences.selectionForegroundColor) == selectionForeground)
    #expect(preferences.ansiColors == activeTheme.palette.ansiColors)
  }

  /// 横向布局单独锁定 Tabbar 与 `[tab-bar.tab]` 的覆盖/继承结果。
  private func verifyHorizontalWorkspace(_ theme: TerminalTheme) throws {
    let defaults = isolatedDefaults()
    let preferences = AppPreferences(defaults: defaults)
    preferences.appearance = theme.mode == .dark ? .dark : .light
    preferences.selectTheme(theme)
    preferences.tabBarLayout = .top
    let activeTheme = preferences.activeTheme
    let model = try makeNonTerminalTestModel(defaults: defaults, directories: ["/tmp/theme-matrix"])
    let controller = WorkspaceViewController(model: model, preferences: preferences)
    let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()

    let tabbar = try themedView("workspace-tabbar", in: controller)
    let tabbarColor = try slot("tabbar.background", in: activeTheme)
    #expect(tabbar.appliedThemeTint == tabbarColor, "\(theme.name) Tabbar")
    let border = try identifiedView("workspace-tabbar-border", in: controller)
    let tabbarBorder = try slot("tabbar.border", in: activeTheme)
    #expect(layerColor(of: border) == tabbarBorder, "\(theme.name) Tabbar border")

    let tab = try #require(controller.view.descendants.compactMap { $0 as? TabRowButton }.first)
    let style = activeTheme.style.horizontalTab ?? activeTheme.style.tab
    let fallbackActiveBackground = try slot("tab.activeBackground", in: activeTheme)
    let fallbackActiveForeground = try slot("tab.activeForeground", in: activeTheme)
    let activeBackground = style.activeBackground ?? fallbackActiveBackground
    let activeForeground = style.activeForeground ?? fallbackActiveForeground
    let tabTint = try #require(tab.contentTintColor)
    // 横向选中胶囊与侧栏行共用内缩 decoration 层；按钮本体保持透明。
    let decoration = try tabDecoration(in: tab)
    #expect(layerColor(of: decoration) == activeBackground, "\(theme.name) horizontal Tab active")
    #expect(HexColor(nsColor: tabTint) == activeForeground, "\(theme.name) horizontal Tab foreground")
    // 选中胶囊常显小号关闭按钮，未选中标签保持纯文字。
    let closeButton = try #require(
      tab.descendants.first { $0.identifier?.rawValue.hasPrefix("sidebar-tab-close-") == true })
    #expect(closeButton.isHidden == false, "\(theme.name) horizontal selected close")
  }

  private func slot(_ id: String, in theme: TerminalTheme) throws -> HexColor {
    try #require(theme.resolvedColor(forSlot: id), "主题 \(theme.name) 缺少 \(id)")
  }

  /// Panel 与 Accents 通过动态角色色进入查找栏、浮层、详情内容和通用控件；直接核对
  /// ThemeRuntime 可以避开某个业务页是否恰好有数据，同时仍锁住最终 AppKit 颜色入口。
  private func verifyRuntimeRoles(_ theme: TerminalTheme) throws {
    let appearanceName: NSAppearance.Name = theme.mode == .dark ? .darkAqua : .aqua
    let appearance = try #require(NSAppearance(named: appearanceName))
    let mappings: [(ThemeRuntime.Role, String)] = [
      (.panel, "panel.background"),
      (.surface, "panel.surface"),
      (.border, "panel.border"),
      (.accent, "interface.accent"),
      (.foreground, "interface.foreground"),
      (.secondary, "interface.secondaryForeground"),
      (.tertiary, "interface.tertiaryForeground"),
    ]
    for (role, slotID) in mappings {
      let rendered = HexColor(nsColor: ThemeRuntime.shared.color(for: role, appearance: appearance))
      let expected = try slot(slotID, in: theme)
      #expect(rendered == expected, "\(theme.name) \(slotID)")
    }
  }

  private func tabDecoration(in tab: TabRowButton) throws -> NSView {
    try #require(tab.descendants.first {
      $0.identifier?.rawValue.hasPrefix("workspace-tab-background-") == true
    })
  }

  private func identifiedView(
    _ id: String,
    in controller: WorkspaceViewController
  ) throws -> NSView {
    try #require(
      controller.view.descendants.first { $0.identifier?.rawValue == id },
      "工作区缺少主题验收对象 \(id)"
    )
  }

  private func themedView(
    _ id: String,
    in controller: WorkspaceViewController
  ) throws -> ThemeVisualEffectView {
    try #require(try identifiedView(id, in: controller) as? ThemeVisualEffectView)
  }

  private func layerColor(of view: NSView) -> HexColor? {
    view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map(HexColor.init(nsColor:))
  }

  private func layerBorderColor(of view: NSView) -> HexColor? {
    view.layer?.borderColor.flatMap(NSColor.init(cgColor:)).map(HexColor.init(nsColor:))
  }
}

private extension NSView {
  var descendants: [NSView] {
    subviews + subviews.flatMap(\.descendants)
  }
}

/// 标签整理测试只验证 AppKit 列表，不需要真实 PTY。使用编辑器 Pane 避免与串行的
/// PTY 生命周期测试并发抢占伪终端资源，同时仍经过正式工作区快照恢复路径。
@MainActor
private func makeNonTerminalTestModel(
  defaults: UserDefaults,
  directories: [String]
) throws -> AppModel {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let tabs = directories.enumerated().map { index, directory in
    WorkspaceTabSnapshot(
      id: UUID(),
      title: URL(fileURLWithPath: directory).lastPathComponent,
      layout: .leaf(
        PaneDescriptor(
          kind: .editor,
          workingDirectory: directory,
          resourcePath: "/tmp/aster-sidebar-test-\(index).txt"
        )
      ),
      createdAt: baseDate.addingTimeInterval(Double(index)),
      updatedAt: baseDate.addingTimeInterval(Double(index))
    )
  }
  let snapshot = WorkspaceSnapshot(
    selectedTabID: tabs.last?.id ?? UUID(),
    tabs: tabs
  )
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  return model
}

/// 覆盖 Claude Code / vim 等 TUI 发送 `CSI Ps SP q` 的场景：用户配置过形状后，
/// 程序端请求必须被丢弃；未配置时仍保持 SwiftTerm 的默认（跟随程序）行为。
@Test("程序端 DECSCUSR 请求不会覆盖用户配置的光标形状")
@MainActor
func programmaticCursorStyleDoesNotOverrideConfiguration() async throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
  let terminal = view.getTerminal()

  view.preferredCursorStyle = .steadyBar
  terminal.options.cursorStyle = .steadyBar
  terminal.setCursorStyle(.blinkBlock)
  // 纠正被排到回调之后执行，断言前必须让主 actor 跑完那个任务。
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .steadyBar)

  view.preferredCursorStyle = nil
  terminal.setCursorStyle(.blinkUnderline)
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .blinkUnderline)
}

@Test("光标默认模式只接受程序控制闪烁而不覆盖用户形状")
@MainActor
func cursorBlinkPriorityMatchesOttyDefaultAndAlwaysModes() async throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
  let terminal = view.getTerminal()

  // Codex 等 TUI 会用 DECSCUSR 请求方块光标。Default 模式允许它改变“是否闪烁”，
  // 但光标几何始终属于 Aster 外观设置，用户选择的竖线不能被程序改成方块。
  view.configureCursor(initialStyle: .steadyBar, pinsProgramBlinking: false)
  terminal.setCursorStyle(.blinkBlock)
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .blinkBar)

  terminal.setCursorStyle(.steadyHollowBlock)
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .steadyBar)

  view.configureCursor(initialStyle: .steadyHollowBlock, pinsProgramBlinking: true)
  terminal.setCursorStyle(.blinkBlock)
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .steadyHollowBlock)
}

@Test("Pane 切换停止旧光标闪烁但不把竖线改成镂空方框")
@MainActor
func paneFocusPreservesConfiguredCursorGeometry() throws {
  let left = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
  let right = AsterTerminalView(frame: NSRect(x: 300, y: 0, width: 300, height: 220))
  left.configureCursor(initialStyle: .blinkBar, pinsProgramBlinking: true)
  right.configureCursor(initialStyle: .blinkBar, pinsProgramBlinking: true)

  left.setPaneActive(true)
  right.setPaneActive(false)
  #expect(left.getTerminal().options.cursorStyle == .blinkBar)
  #expect(right.getTerminal().options.cursorStyle == .steadyBar)

  left.setPaneActive(false)
  right.setPaneActive(true)
  #expect(left.getTerminal().options.cursorStyle == .steadyBar)
  #expect(right.getTerminal().options.cursorStyle == .blinkBar)
  // 失焦只暂停闪烁；SwiftTerm 的通用 hollow-block 替代样式不能覆盖用户选择的竖线。
  #expect(!left.caretViewTracksFocus)
  #expect(!right.caretViewTracksFocus)
}

/// 合成一次落在窗口中心的左键按下，用于驱动自绘控件的 `mouseDown`。
@MainActor
private func makeClickEvent(in window: NSWindow) -> NSEvent {
  NSEvent.mouseEvent(
    with: .leftMouseDown,
    location: NSPoint(x: window.frame.midX, y: window.frame.midY),
    modifierFlags: [],
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    eventNumber: 0,
    clickCount: 1,
    pressure: 1
  )!
}

@MainActor
private func makeTestWindow(content: NSViewController, size: NSSize) -> NSWindow {
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.titleVisibility = .hidden
  window.titlebarAppearsTransparent = true
  window.contentViewController = content
  return window
}

@Test("分屏里左 codex 右 claude 时，标签行 Agent 图标跟随活动 Pane 切换")
@MainActor
func sidebarAgentIconFollowsActivePane() async throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let leftPaneID = try #require(tab.activePaneID as UUID?)
  let leftSession = try #require(tab.activeSession)
  model.splitSelectedTab(.right)
  let rightPaneID = try #require(tab.activePaneID as UUID?)
  let rightSession = try #require(tab.activeSession)
  #expect(leftPaneID != rightPaneID)

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()
  let leftView = try #require(
    leftSession.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  let rightView = try #require(
    rightSession.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer {
    leftSession.stop(immediately: true)
    rightSession.stop(immediately: true)
  }

  // 左 codex、右 claude，都空闲（idle 信号不带前置 processing，不会产生完成徽章）。
  leftView.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
  rightView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .idle))
  try await Task.sleep(for: .milliseconds(80))

  // 当前活动 Pane 是右侧 claude → 图标必须是 claude，而不是字典序先命中的 codex。
  #expect(
    (try visibleTabAccessory(for: tab, in: controller)).accessibilityLabel() == "标签图标 claude")

  tab.setActivePane(leftPaneID)
  try await Task.sleep(for: .milliseconds(80))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller)).accessibilityLabel() == "标签图标 openai")

  tab.setActivePane(rightPaneID)
  try await Task.sleep(for: .milliseconds(80))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller)).accessibilityLabel() == "标签图标 claude")
}
