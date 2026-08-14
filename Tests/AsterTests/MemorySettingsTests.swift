import AppKit
import Testing

@testable import Aster
@testable import AsterCore

// Session Memory 的设置面与 Task 命令入口的回归。
// 断言集中在隐私边界（默认关闭、外发需确认、排除列表的解析规则）与命令可发现性上，
// 不锁 DOM 细节 —— 网页侧的字段清单由 `node --check` 与人工验收覆盖。

@MainActor
private func isolatedMemoryDefaults() -> UserDefaults {
  let suite = "MemorySettingsTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

/// 设置页 + 隔离 suite 的组装。提炼器重装默认读 `.standard`，测试必须把它也指向
/// 隔离 suite —— 否则用例结果会依赖开发者本机是否真的开过 CLI 提炼。
@MainActor
private func makeMemorySettings() -> (UserDefaults, AppPreferences, SettingsViewController) {
  let defaults = isolatedMemoryDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  controller.memoryExtractionDefaults = defaults
  return (defaults, preferences, controller)
}

// MARK: - 排除列表解析

@Test("排除目录只接受绝对路径，去尾斜杠并去重")
@MainActor
func memoryExcludedPathsAreNormalized() {
  let parsed = SettingsViewController.memoryExcludedPathList(
    " /Users/me/secrets/ , /Users/me/secrets , relative/path , /var/tmp , , /Users/me/work ")
  #expect(parsed == ["/Users/me/secrets", "/var/tmp", "/Users/me/work"])
}

@Test("排除目录展开 ~ 后仍是绝对路径")
@MainActor
func memoryExcludedPathsExpandTilde() {
  let parsed = SettingsViewController.memoryExcludedPathList("~/private")
  #expect(parsed.count == 1)
  #expect(parsed[0].hasPrefix("/"))
  #expect(parsed[0].hasSuffix("/private"))
}

@Test("排除命令按逗号与空白切分并去重")
@MainActor
func memoryExcludedCommandsAreNormalized() {
  let parsed = SettingsViewController.memoryExcludedCommandList("op, vault  gpg , op,,  ")
  #expect(parsed == ["op", "vault", "gpg"])
}

@Test("排除列表有上限，避免一次粘贴撑爆策略判定")
@MainActor
func memoryExclusionListsAreBounded() {
  let many = (0..<300).map { "/tmp/dir\($0)" }.joined(separator: ",")
  #expect(SettingsViewController.memoryExcludedPathList(many).count == 128)
  let commands = (0..<300).map { "cmd\($0)" }.joined(separator: ",")
  #expect(SettingsViewController.memoryExcludedCommandList(commands).count == 128)
}

// MARK: - 设置快照与写入

@Test("记录设置默认关闭且提炼开关默认不可用")
@MainActor
func memorySettingsDefaultToOff() throws {
  let (_, _, controller) = makeMemorySettings()
  let values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["memory.recordingMode"] as? String == RecordingMode.off.rawValue)
  #expect(values["memory.excludedPaths"] as? String == "")
  #expect(values["memory.excludedCommands"] as? String == "")
  #expect(values["memory.extractionEnabled"] as? Bool == false)
  #expect(values["memory.extractionDisabled"] as? Bool == true)
  #expect(values["memory.extractionProvider"] as? String == AgentProvider.claudeCode.rawValue)
}

@Test("记录模式与排除列表经设置桥接写入偏好")
@MainActor
func memoryRecordingSettingsRoundTrip() throws {
  let (_, preferences, controller) = makeMemorySettings()

  try controller.applySettingForTesting(key: "memory.recordingMode", value: "on")
  try controller.applySettingForTesting(
    key: "memory.excludedPaths", value: "/Users/me/secrets, /var/tmp")
  try controller.applySettingForTesting(key: "memory.excludedCommands", value: "op, vault")

  #expect(preferences.memoryRecordingMode == .on)
  #expect(preferences.memoryExcludedPaths == ["/Users/me/secrets", "/var/tmp"])
  #expect(preferences.memoryExcludedCommands == ["op", "vault"])

  let policy = preferences.memoryRecordingPolicy
  #expect(policy.shouldRecord(command: "ls", workingDirectory: "/Users/me/work"))
  #expect(!policy.shouldRecord(command: "ls", workingDirectory: "/Users/me/secrets/deep"))
  #expect(!policy.shouldRecord(command: "op read x", workingDirectory: "/Users/me/work"))

  let values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["memory.recordingMode"] as? String == "on")
  #expect(values["memory.excludedPaths"] as? String == "/Users/me/secrets, /var/tmp")
}

