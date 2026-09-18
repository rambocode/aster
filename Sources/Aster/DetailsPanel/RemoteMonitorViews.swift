// 服务器监控页的可复用视图：分页 chip 行、两列数值行、占比条。

import AppKit
import AsterCore
import Foundation

/// 分页标题。`L()` 只接受字面量，因此映射写在视图层，Core 只保留分页身份。
@MainActor
func remoteMonitorTabTitle(_ tab: RemoteMonitorTab) -> String {
  switch tab {
  case .overview: L("概览")
  case .disks: L("磁盘")
  case .processes: L("进程")
  case .ports: L("端口")
  }
}

/// 监控分页的 chip 行。
///
/// 视觉与详情面板顶部的页签一致（选中项灰底圆角），但它属于 Info 页内部，不参与
/// 面板级的页签配置——用户隐藏不了其中某一页，那只会让监控数据凭空缺一块。
@MainActor
final class RemoteMonitorTabBar: NSStackView {
  private var buttons: [RemoteMonitorTab: NSButton] = [:]
  private let onSelect: (RemoteMonitorTab) -> Void
  private(set) var selection: RemoteMonitorTab
  private var mode: RemoteInspectorLayout.Mode = .compact

  init(selection: RemoteMonitorTab, onSelect: @escaping (RemoteMonitorTab) -> Void) {
    self.selection = selection
    self.onSelect = onSelect
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 4
    edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 2, right: 14)
    for tab in RemoteMonitorTab.allCases {
      let button = ActionButton(title: remoteMonitorTabTitle(tab), bezelStyle: .inline) { [weak self] in
        self?.select(tab)
      }
      button.isBordered = false
      button.identifier = NSUserInterfaceItemIdentifier(
        "details-remote-monitor-tab-\(tab.rawValue)")
      buttons[tab] = button
      addArrangedSubview(button)
    }
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  func select(_ tab: RemoteMonitorTab) {
    guard selection != tab else { return }
    selection = tab
    applyStyle()
    onSelect(tab)
  }

  /// 窄栏把 chip 字号和间距一起收紧，四个页签才塞得进 240pt 的最小宽度。
  func apply(mode: RemoteInspectorLayout.Mode) {
    guard self.mode != mode else { return }
    self.mode = mode
    spacing = mode == .compact ? 2 : 4
    applyStyle()
  }

  private func applyStyle() {
    let size: CGFloat = mode == .compact ? 10.5 : 11.5
    for (tab, button) in buttons {
      let selected = tab == selection
      button.attributedTitle = NSAttributedString(
        string: remoteMonitorTabTitle(tab),
        attributes: [
          .font: NSFont.systemFont(ofSize: size, weight: selected ? .semibold : .regular),
          .foregroundColor: selected ? AsterTheme.ink : AsterTheme.secondaryInk,
        ])
      button.wantsLayer = true
      button.layer?.cornerRadius = 5
      button.layer?.backgroundColor =
        selected ? AsterTheme.ink.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
    }
  }
}

/// 「左侧名称 + 右侧数值」的一行。
///
/// 监控里的进程、端口过去是一条等宽长字符串，窄栏下尾部被整体截断，先丢的恰好是
/// 用户最想看的数值。拆成两列后名称让位、数值常驻。
@MainActor
func remoteMetricRow(
  leading: String,
  trailing: String,
  leadingColor: NSColor = AsterTheme.ink,
  trailingColor: NSColor = AsterTheme.secondaryInk,
  size: CGFloat = 10.5,
  truncatesLeadingInMiddle: Bool = false
) -> NSView {
  let name = NSTextField(labelWithString: leading)
  name.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
  name.textColor = leadingColor
  name.lineBreakMode = truncatesLeadingInMiddle ? .byTruncatingMiddle : .byTruncatingTail
  name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  name.setContentHuggingPriority(.defaultLow, for: .horizontal)

  let value = NSTextField(labelWithString: trailing)
  value.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
  value.textColor = trailingColor
  value.alignment = .right
  value.lineBreakMode = .byClipping
  value.setContentCompressionResistancePriority(.required, for: .horizontal)
  value.setContentHuggingPriority(.required, for: .horizontal)

  let row = NSStackView(views: [name, value])
  row.orientation = .horizontal
  row.alignment = .firstBaseline
  row.spacing = 8
  row.distribution = .fill
  return row
}
