import AppKit
import AsterCore
import Sparkle

extension Notification.Name {
  /// 更新状态变化。设置页据此重推快照；Sparkle 的检查是异步且可能跨越数分钟的用户
  /// 交互，没有同步返回值可用。
  static let softwareUpdateStatusDidChange = Notification.Name(
    "Aster.SoftwareUpdateStatusDidChange")
}

/// 设置页与菜单看到的更新能力面。
///
/// 把 Sparkle 挡在这个协议后面，测试可以在不联网、也不打包成 .app 的前提下驱动全部
/// 接线；`SettingsViewController` 与 `AsterAppDelegate` 因此都不需要 `import Sparkle`。
@MainActor
protocol SoftwareUpdateControlling: AnyObject {
  /// 真值在 Sparkle 自己的 UserDefaults（SUEnableAutomaticChecks / SUAutomaticallyUpdate），
  /// 这里只透传。Aster 不保存副本——Sparkle 自带的更新对话框也会写这两个键，存副本
  /// 必然漂移。
  var automaticallyChecksForUpdates: Bool { get set }
  var automaticallyDownloadsUpdates: Bool { get set }
  var canCheckForUpdates: Bool { get }
  var status: SoftwareUpdateStatus { get }
  var lastCheckDate: Date? { get }
  func checkForUpdates()
  func channelDidChange(to channel: UpdateChannel)
  /// 由 `applicationDidFinishLaunching` 在窗口恢复完成后调用；实现必须幂等。
  func start()
}

/// Sparkle 2 与 Aster 之间的唯一边界：持有 updater controller、充当它的两个 delegate，
/// 并把 Sparkle 的一串回调折叠成单个 `SoftwareUpdateStatus` 广播出去。
///
/// 网络语义：这是 Aster 第二个会主动发起网络请求的组件（第一个是
/// `AutocompleteService.updateNow()`）。只请求 Info.plist 里固定的 appcast，更新包经
/// EdDSA 与代码签名双重校验后才安装；不启用 `SUSendProfileInfo`，不上报任何使用数据。
@MainActor
final class SoftwareUpdateService: NSObject, SoftwareUpdateControlling {
  /// 生产环境惰性单例。
  ///
  /// 开发构建（`swift run` / `swift test`）与未配置更新源的构建返回 nil：Sparkle 在这些
  /// 环境下 `startUpdater()` 会弹「请联系开发者」告警，而设置页此时应该走
  /// capability=false 的禁用态，而不是假装可用。
  static let shared: SoftwareUpdateService? = {
    guard Bundle.main.bundleURL.pathExtension == "app",
      let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      URL(string: feed)?.scheme == "https",
      let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      !publicKey.isEmpty
    else { return nil }
    return SoftwareUpdateService(defaults: .standard)
  }()

  private let defaults: UserDefaults
  /// `SPUStandardUpdaterController` 的两个 delegate 是弱引用的初始化参数，而 delegate
  /// 就是 self，只能在 `super.init()` 之后赋值，因此这里是隐式解包可选。
  private var controller: SPUStandardUpdaterController!
  private var didStart = false

  private(set) var status: SoftwareUpdateStatus = .idle {
    didSet {
      guard status != oldValue else { return }
      NotificationCenter.default.post(name: .softwareUpdateStatusDidChange, object: self)
    }
  }

  private init(defaults: UserDefaults) {
    self.defaults = defaults
    super.init()
    // startingUpdater: false 是必须的。startUpdater 在配置有误时会在几秒后弹告警让
    // 用户联系开发者；启动时机必须由 applicationDidFinishLaunching 显式决定，
    // 而不是在设置页第一次触碰这个单例时意外触发。
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
  }

  private var updater: SPUUpdater { controller.updater }

  /// 由 `applicationDidFinishLaunching` 在窗口恢复完成后调用。幂等。
  func start() {
    guard !didStart else { return }
    didStart = true
    controller.startUpdater()
  }

