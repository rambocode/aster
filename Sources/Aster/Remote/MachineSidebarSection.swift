import AppKit
import AsterCore
import Foundation

/// 机器侧栏的一行按钮（P4.3）。
///
/// 结构与 `TabRowButton` 保持同一视觉语言（同样的左内缩、同样的选中背景），但它
/// 表达的是「连到哪台机器的哪个命名会话」，与标签行是两类对象，因此不复用后者：
/// 标签行携带 Agent 角标、关闭按钮和拖拽换窗，机器行一条都不需要。
final class MachineRowButton: NSButton {
  /// 该行对应的机器配置 ID。右键菜单与测试按它定位行。
  let machineID: UUID
  private let handler: () -> Void
  private let isSelected: Bool
  private let tint: NSColor

  init(
    row: MachineFleetRow,
    selected: Bool,
    theme: TerminalTheme,
    action: @escaping () -> Void,
    menuProvider: @escaping () -> NSMenu?
  ) {
    machineID = row.id
    handler = action
    isSelected = selected
    tint = NSColor(
      theme.resolvedColor(forSlot: "tab.foreground")
        ?? theme.style.tab.foreground ?? theme.palette.secondaryForeground)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    target = self
    self.action = #selector(invoke)
    identifier = NSUserInterfaceItemIdentifier("machine-row-\(row.id.uuidString)")
    setAccessibilityRole(.button)
    setAccessibilityLabel("机器 \(row.label)")
    toolTip = Self.toolTip(row)
    heightAnchor.constraint(equalToConstant: 34).isActive = true
    menu = menuProvider()

    let background = NSView()
    background.wantsLayer = true
    background.layer?.cornerRadius = 6
    background.layer?.backgroundColor =
      selected
      ? NSColor(
        theme.resolvedColor(forSlot: "tab.activeBackground")
          ?? theme.style.tab.activeBackground ?? theme.palette.panelBackground
      ).cgColor
      : NSColor.clear.cgColor
    background.translatesAutoresizingMaskIntoConstraints = false
    addSubview(background)

    let row_ = NSStackView()
    row_.orientation = .horizontal
    row_.spacing = 6
    row_.alignment = .centerY
    row_.translatesAutoresizingMaskIntoConstraints = false

    let icon = NSImageView()
    icon.image = NSImage(
      systemSymbolName: row.isLocal ? "laptopcomputer" : "server.rack",
      accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    icon.contentTintColor = tint
    icon.setContentHuggingPriority(.required, for: .horizontal)
    row_.addArrangedSubview(icon)

    let text = NSStackView()
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 0
    let label = makeLabel(row.label, size: 12, weight: .medium, color: tint)
    label.lineBreakMode = .byTruncatingTail
    text.addArrangedSubview(label)
    // 副标题必须显示绑定的命名会话名：同一主机的两个配置只能靠它区分。
    let subtitle = makeLabel(
      row.subtitle, size: 10, weight: .regular,
      color: tint.withAlphaComponent(0.65))
    subtitle.lineBreakMode = .byTruncatingMiddle
    text.addArrangedSubview(subtitle)
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row_.addArrangedSubview(text)

    // 远端探测到的 Agent：在线时把命令名列在行尾（herdrm 的做法是画图标；这里先用文字，
    // 一眼能看到"这台机器上有 grok / claude"），详情在悬停提示与右键菜单。
    if let agents = row.agents, row.state == .online {
      let names = agents.map(\.provider.commandName).joined(separator: " ")
      let label = makeLabel(
        names.isEmpty ? "无 agent" : names, size: 9.5, weight: .medium,
        color: tint.withAlphaComponent(names.isEmpty ? 0.45 : 0.75))
      label.identifier = NSUserInterfaceItemIdentifier("machine-agents")
      label.lineBreakMode = .byTruncatingTail
      label.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
      label.setContentHuggingPriority(.required, for: .horizontal)
      row_.addArrangedSubview(label)
    }
    if let accessory = Self.makeStateAccessory(row: row, tint: tint) {
      row_.addArrangedSubview(accessory)
    }

    addSubview(row_)
    NSLayoutConstraint.activate([
      background.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: CGFloat(theme.style.resolvedSidebarPadding.leading) + 4),
      background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      background.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      row_.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
      row_.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -8),
      row_.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    // 离线/禁用行整体降透明度，明确「这是缓存结构」（P4.7）。
    alphaValue = Self.isDimmed(row.state) ? 0.55 : 1
  }

  required init?(coder: NSCoder) { nil }

  @objc private func invoke() { handler() }

  /// 连接状态指示：connecting/reconnecting 用与标签行同一套动画，attention 用醒目图标。
  ///
  /// 之所以不给 online 画任何东西：一列全是绿点会让真正需要注意的 attention 淹没在噪声里。
  private static func makeStateAccessory(row: MachineFleetRow, tint: NSColor) -> NSView? {
    switch row.state {
    case .connecting, .reconnecting:
      return TabActivitySpinnerView(tint: tint, style: .spin)
    case .attention:
      let icon = NSImageView()
      icon.image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "需要处理")?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
      icon.contentTintColor = .systemOrange
      icon.identifier = NSUserInterfaceItemIdentifier("machine-attention")
      icon.setContentHuggingPriority(.required, for: .horizontal)
      icon.toolTip = row.lastError
      return icon
    case .disabled:
      let icon = NSImageView()
      icon.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "已禁用")?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
      icon.contentTintColor = tint.withAlphaComponent(0.6)
      icon.identifier = NSUserInterfaceItemIdentifier("machine-disabled")
      icon.setContentHuggingPriority(.required, for: .horizontal)
      return icon
    case .disconnected:
      let icon = NSImageView()
      icon.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "未连接")?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
      icon.contentTintColor = tint.withAlphaComponent(0.6)
      icon.identifier = NSUserInterfaceItemIdentifier("machine-offline")
      icon.setContentHuggingPriority(.required, for: .horizontal)
      return icon
    case .online:
      return nil
    }
  }

  private static func isDimmed(_ state: SessionConnectionState) -> Bool {
    switch state {
    case .online, .connecting: false
    case .reconnecting, .attention, .disabled, .disconnected: true
    }
  }

  /// 悬停提示：状态 + 最后更新时间。离线时用户必须能看到缓存有多旧。
  static func toolTip(_ row: MachineFleetRow) -> String {
    var lines = ["状态：\(stateText(row.state))", lastUpdatedText(row.lastUpdatedAt)]
    if let error = row.lastError, !error.isEmpty { lines.append(error) }
    if let agents = row.agents {
      lines.append(agents.isEmpty ? "Agent：远端未发现已知 CLI" : "Agent：" + agentsText(agents))
    } else if !row.isLocal {
      lines.append("Agent：尚未探测")
    }
    return lines.joined(separator: "\n")
  }

  /// 「Grok Build 1.0.30、Claude Code 2.1.0」。版本取 `--version` 首行去掉命令名前缀。
  static func agentsText(_ agents: [RemoteAgentCatalogEntry]) -> String {
    agents.map { entry in
      guard let version = entry.version?.trimmingCharacters(in: .whitespacesAndNewlines),
        !version.isEmpty
      else { return entry.provider.displayName }
      let trimmed = version.hasPrefix(entry.provider.commandName + " ")
        ? String(version.dropFirst(entry.provider.commandName.count + 1)) : version
      return "\(entry.provider.displayName) \(trimmed)"
    }.joined(separator: "、")
  }

  /// 「最后更新」文案。从未连上时明确说明，不显示一个假的时间。
  static func lastUpdatedText(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "从未连接" }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "最后更新 \(seconds) 秒前" }
    if seconds < 3600 { return "最后更新 \(seconds / 60) 分钟前" }
    if seconds < 86400 { return "最后更新 \(seconds / 3600) 小时前" }
    return "最后更新 \(seconds / 86400) 天前"
  }

  /// 连接状态的中文文案。终端退出不在这里表达，它属于终端状态。
  static func stateText(_ state: SessionConnectionState) -> String {
    switch state {
    case .disconnected: "未连接"
    case .connecting: "连接中"
    case .online: "在线"
    case .reconnecting: "重连中"
    case .attention: "需要处理"
    case .disabled: "已禁用"
    }
  }
}
