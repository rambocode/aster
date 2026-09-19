// 系统顶部状态栏的用量条目：图标 + 各账号百分比 + 「等待输入」红点。
import AppKit
import AsterCore
import Foundation

/// 真正的 `NSStatusItem` 实现。
///
/// 状态栏是系统级的常驻界面，任何一次多余重绘都会让菜单栏闪一下，所以 `apply` 先比
/// 内容再决定改不改。红点不画进模板图：模板图会被系统统一染成单色，红色会丢失，
/// 因此单独用一层 `CALayer` 叠在按钮上。
@MainActor
final class UsageStatusItemController: UsageStatusItemPresenting {
  /// 首选图标；系统不认识（旧 SF Symbols）时退到通用柱状图。
  private static let symbolNames = ["gauge.with.dots.needle.50percent", "chart.bar"]
  private static let badgeDiameter: CGFloat = 5.5

  private let statusBar: NSStatusBar
  private let item: NSStatusItem
  private let badgeLayer = CALayer()
  /// 上一次真正应用过的内容；`nil` 表示还没渲染过。
  private var applied: (summary: UsageStatusSummary, accounts: [UsageAccountSnapshot])?
  /// 实际重绘过几次。测试用它确认「值没变不重绘」。
  private(set) var renderCount = 0

  var onClick: (() -> Void)?

  init(statusBar: NSStatusBar = .system) {
    self.statusBar = statusBar
    item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    item.isVisible = true
    badgeLayer.cornerRadius = Self.badgeDiameter / 2
    if let button = item.button {
      button.identifier = NSUserInterfaceItemIdentifier("usage-status-item")
      button.image = Self.makeSymbolImage()
      button.imagePosition = .imageLeading
      button.wantsLayer = true
      button.target = self
      button.action = #selector(handleClick)
      button.toolTip = L("AI 用量")
      button.setAccessibilityLabel(L("AI 用量"))
    }
  }

  // MARK: - UsageStatusItemPresenting

  var buttonFrameInScreen: NSRect? {
    guard let button = item.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  func apply(_ summary: UsageStatusSummary, accounts: [UsageAccountSnapshot] = []) {
    if let applied, applied.summary == summary, applied.accounts == accounts { return }
    applied = (summary, accounts)
    renderCount += 1
    guard let button = item.button else { return }
    button.attributedTitle = Self.title(for: summary)
    let tooltip = Self.tooltip(for: accounts)
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    updateBadge(needsAttention: summary.needsAttention)
  }

  func remove() {
    badgeLayer.removeFromSuperlayer()
    item.button?.target = nil
    statusBar.removeStatusItem(item)
  }

  // MARK: - 内容

  /// 每段一个百分比，段间用「 · 」分隔；没有任何段时只留图标。
  /// 等宽数字保证百分比跳动时图标不来回位移。
  private static func title(for summary: UsageStatusSummary) -> NSAttributedString {
    let result = NSMutableAttributedString()
    guard !summary.segments.isEmpty else { return result }
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    for (index, segment) in summary.segments.enumerated() {
      let separator = index == 0 ? " " : " · "
      result.append(
        NSAttributedString(
          string: separator,
          attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
      result.append(
        NSAttributedString(
          string: "\(Int(segment.usedPercent.rounded()))%",
          attributes: [.font: font, .foregroundColor: color(for: segment.severity)]))
    }
    return result
  }

  private static func color(for severity: UsageStatusSummary.Severity) -> NSColor {
    switch severity {
    case .normal: .labelColor
    case .warning: AsterTheme.warning
    case .critical: .systemRed
    }
  }

  /// 每个账号一行：账号名（订阅档位）＋全部窗口的百分比。没有数据时退回功能名。
  ///
  /// 内部可见以便测试。整行是纯数据拼接，没有需要翻译的句子，因此不走 `L()`。
  static func tooltip(for accounts: [UsageAccountSnapshot]) -> String {
    let lines = accounts.compactMap { account -> String? in
      guard !account.windows.isEmpty else { return nil }
      let detail = account.windows
        .map { "\($0.displayLabel) \(Int($0.usedPercent.rounded()))%" }
        .joined(separator: " · ")
      let plan = account.plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let name = plan.isEmpty ? account.label : "\(account.label)（\(plan)）"
      return "\(name)：\(detail)"
    }
    return lines.isEmpty ? L("AI 用量") : lines.joined(separator: "\n")
  }

  private static func makeSymbolImage() -> NSImage? {
    for name in symbolNames {
      if let image = NSImage(systemSymbolName: name, accessibilityDescription: L("AI 用量")) {
        image.isTemplate = true
        return image
      }
    }
    return nil
  }

  /// 红点叠在图标右上角。位置按 cell 实际绘制的图标矩形算，
  /// 因为菜单栏高度与图标留白由系统决定，写死偏移在不同机型上会错位。
  private func updateBadge(needsAttention: Bool) {
    guard let button = item.button else { return }
    guard needsAttention else {
      badgeLayer.removeFromSuperlayer()
      return
    }
    button.layoutSubtreeIfNeeded()
    let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
    let size = Self.badgeDiameter
    badgeLayer.frame = CGRect(
      x: imageRect.maxX - size + 1, y: imageRect.maxY - size + 1, width: size, height: size)
    badgeLayer.backgroundColor = NSColor.systemRed.cgColor
    if badgeLayer.superlayer == nil { button.layer?.addSublayer(badgeLayer) }
  }

  @objc private func handleClick() {
    onClick?()
  }
}
