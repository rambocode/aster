import AppKit
import Testing
import WebKit

@testable import Aster
@testable import AsterCore

@MainActor
private struct LinkSettingsFixture {
  let defaults: UserDefaults
  let preferences: AppPreferences
  let controller: SettingsViewController
  let web: WKWebView
  let suite: String

  init() throws {
    suite = "LinkProtocolSettings.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    preferences = AppPreferences(defaults: defaults)
    preferences.configuration.controls.customLinkSchemes = []
    controller = SettingsViewController(preferences: preferences)
    controller.loadViewIfNeeded()
    web = try #require(controller.settingsWebViewForTesting)
  }

  func close() { defaults.removePersistentDomain(forName: suite) }

  /// 显式指定证据目录时才展示隔离窗口并截图，不触碰应用的真实设置或授权。
  func capture(_ name: String) async throws {
    guard let directory = ProcessInfo.processInfo.environment["ASTER_LINK_UI_EVIDENCE_DIR"] else {
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "链接协议交互验证"
    window.contentViewController = controller
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    window.contentView?.layoutSubtreeIfNeeded()
    if name == "reset-feedback" {
      try await evaluate(
        "document.querySelector('[data-setting-key=\"resetLinkApprovals\"]').scrollIntoView({block:'center'}); ''"
      )
    }
    try await Task.sleep(for: .milliseconds(80))
    let image: NSImage? = try await withCheckedThrowingContinuation { continuation in
      web.takeSnapshot(with: nil) { image, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: image)
        }
      }
    }
    let tiff = try #require(image?.tiffRepresentation)
    let png = try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
  }

  @discardableResult
  func evaluate(_ script: String) async throws -> String {
    let result = try await web.evaluateJavaScript(script)
    return result as? String ?? ""
  }

  func wait(_ expression: String) async throws {
    for _ in 0..<150 {
      if try await evaluate("String(Boolean(\(expression)))") == "true" { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("设置页面未达到预期状态：\(expression)")
  }

  func openControls() async throws {
    try await wait("document.querySelectorAll('.nav-item').length === 10")
    try await evaluate(
      "window.AsterSettings.receive({type:'selectSection',section:'controls'}); ''")
    try await wait("document.querySelector('[data-setting-key=\"controls.linkSchemes\"] select')")
  }
}

@Test("协议配置逐行即时保存，快速输入、删除、校验和键盘关闭保持一致")
@MainActor
func linkProtocolDialogPersistsEditsAndPreservesFocus() async throws {
  let fixture = try LinkSettingsFixture()
  defer { fixture.close() }
  try await fixture.openControls()
  try await fixture.evaluate(
    """
    (() => { const select = document.querySelector('[data-setting-key="controls.linkSchemes"] select');
      select.value = 'custom'; select.dispatchEvent(new Event('change')); return ''; })()
    """)
  try await fixture.wait(
    "document.querySelector('[data-setting-key=\"configureLinkSchemes\"] button')")
  #expect(fixture.preferences.configuration.controls.detectAllLinkSchemes == false)
  try await fixture.evaluate(
    "document.querySelector('[data-setting-key=\"configureLinkSchemes\"] button').click(); ''")
  try await fixture.wait("document.querySelector('.protocol-dialog')")
  #expect(
    try await fixture.evaluate("String(document.activeElement.classList.contains('protocol-add'))")
      == "true")
  try await fixture.evaluate(
    "document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true})); ''"
  )
  #expect(
    try await fixture.evaluate("String(document.activeElement.classList.contains('protocol-done'))")
      == "true")
  try await fixture.evaluate(
    "document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true})); ''"
  )
  #expect(
    try await fixture.evaluate("String(document.activeElement.classList.contains('protocol-add'))")
      == "true")
  try await fixture.evaluate(
    """
    (() => { document.querySelector('.protocol-add').click(); const input = document.querySelector('.protocol-row input');
      for (const value of ['c','co','codex','SSH://']) { input.value = value; input.dispatchEvent(new Event('input')); }
      return ''; })()
    """)
  try await fixture.wait("document.querySelector('.protocol-done')?.disabled === false")
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes == ["ssh"])
  #expect(
    try await fixture.evaluate("String(document.activeElement.matches('.protocol-row input'))")
      == "true")

  try await fixture.evaluate(
    """
    (() => { const input = document.querySelector('.protocol-row input'); input.value = 'bad protocol';
      input.dispatchEvent(new Event('input')); return ''; })()
    """)
  #expect(
    try await fixture.evaluate(
      "document.querySelector('.protocol-row input').getAttribute('aria-invalid')") == "true")
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes == ["ssh"])
  try await fixture.evaluate(
    """
    (() => { const input = document.querySelector('.protocol-row input'); input.value = 'codex';
      input.dispatchEvent(new Event('input')); return ''; })()
    """)
  try await fixture.wait("document.querySelector('.protocol-done')?.disabled === false")
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes == ["codex"])
  try await fixture.capture("protocol-editor")
  try await fixture.evaluate("document.querySelector('.protocol-done').click(); ''")
  try await fixture.wait("!document.querySelector('.protocol-dialog')")
  try await fixture.evaluate(
    """
    (() => { const select = document.querySelector('[data-setting-key="controls.linkSchemes"] select');
      select.value = 'all'; select.dispatchEvent(new Event('change')); return ''; })()
    """)
  try await fixture.wait("!document.querySelector('[data-setting-key=\"configureLinkSchemes\"]')")
  #expect(fixture.preferences.configuration.controls.detectAllLinkSchemes == true)
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes == ["codex"])
  try await fixture.evaluate(
    """
    (() => { const select = document.querySelector('[data-setting-key="controls.linkSchemes"] select');
      select.value = 'custom'; select.dispatchEvent(new Event('change')); return ''; })()
    """)
  try await fixture.wait(
    "document.querySelector('[data-setting-key=\"configureLinkSchemes\"] button')")
  try await fixture.evaluate(
    "document.querySelector('[data-setting-key=\"configureLinkSchemes\"] button').click(); ''")
  #expect(
    try await fixture.evaluate("document.querySelector('.protocol-row input').value") == "codex")
  try await fixture.evaluate("document.querySelector('.protocol-row button').click(); ''")
  try await fixture.wait("document.querySelector('.protocol-done')?.disabled === false")
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes.isEmpty)
  try await fixture.evaluate(
    "document.querySelector('.protocol-dialog').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true})); ''"
  )
  try await fixture.wait("!document.querySelector('.protocol-dialog')")
  #expect(
    try await fixture.evaluate(
      "String(document.activeElement.closest('[data-setting-key=\"configureLinkSchemes\"]') !== null)"
    ) == "true")
  #expect(try await fixture.evaluate("String(document.getElementById('app').inert)") == "false")
  let reloaded = AppPreferences(defaults: fixture.defaults)
  #expect(reloaded.configuration.controls.resolvedCustomLinkSchemes.isEmpty)
  #expect(reloaded.configuration.controls.detectAllLinkSchemes == false)
}

