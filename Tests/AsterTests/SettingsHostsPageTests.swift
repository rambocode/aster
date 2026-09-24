import AppKit
import Testing
import WebKit

@testable import Aster
@testable import AsterCore

// 「主机」网页端到端：真实 WKWebView 加载设置页，经网页脚本渲染列表、搜索、打开表单并提交，
// 最终落到临时 hosts.json。设 `ASTER_HOSTS_UI_EVIDENCE_DIR` 时额外在隔离窗口里截图。

@MainActor
private struct HostsPageFixture {
  let suite: String
  let hosts: HostsBridgeFixture
  let controller: SettingsViewController
  let web: WKWebView

  init(profiles: [SSHHostProfile]) throws {
    suite = "SettingsHostsPage.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    hosts = try HostsBridgeFixture(hosts: profiles)
    controller = SettingsViewController(
      preferences: AppPreferences(defaults: defaults), hostsBridge: hosts.bridge)
    controller.loadViewIfNeeded()
    web = try #require(controller.settingsWebViewForTesting)
  }

  func close() {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    hosts.cleanUp()
  }

  @discardableResult
  func evaluate(_ script: String) async throws -> String {
    let result = try await web.evaluateJavaScript(script)
    return result as? String ?? ""
  }

  /// 轮询直到表达式为真；超时记录问题。
  func wait(_ expression: String) async throws {
    for _ in 0..<150 {
      if try await evaluate("String(Boolean(\(expression)))") == "true" { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("主机页未达到预期状态：\(expression)")
  }

  /// 指定证据目录时，把设置页放进隔离窗口截图（不碰真实设置）。
  func capture(_ name: String) async throws {
    guard let directory = ProcessInfo.processInfo.environment["ASTER_HOSTS_UI_EVIDENCE_DIR"] else { return }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 900, height: 640))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let image: NSImage? = try await withCheckedThrowingContinuation { continuation in
      web.takeSnapshot(with: nil) { image, error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: image) }
      }
    }
    let tiff = try #require(image?.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
  }
}

@Test("主机页渲染分组列表、搜索过滤，并经表单保存到 hosts.json")
@MainActor
func settingsHostsPageRendersAndSaves() async throws {
  let bastion = SSHHostProfile(
    name: "bastion", group: SSHHostProfile.importedGroup, host: "bastion.example.com", user: "ops")
  let web = SSHHostProfile(
    name: "web", group: "prod", host: "web.example.com", port: 2222, user: "deploy", jumpHostID: bastion.id)
  let scratch = SSHHostProfile(name: "scratch", host: "10.0.0.8")
  let fixture = try HostsPageFixture(profiles: [scratch, web, bastion])
  defer { fixture.close() }
  fixture.hosts.passwords.saved = ["deploy@web.example.com:2222"]

  try await fixture.wait("document.querySelectorAll('.nav-item').length === 11")
  try await fixture.evaluate("window.AsterSettings.receive({type:'selectSection',section:'hosts'}); ''")
  try await fixture.wait("document.querySelectorAll('.hosts-row').length === 4")
  #expect(try await fixture.evaluate(
    "[...document.querySelectorAll('.hosts-group-header')].map(h => h.textContent).join('|')")
    == "▾~/.ssh/config· 1|▾prod· 1|▾未分组· 1")
  #expect(try await fixture.evaluate(
    "document.querySelector('[data-host-id=\"\(web.id.uuidString)\"]').textContent")
    .contains("已保存口令"))
  try await fixture.capture("hosts-list")

  // 搜索只重绘列表：按端口过滤只剩 web（外加固定的「默认」行）。
  try await fixture.evaluate(
    "const s = document.querySelector('.hosts-search'); s.value = '2222'; s.dispatchEvent(new Event('input')); ''")
  try await fixture.wait("document.querySelectorAll('.hosts-row').length === 2")

  // 打开 web 的表单，改用户名后保存；回执成功才关闭。
  try await fixture.evaluate("document.querySelector('[data-host-id=\"\(web.id.uuidString)\"]').click(); ''")
  try await fixture.wait("document.querySelector('.hosts-dialog')")
  try await fixture.capture("hosts-editor")
  try await fixture.evaluate("""
    const dialog = document.querySelector('.hosts-dialog');
    const user = [...dialog.querySelectorAll('.hosts-field')].find(f => f.textContent.startsWith('用户')).querySelector('input');
    const byLabel = text => [...dialog.querySelectorAll('.hosts-field')].find(f => f.textContent.startsWith(text));
    user.value = 'admin';
    byLabel('只用指定私钥').querySelector('select').value = 'true';
    const knownHosts = byLabel('known_hosts 文件').querySelector('textarea');
    if (!knownHosts.placeholder.includes('~/.ssh/known_hosts')) throw new Error('placeholder');
    knownHosts.value = '~/.orbstack/ssh/known_hosts\\n\\n  ~/.ssh/known_hosts ';
    [...dialog.querySelectorAll('button')].find(b => b.textContent === '保存').click(); ''
    """)
  try await fixture.wait("!document.querySelector('.hosts-dialog')")
  let saved = try SSHHostStore(fileURL: fixture.hosts.bridge.directory.store.fileURL).load()
  let updated = try #require(saved.first { $0.id == web.id })
  #expect(updated.user == "admin")
  #expect(updated.port == 2222 && updated.jumpHostID == bastion.id && updated.group == "prod")
  #expect(updated.identitiesOnly == true)
  #expect(updated.knownHostsFiles == ["~/.orbstack/ssh/known_hosts", "~/.ssh/known_hosts"])
}

