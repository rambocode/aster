import AppKit
import AsterCore
import Combine

/// Composer 使用多行 `NSTextView`，AppKit 没有原生 placeholder。空草稿时在绘制层显示
/// 提示，既不写入草稿，也不会影响发送或队列的字节内容。
@MainActor
final class ComposerTextView: NSTextView {
  var placeholder = "" {
    didSet { needsDisplay = true }
  }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: AsterTheme.tertiaryInk,
    ]
    let origin = NSPoint(
      x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
      y: textContainerInset.height
    )
    (placeholder as NSString).draw(at: origin, withAttributes: attributes)
  }
}

/// Pane 输入与查找控件的 AppKit 适配对象。
///
/// 这些对象服务于工作区编排，但不负责 Panel 或 Pane 的布局生命周期。

@MainActor
final class AgentComposerTextDelegate: NSObject, NSTextViewDelegate {
  private weak var model: AppModel?
  private let paneID: UUID

  init(model: AppModel, paneID: UUID) {
    self.model = model
    self.paneID = paneID
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    _ = model?.updateComposerDraft(textView.string, paneID: paneID)
  }
}

/// 当前 Pane 查找栏的轻量控制器。实时搜索、选项和计数共享同一状态，避免每个按钮
/// 各自读取一套条件；控制器随工作区本轮视图树一起释放。
@MainActor
final class TerminalFindBarController: NSObject, NSSearchFieldDelegate {
  private weak var session: TerminalSession?
  private weak var field: NSSearchField?
  private weak var caseSensitiveButton: NSButton?
  private weak var regularExpressionButton: NSButton?
  private weak var summaryLabel: NSTextField?

  init(
    session: TerminalSession?,
    field: NSSearchField,
    caseSensitiveButton: NSButton,
    regularExpressionButton: NSButton,
    summaryLabel: NSTextField
  ) {
    self.session = session
    self.field = field
    self.caseSensitiveButton = caseSensitiveButton
    self.regularExpressionButton = regularExpressionButton
    self.summaryLabel = summaryLabel
  }

  func controlTextDidChange(_ obj: Notification) {
    guard let field, !field.stringValue.isEmpty else {
      session?.clearFind()
      summaryLabel?.stringValue = "0 / 0"
      return
    }
    _ = perform(previous: false)
  }

  @objc func findNext(_ sender: Any?) { _ = perform(previous: false) }
  @objc func findPrevious(_ sender: Any?) { _ = perform(previous: true) }
  @objc func optionsChanged(_ sender: Any?) {
    session?.clearFind()
    _ = perform(previous: false)
  }

  @discardableResult
  private func perform(previous: Bool) -> Bool {
    guard let session, let term = field?.stringValue, !term.isEmpty else { return false }
    let caseSensitive = caseSensitiveButton?.state == .on
    let regularExpression = regularExpressionButton?.state == .on
    let found = session.findNext(
      term,
      previous: previous,
      caseSensitive: caseSensitive,
      regularExpression: regularExpression
    )
    let summary = session.findMatchSummary(
      term,
      caseSensitive: caseSensitive,
      regularExpression: regularExpression
    )
    summaryLabel?.stringValue = "\(summary.index) / \(summary.total)"
    return found
  }
}

/// `TABS` 标题右侧的标签整理入口。使用原生 `NSMenu` 保留 macOS 的毛玻璃、阴影、
/// 键盘导航和辅助功能；菜单展开期间按钮保持截图中的浅灰圆角按下态。
