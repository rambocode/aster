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

/// 进程表的表头：三列标题，当前排序列带方向箭头，整块可点。
@MainActor
final class RemoteProcessHeaderRow: NSStackView {
  private let nameButton = NSButton(title: "", target: nil, action: nil)
  private var cpuButton: ActionButton!
  private var memoryButton: ActionButton!

  init(onSelect: @escaping (RemoteProcessSortColumn) -> Void) {
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .firstBaseline
    spacing = 8
    distribution = .fill

    cpuButton = ActionButton(bezelStyle: .inline) { onSelect(.cpu) }
    memoryButton = ActionButton(bezelStyle: .inline) { onSelect(.memory) }
    cpuButton.identifier = NSUserInterfaceItemIdentifier("details-remote-process-sort-cpu")
    memoryButton.identifier = NSUserInterfaceItemIdentifier("details-remote-process-sort-memory")
    // 进程列不参与排序：名称排序对「谁在吃资源」这个问题没有帮助，留着只会多一个误点目标。
    nameButton.isEnabled = false
    let headerButtons: [NSButton] = [nameButton, cpuButton, memoryButton]
    for button in headerButtons {
      button.isBordered = false
      button.alignment = .left
    }
    nameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let valueButtons: [NSButton] = [cpuButton, memoryButton]
    for button in valueButtons {
      button.alignment = .right
      button.setContentCompressionResistancePriority(.required, for: .horizontal)
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
    }
    addArrangedSubview(nameButton)
    addArrangedSubview(cpuButton)
    addArrangedSubview(memoryButton)
  }

  required init?(coder: NSCoder) { nil }

  func apply(sort: RemoteProcessSort) {
    setTitle(nameButton, L("进程"), active: false, sort: sort)
    setTitle(cpuButton, L("CPU"), active: sort.column == .cpu, sort: sort)
    setTitle(memoryButton, L("内存"), active: sort.column == .memory, sort: sort)
  }

  /// 箭头只画在当前排序列上；朝上是升序、朝下是降序，与 Finder 列表一致。
  private func setTitle(
    _ button: NSButton, _ text: String, active: Bool, sort: RemoteProcessSort
  ) {
    let arrow = active ? (sort.order == .ascending ? " ▲" : " ▼") : ""
    button.attributedTitle = NSAttributedString(
      string: text + arrow,
      attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: active ? .semibold : .regular),
        .foregroundColor: active ? AsterTheme.ink : AsterTheme.tertiaryInk,
      ])
  }
}

/// 进程表的一行：名称可截断，CPU 与内存两列固定宽度常驻；整行可点开详情。
@MainActor
final class RemoteProcessRow: HoverHighlightRowView {
  private let nameButton = PointingHandButton()
  private let cpuLabel = NSTextField(labelWithString: "")
  private let memoryLabel = NSTextField(labelWithString: "")
  private var onOpen: (() -> Void)?

  init(sample: RemoteProcessSample, onOpen: @escaping () -> Void) {
    super.init(frame: .zero)
    self.onOpen = onOpen
    hoverHorizontalInset = 0

    nameButton.isBordered = false
    nameButton.alignment = .left
    nameButton.imagePosition = .noImage
    nameButton.lineBreakMode = .byTruncatingTail
    nameButton.target = self
    nameButton.action = #selector(openDetail)
    nameButton.attributedTitle = NSAttributedString(
      string: sample.command,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
        .foregroundColor: AsterTheme.ink,
      ])
    nameButton.toolTip = sample.arguments.isEmpty ? sample.command : sample.arguments
    nameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    for (label, text) in [
      (cpuLabel, String(format: "%.1f%%", sample.cpuPercent)),
      (memoryLabel, RemoteInspectionFormat.kibibytes(sample.residentKiB)),
    ] {
      label.stringValue = text
      label.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
      label.textColor = AsterTheme.secondaryInk
      label.alignment = .right
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
      label.setContentHuggingPriority(.required, for: .horizontal)
    }

    let row = NSStackView(views: [nameButton, cpuLabel, memoryLabel])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 8
    row.distribution = .fill
    addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
      cpuLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
      memoryLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
    ])
  }

  required init?(coder: NSCoder) { nil }

  @objc private func openDetail() { onOpen?() }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    onOpen?()
  }
}
