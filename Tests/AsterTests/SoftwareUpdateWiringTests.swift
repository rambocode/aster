import AppKit
import Testing

@testable import Aster
@testable import AsterCore

// 更新功能的「接线」回归：菜单位置与可用性、Info.plist 的 Sparkle 声明，以及
// 「测试进程绝不真的启动 Sparkle」这条安全性质。

/// 菜单替身与设置页的 stub 分文件，避免两处测试互相牵连。
@MainActor
private final class MenuUpdateControllerStub: SoftwareUpdateControlling {
  var automaticallyChecksForUpdates = true
  var automaticallyDownloadsUpdates = false
  var canCheckForUpdates = true
  var status: SoftwareUpdateStatus = .idle
  var lastCheckDate: Date?
  private(set) var checkCount = 0
  private(set) var startCount = 0

  func start() { startCount += 1 }
  func checkForUpdates() { checkCount += 1 }
  func channelDidChange(to channel: UpdateChannel) {}
}

@MainActor
private func makeDelegate(
  updateController: (any SoftwareUpdateControlling)?
) -> AsterAppDelegate {
  let suite = "SoftwareUpdateWiring.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return AsterAppDelegate(
    model: AppModel(), preferences: AppPreferences(defaults: defaults),
    softwareUpdateController: updateController)
}

@Test("Aster 菜单在「关于」之后、「设置」之前提供检查更新入口")
@MainActor
func applicationMenuContainsCheckForUpdatesItem() throws {
  let delegate = makeDelegate(updateController: MenuUpdateControllerStub())
  let appMenu = try #require(delegate.makeMainMenu().item(at: 0)?.submenu)

  let about = appMenu.indexOfItem(withTitle: "关于 Aster")
  let update = appMenu.indexOfItem(withTitle: "检查更新…")
  let settings = appMenu.indexOfItem(withTitle: "设置…")
  #expect(about >= 0)
  #expect(update == about + 1)
  #expect(update < settings)

  let item = try #require(appMenu.item(at: update))
  #expect(item.action == #selector(AsterAppDelegate.checkForUpdates(_:)))
  #expect(item.target === delegate)
  // 不占用快捷键：macOS 上「检查更新…」历来没有默认键位。
  #expect(item.keyEquivalent.isEmpty)
}

@Test("更新会话进行中时检查更新菜单项置灰，开发构建保持可点")
@MainActor
func checkForUpdatesMenuItemValidation() throws {
  let stub = MenuUpdateControllerStub()
  let delegate = makeDelegate(updateController: stub)
  let appMenu = try #require(delegate.makeMainMenu().item(at: 0)?.submenu)
  let item = try #require(appMenu.item(at: appMenu.indexOfItem(withTitle: "检查更新…")))

  #expect(delegate.validateMenuItem(item))
  stub.canCheckForUpdates = false
  #expect(delegate.validateMenuItem(item) == false)

  // 开发构建没有 updater：菜单项保持可点，点击后跳设置页说明原因，
  // 而不是给出一个用户无法区分「没配置」与「坏了」的置灰项。
  let bare = makeDelegate(updateController: nil)
  let bareMenu = try #require(bare.makeMainMenu().item(at: 0)?.submenu)
  let bareItem = try #require(bareMenu.item(at: bareMenu.indexOfItem(withTitle: "检查更新…")))
  #expect(bare.validateMenuItem(bareItem))
}

@Test("菜单动作转交给更新控制面")
@MainActor
func checkForUpdatesMenuActionDelegatesToController() throws {
  let stub = MenuUpdateControllerStub()
  let delegate = makeDelegate(updateController: stub)
  delegate.checkForUpdates(nil)
  #expect(stub.checkCount == 1)
}

/// Info.plist 是 Sparkle 的配置真值，任何一项写错都只会在用户机器上静默失效。
@Test("Info.plist 声明 Sparkle 的更新源、公钥与自动检查默认值")
func infoPlistDeclaresSparkleConfiguration() throws {
  let plistURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist")
  let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])

  let feed = try #require(plist["SUFeedURL"] as? String)
  // 非 https 的 feed 会被 ATS 拦下，而 Aster 没有 NSAppTransportSecurity 例外。
  #expect(feed.hasPrefix("https://"))
  #expect(!(try #require(plist["SUPublicEDKey"] as? String)).isEmpty)
  // 显式声明为真才能绕过 Sparkle 第二次启动的权限对话框，保证「自动检查更新」
  // 只有设置页一个写入入口。
  #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
  #expect(plist["SUScheduledCheckInterval"] as? Int == 86_400)

  // Sparkle 用 CFBundleVersion 做版本比较，非数字会静默失效；同时它必须单调递增。
  let bundleVersion = try #require(plist["CFBundleVersion"] as? String)
  #expect(Int(bundleVersion) != nil)

  // 未沙箱的应用不该开启 XPC 路径，否则平白引入签名与授权弹窗风险。
  #expect(plist["SUEnableInstallerLauncherService"] == nil)
  #expect(plist["SUEnableDownloaderService"] == nil)
  // 静默安装必须由用户主动开启，不作为出厂默认值。
  #expect(plist["SUAutomaticallyUpdate"] == nil)
}

/// 兼作安全性质断言：测试套件永远不会真的启动 Sparkle 或发出网络请求。
@Test("非打包构建不构造更新器")
@MainActor
func updateServiceIsUnavailableOutsidePackagedApp() {
  #expect(SoftwareUpdateService.shared == nil)
}
