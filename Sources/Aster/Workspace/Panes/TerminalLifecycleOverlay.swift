import AppKit
import AsterCore
import Darwin

/// 覆盖在已结束终端最后一帧之上的可恢复状态卡。根视图本身穿透命中，用户仍可选择、
/// 复制和检查旧输出；只有状态卡与“重新启动 Shell”按钮接收鼠标事件。
@MainActor
final class TerminalLifecycleOverlayView: NSView {
  private struct Presentation {
    var title: String
    var detail: String
    var symbol: String

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
      case .detached:
        title = "已分离"
        detail = "后台任务继续运行，布局已保留。重新附加即可恢复画面。"
        symbol = "bolt.horizontal.circle"
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

  /// 冷恢复路径对应的状态卡展示。
  private struct RecoveryPresentation {
    var title: String
    var detail: String
    var symbol: String

    /// 将 PaneRecoveryPath 映射为状态卡文案与图标。
    init(_ path: PaneRecoveryPath) {
      switch path {
      case .continueRunning:
        title = "继续运行"
        detail = "后台任务持续运行中，已重新连接。"
        symbol = "checkmark.circle"
      case .newShell:
        title = "新 Shell"
        detail = "服务重启后创建了新的 Shell 进程。"
        symbol = "terminal"
      case .historyReplay:
        title = "历史回放"
        detail = "正在回放磁盘上保存的屏幕历史，非实时状态。"
        symbol = "clock.arrow.circlepath"
      case .agentRestore(_, _, _, let provider, _):
        title = "Agent 对话恢复"
        detail = "已通过 \(provider.rawValue) --resume 恢复对话。"
        symbol = "arrow.uturn.backward.circle"
      case .failed(_, _, _, let reason):
        title = "恢复失败"
        detail = "\(reason)。已创建新 Shell 替代。"
        symbol = "exclamationmark.triangle"
      }
    }
  }

  init?(session: TerminalSession) {
    guard var presentation = Presentation(
      state: session.lifecycleState,
      startupError: session.startupError
    ) else { return nil }
    // 受管（远端）Pane：显示桥的退出码对用户没有意义，说远端发生了什么、能做什么。
    // 附加前就已退出的受管终端走 markManagedFailure（引用被清掉、只留 managedFailure），同样算受管。
    let isManaged = session.managedTerminal != nil || session.managedFailure != nil
    if isManaged, case .ended = session.lifecycleState {
      presentation.title = "远端进程已结束"
      presentation.detail =
        (session.managedExitSummary ?? session.managedFailure ?? "远端进程已退出。")
        + " 可以在此 Pane 重新启动一个远端 Shell，或关闭这个标签。"
      presentation.symbol = "server.rack"
    }
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

    // 分离态的按钮是“重新附加”，不能沿用“重新启动 Shell”——后者会让用户以为
    // 需要新建进程，而受管任务其实仍在运行。
    let isDetached = session.lifecycleState == .detached
    let restart = ActionButton(
      title: isDetached ? "重新附加" : "重新启动 Shell",
      symbol: isDetached ? "bolt.horizontal.circle" : "arrow.clockwise"
    ) { [weak session] in
      guard let session else { return }
      _ = isDetached ? session.reattachManagedTerminal() : session.restart()
    }
    restart.identifier = NSUserInterfaceItemIdentifier(
      "terminal-restart-shell-\(session.id.uuidString)")
    restart.isEnabled = session.canRestart

    let text = NSStackView(views: [title, detail, privacy])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    var trailing: [NSView] = [restart]
    // 远端 Pane 结束后多一个「关闭标签」：Agent 退出后用户要么继续用远端 Shell，要么关掉。
    if isManaged, case .ended = session.lifecycleState {
      let close = ActionButton(title: "关闭标签", symbol: "xmark.circle") { [weak session] in
        session?.requestManagedClose()
      }
      close.identifier = NSUserInterfaceItemIdentifier(
        "terminal-close-managed-\(session.id.uuidString)")
      trailing.append(close)
    }
    let row = NSStackView(views: [icon, text] + trailing)
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

  /// 从冷恢复路径创建状态卡。仅在有有效 recoveryPath 时返回非 nil。
  init?(session: TerminalSession, recoveryPath: PaneRecoveryPath) {
    let rp = RecoveryPresentation(recoveryPath)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("terminal-recovery-overlay-\(session.id.uuidString)")

    let card = NSView()
    card.wantsLayer = true
    card.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.96).cgColor
    card.layer?.borderColor = AsterTheme.hairline.cgColor
    card.layer?.borderWidth = 1
    card.layer?.cornerRadius = 10

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: rp.symbol,
        accessibilityDescription: rp.title
      ) ?? NSImage()
    )
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    icon.contentTintColor = AsterTheme.warning
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 22),
      icon.heightAnchor.constraint(equalToConstant: 22),
    ])

    let title = NSTextField(labelWithString: rp.title)
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    title.textColor = AsterTheme.ink
    let detail = NSTextField(wrappingLabelWithString: rp.detail)
    detail.font = .systemFont(ofSize: 10.5)
    detail.textColor = AsterTheme.secondaryInk
    detail.maximumNumberOfLines = 2

    let text = NSStackView(views: [title, detail])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    let row = NSStackView(views: [icon, text])
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
