import AppKit
import Testing

@testable import Aster
@testable import AsterCore

// 详情面板页签行的布局回归：首个 chip 的灰底必须离开面板左缘，
// 而不是被 NSButton 的 bezel 内缩吃掉大半个边距。

@MainActor
private func findDescendant(in view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
  if predicate(view) { return view }
  for subview in view.subviews {
    if let found = findDescendant(in: subview, matching: predicate) { return found }
  }
  return nil
}

@Test("详情面板首个页签 chip 的灰底距面板左缘留出固定内边距")
@MainActor
func detailsPanelHeaderKeepsChipLeadingInset() throws {
  let suite = "DetailsPanelHeaderLayoutTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let preferences = AppPreferences(defaults: defaults)
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 340, height: 620),
    styleMask: [.titled, .resizable],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.layoutIfNeeded()

  let chip = try #require(
    findDescendant(in: controller.view) { $0.identifier?.rawValue == "details-chip-info" })
  // 按 frame 量：灰底画在 chip 的 layer 上，用户看到的就是这个矩形。
  let rect = chip.convert(chip.bounds, to: controller.view)
  #expect(abs(rect.minX - DetailsPanelHeaderMetrics.leadingInset) < 0.5)

  // 图标不能贴着灰底左边框：按钮把图标画在自己的左缘，呼吸空间做在图像的透明边距里，
  // 因此用「绘制矩形左缘 + 内边距」还原用户实际看到的图标左边。
  let button = try #require(chip as? NSButton)
  let iconRect = try #require((button.cell as? NSButtonCell)?.imageRect(forBounds: button.bounds))
  let iconInPanel = button.convert(iconRect, to: controller.view)
  let visibleIconMinX = iconInPanel.minX + DetailsPanelHeaderMetrics.iconLeadingPadding
  #expect(visibleIconMinX - rect.minX >= DetailsPanelHeaderMetrics.iconLeadingPadding - 0.5)
}
