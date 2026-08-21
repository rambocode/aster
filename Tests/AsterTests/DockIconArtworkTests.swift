import AppKit
import Testing

@testable import Aster

/// 取图标某点的颜色。测试全部按 1024 设计网格的归一化坐标取样，尺寸变了也不用改。
@MainActor
private func sample(_ image: NSImage, x: CGFloat, y: CGFloat) throws -> NSColor {
  let data = try #require(image.tiffRepresentation)
  let representation = try #require(NSBitmapImageRep(data: data))
  let pixelX = Int(x * CGFloat(representation.pixelsWide))
  let pixelY = Int(y * CGFloat(representation.pixelsHigh))
  return try #require(representation.colorAt(x: pixelX, y: pixelY))
}

private let renderSize = NSSize(width: 256, height: 256)

@Test("Dock 图标四角透明，底板填品牌珊瑚色")
@MainActor
func dockIconArtworkKeepsCornersTransparent() throws {
  let image = DockIconArtwork.image(
    size: renderSize, sparkleAngle: 0, plate: DockIconArtwork.plateColor)
  // 圆角半径约 22.4%，(1%, 1%) 一定落在圆角之外。白底回归会让这里变成不透明白。
  #expect(try sample(image, x: 0.01, y: 0.01).alphaComponent == 0)
  #expect(try sample(image, x: 0.99, y: 0.01).alphaComponent == 0)
  // 底板中部靠左没有前景，应当是纯珊瑚色。
  let plate = try sample(image, x: 0.1, y: 0.5)
  #expect(plate.alphaComponent == 1)
  #expect(abs(plate.redComponent - DockIconArtwork.plateColor.redComponent) < 0.02)
  #expect(abs(plate.greenComponent - DockIconArtwork.plateColor.greenComponent) < 0.02)
}

@Test("出错底板换成不透明红，而不是给珊瑚色叠一层半透明红")
@MainActor
func dockIconArtworkErrorPlateIsUnmistakablyRed() throws {
  let normal = try sample(
    DockIconArtwork.image(size: renderSize, sparkleAngle: 0, plate: DockIconArtwork.plateColor),
    x: 0.1, y: 0.5)
  let error = try sample(
    DockIconArtwork.image(
      size: renderSize, sparkleAngle: 0, plate: DockIconArtwork.errorPlateColor),
    x: 0.1, y: 0.5)
  // 旧实现用 systemRed@48% 的 sourceAtop 叠在珊瑚色上，混出来仍然偏橙：绿分量几乎没变，
  // 用户看不出状态切换。这里锁死「绿分量必须明显下降」这条可见性条件。
  #expect(normal.greenComponent - error.greenComponent > 0.1)
  #expect(error.redComponent > 0.7)
}

@Test("旋转只作用于中央星芒，圆角底板与提示符保持不动")
@MainActor
func dockIconArtworkRotatesOnlyTheSparkle() throws {
  let base = DockIconArtwork.image(
    size: renderSize, sparkleAngle: 0, plate: DockIconArtwork.plateColor)
  // 45° 是最能区分四向星芒的角度；30° 是实际动画的每帧步进。
  let turned = DockIconArtwork.image(
    size: renderSize, sparkleAngle: 45, plate: DockIconArtwork.plateColor)

  // 星芒中心 (548, 530)、尖端半径约 125。沿对角线取半径 90 的点：0° 时它落在两条
  // 尖角之间的凹陷里（露出底板），转过 45° 后正好被尖角盖住，由橙变白。
  let diagonal = (x: (548 + 64.0) / 1024, y: (530 + 64.0) / 1024)
  let beforeSpin = try sample(base, x: diagonal.x, y: diagonal.y)
  let afterSpin = try sample(turned, x: diagonal.x, y: diagonal.y)
  // 用蓝分量而不是 HSB brightness 判白：珊瑚色 #EA6D49 的 brightness 已经是 0.918，
  // 与白色只差 0.08，区分度太低；蓝分量是 0.28 vs 1.0，差距明确。
  #expect(afterSpin.blueComponent > 0.9)
  #expect(afterSpin.blueComponent - beforeSpin.blueComponent > 0.3)

  // `>` 提示符与底板不参与旋转，两帧必须逐点一致。
  for (x, y) in [(200.0 / 1024, 356.0 / 1024), (0.1, 0.5), (0.9, 0.1)] {
    let before = try sample(base, x: x, y: y)
    let after = try sample(turned, x: x, y: y)
    #expect(abs(before.redComponent - after.redComponent) < 0.01)
    #expect(abs(before.alphaComponent - after.alphaComponent) < 0.01)
  }
}