@Test("隐身模式同样零落盘")
@MainActor
func incognitoModeRecordsNothing() throws {
  let (_, preferences, controller) = makeMemorySettings()
  try controller.applySettingForTesting(key: "memory.recordingMode", value: "incognito")
  #expect(preferences.memoryRecordingMode == .incognito)
  #expect(!preferences.memoryRecordingPolicy.shouldRecord(workingDirectory: "/Users/me/work"))
}

@Test("未知记录模式被拒绝，不会写入偏好")
@MainActor
func invalidRecordingModeIsRejected() {
  let (_, preferences, controller) = makeMemorySettings()
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "memory.recordingMode", value: "everything")
  }
  #expect(preferences.memoryRecordingMode == .off)
}

@Test("首次开启 CLI 提炼在确认外发前不生效")
@MainActor
func extractionRequiresAcknowledgement() throws {
  let (_, preferences, controller) = makeMemorySettings()
  // 控制器未上屏（无 window），确认 sheet 无法展示 —— 此时必须保持关闭，
  // 绝不能因为“弹不出确认框”就默认放行数据外发。
  try controller.applySettingForTesting(key: "memory.extractionEnabled", value: true)
  #expect(preferences.memoryExtractionEnabled == false)
  #expect(preferences.memoryExtractionAcknowledged == false)
}

@Test("已确认过外发后开关直接生效，关闭永远直接生效")
@MainActor
func extractionTogglesAfterAcknowledgement() throws {
  let (_, preferences, controller) = makeMemorySettings()
  preferences.memoryExtractionAcknowledged = true

  try controller.applySettingForTesting(key: "memory.extractionEnabled", value: true)
  #expect(preferences.memoryExtractionEnabled == true)

  let values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["memory.extractionDisabled"] as? Bool == false)

  try controller.applySettingForTesting(key: "memory.extractionEnabled", value: false)
  #expect(preferences.memoryExtractionEnabled == false)
}

@Test("改动提炼设置会立刻重装提炼器，关闭后不再有 CLI 外发路径")
@MainActor
func extractionToggleReinstallsProvider() throws {
  // `MemoryExtraction.provider` 是进程级单例：用例必须自己存档还原，
  // 否则会把状态漏给同进程内后续跑的测试。
  let original = MemoryExtraction.provider
  defer { MemoryExtraction.provider = original }

  let (_, preferences, controller) = makeMemorySettings()
  preferences.memoryExtractionAcknowledged = true

  try controller.applySettingForTesting(key: "memory.extractionEnabled", value: true)
  #expect(MemoryExtraction.provider is CLIAgentMemoryExtractor)

  // 关掉开关后必须真的换回本地提炼器 —— 只改偏好不换 provider 的话，
  // 用户关了开关，下一个结束的会话仍然会被发出去。
  try controller.applySettingForTesting(key: "memory.extractionEnabled", value: false)
  #expect(!(MemoryExtraction.provider is CLIAgentMemoryExtractor))
}

@Test("提炼 provider 只接受已知 Agent")
@MainActor
func extractionProviderIsValidated() throws {
  let (_, preferences, controller) = makeMemorySettings()
  try controller.applySettingForTesting(key: "memory.extractionProvider", value: "codex")
  #expect(preferences.memoryExtractionProvider == AgentProvider.codex.rawValue)
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "memory.extractionProvider", value: "not-an-agent")
  }
  #expect(preferences.memoryExtractionProvider == AgentProvider.codex.rawValue)
}

@Test("存储占用统计不会因目录缺失而报错")
@MainActor
func memoryStoreSizeHandlesMissingDirectory() {
  let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("aster-memory-\(UUID().uuidString)", isDirectory: true)
  #expect(SettingsViewController.memoryStoreByteCount(at: missing) == 0)
}

// MARK: - MCP 注册

@Test("没有工作区窗口时 MCP 卡片给出引导而不是假装可安装")
@MainActor
func memoryMCPSnapshotWithoutProject() throws {
  let (_, _, controller) = makeMemorySettings()
  let snapshot = try #require(
    controller.settingsSnapshotForTesting()["memoryMCP"] as? [String: Any])
  #expect(snapshot["projectPath"] as? String == "")
  #expect(snapshot["installed"] as? Bool == false)
  // 没有项目就不该让按钮可点：点了也只会弹一个「没有可注册的项目」。
  #expect(snapshot["canInstall"] as? Bool == false)
  #expect((snapshot["status"] as? String)?.isEmpty == false)
  #expect((snapshot["detail"] as? String)?.isEmpty == false)
}

