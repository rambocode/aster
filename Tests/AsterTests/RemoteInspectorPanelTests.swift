import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

// MARK: - 测试夹具

@MainActor
private func remoteTestDefaults() -> UserDefaults {
  let suite = "AsterRemoteInspectorTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

/// 构造一个场景 A 的远端上下文。解析真实 argv，避免测试与生产走两套身份规则。
private func makeRemoteContext(host: String = "example.com") -> RemoteInspectionContext {
  let invocation = SSHCommandInvocation.parse("ssh \(host)")!
  let endpoint = SSHResolvedEndpoint(hostName: host)!
  return .ssh(invocation: invocation, endpoint: endpoint)
}

@MainActor
private func makeHost(
  tabID: UUID = UUID(),
  paneID: UUID = UUID(),
  channelKey: String = "ssh:test",
  directory: String?
) -> RemoteInspectionHost {
  RemoteInspectionHost(
    tabID: tabID,
    paneID: paneID,
    context: makeRemoteContext(),
    channelKey: channelKey,
    workingDirectory: directory.map { RemoteWorkingDirectory(host: "example.com", path: $0) }
  )
}

private func makeListing(
  directory: String,
  names: [String] = ["a.txt"],
  totalCount: Int? = nil,
  truncated: Bool = false
) -> RemoteDirectoryListing {
  let entries = names.map { name in
    RemoteDirectoryEntry(
      name: name,
      kind: .file,
      targetIsDirectory: false,
      size: 10,
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
      mode: 0o644,
      isHidden: name.hasPrefix("."),
      nameDecodedLossy: false
    )
  }
  return RemoteDirectoryListing(
    directory: directory,
    entries: entries,
    totalCount: totalCount ?? entries.count,
    isTruncated: truncated
  )
}

/// 记录假 client 收到的请求。测试全程在主线程，因此不需要额外同步。
@MainActor
private final class RemoteCallLog {
  var directories: [String] = []
  var monitorCalls = 0
  var commits = 0
}

/// 等待若干次事件循环让 `Task` 推进；必要时按毫秒等待去抖与轮询。
@MainActor
private func settle(milliseconds: Int = 0) async {
  if milliseconds > 0 {
    try? await Task.sleep(for: .milliseconds(milliseconds))
  }
  for _ in 0..<6 { await Task.yield() }
}

extension NSView {
  /// 整棵子树，供测试按 identifier 或文本查找。
  fileprivate var remoteTestDescendants: [NSView] {
    subviews + subviews.flatMap(\.remoteTestDescendants)
  }

  /// 子树里所有静态文本，用于断言状态文案。
  fileprivate var remoteTestTexts: [String] {
    remoteTestDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
  }
}

// MARK: - Files 页

@Test("远端模式下 Files 页换成远端列表，本地文件树不再构建")
@MainActor
func remoteModeReplacesLocalFilesContent() async throws {
  _ = NSApplication.shared
  let defaults = remoteTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }

  let client = RemoteInspectionClient(
    listDirectory: { _, directory in .success(makeListing(directory: directory)) },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot()) }
  )
  let source = RemoteInspectionSource(
    context: { _ in makeRemoteContext() },
    workingDirectory: { _ in RemoteWorkingDirectory(host: "example.com", path: "/srv") }
  )
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, remoteClient: client, remoteSource: source)
  controller.loadViewIfNeeded()
  await settle(milliseconds: 400)

  let identifiers = Set(controller.view.remoteTestDescendants.compactMap { $0.identifier?.rawValue })
  #expect(identifiers.contains("details-remote-files-table"))
  #expect(identifiers.contains("details-files-table") == false)
  #expect(controller.inspectorRemoteContext != nil)
}

