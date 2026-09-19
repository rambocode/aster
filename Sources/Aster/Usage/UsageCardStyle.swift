// 浮动窗里三页共用的卡片外观。磨砂背景下卡片必须自带一层「板子」，否则会被桌面冲淡。
import AppKit
import AsterCore

/// 配额页、Token 页、会话页的卡片统一走这里，改一处三页同时生效。
///
/// 面板底是 `NSVisualEffectView` 磨砂，透出来的是桌面和别的窗口。卡片若只用
/// `AsterTheme.ink` 的低透明度着色，遇到花哨的背景就会被冲掉，小字跟着发虚。
/// 所以卡片底用 `AsterTheme.paper`（亮色近白、暗色近黑）压一层不透明度，把内容
/// 从背景里托起来；描边用全强度 `hairline`，磨砂下半强度的线会断续。
enum UsageCardStyle {
  /// 卡片底的不透明度。够把背景压住，又保留「浮在玻璃上」的观感。
  static let fillAlpha: CGFloat = 0.55
  static let cornerRadius: CGFloat = 10
  static let borderWidth: CGFloat = 1
  /// 卡片内边距，三页保持一致。
  static let contentInset: CGFloat = 14

  /// 把卡片外观应用到某个视图。必须在视图已有 `layer` 时调用。
  ///
  /// 动态色要在目标外观下解析成 `cgColor`；调用方需在 `viewDidChangeEffectiveAppearance`
  /// 里再调一次，否则亮暗切换后颜色停在旧值。
  static func apply(to view: NSView, hovered: Bool = false) {
    view.wantsLayer = true
    guard let layer = view.layer else { return }
    layer.cornerRadius = cornerRadius
    layer.borderWidth = borderWidth
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      // 悬停时再压实一点，让「这张卡可以点」有反馈，又不至于跳色。
      let alpha = hovered ? fillAlpha + 0.14 : fillAlpha
      layer.backgroundColor = AsterTheme.paper.withAlphaComponent(alpha).cgColor
      layer.borderColor = AsterTheme.hairline.cgColor
    }
  }
}
