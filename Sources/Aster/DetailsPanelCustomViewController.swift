import AppKit
import AsterCore
import WebKit

/// 详情面板里用户添加的视图：在面板内的终端里运行程序（TUI），或加载一个网页。
/// 命令 / 网址 / 目录里的 `${cwd}` 等变量按当前聚焦标签解析；解析结果变化时 TUI 重启、
/// 网页重新加载，与 Otty「用了 ${cwd} 的视图每个目录一个」的行为一致。
@MainActor
final class DetailsPanelCustomViewController: NSViewController, WKNavigationDelegate {
  let definition: DetailsPanelCustomView
  private let preferences: AppPreferences
  private let contextProvider: () -> (context: TabTitleContext, pid: Int32?)?
  private var resolvedCommand = ""
  private var resolvedURL = ""
  private var resolvedFolder = ""
  private var terminalView: GhosttySurfaceView?
  private var webView: WKWebView?
  private let statusLabel = NSTextField(wrappingLabelWithString: "")

  init(
    definition: DetailsPanelCustomView,
    preferences: AppPreferences,
    contextProvider: @escaping () -> (context: TabTitleContext, pid: Int32?)?
  ) {
    self.definition = definition
    self.preferences = preferences
    self.contextProvider = contextProvider
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    root.identifier = NSUserInterfaceItemIdentifier("details-custom-view-\(definition.id.uuidString)")
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .center
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.isHidden = true
    root.addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
    ])
    view = root
    refreshContext()
  }

  /// 聚焦标签或其目录变化后重新解析模板；只有解析结果真的变了才重建内容。
  func refreshContext() {
    guard isViewLoaded else { return }
    let context = contextProvider()
    let base = context?.context ?? TabTitleContext(cwd: NSHomeDirectory())
    let pid = context?.pid
    func render(_ template: String) -> String {
      DetailsPanelViewTemplate.render(template, context: base, alias: nil, pid: pid)
    }
    switch definition.kind {
    case .tui:
      let command = render(definition.command)
      let folder = resolveFolder(render(definition.folder))
      guard command != resolvedCommand || folder != resolvedFolder || terminalView == nil else { return }
      resolvedCommand = command
      resolvedFolder = folder
      installTerminal(command: command, folder: folder)
    case .web:
      let url = render(definition.url)
      guard url != resolvedURL || webView == nil else { return }
      resolvedURL = url
      installWeb(urlString: url)
    }
  }

  /// 目录留空时为该视图单独建一个目录（`~/.config/aster/views/<名称>`）。
  private func resolveFolder(_ value: String) -> String {
    var folder = value.trimmingCharacters(in: .whitespaces)
    if folder.hasPrefix("~") { folder = NSHomeDirectory() + folder.dropFirst() }
    if folder.isEmpty {
      let safeName = definition.name.replacingOccurrences(of: "/", with: "-")
      folder = NSHomeDirectory() + "/.config/aster/views/" + safeName
      try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) || !isDirectory.boolValue {
      return NSHomeDirectory()
    }
    return folder
  }

  private func installTerminal(command: String, folder: String) {
    terminalView?.destroySurface()
    terminalView?.removeFromSuperview()
    terminalView = nil
    guard !command.isEmpty else {
      showStatus("该视图还没有配置命令。")
      return
    }
    let inherited = ProcessInfo.processInfo.environment
    let launch = TerminalLaunchEnvironmentBuilder.make(
      inherited: inherited,
      configuredTerm: preferences.terminalIdentity,
      shellPath: inherited["SHELL"] ?? "/bin/zsh",
      shellIntegrationEnabled: false,
      paneIdentifier: "details-view-\(definition.id.uuidString)",
      version: AsterResourceLocations.productVersion(),
      resourcesDirectory: AsterResourceLocations.resourcesDirectory()?.path,
      engineTerminfoDirectory: AsterResourceLocations.engineTerminfoDirectory()?.path,
      terminfoEntryExists: SystemTerminfoChecker.entryExists
    )
    // 面板内的程序不该再开窗口 / 标签 / 分屏：不注入 Aster CLI 与 Shell 集成变量。
    var environment = launch.environment
    environment["ASTER_DETAILS_VIEW"] = definition.name
    let terminal = GhosttySurfaceView(
      workingDirectory: folder,
      environment: environment,
      configurationText: GhosttyConfiguration.make(preferences: preferences)
    )
    terminal.command = command
    terminal.waitAfterCommand = true
    terminal.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(terminal, positioned: .below, relativeTo: statusLabel)
    terminal.pinEdges(to: view)
    terminalView = terminal
    statusLabel.isHidden = true
  }

  private func installWeb(urlString: String) {
    webView?.removeFromSuperview()
    webView = nil
    guard let url = WebPaneURLPolicy.allowedURL(from: urlString) else {
      showStatus(urlString.isEmpty ? "该视图还没有配置网址。" : "网址必须是 http(s) 地址：\(urlString)")
      return
    }
    let configuration = WKWebViewConfiguration()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.websiteDataStore = WebPaneDataStorePolicy.dataStore(
      persist: preferences.configuration.resolvedView.resolvedWebPanePersistData)
    let web = WKWebView(frame: .zero, configuration: configuration)
    // 「移动版页面」：以手机浏览器身份请求，站点会返回为窄栏写的布局。
    if definition.mobile {
      web.customUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
    web.navigationDelegate = self
    web.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(web, positioned: .below, relativeTo: statusLabel)
    web.pinEdges(to: view)
    webView = web
    statusLabel.isHidden = true
    web.load(URLRequest(url: url))
  }

  private func showStatus(_ text: String) {
    statusLabel.stringValue = text
    statusLabel.isHidden = false
  }

  /// 面板收起 / 视图被删除时释放进程与网页。
  func tearDown() {
    terminalView?.destroySurface()
    terminalView?.removeFromSuperview()
    terminalView = nil
    webView?.stopLoading()
    webView?.removeFromSuperview()
    webView = nil
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(WebPaneURLPolicy.allows(navigationAction.request.url) ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    showStatus("加载失败：\(error.localizedDescription)")
  }
}