@Test("远端模式下 Git 页显示不支持占位而不跑本地 git")
@MainActor
func remoteModeShowsGitPlaceholder() async throws {
  _ = NSApplication.shared
  let defaults = remoteTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 2
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }

  var gitCalls = 0
  let inspection = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in
      gitCalls += 1
      return GitStatusSummary()
    },
    files: { _, _ in [] }
  )
  let source = RemoteInspectionSource(
    context: { _ in makeRemoteContext() },
    workingDirectory: { _ in nil }
  )
  let controller = DetailsPanelViewController(
    model: model,
    preferences: preferences,
    inspectionClient: inspection,
    remoteSource: source
  )
  controller.loadViewIfNeeded()
  await settle()

  let placeholder = controller.view.remoteTestDescendants
    .first { $0.identifier?.rawValue == "details-remote-unsupported" }
  #expect(placeholder != nil)
  #expect(placeholder?.isHidden == false)
  #expect(gitCalls == 0)
}

@Test("远端目录请求按 300ms 去抖，只发出最后一次")
@MainActor
func remoteDirectoryRequestsAreDebounced() async throws {
  _ = NSApplication.shared
  let log = RemoteCallLog()
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in
      log.directories.append(directory)
      return .success(makeListing(directory: directory))
    },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot()) }
  )
  let controller = RemoteFilesSectionController(
    client: client, onCommitted: { log.commits += 1 }, prefillCommand: { _ in }, notify: { _ in })
  controller.loadViewIfNeeded()

  let tabID = UUID()
  let paneID = UUID()
  for directory in ["/a", "/b", "/c"] {
    controller.activate(
      host: makeHost(tabID: tabID, paneID: paneID, directory: directory))
  }
  await settle(milliseconds: 450)

  #expect(log.directories == ["/c"])
}

@Test("远端目录的迟到结果按身份丢弃")
@MainActor
func lateRemoteDirectoryResultIsDiscarded() async throws {
  _ = NSApplication.shared
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in
      // 只有第一个目录慢：它返回时用户已经切到另一个目录，结果必须被丢掉。
      if directory == "/slow" { try? await Task.sleep(for: .milliseconds(400)) }
      return .success(makeListing(directory: directory))
    },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot()) }
  )
  let controller = RemoteFilesSectionController(
    client: client, onCommitted: {}, prefillCommand: { _ in }, notify: { _ in })
  controller.loadViewIfNeeded()

  let tabID = UUID()
  let paneID = UUID()
  controller.activate(host: makeHost(tabID: tabID, paneID: paneID, directory: "/slow"))
  await settle(milliseconds: 350)
  controller.activate(host: makeHost(tabID: tabID, paneID: paneID, directory: "/fast"))
  await settle(milliseconds: 700)

  guard case .listed(let listing) = controller.state else {
    Issue.record("期望列表就绪，实际为 \(controller.state)")
    return
  }
  #expect(listing.directory == "/fast")
}

@Test("切 Pane 后远端列表结果不再提交")
@MainActor
func suspendedRemoteFilesDoesNotCommit() async throws {
  _ = NSApplication.shared
  let log = RemoteCallLog()
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in
      try? await Task.sleep(for: .milliseconds(200))
      return .success(makeListing(directory: directory))
    },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot()) }
  )
  let controller = RemoteFilesSectionController(
    client: client, onCommitted: { log.commits += 1 }, prefillCommand: { _ in }, notify: { _ in })
  controller.loadViewIfNeeded()
  controller.activate(host: makeHost(directory: "/srv"))
  await settle(milliseconds: 350)
  controller.suspend()
  await settle(milliseconds: 300)

  #expect(log.commits == 0)
  if case .listed = controller.state {
    Issue.record("挂起后不应提交列表")
  }
}

@Test("远端列表被截断时标注已显示条数")
@MainActor
func truncatedRemoteListingShowsCount() async throws {
  _ = NSApplication.shared
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in
      .success(
        makeListing(directory: directory, names: ["a", "b"], totalCount: 3_000, truncated: true))
    },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot()) }
  )
  let controller = RemoteFilesSectionController(
    client: client, onCommitted: {}, prefillCommand: { _ in }, notify: { _ in })
  controller.loadViewIfNeeded()
  controller.activate(host: makeHost(directory: "/srv"))
  await settle(milliseconds: 450)

  let texts = controller.view.remoteTestTexts
  #expect(texts.contains { $0.contains("已截断") && $0.contains("3000") })
}