@Test("MCP 状态映射到按钮文案：未装 / 已装 / 需修复")
@MainActor
func memoryMCPStateMapsToActionTitle() throws {
  let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("aster-mcp-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  // 伪造一个可执行文件充当 aster-memory-mcp，避免依赖构建产物是否已生成。
  let executable = root.appendingPathComponent("aster-memory-mcp", isDirectory: false)
  FileManager.default.createFile(
    atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
    attributes: [.posixPermissions: 0o755])

  #expect(try MCPInstallService.state(projectDirectory: root, executableURL: executable)
    == .notInstalled)

  try MCPInstallService.install(projectDirectory: root, executableURL: executable)
  #expect(try MCPInstallService.state(projectDirectory: root, executableURL: executable)
    == .installed(commandPath: executable.standardizedFileURL.path))

  // 安装是幂等的：重复点「安装」不应写出第二份注册项或报错。
  try MCPInstallService.install(projectDirectory: root, executableURL: executable)
  #expect(try MCPInstallService.state(projectDirectory: root, executableURL: executable)
    == .installed(commandPath: executable.standardizedFileURL.path))

  // App 被移动后记录的路径失效 —— UI 必须显示「修复路径」而不是「已安装」。
  let moved = root.appendingPathComponent("moved-aster-memory-mcp", isDirectory: false)
  FileManager.default.createFile(
    atPath: moved.path, contents: Data("#!/bin/sh\n".utf8),
    attributes: [.posixPermissions: 0o755])
  #expect(try MCPInstallService.state(projectDirectory: root, executableURL: moved)
    == .outdated(
      commandPath: executable.standardizedFileURL.path,
      expected: moved.standardizedFileURL.path))

  try MCPInstallService.uninstall(projectDirectory: root)
  #expect(try MCPInstallService.state(projectDirectory: root, executableURL: executable)
    == .notInstalled)
}

@Test("Codex 说明只给可复制片段，不触碰用户的 config.toml")
@MainActor
func codexInstructionsAreAdviceOnly() {
  let text = MCPInstallService.codexInstructions()
  #expect(text.contains("[mcp_servers.aster-memory]"))
  #expect(text.contains("~/.codex/config.toml"))

  // 真正的保证：Aster 不会自己去写那个文件。若哪天有人给服务加了写入路径，
  // 这条断言不会挡住他 —— 但它记录了这个决定，改动时会被 review 看到。
  let home = FileManager.default.homeDirectoryForCurrentUser
  let codexConfig = home.appendingPathComponent(".codex/config.toml")
  let before = try? Data(contentsOf: codexConfig)
  _ = MCPInstallService.codexInstructions()
  let after = try? Data(contentsOf: codexConfig)
  #expect(before == after)
}

// MARK: - Task 命令入口

@Test("命令面板提供 Memory 浏览与 Task 闭环的四个入口")
@MainActor
func paletteExposesMemoryCommands() {
  let suite = "MemorySettingsTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let identifiers = Set(model.paletteCommands.map(\.id))
  #expect(identifiers.contains("memory-browser"))
  #expect(identifiers.contains("memory-new-task"))
  #expect(identifiers.contains("memory-assign-task"))
  #expect(identifiers.contains("memory-continue-task"))

  // 命令必须能被中英文关键词搜到，否则用户在面板里根本找不到它们。
  #expect(!CommandPalette.filter(model.paletteCommands, query: "Task").isEmpty)
  #expect(!CommandPalette.filter(model.paletteCommands, query: "memory").isEmpty)
}

@Test("Memory 浏览器提供 Memory / Task / Context 三个分段与 Task 状态流转控件")
@MainActor
func memoryBrowserExposesTaskStatusControl() {
  let suite = "MemorySettingsTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let browser = MemoryBrowserViewController(
    model: model, projectPath: nil, initialTab: .tasks)
  browser.loadViewIfNeeded()

  let segmented = findSubview(in: browser.view) { $0 is NSSegmentedControl }
    as? NSSegmentedControl
  #expect(segmented?.segmentCount == MemoryBrowserTab.allCases.count)

  // 状态流转必须覆盖全部三态：只给「标记完成」的话，放弃与重新打开就没有出口。
  let popUp = findSubview(in: browser.view) { $0 is NSPopUpButton } as? NSPopUpButton
  #expect(popUp?.numberOfItems == TaskStatus.allCases.count)
  #expect(popUp?.itemTitles == TaskStatus.allCases.map(\.displayName))
}

/// 在视图树里找第一个满足条件的子视图。浮层没有 identifier 契约，
/// 这里按类型定位即可，不锁具体层级——层级变化不该让测试变红。
@MainActor
private func findSubview(in view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
  if predicate(view) { return view }
  for subview in view.subviews {
    if let found = findSubview(in: subview, matching: predicate) { return found }
  }
  return nil
}

@Test("没有可关联会话时归入 Task 给出明确提示而不是静默失败")
@MainActor
func assignSessionWithoutPaneReportsNotice() {
  let suite = "MemorySettingsTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  model.notice = nil
  model.promptAssignSessionToTask()
  #expect(model.notice != nil)
}
