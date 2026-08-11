import AppKit
import WebKit

/// Web Pane 的唯一 URL 边界。恢复快照、Recipe 和页面导航都必须再次通过这里，避免
/// `file:`、`javascript:` 或自定义 scheme 从持久化数据进入拥有网络能力的视图。
enum WebPaneURLPolicy {
  static func allowedURL(from value: String) -> URL? {
    guard value.utf8.count <= 4_096,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let url = URL(string: value),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil
    else { return nil }
    return url
  }

  static func allows(_ url: URL?) -> Bool {
    guard let url else { return false }
    return allowedURL(from: url.absoluteString) != nil
  }
}

/// “链接在 Aster 中打开”的轻量网页 Pane。它只承载 HTTP(S) 导航，不暴露脚本桥接、
/// 本地文件读取或自定义协议；新窗口导航收敛到当前 Pane，保持工作区分屏模型稳定。
@MainActor
final class WebPaneViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
  private let initialURL: URL?
  private let webView: WKWebView
  private let locationLabel = NSTextField(labelWithString: "")
  private let backButton = NSButton(title: "‹", target: nil, action: nil)
  private let forwardButton = NSButton(title: "›", target: nil, action: nil)

  init(runtime: WorkspacePaneRuntime) {
    initialURL = runtime.descriptor.resourcePath.flatMap(WebPaneURLPolicy.allowedURL)
    let configuration = WKWebViewConfiguration()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    let toolbar = NSView()
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

    backButton.target = self
    backButton.action = #selector(goBack)
    backButton.bezelStyle = .inline
    backButton.toolTip = "后退"
    forwardButton.target = self
    forwardButton.action = #selector(goForward)
    forwardButton.bezelStyle = .inline
    forwardButton.toolTip = "前进"
    let reloadButton = NSButton(title: "↻", target: self, action: #selector(reload))
    reloadButton.bezelStyle = .inline
    reloadButton.toolTip = "重新加载"

    locationLabel.lineBreakMode = .byTruncatingMiddle
    locationLabel.font = .systemFont(ofSize: 11)
    locationLabel.textColor = .secondaryLabelColor
    locationLabel.stringValue = initialURL?.absoluteString ?? "无法打开该网页"
    let controls = NSStackView(views: [backButton, forwardButton, reloadButton, locationLabel])
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.spacing = 5
    controls.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(controls)

    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(toolbar)
    root.addSubview(webView)
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: root.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 30),
      controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
      controls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
      controls.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    view = root
    updateNavigationButtons()
    if let initialURL { webView.load(URLRequest(url: initialURL)) }
  }

  @objc private func goBack() {
    guard webView.canGoBack else { return }
    webView.goBack()
  }

  @objc private func goForward() {
    guard webView.canGoForward else { return }
    webView.goForward()
  }

  @objc private func reload() { webView.reload() }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(WebPaneURLPolicy.allows(navigationAction.request.url) ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if WebPaneURLPolicy.allows(navigationAction.request.url) {
      webView.load(navigationAction.request)
    }
    return nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    locationLabel.stringValue = webView.url?.absoluteString ?? initialURL?.absoluteString ?? "网页"
    updateNavigationButtons()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    locationLabel.stringValue = "加载失败：\(error.localizedDescription)"
    updateNavigationButtons()
  }

  private func updateNavigationButtons() {
    backButton.isEnabled = webView.canGoBack
    forwardButton.isEnabled = webView.canGoForward
  }
}