@Test("远端目录不存在时给出返回上级与浏览 $HOME")
@MainActor
func missingRemoteDirectoryShowsRecoveryActions() async throws {
  _ = NSApplication.shared
  let client = RemoteInspectionClient(
    listDirectory: { _, _ in .failure(.directoryMissing) },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot()) }
  )
  let controller = RemoteFilesSectionController(
    client: client, onCommitted: {}, prefillCommand: { _ in }, notify: { _ in })
  controller.loadViewIfNeeded()
  controller.activate(host: makeHost(directory: "/gone"))
  await settle(milliseconds: 450)

  #expect(controller.state == .failed(.directoryMissing, "/gone"))
  #expect(controller.view.remoteTestTexts.contains { $0.contains("远端目录不存在") })
  let titles = controller.view.remoteTestDescendants.compactMap { ($0 as? NSButton)?.title }
  #expect(titles.contains("返回上级"))
  #expect(titles.contains("浏览 $HOME"))
}

@Test("需要认证时提示开启 SSH 连接复用且不给重试")
@MainActor
func authenticationFailureAsksForConnectionSharing() async throws {
  _ = NSApplication.shared
  let client = RemoteInspectionClient(
    listDirectory: { _, _ in .failure(.authenticationRequired) },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot()) }
  )
  let controller = RemoteFilesSectionController(
    client: client, onCommitted: {}, prefillCommand: { _ in }, notify: { _ in })
  controller.loadViewIfNeeded()
  controller.activate(host: makeHost(directory: "/srv"))
  await settle(milliseconds: 450)

  #expect(controller.view.remoteTestTexts.contains { $0.contains("SSH 连接复用") })
  let identifiers = controller.view.remoteTestDescendants.compactMap { $0.identifier?.rawValue }
  #expect(identifiers.contains("details-remote-files-retry") == false)
}

@Test("远端文件名剥离路径分隔符后才用作本地默认文件名")
@MainActor
func downloadNameIsSanitized() {
  #expect(RemoteFilesSectionController.sanitizedDownloadName("a/b") == "a_b")
  #expect(RemoteFilesSectionController.sanitizedDownloadName("..") == "download")
  #expect(RemoteFilesSectionController.sanitizedDownloadName("  ") == "download")
  #expect(RemoteFilesSectionController.sanitizedDownloadName("notes.txt") == "notes.txt")
}

// MARK: - Info 页

@Test("上一个监控 tick 未完成时跳过本次采集")
@MainActor
func monitorSkipsTickWhileFetching() async throws {
  _ = NSApplication.shared
  let log = RemoteCallLog()
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in .success(makeListing(directory: directory)) },
    monitor: { _, _ in
      log.monitorCalls += 1
      try? await Task.sleep(for: .milliseconds(300))
      return .success(RemoteHostMonitorSnapshot(host: "srv"))
    }
  )
  let controller = RemoteMonitorSectionController(client: client, onCommitted: {})
  controller.loadViewIfNeeded()
  let host = makeHost(directory: "/srv")
  controller.activate(host: host)
  await settle()
  // 同一宿主再次激活：上一个 tick 还在路上，必须跳过而不是排队。
  controller.activate(host: host)
  await settle()

  #expect(log.monitorCalls == 1)
  #expect(controller.isFetching)
}