@Test("主机行菜单按口令状态显示「忘记口令」，删除确认列出受影响主机后才删除")
@MainActor
func settingsHostsPageMenuAndDeleteConfirmation() async throws {
  let bastion = SSHHostProfile(name: "bastion", host: "bastion.example.com", user: "ops")
  let web = SSHHostProfile(name: "web", host: "web.example.com", user: "deploy", jumpHostID: bastion.id)
  let fixture = try HostsPageFixture(profiles: [bastion, web])
  defer { fixture.close() }
  fixture.hosts.passwords.saved = ["deploy@web.example.com:22"]

  try await fixture.wait("document.querySelectorAll('.nav-item').length === 11")
  try await fixture.evaluate("window.AsterSettings.receive({type:'selectSection',section:'hosts'}); ''")
  try await fixture.wait("document.querySelectorAll('.hosts-row').length === 3")

  let menuItems = { (id: UUID) in
    "(() => { document.querySelector('[data-host-id=\"\(id.uuidString)\"] .hosts-more').click();"
      + " return [...document.querySelectorAll('.hosts-menu-item')].map(i => i.textContent).join('|'); })()"
  }
  #expect(try await fixture.evaluate(menuItems(web.id)) == "编辑…|复制|添加为机器…|忘记口令…|删除…")
  try await fixture.capture("hosts-menu")
  #expect(try await fixture.evaluate(menuItems(bastion.id)) == "编辑…|复制|添加为机器…|删除…")

  // 删除 bastion：确认框列出把它当跳板的 web；确认后才真正删除。
  try await fixture.evaluate(
    "[...document.querySelectorAll('.hosts-menu-item')].find(i => i.textContent === '删除…').click(); ''")
  try await fixture.wait("document.querySelector('.hosts-confirm-list')")
  #expect(try await fixture.evaluate("document.querySelector('.hosts-confirm-list').textContent").contains("web"))
  try await fixture.capture("hosts-delete-confirm")
  #expect(fixture.hosts.bridge.directory.host(bastion.id) != nil)
  try await fixture.evaluate(
    "[...document.querySelectorAll('.settings-dialog button')].find(b => b.textContent === '删除').click(); ''")
  try await fixture.wait("document.querySelectorAll('.hosts-row').length === 2")
  #expect(fixture.hosts.bridge.directory.host(bastion.id) == nil)
  #expect(fixture.hosts.bridge.directory.host(web.id)?.jumpHostID == nil)

  // 导入汇总由原生消息驱动，列出被忽略的选项。
  try await fixture.evaluate("""
    window.AsterSettings.receive({type:'hostsImportReport', report:{added:2, updated:1, unchanged:0,
      ignored:[{file:'~/.ssh/config', line:12, option:'Match', reason:'unsupported'}],
      unresolvedJumps:[{host:'db', proxyJump:'gw.example.com'}], rejected:[]}}); ''
    """)
  try await fixture.wait("document.querySelector('.hosts-report-list')")
  #expect(try await fixture.evaluate("document.querySelector('.settings-dialog').textContent").contains("~/.ssh/config:12"))
  try await fixture.capture("hosts-import-report")
  try await fixture.evaluate(
    "[...document.querySelectorAll('.settings-dialog button')].find(b => b.textContent === '完成').click(); ''")

  // 默认项表单：不显示名称与主机；新增一条格式不对的转发规则时，保存被网页端拦下并说明原因。
  try await fixture.evaluate("document.querySelector('.hosts-defaults').click(); ''")
  try await fixture.wait("document.querySelector('.hosts-dialog')")
  #expect(try await fixture.evaluate(
    "[...document.querySelectorAll('.hosts-field-label')].map(l => l.textContent).slice(0, 2).join('|')") == "端口|用户")
  try await fixture.evaluate("""
    const dialog = document.querySelector('.hosts-dialog');
    dialog.querySelectorAll('details').forEach(d => d.open = true);
    [...dialog.querySelectorAll('button')].find(b => b.textContent === '+ 添加规则').click();
    [...dialog.querySelectorAll('button')].find(b => b.textContent === '保存').click(); ''
    """)
  try await fixture.wait("document.querySelector('.hosts-form-error')?.textContent.includes('第 1 条转发规则')")
  try await fixture.capture("hosts-defaults-editor")
}
