// 远端 Files 页在「还没收到远端目录上报」时显示的引导横幅，以及它触发的
// 远端集成探测 / 安装与手工输入路径流程。

import AppKit
import AsterCore
import Foundation

/// 未收到远端 OSC 7 上报时的引导视图。
///
/// 只负责呈现与转发点击：安装远端集成需要旁路通道与确认对话框，那部分留在
/// `RemoteFilesSectionController`，横幅本身不持有任何连接资源。
@MainActor
final class RemoteIntegrationBanner: NSView {
  private let titleLabel = makeLabel(L("未收到远端目录上报"), size: 12, weight: .semibold)
  private let detailLabel = makeLabel(
    L("安装远端集成后，远端 Shell 会上报当前目录，此处将跟随 cd 自动刷新。"),
    size: 11,
    color: AsterTheme.secondaryInk
  )
  private let statusLabel = makeLabel("", size: 11, color: AsterTheme.secondaryInk)

  /// 点击「安装远端集成…」。
  var onInstall: (() -> Void)?
  /// 点击「浏览 $HOME」。
  var onBrowseHome: (() -> Void)?
  /// 点击「输入路径…」。
  var onEnterPath: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    detailLabel.maximumNumberOfLines = 3
    detailLabel.lineBreakMode = .byWordWrapping
    statusLabel.maximumNumberOfLines = 3
    statusLabel.lineBreakMode = .byWordWrapping
    statusLabel.isHidden = true

    let install = ActionButton(title: L("安装远端集成…"), bezelStyle: .rounded) { [weak self] in
      self?.onInstall?()
    }
    install.identifier = NSUserInterfaceItemIdentifier("details-remote-install-integration")
    let browse = ActionButton(title: L("浏览 $HOME"), bezelStyle: .rounded) { [weak self] in
      self?.onBrowseHome?()
    }
    browse.identifier = NSUserInterfaceItemIdentifier("details-remote-browse-home")
    let enterPath = ActionButton(title: L("输入路径…"), bezelStyle: .rounded) { [weak self] in
      self?.onEnterPath?()
    }
    enterPath.identifier = NSUserInterfaceItemIdentifier("details-remote-enter-path")

    let actions = NSStackView(views: [install, browse, enterPath])
    actions.orientation = .horizontal
    actions.alignment = .centerY
    actions.spacing = 6

    let column = NSStackView(views: [titleLabel, detailLabel, actions, statusLabel])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: leadingAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      column.topAnchor.constraint(equalTo: topAnchor),
      column.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 显示安装进度或结果。空字符串表示收起该行。
  func setStatus(_ text: String) {
    statusLabel.stringValue = text
    statusLabel.isHidden = text.isEmpty
  }
}

// MARK: - 横幅动作

extension RemoteFilesSectionController {
  /// 绑定横幅上的三个动作。
  func configureBanner() {
    banner.onInstall = { [weak self] in self?.presentIntegrationInstall() }
    banner.onBrowseHome = { [weak self] in
      // 远端命令默认在 `$HOME` 启动，空目录参数即「登录目录」，不需要在本地展开 `~`。
      self?.openDirectory("")
    }
    banner.onEnterPath = { [weak self] in self?.promptForDirectory() }
  }

  /// 手工输入远端目录。输入是不可信文本，只做长度与控制字符检查后交给远端脚本的位置参数。
  func promptForDirectory() {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "/var/log"
    let alert = NSAlert()
    alert.messageText = L("输入路径…")
    alert.accessoryView = field
    alert.addButton(withTitle: L("打开"))
    alert.addButton(withTitle: L("取消"))
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, path.utf8.count <= 4_096,
      path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
    else { return }
    openDirectory(path)
  }

  // MARK: - 远端集成安装

  /// 先探测远端状态，把将要改动的文件列给用户确认，再执行安装。
  func presentIntegrationInstall() {
    guard let host else { return }
    banner.setStatus(L("正在探测远端 Shell 集成…"))
    let client = client
    Task { @MainActor [weak self] in
      let inspected = await client.inspectIntegration(host.context)
      guard let self, self.host?.addressesSameChannel(as: host) == true else { return }
      switch inspected {
      case .failure(let failure):
        // 探测阶段失败时还没有动过远端任何文件，说成「安装失败」会让用户以为
        // 远端被改了一半，必须用探测自己的文案。
        self.banner.setStatus(L("探测失败：\(failure.message)"))
      case .success(let status):
        self.banner.setStatus("")
        let shells = RemoteShellIntegrationShell.allCases.filter {
          status.state(for: $0) != .installed
        }
        guard !shells.isEmpty else {
          self.banner.setStatus(L("远端集成已安装，重新登录后生效"))
          return
        }
        let paths = RemoteShellIntegrationInstall.plannedPaths(for: shells, home: status.home)
        guard self.confirmInstall(paths: paths) else { return }
        self.banner.setStatus(L("正在安装远端集成…"))
        let installed = await client.installIntegration(host.context, shells)
        guard self.host?.addressesSameChannel(as: host) == true else { return }
        switch installed {
        case .success:
          self.banner.setStatus(L("远端集成已安装，重新登录后生效"))
        case .failure(let failure):
          self.banner.setStatus(L("安装失败：\(failure.message)"))
        }
      }
    }
  }

  private func confirmInstall(paths: [String]) -> Bool {
    let alert = NSAlert()
    alert.messageText = L("安装远端集成…")
    alert.informativeText = L("将修改远端文件：\(paths.joined(separator: "\n"))")
    alert.addButton(withTitle: L("安装"))
    alert.addButton(withTitle: L("取消"))
    return alert.runModal() == .alertFirstButtonReturn
  }
}