@Test("重置清除三类授权，保留协议配置，成功反馈跨快照刷新保持到期")
@MainActor
func linkProtocolResetFeedbackSurvivesSnapshots() async throws {
  let fixture = try LinkSettingsFixture()
  defer { fixture.close() }
  fixture.preferences.configuration.controls.customLinkSchemes = ["codex"]
  fixture.preferences.configuration.controls.allowedNonStandardLinkSchemes = ["codex"]
  fixture.preferences.configuration.controls.allowedExternalLinkHosts = ["example.com"]
  fixture.preferences.configuration.controls.allowedExecutableFileSignatures = ["test-signature"]
  #expect(
    fixture.preferences.configuration.controls.allowedNonStandardLinkSchemes?.isEmpty == false)
  #expect(fixture.preferences.configuration.controls.allowedExternalLinkHosts?.isEmpty == false)
  #expect(
    fixture.preferences.configuration.controls.allowedExecutableFileSignatures?.isEmpty == false)
  try await fixture.openControls()
  try await fixture.evaluate(
    "document.querySelector('[data-setting-key=\"resetLinkApprovals\"] button').click(); ''")
  try await fixture.wait(
    "document.querySelector('[data-setting-key=\"resetLinkApprovals\"] button')?.textContent.includes('✓')"
  )
  try await fixture.capture("reset-feedback")
  let controls = fixture.preferences.configuration.controls
  #expect(controls.allowedNonStandardLinkSchemes?.isEmpty == true)
  #expect(controls.allowedExternalLinkHosts?.isEmpty == true)
  #expect(controls.allowedExecutableFileSignatures?.isEmpty == true)
  #expect(controls.resolvedCustomLinkSchemes == ["codex"])
  var confirmations: [TargetSecurityReason] = []
  let opener = TerminalTargetOpenCoordinator(
    preferences: fixture.preferences,
    inspectFile: { _ in .regular(executable: true) },
    isTextFile: { _ in false },
    openURL: { _ in
      Issue.record("取消确认后不得执行系统打开")
      return false
    },
    executableSignature: { _ in "test-signature" },
    confirm: { reason in
      confirmations.append(reason)
      return .cancel
    },
    reportError: { _ in Issue.record("合法测试目标不应解析失败") })
  for target in ["https://example.com", "codex://session/1", "/tmp/test-tool"] {
    #expect(!opener.open(target, source: .plainText, currentDirectory: "/tmp"))
  }
  #expect(
    confirmations == [
      .externalLink("example.com"), .nonStandardScheme("codex"), .executableFile("/tmp/test-tool"),
    ])
  // ready 请求会真实推送新快照，验证成功状态不依附已被替换的按钮节点。
  try await fixture.evaluate(
    "window.webkit.messageHandlers.asterSettings.postMessage({version:1,kind:'ready'}); ''")
  try await Task.sleep(for: .milliseconds(100))
  #expect(
    try await fixture.evaluate(
      "String(document.querySelector('[data-setting-key=\"resetLinkApprovals\"] button').textContent.includes('✓'))"
    ) == "true")
  try await fixture.wait(
    "!document.querySelector('[data-setting-key=\"resetLinkApprovals\"] button')?.textContent.includes('✓')"
  )
  #expect(
    try await fixture.evaluate(
      "String(document.querySelector('[data-setting-key=\"resetLinkApprovals\"] button').textContent.includes('✓'))"
    ) == "false")
}

