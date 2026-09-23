// 文件 Pane 内容查找：⌘F 路由与源码查找栏行为。
import AppKit
import AsterCore
import Foundation
import PDFKit
import Testing
import WebKit

@testable import Aster

/// 建一个临时源码文件和隔离的 defaults，返回打开它的编辑器 Pane 描述。
@MainActor
private func makeEditorFixture(_ text: String) throws -> (
  descriptor: PaneDescriptor, defaults: UserDefaults, cleanup: () -> Void
) {
  _ = NSApplication.shared
  let suite = "AsterFilePaneFindTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-pane-find-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let file = root.appendingPathComponent("find.swift")
  try Data(text.utf8).write(to: file)
  let descriptor = PaneDescriptor(kind: .editor, workingDirectory: root.path, resourcePath: file.path)
  return (descriptor, defaults, {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  })
}

@Test("活动 Pane 是文件时 ⌘F 交给文件查找栏，不打开终端查找栏")
@MainActor
func findRoutesToActiveFilePane() throws {
  let fixture = try makeEditorFixture("let value = 1\n")
  defer { fixture.cleanup() }
  let model = AppModel(defaults: fixture.defaults)
  model.openResourceInNewTab(fixture.descriptor)
  #expect(model.selectedTab?.activePaneID == fixture.descriptor.id)
  var requests: [(paneID: UUID, toggle: Bool)] = []
  let subscription = model.fileFindRequested.sink { requests.append($0) }
  defer { subscription.cancel() }

  model.toggleFind()
  model.presentFind()

  #expect(!model.isFindPresented)
  #expect(requests.map(\.paneID) == [fixture.descriptor.id, fixture.descriptor.id])
  #expect(requests.map(\.toggle) == [true, false])
}

@Test("文件查找栏在源码中实时查找、回车跳下一处并回绕")
@MainActor
func filePaneFindBarSelectsMatchesInSource() throws {
  let fixture = try makeEditorFixture("alpha beta\nAlpha gamma\nalpha\n")
  defer { fixture.cleanup() }
  let model = AppModel(defaults: fixture.defaults)
  let tab = TerminalTabItem(
    title: "find.swift", workingDirectory: fixture.descriptor.workingDirectory,
    layout: .leaf(fixture.descriptor))
  let runtime = try #require(tab.activeRuntime)
  let controller = FilePaneViewController(
    runtime: runtime, tab: tab, model: model,
    preferences: AppPreferences(defaults: fixture.defaults))
  controller.loadViewIfNeeded()
  let textView = try #require(controller.sourceTextView)

  model.fileFindRequested.send((paneID: runtime.id, toggle: true))
  let bar = try #require(controller.view.descendants.compactMap { $0 as? FilePaneFindBar }.first)
  let field = try #require(bar.descendants.compactMap { $0 as? NSSearchField }.first)
  field.stringValue = "alpha"
  bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
  #expect(textView.selectedRange() == NSRange(location: 0, length: 5))

  let newline = #selector(NSResponder.insertNewline(_:))
  _ = bar.control(field, textView: NSTextView(), doCommandBy: newline)
  #expect(textView.selectedRange() == NSRange(location: 11, length: 5))
  _ = bar.control(field, textView: NSTextView(), doCommandBy: newline)
  _ = bar.control(field, textView: NSTextView(), doCommandBy: newline)
  #expect(textView.selectedRange() == NSRange(location: 0, length: 5))

  // 再按一次 ⌘F 关闭查找栏。
  model.fileFindRequested.send((paneID: runtime.id, toggle: true))
  #expect(controller.view.descendants.compactMap { $0 as? FilePaneFindBar }.first == nil)
}

