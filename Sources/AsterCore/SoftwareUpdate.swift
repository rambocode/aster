import Foundation

/// 软件更新的发布通道。
///
/// Sparkle 的 appcast 用 `<sparkle:channel>` 标记非默认通道，未标记的条目永远落在
/// 默认通道上——也就是说「稳定版」不是一个通道名字，而是「不声明任何通道」。
/// 这个反直觉的语义是 `sparkleChannelNames` 对 `.stable` 返回空集合的原因。
public enum UpdateChannel: String, CaseIterable, Codable, Sendable {
  case stable
  case preview

  /// 传给 `SPUUpdaterDelegate.allowedChannels(for:)` 的集合。
  ///
  /// `.preview` 只追加 `preview` 而不排除默认通道：Sparkle 在设计上不允许 updater 把
  /// 自己排除出默认通道，预览用户因此始终能收到稳定分支上的紧急修复，也保证预览分支
  /// 最终会被稳定版本追上并收敛回去。
  public var sparkleChannelNames: Set<String> {
    switch self {
    case .stable: []
    case .preview: ["preview"]
    }
  }
}

/// 设置页与菜单共享的更新状态投影。
///
/// 刻意不携带 `Date`：时间格式化属于渲染层，放进领域模型会把 `RelativeDateTimeFormatter`
/// 的本地化行为带进纯逻辑测试。
public enum SoftwareUpdateStatus: Equatable, Sendable {
  /// 开发构建或未配置更新源，进程内没有 updater。
  case unavailable
  /// 本次启动尚未检查过。
  case idle
  case checking
  case upToDate
  case available(version: String)
  case downloading(version: String)
  case readyToInstall(version: String)
  case failed(reason: String)

  /// 状态点旁的说明文字，替换设置页该行的 detail。
  public var statusText: String {
    switch self {
    case .unavailable: "此构建未启用自动更新"
    case .idle: "尚未检查更新"
    case .checking: "正在检查更新…"
    case .upToDate: "已是最新版本"
    case .available(let version): "发现新版本 \(version)"
    case .downloading(let version): "正在下载 \(version)…"
    case .readyToInstall(let version): "\(version) 已下载，退出 Aster 后安装"
    case .failed(let reason): "更新检查失败：\(reason)"
    }
  }

  /// 状态点颜色键，与 `settings.css` 的 `.setting-status-dot[data-state]` 一一对应。
  /// 未检查、检查中与不可用共用中性色：它们都不是「结论」，不该抢用户注意力。
  public var statusState: String {
    switch self {
    case .unavailable, .idle, .checking: "unknown"
    case .upToDate: "upToDate"
    case .available, .downloading, .readyToInstall: "updateAvailable"
    case .failed: "failed"
    }
  }

  /// 检查已出结论，可以收掉设置页顶部的进行中横幅。
  public var isTerminal: Bool {
    switch self {
    case .checking, .downloading: false
    default: true
    }
  }
}
