// 界面文字可读性：字号档位与次要文字加深规则。只描述规则，不依赖 AppKit；
// 应用层的 `InterfaceScale` 与 `ThemeRuntime` 负责把它们落到字体和颜色上。

import Foundation

/// 界面（侧栏、面板、设置页）文字的缩放档位。终端字号由 `appearance.fontSize` 单独控制，
/// 两者互不影响。用固定档位而不是自由倍数：每一档的布局都能逐屏验收。
public enum InterfaceTextScale: String, CaseIterable, Codable, Equatable, Sendable {
  case small
  case standard
  case large
  case larger
  case largest

  /// 相对默认字号的倍数。
  public var factor: Double {
    switch self {
    case .small: 0.9
    case .standard: 1
    case .large: 1.15
    case .larger: 1.3
    case .largest: 1.5
    }
  }

  /// 未知档位落回默认，而不是让整份配置解码失败：手改配置写错一个词不该丢掉全部设置。
  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = InterfaceTextScale(rawValue: raw) ?? .standard
  }
}

/// 「加深界面文字」的取色规则：把次要文字色朝主文字色推，直到和背景的对比度达标。
public enum InterfaceTextContrast {
  /// WCAG AA 对正文的最低对比度要求。
  public static let minimumRatio = 4.5

  /// 返回加深后的文字色。
  ///
  /// - Parameters:
  ///   - color: 原本的次要 / 三级文字色。
  ///   - foreground: 主文字色，加深的方向与上限。
  ///   - background: 文字所在的底色；半透明（磨砂材质）时算不出真实对比度，传 `nil`。
  ///
  /// 先固定推近 `baseBlend`，保证开关打开后一定看得出变化；背景已知时再继续推，直到对比度
  /// 不低于 `minimumRatio` 或已经等于主文字色。原色的透明度保持不变。
  public static func strengthened(
    _ color: HexColor, toward foreground: HexColor, against background: HexColor?,
    baseBlend: Double = 0.4
  ) -> HexColor {
    var blend = min(max(baseBlend, 0), 1)
    var result = mix(color, foreground, blend)
    guard let background, background.alpha == 255 else { return result }
    while blend < 1, contrastRatio(result, background) < minimumRatio {
      blend = min(blend + 0.1, 1)
      result = mix(color, foreground, blend)
    }
    return result
  }

  /// WCAG 2 对比度，范围 1...21。两色都按不透明处理。
  public static func contrastRatio(_ first: HexColor, _ second: HexColor) -> Double {
    let a = relativeLuminance(first)
    let b = relativeLuminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// sRGB 相对亮度（WCAG 定义）。
  static func relativeLuminance(_ color: HexColor) -> Double {
    func linear(_ channel: UInt8) -> Double {
      let value = Double(channel) / 255
      return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
  }

  /// 按 `fraction` 从 `base` 线性混到 `target`，保留 `base` 的透明度。
  private static func mix(_ base: HexColor, _ target: HexColor, _ fraction: Double) -> HexColor {
    func channel(_ from: UInt8, _ to: UInt8) -> UInt8 {
      UInt8((Double(from) + (Double(to) - Double(from)) * fraction).rounded())
    }
    return HexColor(
      red: channel(base.red, target.red),
      green: channel(base.green, target.green),
      blue: channel(base.blue, target.blue),
      alpha: base.alpha
    )
  }
}
