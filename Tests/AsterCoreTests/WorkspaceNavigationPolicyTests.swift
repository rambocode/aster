import Foundation
import Testing

@testable import AsterCore

@Test("OSC 1、2、0 分别更新标签标题、窗口标题和两者")
func terminalTitlesTrackIndependentOSCChannels() {
  var titles = TerminalTitleState(fallback: "Shell")

  titles.applyOSC(code: 2, text: "project — vim")
  #expect(titles.tabTitle == "project — vim")
  #expect(titles.windowTitle == "project — vim")

  titles.applyOSC(code: 1, text: "vim")
  #expect(titles.tabTitle == "vim")
  #expect(titles.windowTitle == "project — vim")

  titles.applyOSC(code: 0, text: "ssh db-01")
  #expect(titles.tabTitle == "ssh db-01")
  #expect(titles.windowTitle == "ssh db-01")
}

@Test("固定标题忽略程序更新，前缀标题保留动态更新")
func terminalTitleOverridesResolveWithoutDiscardingProgramState() {
  var titles = TerminalTitleState(fallback: "Shell")
  titles.applyOSC(code: 0, text: "zsh")

  titles.tabOverride = .name("Production")
  titles.applyOSC(code: 1, text: "ssh db-01")
  #expect(titles.tabTitle == "Production")

  titles.tabOverride = .prefix("prod: ")
  #expect(titles.tabTitle == "prod: ssh db-01")
  titles.applyOSC(code: 1, text: "lazygit")
  #expect(titles.tabTitle == "prod: lazygit")

  titles.tabOverride = .automatic
  #expect(titles.tabTitle == "lazygit")
}

@Test("外部标题会移除控制字符并限制持久化长度")
func terminalTitlesSanitizeUntrustedOSCText() {
  var titles = TerminalTitleState(fallback: "Shell")
  titles.applyOSC(code: 0, text: "prod\n\u{001B}[31m" + String(repeating: "x", count: 1_000))

  #expect(!titles.tabTitle.contains("\n"))
  #expect(!titles.tabTitle.contains("\u{001B}"))
  #expect(titles.tabTitle.utf8.count <= TerminalTitleState.maximumTitleBytes)
}

@Test("反序列化标题状态进入运行态前会清理空覆盖和不可信文本")
func terminalTitleStateNormalizesDecodedStorage() throws {
  let encoded = try JSONEncoder().encode(
    TerminalTitleState(
      programWindowTitle: "safe",
      tabOverride: .name("temporary"),
      fallback: "Shell"
    ))
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object["programWindowTitle"] = "bad\n\u{001B}[31m"
  object["tabOverride"] = ["name": ["_0": ""]]

  let malformed = try JSONSerialization.data(withJSONObject: object)
  let normalized = try JSONDecoder().decode(TerminalTitleState.self, from: malformed).normalized()

  #expect(normalized.tabOverride == .automatic)
  #expect(normalized.programWindowTitle == "bad[31m")
}

@Test("标题栈观察器跨 PTY 分片恢复窗口和图标标题")
func terminalTitleStackObserverRestoresBothChannelsAcrossChunks() {
  var observer = TerminalTitleStackObserver()
  let output = Array(
    "\u{001B}]0;alpha\u{0007}\u{001B}[22;0t\u{001B}]0;beta\u{0007}\u{001B}[23;0t".utf8)

  let first = observer.consume(output.prefix(17))
  let second = observer.consume(output.dropFirst(17))

  #expect(first == [.init(code: 0, title: "alpha")])
  #expect(second == [
    .init(code: 0, title: "beta"),
    .init(code: 2, title: "alpha"),
    .init(code: 1, title: "alpha"),
  ])
}

