import AppKit
import AsterCore
import Foundation
import Testing
import WebKit

@testable import Aster

@Test("后台源码渲染支持 highlight.js operator token")
func fileRenderPipelineSupportsOperatorToken() async throws {
  let artifact = await FileRenderPipeline().renderSource(
    "let selected = preferred ?? fallback",
    language: "swift"
  )
  guard case .highlightedRTF(let data)? = artifact else {
    Issue.record("源码渲染没有返回 RTF")
    return
  }
  #expect(!data.isEmpty)
}

@Test("File Pane 通过目录事件即时重载外部 atomic replace")
@MainActor
func filePaneReloadsExternalAtomicReplacementWithoutPolling() async throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneEventsTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-pane-events-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("event.swift")
  try Data("let value = 1\n".utf8).write(to: file)
  let descriptor = PaneDescriptor(
    kind: .editor,
    workingDirectory: root.path,
    resourcePath: file.path
  )
  let tab = TerminalTabItem(
    title: "event.swift",
    workingDirectory: root.path,
    layout: .leaf(descriptor)
  )
  let runtime = try #require(tab.activeRuntime)
  let controller = FilePaneViewController(
    runtime: runtime,
    tab: tab,
    model: AppModel(defaults: defaults),
    preferences: AppPreferences(defaults: defaults)
  )
  controller.loadViewIfNeeded()
  try await Task.sleep(for: .milliseconds(20))

  let replacement = "let value = 2\n"
  try Data(replacement.utf8).write(to: file, options: .atomic)
  let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
  while runtime.documentText != replacement, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }

  #expect(runtime.documentText == replacement)
}

@Test("Preview File Pane 默认只读并展示统一保存关闭工具栏")
@MainActor
func previewFilePaneStartsReadOnlyWithUnifiedToolbar() throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-pane-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("CONTEXT.md")
  try Data("# Aster\n\nPreview".utf8).write(to: file)
  let descriptor = PaneDescriptor(
    kind: .preview,
    workingDirectory: root.path,
    resourcePath: file.path
  )
  let tab = TerminalTabItem(
    title: "CONTEXT.md",
    workingDirectory: root.path,
    layout: .leaf(descriptor)
  )
  let runtime = try #require(tab.activeRuntime)
  let model = AppModel(defaults: defaults)
  let controller = FilePaneViewController(
    runtime: runtime,
    tab: tab,
    model: model,
    preferences: AppPreferences(defaults: defaults)
  )
  controller.loadViewIfNeeded()

  let mode = try #require(
    controller.view.descendants.compactMap { $0 as? NSSegmentedControl }
      .first { $0.identifier?.rawValue == "file-pane-presentation" })
  let status = try #require(
    controller.view.descendants.compactMap { $0 as? NSTextField }
      .first { $0.identifier?.rawValue == "file-pane-status" })
  #expect(runtime.isReadOnly)
  #expect(mode.selectedSegment == 1)
  #expect(status.stringValue == "✓ Saved")
  let buttonTitles = controller.view.descendants.compactMap { ($0 as? NSButton)?.title }
  #expect(buttonTitles.contains("Close"))
}

@Test("Markdown Preview File Pane 渲染标题和正文")
@MainActor
func markdownPreviewFilePaneRendersDocumentContent() async throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneMarkdownTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-markdown-preview-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("README.md")
  try Data("# Visible heading\n\nRendered paragraph.".utf8).write(to: file)
  let descriptor = PaneDescriptor(
    kind: .preview,
    workingDirectory: root.path,
    resourcePath: file.path
  )
  let tab = TerminalTabItem(
    title: "README.md",
    workingDirectory: root.path,
    layout: .leaf(descriptor)
  )
  let runtime = try #require(tab.activeRuntime)
  let model = AppModel(defaults: defaults)
  let controller = FilePaneViewController(
    runtime: runtime,
    tab: tab,
    model: model,
    preferences: AppPreferences(defaults: defaults)
  )
  controller.loadViewIfNeeded()

  let webView = try #require(controller.view.descendants.compactMap { $0 as? WKWebView }.first)
  var renderedText = ""
  for _ in 0..<40 {
    try await Task.sleep(for: .milliseconds(25))
    renderedText =
      (try? await webView.evaluateJavaScript("document.body.innerText") as? String) ?? ""
    if renderedText.contains("Visible heading") { break }
  }

  #expect(renderedText.contains("Visible heading"))
  #expect(renderedText.contains("Rendered paragraph."))

  // Source/Preview 往返只交换缓存视图，不应重新创建昂贵的 WKWebView。
  let firstWebView = webView
  let mode = try #require(
    controller.view.descendants.compactMap { $0 as? NSSegmentedControl }
      .first { $0.identifier?.rawValue == "file-pane-presentation" })
  mode.selectedSegment = 0
  mode.sendAction(mode.action, to: mode.target)
  let sourceTextView = try #require(controller.sourceTextView)
  mode.selectedSegment = 1
  mode.sendAction(mode.action, to: mode.target)
  #expect(controller.previewWebView === firstWebView)
  mode.selectedSegment = 0
  mode.sendAction(mode.action, to: mode.target)
  #expect(controller.sourceTextView === sourceTextView)
}

@Test("只读 Source File Pane 渲染带参数的 Swift 源码")
@MainActor
func readOnlySourceFilePaneHighlightsSwiftParameters() throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneSourceTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-source-preview-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("Example.swift")
  let source = "func greet(name: String) -> String { name }"
  try Data(source.utf8).write(to: file)
  let descriptor = PaneDescriptor(
    kind: .preview,
    workingDirectory: root.path,
    resourcePath: file.path
  )
  let tab = TerminalTabItem(
    title: "Example.swift",
    workingDirectory: root.path,
    layout: .leaf(descriptor)
  )
  let runtime = try #require(tab.activeRuntime)
  let model = AppModel(defaults: defaults)
  let controller = FilePaneViewController(
    runtime: runtime,
    tab: tab,
    model: model,
    preferences: AppPreferences(defaults: defaults)
  )
  controller.loadViewIfNeeded()

  let textView = try #require(controller.sourceTextView)
  #expect(textView.string == source)
  #expect(!textView.isEditable)

  let mode = try #require(
    controller.view.descendants.compactMap { $0 as? NSSegmentedControl }
      .first { $0.identifier?.rawValue == "file-pane-presentation" })
  #expect(mode.selectedSegment == 1)
  mode.selectedSegment = 0
  mode.sendAction(mode.action, to: mode.target)
  #expect(!runtime.isReadOnly)
  #expect(textView.isEditable)
  #expect(controller.sourceTextView === textView)
}

extension NSView {
  fileprivate var descendants: [NSView] { subviews.flatMap { [$0] + $0.descendants } }
}