/// 打开指定文件的 File Pane，并按 ⌘F 打开查找栏；返回查找栏和其输入框、计数标签。
@MainActor
private func openFindBar(
  _ descriptor: PaneDescriptor, defaults: UserDefaults
) throws -> (
  controller: FilePaneViewController, bar: FilePaneFindBar, field: NSSearchField,
  summary: NSTextField
) {
  let tab = TerminalTabItem(
    title: "find", workingDirectory: descriptor.workingDirectory, layout: .leaf(descriptor))
  let runtime = try #require(tab.activeRuntime)
  let model = AppModel(defaults: defaults)
  let controller = FilePaneViewController(
    runtime: runtime, tab: tab, model: model, preferences: AppPreferences(defaults: defaults))
  controller.loadViewIfNeeded()
  model.fileFindRequested.send((paneID: runtime.id, toggle: true))
  let bar = try #require(controller.view.descendants.compactMap { $0 as? FilePaneFindBar }.first)
  let field = try #require(bar.descendants.compactMap { $0 as? NSSearchField }.first)
  let summary = try #require(
    bar.descendants.compactMap { $0 as? NSTextField }
      .first { $0.identifier?.rawValue == "file-pane-find-summary" })
  return (controller, bar, field, summary)
}

/// 模拟在查找框里输入查询。
@MainActor
private func type(_ query: String, into field: NSSearchField, bar: FilePaneFindBar) {
  field.stringValue = query
  bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
}

@Test("文件查找栏在 Markdown 预览中交给 WebKit 查找")
@MainActor
func filePaneFindBarSearchesWebPreview() async throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneFindWebTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-pane-find-web-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("README.md")
  try Data("# Heading\n\nNeedle paragraph.".utf8).write(to: file)
  let descriptor = PaneDescriptor(kind: .preview, workingDirectory: root.path, resourcePath: file.path)
  let (controller, bar, field, summary) = try openFindBar(descriptor, defaults: defaults)
  let webView = try #require(controller.previewWebView)
  for _ in 0..<80 {
    let text = (try? await webView.evaluateJavaScript("document.body.innerText") as? String) ?? ""
    if text.contains("Needle") { break }
    try await Task.sleep(for: .milliseconds(25))
  }

  type("needle", into: field, bar: bar)
  for _ in 0..<80 where summary.stringValue.isEmpty {
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(summary.stringValue == L("有匹配"))

  type("absent-term", into: field, bar: bar)
  for _ in 0..<80 where summary.stringValue != L("无匹配") {
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(summary.stringValue == L("无匹配"))
}

@Test("文件查找栏在 PDF 中计数并前后跳转")
@MainActor
func filePaneFindBarSearchesPDF() throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneFindPDFTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-pane-find-pdf-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  // 用 NSTextView 生成带真实文字层的 PDF，PDFKit 才能查到。
  let source = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
  source.string = "apple banana\napple cherry\napple"
  let file = root.appendingPathComponent("fruit.pdf")
  try source.dataWithPDF(inside: source.bounds).write(to: file)
  let descriptor = PaneDescriptor(kind: .preview, workingDirectory: root.path, resourcePath: file.path)
  let (controller, bar, field, summary) = try openFindBar(descriptor, defaults: defaults)
  let pdfView = try #require(controller.view.descendants.compactMap { $0 as? PDFView }.first)

  type("APPLE", into: field, bar: bar)
  #expect(summary.stringValue == "1 / 3")
  #expect(pdfView.currentSelection?.string?.lowercased() == "apple")
  let newline = #selector(NSResponder.insertNewline(_:))
  _ = bar.control(field, textView: NSTextView(), doCommandBy: newline)
  #expect(summary.stringValue == "2 / 3")
  // 正则开关对 PDF 无效，应置灰。
  let regex = try #require(
    bar.descendants.compactMap { $0 as? NSButton }.first { $0.title == ".*" })
  #expect(!regex.isEnabled)
}

extension NSView {
  /// 深度优先列出全部后代视图，测试里按类型或 identifier 查找控件。
  fileprivate var descendants: [NSView] { subviews.flatMap { [$0] + $0.descendants } }
}
