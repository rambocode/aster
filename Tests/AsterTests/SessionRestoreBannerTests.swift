import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 恢复横幅是一段前置在 Shell 启动命令前的 /bin/sh 片段；这里锁定它的结构与转义,
// 保证任何文案/时间都不会破坏 sh 语法,也不会丢掉真正的 Shell 启动命令。

@Test func restoreBannerPrintsQuitAndRestoreLinesWithBlankLineBetween() {
  let quit = Date(timeIntervalSince1970: 1_726_308_000)  // 2024-09-14 10:00 UTC
  let restored = quit.addingTimeInterval(3 * 86_400)
  let lines = SessionRestoreBanner.lines(quitAt: quit, restoredAt: restored)
  #expect(lines.count == 2)
  #expect(lines[0].hasPrefix("───── >_ "))
  #expect(lines[0].contains("退出于 "))
  #expect(lines[1].contains("恢复于 "))

  let prefix = SessionRestoreBanner.shellPrefix(quitAt: quit, restoredAt: restored)
  #expect(prefix.hasPrefix("printf '\\033[2;32m%s\\033[0m\\n' '"))
  // 两行之间夹一个空参数,printf 复用格式串打出空行。
  #expect(prefix.contains("' '' '"))
}

@Test func restoreBannerOmitsQuitLineForLegacySnapshotWithoutTimestamp() {
  let lines = SessionRestoreBanner.lines(quitAt: nil, restoredAt: Date())
  #expect(lines.count == 1)
  #expect(lines[0].contains("恢复于 "))
  let prefix = SessionRestoreBanner.shellPrefix(quitAt: nil, restoredAt: Date())
  #expect(!prefix.contains("' '' '"))
}

@Test func restoreBannerLaunchCommandKeepsShellAsFirstArgumentAndExecsOriginalCommand() throws {
  let launch = GhosttyConfiguration.launchCommand(shell: "/bin/zsh", arguments: ["-l", "-i"])
  let command = SessionRestoreBanner.launchCommand(
    prefixing: launch, shell: "/bin/zsh", reinjectGhosttyZshIntegration: false,
    quitAt: Date(), restoredAt: Date())
  // Ghostty 按 arg0 的 basename 探测 Shell 并注入集成：外层必须是 zsh 本身，不能是 printf。
  #expect(command.hasPrefix("\"/bin/zsh\" \"-c\" \"printf "))
  #expect(command.contains("; exec \\\"/bin/zsh\\\" \\\"-l\\\" \\\"-i\\\"\""))
  #expect(!command.contains("ZDOTDIR"))

  // 真跑一次 /bin/sh:横幅落到 stdout,exec 之后的退出码原样透传(Ghostty 据此判断 Shell 退出状态)。
  let probe = SessionRestoreBanner.launchCommand(
    prefixing: "\"/bin/sh\" \"-c\" \"echo shell-started; exit 7\"", shell: "/bin/sh",
    reinjectGhosttyZshIntegration: false, quitAt: Date(), restoredAt: Date())
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", probe]
  let pipe = Pipe()
  process.standardOutput = pipe
  try process.run()
  process.waitUntilExit()
  let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  #expect(process.terminationStatus == 7)
  #expect(output.contains("\u{1B}[2;32m───── >_ "))
  #expect(output.hasSuffix("shell-started\n"))
}

// 外层 zsh -c 启动时 Ghostty 的 .zshenv 会把 ZDOTDIR 还原成用户值,exec 前必须按 Ghostty
// 同样的规则再注入一次,否则最终的交互 zsh 没有集成(无 OSC 133/7、光标样式退回默认方块)。
@Test func restoreBannerReinjectsGhosttyZshIntegrationBeforeExec() throws {
  let resources = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-banner-res-\(UUID().uuidString)", isDirectory: true)
  let integration = resources.appendingPathComponent("shell-integration/zsh", isDirectory: true)
  try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true)
  try Data().write(to: integration.appendingPathComponent(".zshenv"))
  defer { try? FileManager.default.removeItem(at: resources) }

  // 内层「Shell」只回显它拿到的注入环境。
  let inner = "\"/bin/sh\" \"-c\" \"printf %s:%s \\\"$ZDOTDIR\\\" \\\"${GHOSTTY_ZSH_ZDOTDIR-unset}\\\"\""
  let command = SessionRestoreBanner.launchCommand(
    prefixing: inner, shell: "/bin/zsh", reinjectGhosttyZshIntegration: true,
    quitAt: nil, restoredAt: Date())
  #expect(command.hasPrefix("\"/bin/zsh\" \"-c\" \"printf "))

  func run(environment extra: [String: String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    var environment = ProcessInfo.processInfo.environment
    environment["GHOSTTY_RESOURCES_DIR"] = resources.path
    environment.removeValue(forKey: "ZDOTDIR")
    environment.removeValue(forKey: "GHOSTTY_ZSH_ZDOTDIR")
    for (key, value) in extra { environment[key] = value }
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return output.split(separator: "\n").last.map(String.init) ?? ""
  }
  // 用户没有 ZDOTDIR:只把 ZDOTDIR 指向集成目录。
  #expect(try run(environment: [:]) == "\(integration.path):unset")
  // 用户有 ZDOTDIR:先保存到 GHOSTTY_ZSH_ZDOTDIR,再覆盖 ZDOTDIR,与 Ghostty setupZsh 一致。
  #expect(try run(environment: ["ZDOTDIR": "/tmp/user-zdotdir"]) == "\(integration.path):/tmp/user-zdotdir")
}

// 走真实恢复路径:快照带 savedAt → AppModel 重建标签 → Session 首次拉起 Shell 时把横幅
// 前置到启动命令;新建标签与「重新拉起」不再带横幅。
@Test("快照恢复的终端 Pane 首次启动命令前置时间横幅,新建标签不带")
@MainActor
func restoredPaneLaunchCommandCarriesBannerOnlyOnce() throws {
  let suite = "RestoreBanner.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let tabSnapshot = WorkspaceTabSnapshot(
    id: UUID(), title: "restored",
    layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home)))
  let snapshot = WorkspaceSnapshot(
    selectedTabID: tabSnapshot.id, tabs: [tabSnapshot],
    savedAt: Date(timeIntervalSinceNow: -3 * 86_400))
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")

  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  defer {
    for item in model.tabs {
      for runtime in item.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    }
  }
  #expect(session.hasPendingRestoreBanner)

  let terminal = try liveGhosttyView(for: session, preferences: preferences)
  let command = try #require(terminal.command)
  // 外层仍是 Shell 本身(Ghostty 据 arg0 注入集成),横幅 printf 放在 -c 脚本里,最后 exec 原启动命令。
  #expect(command.hasPrefix("\""))
  #expect(command.contains("\" \"-c\" \"printf '\\\\033[2;32m%s\\\\033[0m\\\\n' '───── >_ "))
  #expect(command.contains("退出于 "))
  #expect(command.contains("恢复于 "))
  #expect(command.contains("; exec \\\"") && command.hasSuffix("\\\"-i\\\"\""))
  // 横幅一次性消费:之后重建 surface / 重启 Shell 不会重复打印。
  #expect(!session.hasPendingRestoreBanner)

  // 用户新建的标签没有恢复语义,启动命令保持纯 Shell。
  model.newTab()
  let fresh = try #require(model.selectedTab?.activeSession)
  #expect(!fresh.hasPendingRestoreBanner)
  let freshCommand = try #require(try liveGhosttyView(for: fresh, preferences: preferences).command)
  #expect(!freshCommand.contains("printf"))
}
