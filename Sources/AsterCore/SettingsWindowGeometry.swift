import Foundation

/// 设置窗口的尺寸契约：宽高都可拉伸并跨启动记忆。
///
/// 钳制规则放在 AsterCore 而不是窗口控制器里，是为了让「恢复出来的尺寸合不合法」
/// 成为纯函数并被测试覆盖；AppKit 层只负责把结果套到 `NSWindow` 上。
public enum SettingsWindowGeometry: Sendable {
  /// 首次打开（无记忆值）时的内容宽度。
  public static let width: Double = 700
  /// 内容区最小宽度：侧栏固定为 200pt，剩余空间保证右侧单列设置仍可完整使用。
  public static let minimumWidth: Double = 700
  /// 内容区最小高度：低于该值时侧栏导航与内容卡片会同时被压瘪。
  public static let minimumHeight: Double = 460
  /// 首次打开（无记忆值）时的内容高度。
  public static let defaultHeight: Double = 460
  /// 记忆宽度的持久化键，窗口状态不进入可导出的用户配置。
  public static let widthDefaultsKey = "aster.settings.window-width.v1"
  /// 记忆高度的持久化键，沿用 `aster.<域>.<名>.v<版本>` 命名约定。
  public static let heightDefaultsKey = "aster.settings.window-height.v1"

  /// 把候选内容宽度收进 `[minimumWidth, availableWidth]`。
  ///
  /// 用户拔掉外接显示器后，上次记住的宽窗口可能超过当前屏幕；恢复时按可视宽度收窄。
  /// `availableWidth` 小于最小宽度时仍以最小宽度为准，避免右侧设置被压到不可用。
  public static func clampWidth(_ width: Double, availableWidth: Double) -> Double {
    guard width.isFinite, width > 0 else { return Self.width }
    let upperBound = max(minimumWidth, availableWidth)
    return min(max(width, minimumWidth), upperBound)
  }

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
