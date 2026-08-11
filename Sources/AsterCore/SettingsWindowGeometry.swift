import Foundation

/// 设置窗口的尺寸契约：宽度固定、高度可拉伸并跨启动记忆。
///
/// 钳制规则放在 AsterCore 而不是窗口控制器里，是为了让「恢复出来的高度合不合法」
/// 成为纯函数并被测试覆盖；AppKit 层只负责把结果套到 `NSWindow` 上。
public enum SettingsWindowGeometry: Sendable {
  /// 设置页的固定内容宽度。九类导航 + 卡片排版按该宽度设计，横向不参与伸缩。
  public static let width: Double = 700
  /// 内容区最小高度：低于该值时侧栏导航与内容卡片会同时被压瘪。
  public static let minimumHeight: Double = 460
  /// 首次打开（无记忆值）时的内容高度。
  public static let defaultHeight: Double = 460
  /// 记忆高度的持久化键，沿用 `aster.<域>.<名>.v<版本>` 命名约定。
  public static let heightDefaultsKey = "aster.settings.window-height.v1"

  /// 把候选内容高度收进 `[minimumHeight, availableHeight]`。
  ///
  /// 上界必须跟随当前屏幕：拔掉外接显示器或调低分辨率后，上次记住的高度会比屏幕还高，
  /// 恢复出来的窗口标题栏被推到菜单栏之上，用户既拖不动也关不掉。`availableHeight`
  /// 小于最小高度时以最小高度为准，宁可超出屏幕也不给出一个没法用的窄窗口。
  public static func clampHeight(_ height: Double, availableHeight: Double) -> Double {
    guard height.isFinite, height > 0 else { return defaultHeight }
    let upperBound = max(minimumHeight, availableHeight)
    return min(max(height, minimumHeight), upperBound)
  }
}
