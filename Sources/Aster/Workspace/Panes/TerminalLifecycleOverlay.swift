import AppKit
import Darwin

/// 覆盖在已结束终端最后一帧之上的可恢复状态卡。根视图本身穿透命中，用户仍可选择、
/// 复制和检查旧输出；只有状态卡与“重新启动 Shell”按钮接收鼠标事件。
@MainActor
final class TerminalLifecycleOverlayView: NSView {
  private struct Presentation {
    let title: String
    let detail: String
    let symbol: String

    init?(state: TerminalSessionLifecycleState, startupError: String?) {
      switch state {
      case .ended(.exited(let code)) where code == 0:
        title = "Shell 已退出"
        detail = "退出状态码 0。最后画面已保留，可以在当前 Pane 重新启动。"
        symbol = "checkmark.circle"
      case .ended(.exited(let code)):
        title = "Shell 异常退出"
        detail = "退出状态码 \(code)。最后画面已保留，可以在当前 Pane 重新启动。"
        symbol = "exclamationmark.triangle"
      case .ended(.signaled(let signal, let coreDumped)):
        title = "Shell 被信号终止"
        let signalLabel = Self.signalLabel(signal)
        let coreSuffix = coreDumped ? "，系统报告已生成 core dump" : ""
        detail = "终止信号 \(signalLabel)\(coreSuffix)。最后画面已保留。"
        symbol = "bolt.trianglebadge.exclamationmark"
      case .ended(.ioFailure):
        title = "终端连接异常中断"
        detail = "PTY 未取得可靠退出状态。最后画面已保留，可以重新启动 Shell。"
        symbol = "cable.connector.slash"
      case .startFailed:
        title = "Shell 启动失败"
        detail = startupError?.split(separator: "\n").first.map(String.init)
          ?? "无法创建本地终端进程，可以修正配置后重试。"
        symbol = "exclamationmark.triangle"
      case .notStarted, .starting, .running, .stopping:
        return nil
      }
    }

    private static func signalLabel(_ signal: Int32) -> String {
      let name = switch signal {
      case SIGHUP: "SIGHUP"
      case SIGINT: "SIGINT"
      case SIGQUIT: "SIGQUIT"
      case SIGABRT: "SIGABRT"
      case SIGKILL: "SIGKILL"
      case SIGSEGV: "SIGSEGV"
      case SIGPIPE: "SIGPIPE"
      case SIGTERM: "SIGTERM"
      default: "SIGNAL"
      }
      return "\(signal)（\(name)）"
    }
  }

  init?(session: TerminalSession) {
    guard let presentation = Presentation(
      state: session.lifecycleState,
      startupError: session.startupError
    ) else { return nil }
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("terminal-ended-overlay-\(session.id.uuidString)")

    let card = NSView()
    card.wantsLayer = true
    card.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.96).cgColor
    card.layer?.borderColor = AsterTheme.hairline.cgColor
    card.layer?.borderWidth = 1
    card.layer?.cornerRadius = 10

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: presentation.symbol,
        accessibilityDescription: presentation.title
      ) ?? NSImage()
    )
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    icon.contentTintColor = AsterTheme.warning
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 22),
      icon.heightAnchor.constraint(equalToConstant: 22),
    ])

    let title = NSTextField(labelWithString: presentation.title)
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = AsterTheme.ink
    let detail = NSTextField(wrappingLabelWithString: presentation.detail)
    detail.font = .systemFont(ofSize: 10.5)
    detail.textColor = AsterTheme.secondaryInk
    detail.maximumNumberOfLines = 2
    let privacy = NSTextField(labelWithString: "已记录本地诊断信息，不包含命令、终端内容或路径。")
    privacy.font = .systemFont(ofSize: 9.5)
    privacy.textColor = AsterTheme.tertiaryInk

    let restart = ActionButton(title: "重新启动 Shell", symbol: "arrow.clockwise") {
      [weak session] in
      _ = session?.restart()
    }
    restart.identifier = NSUserInterfaceItemIdentifier(
      "terminal-restart-shell-\(session.id.uuidString)")
    restart.isEnabled = session.canRestart

    let text = NSStackView(views: [title, detail, privacy])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    let row = NSStackView(views: [icon, text, restart])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    card.addSubview(row)
    row.pinEdges(to: card)

    addSubview(card)
    card.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      card.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      card.centerXAnchor.constraint(equalTo: centerXAnchor),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
      card.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}
