// 文件 Pane 的内容查找栏：在源码、Web 预览（Markdown/HTML/SVG/会话记录）和 PDF 中查找。
import AppKit
import AsterCore
import PDFKit
import WebKit

/// 查找栏当前作用的内容视图。每次查找时由 File Pane 重新解析，Source/Preview
/// 切换后自然落到新的视图上，不需要额外同步。
@MainActor
enum FilePaneFindTarget {
  case text(NSTextView)
  case web(WKWebView)
  case pdf(PDFView)

  /// 在 Pane 内容树里找第一个可查找的视图。PDF 与 Web 先于文本判断，
  /// 避免命中它们内部可能存在的辅助文本视图。
  static func resolve(in root: NSView) -> FilePaneFindTarget? {
    if let pdf: PDFView = root.firstDescendant() { return .pdf(pdf) }
    if let web: WKWebView = root.firstDescendant() { return .web(web) }
    if let text: NSTextView = root.firstDescendant() { return .text(text) }
    return nil
  }

  /// WebKit 与 PDFKit 的查找接口不支持正则，只有源码文本支持。
  var supportsRegularExpression: Bool {
    if case .text = self { return true }
    return false
  }
}

/// 文件 Pane 顶部工具条下方的查找栏。回车找下一处，⇧回车找上一处，Esc 关闭；
/// 输入时实时查找，并显示「当前 / 总数」。
@MainActor
final class FilePaneFindBar: NSView, NSSearchFieldDelegate {
  private let field = NSSearchField()
  private let summaryLabel = makeLabel(
    "", size: 10, color: AsterTheme.secondaryInk, monospaced: true)
  private let caseSensitiveButton = NSButton(title: "Aa", target: nil, action: nil)
  private let regularExpressionButton = NSButton(title: ".*", target: nil, action: nil)
  private let resolveTarget: () -> FilePaneFindTarget?
  private let onClose: () -> Void
  /// PDF 查找结果缓存：PDFKit 每次全文查找代价较高，查询和选项不变时只移动下标。
  private var pdfMatches: [PDFSelection] = []
  private var pdfMatchIndex = 0
  private var pdfCacheKey: String?
  private weak var pdfCacheView: PDFView?

  init(resolveTarget: @escaping () -> FilePaneFindTarget?, onClose: @escaping () -> Void) {
    self.resolveTarget = resolveTarget
    self.onClose = onClose
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("file-pane-findbar")
    wantsLayer = true
    layer?.backgroundColor = AsterTheme.panel.cgColor
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 34).isActive = true
    addBottomBorder(color: AsterTheme.hairline)

