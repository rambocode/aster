import AppKit

/// 按 `Resources/AsterIcon.svg` 的几何在 1024 网格上重画 Dock 图标。
///
/// Dock 的「任务进行时旋转」只转中间的星芒、「出错时变红」要整块换底色，这两件事都
/// 需要分图层绘制；`NSApp.applicationIconImage` 是已经拍平的位图，做不到。所以这里
/// 保留一份与 SVG 逐路径对齐的矢量副本。**改 `AsterIcon.svg` 时必须同步这里的常量。**
enum DockIconArtwork {
  /// 品牌珊瑚色底板，与 `AsterIcon.svg` 的 `#EA6D49` 一致。
  static let plateColor = NSColor(srgbRed: 0xEA / 255, green: 0x6D / 255, blue: 0x49 / 255, alpha: 1)
  /// 「出错时变红」的真值。刻意换成整块不透明红而不是叠半透明红：珊瑚底色本身偏红，
  /// 叠色混出来仍然是橙的，用户根本看不出状态变了。
  static let errorPlateColor = NSColor(
    srgbRed: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255, alpha: 1)

  /// SVG 的设计网格边长；所有路径常量都在这个坐标系里。
  private static let grid: CGFloat = 1024
  /// 圆角半径 ≈ 22.4%，Apple squircle 比例。
  private static let cornerRadius: CGFloat = 230
  /// 前景线宽，与 SVG 的 `stroke-width="52"` 一致。
  private static let strokeWidth: CGFloat = 52
  /// 星芒的几何中心，也是旋转轴心。
  private static let sparkleCenter = CGPoint(x: 548, y: 530)

  /// 渲染一帧 Dock 图标。`sparkleAngle` 只作用于中央星芒，底板与提示符始终静止。
  static func image(size: NSSize, sparkleAngle: CGFloat, plate: NSColor) -> NSImage {
    // flipped: true 让绘制坐标系与 SVG 同为 y 向下，路径常量可以逐字照抄。
    NSImage(size: size, flipped: true) { _ in
      guard let context = NSGraphicsContext.current else { return true }
      context.imageInterpolation = .high

      let scale = NSAffineTransform()
      scale.scale(by: min(size.width, size.height) / grid)
      scale.concat()

      plate.setFill()
      NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: grid, height: grid),
        xRadius: cornerRadius,
        yRadius: cornerRadius
      ).fill()

      NSColor.white.setFill()
      NSColor.white.setStroke()
      promptPath().stroke()
      trackPath().stroke()

      // 星芒单独绕自身中心旋转，所以必须在独立的图形状态里变换，避免污染其它图层。
      context.saveGraphicsState()
      let spin = NSAffineTransform()
      spin.translateX(by: sparkleCenter.x, yBy: sparkleCenter.y)
      spin.rotate(byDegrees: sparkleAngle)
      spin.translateX(by: -sparkleCenter.x, yBy: -sparkleCenter.y)
      spin.concat()
      sparklePath().fill()
      context.restoreGraphicsState()

      return true
    }
  }

  /// 独立提示符 `>`，对应 SVG 第一条 path。
  private static func promptPath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 156, y: 260))
    path.line(to: CGPoint(x: 278, y: 356))
    path.line(to: CGPoint(x: 156, y: 452))
    applyStrokeStyle(path)
    return path
  }

  /// 连续回转轨道，对应 SVG 第二条 path。
  private static func trackPath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 684, y: 676))
    path.curve(
      to: CGPoint(x: 768, y: 398),
      controlPoint1: CGPoint(x: 754, y: 586), controlPoint2: CGPoint(x: 794, y: 488))
    path.curve(
      to: CGPoint(x: 474, y: 286),
      controlPoint1: CGPoint(x: 731, y: 272), controlPoint2: CGPoint(x: 597, y: 231))
    path.curve(
      to: CGPoint(x: 307, y: 592),
      controlPoint1: CGPoint(x: 349, y: 342), controlPoint2: CGPoint(x: 284, y: 466))
    path.curve(
      to: CGPoint(x: 572, y: 800),
      controlPoint1: CGPoint(x: 331, y: 724), controlPoint2: CGPoint(x: 445, y: 797))
    path.curve(
      to: CGPoint(x: 860, y: 748),
      controlPoint1: CGPoint(x: 670, y: 802), controlPoint2: CGPoint(x: 756, y: 779))
    path.line(to: CGPoint(x: 860, y: 610))
    applyStrokeStyle(path)
    return path
  }

  /// 四向星芒，对应 SVG 第三条 path；这是唯一会旋转的图层。
  private static func sparklePath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 548, y: 405))
    path.curve(
      to: CGPoint(x: 674, y: 530),
      controlPoint1: CGPoint(x: 558, y: 480), controlPoint2: CGPoint(x: 599, y: 520))
    path.curve(
      to: CGPoint(x: 548, y: 655),
      controlPoint1: CGPoint(x: 599, y: 540), controlPoint2: CGPoint(x: 558, y: 580))
    path.curve(
      to: CGPoint(x: 422, y: 530),
      controlPoint1: CGPoint(x: 538, y: 580), controlPoint2: CGPoint(x: 497, y: 540))
    path.curve(
      to: CGPoint(x: 548, y: 405),
      controlPoint1: CGPoint(x: 497, y: 520), controlPoint2: CGPoint(x: 538, y: 480))
    path.close()
    return path
  }

  /// 与 SVG 的 `stroke-linecap/linejoin="round"` 对齐；描边端点形状直接影响识别度。
  private static func applyStrokeStyle(_ path: NSBezierPath) {
    path.lineWidth = strokeWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
  }
}