  var automaticallyChecksForUpdates: Bool {
    get { updater.automaticallyChecksForUpdates }
    set { updater.automaticallyChecksForUpdates = newValue }
  }

  var automaticallyDownloadsUpdates: Bool {
    get { updater.automaticallyDownloadsUpdates }
    set { updater.automaticallyDownloadsUpdates = newValue }
  }

  var canCheckForUpdates: Bool { updater.canCheckForUpdates }

  var lastCheckDate: Date? { updater.lastUpdateCheckDate }

  func checkForUpdates() {
    status = .checking
    updater.checkForUpdates()
  }

  /// `allowedChannels(for:)` 是「每次检查现问」的，所以切换通道不需要向 Sparkle 推送
  /// 任何状态，只要让排班重来一次。
  func channelDidChange(to channel: UpdateChannel) {
    updater.resetUpdateCycle()
    guard channel == .preview else {
      // 预览 → 稳定不做立即检查：Sparkle 永远不提供比当前更旧的版本，立刻检查只会
      // 返回一条误导性的「已是最新」，而用户此刻装的其实仍是预览版。
      status = .idle
      return
    }
    status = .checking
    // 静默探测：只触发 delegate 回调刷新状态点，不弹出 Sparkle 的更新窗口。
    // 用户真要装，再点「现在检查」或等下一次排班。
    updater.checkForUpdateInformation()
  }

  /// 用户主动点「稍后」「取消」也会走 didAbortWithError。一律当失败会让设置页因为一次
  /// 正常取消就亮红点，因此显式放行取消类错误。
  private static func isUserCancellation(_ error: any Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == SUSparkleErrorDomain else { return false }
    return nsError.code == SUError.installationCanceledError.rawValue
      || nsError.code == SUError.installationAuthorizeLaterError.rawValue
  }
}

// Sparkle 的 updater delegate 回调都发生在主线程，但它的 ObjC 协议没有 actor 标注。
// 用 @preconcurrency 承接这份既有约定，避免为每个回调手写 nonisolated 再跳回主线程。
extension SoftwareUpdateService: @preconcurrency SPUUpdaterDelegate {
  /// 通道真值在 AppPreferences。Sparkle 每次检查都会重新问一遍，因此这里现读而不缓存。
  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    AppPreferences.updateChannel(from: defaults).sparkleChannelNames
  }

  /// 抑制 Sparkle 在第二次启动时弹出的「是否自动检查更新」权限对话框。
  ///
  /// 这个问题由「设置 → 通用 → 更新」独占回答：允许 Sparkle 自己问，等于让同一个
  /// UserDefaults 键有两个写入入口，正是我们要避免的漂移源。Info.plist 里显式声明的
  /// SUEnableAutomaticChecks 是同一件事的第二道保险。
  func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
    false
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    status = .available(version: item.displayVersionString)
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    status = .upToDate
  }

  func updater(
    _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
    with request: NSMutableURLRequest
  ) {
    status = .downloading(version: item.displayVersionString)
  }

  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    status = .readyToInstall(version: item.displayVersionString)
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    guard !Self.isUserCancellation(error) else {
      status = .idle
      return
    }
    status = .failed(reason: error.localizedDescription)
  }

  /// 兜底：某些「没找到更新」的路径只会走完整周期回调而不触发
  /// `updaterDidNotFindUpdate`，缺了这一条状态会永远停在「正在检查…」。
  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    guard status == .checking else { return }
    status = error == nil ? .upToDate : .idle
  }
}

extension SoftwareUpdateService: @preconcurrency SPUStandardUserDriverDelegate {
  /// 声明支持温和提醒，Sparkle 才会在展示排班更新前征询下面那个方法。
  var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Aster 在前台时不让排班更新抢焦点：终端用户很可能正盯着一条跑了十分钟的命令。
  /// 此时只刷新设置页状态点与 Dock 徽标，用户自己点「检查更新…」时再走完整 UI。
  /// 应用在后台时交回 Sparkle，让它按标准方式提醒。
  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    !NSApp.isActive
  }
}