    field.placeholderString = L("在文件中查找")
    field.identifier = NSUserInterfaceItemIdentifier("file-pane-find-field")
    field.delegate = self
    // 只在回车时发送 action；实时查找走 controlTextDidChange，避免一次输入查两遍。
    field.sendsWholeSearchString = true
    caseSensitiveButton.setButtonType(.toggle)
    caseSensitiveButton.bezelStyle = .inline
    caseSensitiveButton.toolTip = L("区分大小写")
    caseSensitiveButton.target = self
    caseSensitiveButton.action = #selector(optionsChanged)
    regularExpressionButton.setButtonType(.toggle)
    regularExpressionButton.bezelStyle = .inline
    regularExpressionButton.toolTip = L("正则表达式")
    regularExpressionButton.target = self
    regularExpressionButton.action = #selector(optionsChanged)
    summaryLabel.identifier = NSUserInterfaceItemIdentifier("file-pane-find-summary")
    summaryLabel.alignment = .right
    summaryLabel.translatesAutoresizingMaskIntoConstraints = false
    summaryLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    let previous = ActionButton(symbol: "chevron.up") { [weak self] in self?.find(.backward) }
    previous.toolTip = L("上一个")
    let next = ActionButton(symbol: "chevron.down") { [weak self] in self?.find(.forward) }
    next.toolTip = L("下一个")
    let close = ActionButton(symbol: "xmark") { [weak self] in self?.onClose() }
    let row = NSStackView(views: [
      field, summaryLabel, caseSensitiveButton, regularExpressionButton, previous, next, close,
    ])
    row.orientation = .horizontal
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    addSubview(row)
    row.pinEdges(to: self)
    updateRegularExpressionAvailability(resolveTarget())
  }

  required init?(coder: NSCoder) { nil }

  /// 把焦点放进输入框并全选已有查询，便于直接改写。
  func focusField() {
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  // MARK: - NSSearchFieldDelegate

  func controlTextDidChange(_ obj: Notification) { find(.incremental) }

  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
      find(backwards ? .backward : .forward)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onClose()
      return true
    default:
      return false
    }
  }

  @objc private func optionsChanged() {
    pdfCacheKey = nil
    find(.incremental)
  }

  // MARK: - 查找

  private func find(_ direction: DocumentTextSearch.Direction) {
    let target = resolveTarget()
    updateRegularExpressionAvailability(target)
    let query = field.stringValue
    guard let target, !query.isEmpty else {
      summaryLabel.stringValue = ""
      return
    }
    let caseSensitive = caseSensitiveButton.state == .on
    switch target {
    case .text(let textView):
      findInText(textView, query: query, caseSensitive: caseSensitive, direction: direction)
    case .web(let webView):
      findInWeb(webView, query: query, caseSensitive: caseSensitive, direction: direction)
    case .pdf(let pdfView):
      findInPDF(pdfView, query: query, caseSensitive: caseSensitive, direction: direction)
    }
  }

  /// 源码查找：全部匹配交给 Core 计算，选中目标并滚动到可见，再用系统查找指示器提示位置。
  private func findInText(
    _ textView: NSTextView,
    query: String,
    caseSensitive: Bool,
    direction: DocumentTextSearch.Direction
  ) {
    let matches = DocumentTextSearch.ranges(
      of: query,
      in: textView.string,
      caseSensitive: caseSensitive,
      regularExpression: regularExpressionButton.state == .on)
    guard
      let index = DocumentTextSearch.matchIndex(
        in: matches, selection: textView.selectedRange(), direction: direction)
    else {
      summaryLabel.stringValue = "0 / 0"
      return
    }
    let range = matches[index]
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    textView.showFindIndicator(for: range)
    summaryLabel.stringValue = "\(index + 1) / \(matches.count)"
  }

  /// Web 预览查找交给 WebKit：它负责高亮和滚动，但不提供总数，所以只显示是否命中。
  /// 输入时的实时查找从当前命中处继续，WebKit 会把已选中的命中算作起点。
  private func findInWeb(
    _ webView: WKWebView,
    query: String,
    caseSensitive: Bool,
    direction: DocumentTextSearch.Direction
  ) {
    let configuration = WKFindConfiguration()
    configuration.backwards = direction == .backward
    configuration.caseSensitive = caseSensitive
    configuration.wraps = true
    webView.find(query, configuration: configuration) { [weak self] result in
      // 回调返回前查询可能已被改写；只让最新查询更新计数。
      guard let self, field.stringValue == query else { return }
      summaryLabel.stringValue = result.matchFound ? L("有匹配") : L("无匹配")
    }
  }

  /// PDF 查找：PDFKit 一次返回全部命中，缓存后按方向移动下标并高亮当前命中。
  private func findInPDF(
    _ pdfView: PDFView,
    query: String,
    caseSensitive: Bool,
    direction: DocumentTextSearch.Direction
  ) {
    let key = "\(caseSensitive)|\(query)"
    let isNewSearch = pdfCacheKey != key || pdfCacheView !== pdfView
    if isNewSearch {
      let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
      pdfMatches = pdfView.document?.findString(query, withOptions: options) ?? []
      pdfMatchIndex = 0
      pdfCacheKey = key
      pdfCacheView = pdfView
    }
    guard !pdfMatches.isEmpty else {
      pdfView.clearSelection()
      summaryLabel.stringValue = "0 / 0"
      return
    }
    if !isNewSearch {
      switch direction {
      case .forward: pdfMatchIndex = (pdfMatchIndex + 1) % pdfMatches.count
      case .backward: pdfMatchIndex = (pdfMatchIndex - 1 + pdfMatches.count) % pdfMatches.count
      case .incremental: break
      }
    }
    let selection = pdfMatches[pdfMatchIndex]
    pdfView.setCurrentSelection(selection, animate: true)
    pdfView.go(to: selection)
    summaryLabel.stringValue = "\(pdfMatchIndex + 1) / \(pdfMatches.count)"
  }

  /// 目标不支持正则时置灰开关，避免用户以为正则生效。
  private func updateRegularExpressionAvailability(_ target: FilePaneFindTarget?) {
    regularExpressionButton.isEnabled = target?.supportsRegularExpression ?? false
  }
}

extension NSView {
  /// 深度优先返回第一个指定类型的后代视图（含自身）。
  fileprivate func firstDescendant<T: NSView>() -> T? {
    if let match = self as? T { return match }
    for subview in subviews {
      if let match: T = subview.firstDescendant() { return match }
    }
    return nil
  }
}