@Test("协议原生写入拒绝非法值，避免网页绕过校验清空旧配置")
@MainActor
func linkProtocolBridgeRejectsInvalidValuesAtomically() throws {
  let fixture = try LinkSettingsFixture()
  defer { fixture.close() }
  try fixture.controller.applySettingForTesting(
    key: "controls.customLinkSchemes", value: " SSH://, codex ")
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes == ["ssh", "codex"])
  #expect(throws: (any Error).self) {
    try fixture.controller.applySettingForTesting(
      key: "controls.customLinkSchemes", value: "vscode, bad value")
  }
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes == ["ssh", "codex"])
  let maximumList = (0..<64).map { "s\($0)".padding(toLength: 64, withPad: "x", startingAt: 0) }
  try fixture.controller.applySettingForTesting(
    key: "controls.customLinkSchemes", value: maximumList.joined(separator: ", "))
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes == Set(maximumList))
}

@Test("协议编辑保存失败保留输入，重试成功后才能完成关闭")
@MainActor
func linkProtocolDialogRetainsInputUntilRetrySucceeds() async throws {
  let fixture = try LinkSettingsFixture()
  defer { fixture.close() }
  try await fixture.openControls()
  // 模拟明确的保存拒绝；真实字段校验另由 bridge 用例覆盖，不修改用户配置。
  try await fixture.evaluate(
    """
    (() => { let attempts = 0; window.AsterLinkProtocols.open({items:['ssh'],t:x=>x,
      commit:()=>++attempts === 1 ? Promise.reject(new Error('rejected')) : Promise.resolve(),
      restoreFocus:()=>{}});
      const input = document.querySelector('.protocol-row input'); input.value = 'codex';
      input.dispatchEvent(new Event('input')); return ''; })()
    """)
  try await fixture.wait("document.querySelector('.protocol-retry')?.hidden === false")
  #expect(
    try await fixture.evaluate("document.querySelector('.protocol-row input').value") == "codex")
  try await fixture.evaluate(
    "document.querySelector('.protocol-dialog').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true})); ''"
  )
  #expect(
    try await fixture.evaluate("String(Boolean(document.querySelector('.protocol-dialog')))")
      == "true")
  try await fixture.evaluate("document.querySelector('.protocol-retry').click(); ''")
  try await fixture.wait("document.querySelector('.protocol-done')?.disabled === false")
  try await fixture.evaluate("document.querySelector('.protocol-done').click(); ''")
  try await fixture.wait("!document.querySelector('.protocol-dialog')")
}

@Test("最大合法协议列表可通过真实网页消息保存并收到完成回执")
@MainActor
func linkProtocolMaximumListPersistsThroughWebBridge() async throws {
  let fixture = try LinkSettingsFixture()
  defer { fixture.close() }
  let schemes = (0..<64).map { "s\($0)".padding(toLength: 64, withPad: "x", startingAt: 0) }
  fixture.preferences.configuration.controls.customLinkSchemes = Set(schemes)
  fixture.preferences.configuration.controls.detectAllLinkSchemes = false
  try await fixture.openControls()
  try await fixture.evaluate(
    "document.querySelector('[data-setting-key=\"configureLinkSchemes\"] button').click(); ''")
  try await fixture.wait("document.querySelectorAll('.protocol-row input').length === 64")
  let replacement = String(repeating: "z", count: 64)
  _ = try await fixture.web.callAsyncJavaScript(
    "const input = document.querySelector('.protocol-row input'); input.value = value; input.dispatchEvent(new Event('input'));",
    arguments: ["value": replacement], in: nil, contentWorld: .page)
  try await fixture.wait("document.querySelector('.protocol-done')?.disabled === false")
  #expect(fixture.preferences.configuration.controls.resolvedCustomLinkSchemes.count == 64)
  #expect(
    fixture.preferences.configuration.controls.resolvedCustomLinkSchemes.contains(replacement))
}