@Test("标题栈观察器按 xterm 语义区分 23;1t 与 23;2t")
func terminalTitleStackObserverRestoresIndependentChannels() {
  var observer = TerminalTitleStackObserver()
  let output = Array(
    ("\u{001B}]1;icon-a\u{0007}\u{001B}]2;window-a\u{0007}"
      + "\u{001B}[22;1t\u{001B}[22;2t"
      + "\u{001B}]1;icon-b\u{0007}\u{001B}]2;window-b\u{0007}"
      + "\u{001B}[23;1t\u{001B}[23;2t").utf8)

  #expect(observer.consume(output) == [
    .init(code: 1, title: "icon-a"),
    .init(code: 2, title: "window-a"),
    .init(code: 1, title: "icon-b"),
    .init(code: 2, title: "window-b"),
    .init(code: 1, title: "icon-a"),
    .init(code: 2, title: "window-a"),
  ])
}

@Test("普通 UTF-8 续字节不会吞掉后续 OSC 标题")
func terminalTitleStackObserverIgnoresUTF8ContinuationBytes() {
  var observer = TerminalTitleStackObserver()
  let output = Array("Л\u{001B}]1;标题\u{0007}".utf8)

  #expect(observer.consume(output) == [.init(code: 1, title: "标题")])
}

@Test("标题栈观察器丢弃被 CAN 取消的超限 OSC 并继续解析后续标题")
func terminalTitleStackObserverDiscardsCancelledOSC() {
  var observer = TerminalTitleStackObserver()
  let output = Array("\u{001B}]2;discarded\u{0018}\u{001B}]2;accepted\u{0007}".utf8)

  #expect(observer.consume(output) == [.init(code: 2, title: "accepted")])
}

@Test("新标签位置策略区分空标签、内容标签和当前分组末尾")
func newTabPositionResolvesInsertionIndex() {
  #expect(
    NewTabPosition.automatic.insertionIndex(
      selectedIndex: 1, tabCount: 5, hasContent: false, sectionEndIndex: 3) == 3)
  #expect(
    NewTabPosition.automatic.insertionIndex(
      selectedIndex: 1, tabCount: 5, hasContent: true, sectionEndIndex: 3) == 2)
  #expect(
    NewTabPosition.end.insertionIndex(
      selectedIndex: 1, tabCount: 5, hasContent: true, sectionEndIndex: 3) == 5)
  #expect(
    NewTabPosition.afterCurrent.insertionIndex(
      selectedIndex: 4, tabCount: 5, hasContent: false, sectionEndIndex: nil) == 5)
}

@Test("最近关闭标签按 LIFO 恢复并限制保存数量")
func recentlyClosedTabsRestoresMostRecentFirst() throws {
  let pane = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let snapshots = (0..<4).map { index in
    WorkspaceTabSnapshot(
      id: UUID(),
      title: "tab-\(index)",
      layout: .leaf(pane)
    )
  }
  var history = RecentlyClosedTabs(limit: 3)
  snapshots.forEach { history.record($0) }

  #expect(history.entries.map(\.title) == ["tab-1", "tab-2", "tab-3"])
  #expect(history.reopenLast()?.title == "tab-3")
  #expect(history.reopenLast()?.title == "tab-2")

  let encoded = try JSONEncoder().encode(history)
  let restored = try JSONDecoder().decode(RecentlyClosedTabs.self, from: encoded)
  #expect(restored.entries.map(\.title) == ["tab-1"])
}

@Test("异常关闭历史会约束容量并安全裁剪条目")
func recentlyClosedTabsNormalizesDecodedLimit() throws {
  let pane = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let entry = WorkspaceTabSnapshot(id: UUID(), title: "safe", layout: .leaf(pane))
  let malformed = try JSONSerialization.data(withJSONObject: [
    "entries": [
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
    ],
    "limit": -10,
  ])

  var decoded = try JSONDecoder().decode(RecentlyClosedTabs.self, from: malformed)
  decoded.record(entry)

  #expect(decoded.limit == 1)
  #expect(decoded.entries.count == 1)
}
