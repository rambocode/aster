import AppKit
import GhosttyKit
import Testing

@testable import Aster
@testable import AsterCore

/// 端到端复现:真实 Ghostty surface 打印 URL 后,带 Command 修饰键上报鼠标位置,
/// 验证 mouse_over_link action 能回流到 GhosttySurfaceView 并显示预览徽章。
@Test("Command 悬停真实 surface 中的 URL 显示链接预览")
@MainActor
func ghosttyCommandHoverShowsLinkPreview() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.linkhover.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer {
    for tab in model.tabs { tab.stop(immediately: true) }
    window.orderOut(nil)
    defaults.removePersistentDomain(forName: suite)
  }
  window.layoutIfNeeded()

  func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }
  var surfaceView: GhosttySurfaceView?
  for _ in 0..<200 {
    if let view = descendants(controller.view)
      .compactMap({ $0 as? GhosttySurfaceView }).first(where: { $0.surface != nil }),
      view.isProcessRunning
    {
      surfaceView = view
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  let view = try #require(surfaceView, "工作区终端未启动")
  // 合成事件不移动系统真实指针，测试使用事件记录的位置作为窗口指针来源。
  view.linkPointerLocationProvider = { [weak view] in view?.lastLinkHoverLocation }

  // 打印一个独占一行的 URL,并等待它进入屏幕缓冲。
  let url = "codex://aster-link-hover"
  #expect(view.typeText("printf '\\n\(url)\\n'\n"))
  var rendered = false
  for _ in 0..<150 {
    if view.readText(includeScrollback: false)?.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == url }) == true {
      rendered = true
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(rendered, "等待实际输出行，不能把回显的 printf 命令当成链接已经显示")


  // 用真实 NSEvent 走 mouseMoved(with:) 处理路径(含窗口坐标换算与修饰键提取),
  // 带 Command 扫描视口上半区;命中 URL 单元格时 core 应发出 mouse_over_link。
  outer: for yStep in stride(from: 8.0, to: min(view.bounds.height, 400), by: 8.0) {
    for xStep in stride(from: 4.0, to: min(view.bounds.width, 500), by: 8.0) {
      let localPoint = NSPoint(x: xStep, y: view.bounds.height - yStep)
      let windowPoint = view.convert(localPoint, to: nil)
      guard let event = NSEvent.mouseEvent(
        with: .mouseMoved,
        location: windowPoint,
        modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      ) else { continue }
      view.mouseMoved(with: event)
      // action 经主队列异步回流,让出 runloop 再检查。
      try await Task.sleep(for: .milliseconds(1))
      if view.linkPreviewText != nil { break outer }
    }
  }
  #expect(view.linkPreviewText == url, "Command 悬停未显示链接预览")

  #expect(view.linkHoverCursorActive)
  view.applyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
  #expect(NSCursor.current === NSCursor.pointingHand)
  view.linkPreviewEnabled = false
  #expect(view.linkPreviewText == nil)
  #expect(view.linkHoverCursorActive, "关闭预览不应取消链接手形")

  // 在预览关闭状态通过真实 Command 点击入口验证打开仍可用；只捕获目标，不对外打开。
  var clicked: [String] = []
  view.onRequestOpenTarget = { target, _ in clicked.append(target) }
  let clickPoint = view.convert(try #require(view.lastLinkHoverLocation), to: nil)
  func clickEvent(_ type: NSEvent.EventType) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type, location: clickPoint, modifierFlags: [.command], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
  }
  view.beginCommandClickTracking(with: try clickEvent(.leftMouseDown))
  view.finishCommandClick(with: try clickEvent(.leftMouseUp))
  try await Task.sleep(for: .milliseconds(20))
  #expect(clicked == [url])

  view.linkSchemePolicy = .custom([])
  try await Task.sleep(for: .milliseconds(20))
  #expect(!view.linkHoverCursorActive, "禁用协议后不能残留可点击手形")
  #expect(NSCursor.current === NSCursor.iBeam)
  view.linkSchemePolicy = .custom(["codex"])
  try await Task.sleep(for: .milliseconds(20))
  #expect(view.linkHoverCursorActive)
  view.linkPreviewEnabled = true
  #expect(view.linkPreviewText == url, "重新启用预览后无需移动鼠标")

  // 裸文件路径不在 Ghostty 的 URL 正则内,由 Aster 侧悬停检测补足。
  view.removeLinkPreview()
  let path = "/usr/local/bin"
  #expect(view.typeText("printf '\\n\(path)\\n'\n"))
  var pathRendered = false
  for _ in 0..<150 {
    if view.readText(includeScrollback: false)?.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == path }) == true {
      pathRendered = true
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(pathRendered, "路径未作为独立输出行出现在终端缓冲中")
  outerPath: for yStep in stride(from: 8.0, to: min(view.bounds.height, 500), by: 8.0) {
    for xStep in stride(from: 4.0, to: min(view.bounds.width, 500), by: 8.0) {
      let localPoint = NSPoint(x: xStep, y: view.bounds.height - yStep)
      let windowPoint = view.convert(localPoint, to: nil)
      guard let event = NSEvent.mouseEvent(
        with: .mouseMoved,
        location: windowPoint,
        modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      ) else { continue }
      view.mouseMoved(with: event)
      try await Task.sleep(for: .milliseconds(1))
      if view.linkPreviewText == path { break outerPath }
    }
  }
  #expect(view.linkPreviewText == path, "Command 悬停未显示路径预览")

  // 按下 Command（合成 flagsChanged，keyCode 55）应给视口内的 URL 与存在的路径画下划线；
  // 松开后覆盖层清空。
  let commandDown = try #require(
    NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: [.command],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
      keyCode: 55))
  view.flagsChanged(with: commandDown)
  let segments = view.linkUnderlineOverlay?.segments ?? []
  #expect(segments.count >= 2, "Command 按下后应为 URL 与路径各画一条下划线")
  #expect(segments.allSatisfy { $0.width > 0 && $0.height > 0 })
  let commandUp = try #require(
    NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
      keyCode: 55))
  view.flagsChanged(with: commandUp)
  #expect(view.linkUnderlineOverlay?.segments.isEmpty == true, "松开 Command 后下划线应清除")
  #expect(!view.linkHoverCursorActive)
  // 鼠标仍停在同一路径上，重新按下 Command，不能依赖下一次 mouseMoved 才显示手形。
  view.flagsChanged(with: commandDown)
  #expect(view.linkHoverCursorActive, "鼠标静止时按下 Command 应立即显示手形")
  #expect(NSCursor.current == NSCursor.pointingHand)
  // 模拟 AppKit 在移动后覆盖 cursor，再由实际 cursorUpdate 入口恢复手形。
  // 真机实测：AppKit 合成的 cursorUpdate 事件 modifierFlags 为空（Command 仍按住），
  // 这里必须用空 flags 复现；此前用 [.command] 构造事件掩盖了状态被清空的缺陷。
  NSCursor.arrow.set()
  let hoverLocation = try #require(view.lastLinkHoverLocation)
  let cursorEvent = try #require(NSEvent.enterExitEvent(
    with: .cursorUpdate,
    location: view.convert(hoverLocation, to: nil),
    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
    trackingNumber: 0, userData: nil))
  view.cursorUpdate(with: cursorEvent)
  #expect(NSCursor.current == NSCursor.pointingHand, "空 flags 的 cursorUpdate 不得清掉手形")
  #expect(view.linkCommandHeld, "空 flags 的 cursorUpdate 不得清掉 Command 状态")
  #expect(view.linkUnderlinesActive && !(view.linkUnderlineOverlay?.segments.isEmpty ?? true),
    "空 flags 的 cursorUpdate 不得清掉下划线")
  view.flagsChanged(with: commandUp)

  // 用户现场：鼠标先停在带箭头的代理地址，再按 Command，不再产生 mouseMoved。
  let proxyURL = "http://127.0.0.1:8899"
  let proxyLine = "[HPM] Proxy created: /api  → " + proxyURL
  #expect(view.typeText("printf '\\n%s\\n' '\(proxyLine)'\n"))
  var proxyRendered = false
  for _ in 0..<150 {
    if view.readText(includeScrollback: false)?.split(separator: "\n").contains(where: {
      $0.trimmingCharacters(in: .whitespaces) == proxyLine
    }) == true { proxyRendered = true; break }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(proxyRendered)
  var proxyPoint: NSPoint?
  searchProxy: for y in stride(from: 4.0, to: view.bounds.height, by: 8.0) {
    for x in stride(from: 4.0, to: view.bounds.width, by: 8.0) {
      let point = NSPoint(x: x, y: view.bounds.maxY - y)
      if view.inlineLinkTarget(at: point)?.text == proxyURL {
        proxyPoint = point
        break searchProxy
      }
    }
  }
  var point = try #require(proxyPoint)
  let proxyRow = try #require(view.inlineLinkTarget(at: point)).screenRow
  // 把该行推入历史，再滚回来；现场不是刚输出的活动区域。
  #expect(view.typeText("i=0; while [ $i -lt 120 ]; do printf 'history\\n'; i=$((i+1)); done; printf 'HISTORY_READY\\n'\n"))
  var historyReady = false
  for _ in 0..<150 {
    if view.readText(includeScrollback: false)?.split(separator: "\n").contains(where: {
      $0.trimmingCharacters(in: .whitespaces) == "HISTORY_READY"
    }) == true { historyReady = true; break }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(historyReady)
  try #require(view.revealScreenRow(proxyRow))
  try await Task.sleep(for: .milliseconds(20))
  proxyPoint = nil
  searchHistory: for y in stride(from: 4.0, to: view.bounds.height, by: 8.0) {
    for x in stride(from: 4.0, to: view.bounds.width, by: 8.0) {
      let candidate = NSPoint(x: x, y: view.bounds.maxY - y)
      if let target = view.inlineLinkTarget(at: candidate),
        target.text == proxyURL, target.screenRow == proxyRow {
        proxyPoint = candidate
        break searchHistory
      }
    }
  }
  point = try #require(proxyPoint, "滚回历史后必须仍能命中同一个代理链接")
  view.linkPointerLocationProvider = { point }
  view.lastLinkHoverLocation = nil
  let mouse = try #require(NSEvent.mouseEvent(
    with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
    clickCount: 0, pressure: 0))
  view.mouseDown(with: mouse)
  let mouseUp = try #require(NSEvent.mouseEvent(
    with: .leftMouseUp, location: view.convert(point, to: nil), modifierFlags: [],
    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
    clickCount: 1, pressure: 0))
  view.mouseUp(with: mouseUp)
  #expect(view.lastLinkHoverLocation == point, "点击与原生悬停必须共享同一坐标")
  // 故意留下错误缓存：实际窗口指针已移到 URL，Command 必须以新位置为准。
  view.lastLinkHoverLocation = .zero
  for keyCode: UInt16 in [55, 54, 57] {
    let pressed = try #require(NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: [.command], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: keyCode))
    let released = try #require(NSEvent.keyEvent(
      with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: keyCode))
    view.flagsChanged(with: pressed)
    #expect(view.linkPreviewText == proxyURL)
    #expect(view.linkHoverCursorActive, "Command 状态必须驱动手形，不能仅看物理键码 \(keyCode)")
    #expect(view.linkUnderlineOverlay?.segments.contains(where: { $0.contains(point) }) == true)

    view.flagsChanged(with: released)
    #expect(!view.linkHoverCursorActive)
    #expect(view.linkUnderlineOverlay?.segments.isEmpty != false)
  }

}
