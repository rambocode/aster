// 用量数字的展示口径：显示「已经用掉多少」还是「还剩多少」。
import Foundation

/// 配额页与状态栏的数字口径。
///
/// 两种看法各有用处：排查「这周烧得快不快」看已用，决定「还能不能开新会话」看剩余。
/// 切换只影响展示，不影响任何取数与判定——严重度一律按已用百分比算。
public enum UsageDisplayMode: String, Codable, Equatable, Sendable, CaseIterable {
  case used
  case remaining

  /// 分段控件上的短标签。
  public var shortLabel: String {
    switch self {
    case .used: L("已用")
    case .remaining: L("剩余")
    }
  }

  /// 把「已用百分比」换算成当前口径要显示的数字。
  public func displayPercent(usedPercent: Double) -> Double {
    switch self {
    case .used: usedPercent
    case .remaining: max(0, 100 - usedPercent)
    }
  }

  /// 进度条填充比例，0…1。与 `displayPercent` 同口径，所以「剩余」模式下条会随消耗变短。
  public func fillFraction(usedPercent: Double) -> Double {
    min(max(displayPercent(usedPercent: usedPercent) / 100, 0), 1)
  }
}