@Test("监控首个采样显示破折号，第二个采样才给出 CPU 百分比")
@MainActor
func monitorFirstSampleHasNoCPUPercent() async throws {
  _ = NSApplication.shared
  var tick = 0
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in .success(makeListing(directory: directory)) },
    monitor: { _, _ in
      tick += 1
      return .success(
        RemoteHostMonitorSnapshot(
          host: "srv",
          load: RemoteLoadAverage(one: 0.5, five: 0.4, fifteen: 0.3),
          cpuSample: RemoteCPUStatSample(
            idleTicks: UInt64(100 * tick), totalTicks: UInt64(200 * tick), cpuCount: 2)
        ))
    }
  )
  let controller = RemoteMonitorSectionController(client: client, onCommitted: {})
  controller.loadViewIfNeeded()
  controller.activate(host: makeHost(directory: "/srv"))
  await settle(milliseconds: 100)
  #expect(controller.view.remoteTestTexts.contains { $0.contains("—") })

  controller.suspend()
  controller.activate(host: makeHost(directory: "/srv"))
  await settle(milliseconds: 100)
  #expect(controller.view.remoteTestTexts.contains { $0.contains("%") })
}

@Test("面板收起后监控不再排下一次轮询")
@MainActor
func suspendedMonitorHasNoPendingPoll() async throws {
  _ = NSApplication.shared
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in .success(makeListing(directory: directory)) },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot(host: "srv")) }
  )
  let controller = RemoteMonitorSectionController(client: client, onCommitted: {})
  controller.loadViewIfNeeded()
  controller.activate(host: makeHost(directory: "/srv"))
  await settle(milliseconds: 100)
  #expect(controller.hasScheduledPoll)

  controller.suspend()
  #expect(controller.hasScheduledPoll == false)
  #expect(controller.isFetching == false)
}

@Test("监控失败按原因给出文案与重试入口")
@MainActor
func monitorFailureShowsRetry() async throws {
  _ = NSApplication.shared
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in .success(makeListing(directory: directory)) },
    monitor: { _, _ in .failure(.unreachable("timed out")) }
  )
  let controller = RemoteMonitorSectionController(client: client, onCommitted: {})
  controller.loadViewIfNeeded()
  controller.activate(host: makeHost(directory: "/srv"))
  await settle(milliseconds: 100)

  #expect(controller.state == .failed(.unreachable("timed out")))
  let identifiers = controller.view.remoteTestDescendants.compactMap { $0.identifier?.rawValue }
  #expect(identifiers.contains("details-remote-monitor-retry"))
}

@Test("同一通道断开重连后不再停留在上一次连接的目录列表")
@MainActor
func reconnectWithoutReportClearsStaleRemoteListing() async throws {
  _ = NSApplication.shared
  let client = RemoteInspectionClient(
    listDirectory: { _, directory in .success(makeListing(directory: directory)) },
    monitor: { _, _ in .success(RemoteHostMonitorSnapshot()) }
  )
  let controller = RemoteFilesSectionController(
    client: client, onCommitted: {}, prefillCommand: { _ in }, notify: { _ in })
  controller.loadViewIfNeeded()
  let tabID = UUID()
  let paneID = UUID()
  // 第一次连接拿到了目录上报，列出内容。
  controller.activate(
    host: makeHost(tabID: tabID, paneID: paneID, directory: "/tmp/old-session"))
  await settle(milliseconds: 450)
  #expect(controller.activeDirectory == "/tmp/old-session")

  // exit 后再 ssh 同一台机器：通道身份不变，但远端还没上报目录。
  controller.activate(host: makeHost(tabID: tabID, paneID: paneID, directory: nil))
  await settle(milliseconds: 1_800)

  guard case .awaitingIntegration = controller.state else {
    Issue.record("重连后应回到等待远端上报状态，实际：\(controller.state)")
    return
  }
  let texts = controller.view.remoteTestTexts
  #expect(!texts.contains { $0.contains("old-session") })
}

@Test("远端失败详情为空时不显示尾随冒号")
@MainActor
func emptyFailureDetailOmitsTrailingColon() {
  #expect(RemoteInspectionFailure.transport("").message == "连接失败")
  #expect(RemoteInspectionFailure.unreachable("").message == "连接失败")
  #expect(RemoteInspectionFailure.transport("超时").message == "连接失败：超时")
}
