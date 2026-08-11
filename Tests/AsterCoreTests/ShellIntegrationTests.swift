import Foundation
import Testing

@testable import AsterCore

@Test("OSC 133 只接受 A B C D 及合法退出码")
func shellIntegrationEventParsesStrictFTCSMarkers() {
  #expect(ShellIntegrationEvent(payload: "A") == .promptStart)
  #expect(ShellIntegrationEvent(payload: "A;cl=line") == .promptStart)
  #expect(ShellIntegrationEvent(payload: "B") == .inputStart)
  #expect(ShellIntegrationEvent(payload: "C") == .commandStart)
  #expect(ShellIntegrationEvent(payload: "D;0") == .commandFinished(exitStatus: 0))
  #expect(ShellIntegrationEvent(payload: "D;130") == .commandFinished(exitStatus: 130))
  #expect(ShellIntegrationEvent(payload: "D") == .commandFinished(exitStatus: nil))
  #expect(ShellIntegrationEvent(payload: "D;bad") == nil)
  #expect(ShellIntegrationEvent(payload: "C;secret command") == nil)
  #expect(ShellIntegrationEvent(payload: "A;secret=value") == nil)
  #expect(ShellIntegrationEvent(payload: "Z") == nil)
}

@Test("命令时间线把提示符、输入、输出和退出状态组成有界记录")
func shellCommandTimelineBuildsBoundedCommandMarks() {
  var timeline = ShellCommandTimeline(capacity: 2)

  for index in 0..<3 {
    let row = index * 10
    timeline.receive(.promptStart, at: TerminalGridPoint(column: 0, row: row))
    timeline.receive(.inputStart, at: TerminalGridPoint(column: 2, row: row))
    timeline.receive(.commandStart, at: TerminalGridPoint(column: 0, row: row + 1))
    timeline.receive(
      .commandFinished(exitStatus: index),
      at: TerminalGridPoint(column: 0, row: row + 4)
    )
  }

  #expect(timeline.integrationDetected)
  #expect(!timeline.isCommandRunning)
  #expect(timeline.marks.count == 2)
  #expect(timeline.marks.map(\.promptStart.row) == [10, 20])
  #expect(timeline.marks.map(\.exitStatus) == [1, 2])
  #expect(timeline.marks.last?.inputStart == TerminalGridPoint(column: 2, row: 20))
  #expect(timeline.marks.last?.outputStart == TerminalGridPoint(column: 0, row: 21))
  #expect(timeline.marks.last?.outputEnd == TerminalGridPoint(column: 0, row: 24))
  #expect(timeline.currentInputStart == nil)
}

@Test("命令开始后时间线公开运行中的 Outline 锚点")
func shellCommandTimelineExposesRunningCommand() {
  var timeline = ShellCommandTimeline()
  timeline.receive(.promptStart, at: TerminalGridPoint(column: 0, row: 10))
  timeline.receive(.inputStart, at: TerminalGridPoint(column: 2, row: 10))
  timeline.receive(.commandStart, at: TerminalGridPoint(column: 0, row: 11))

  #expect(timeline.isCommandRunning)
  #expect(timeline.runningCommand?.promptStart == TerminalGridPoint(column: 0, row: 10))
  #expect(timeline.runningCommand?.inputStart == TerminalGridPoint(column: 2, row: 10))
  #expect(timeline.runningCommand?.outputStart == TerminalGridPoint(column: 0, row: 11))

  timeline.receive(.commandFinished(exitStatus: 0), at: TerminalGridPoint(column: 0, row: 12))
  #expect(timeline.runningCommand == nil)
}

@Test("缺失或乱序标记不会伪造命令记录")
func shellCommandTimelineRejectsIncompleteSequences() {
  var timeline = ShellCommandTimeline()

  timeline.receive(.commandFinished(exitStatus: 1), at: TerminalGridPoint(column: 0, row: 1))
  timeline.receive(.commandStart, at: TerminalGridPoint(column: 0, row: 2))
  timeline.receive(.commandFinished(exitStatus: 0), at: TerminalGridPoint(column: 0, row: 3))

  #expect(timeline.integrationDetected)
  #expect(timeline.marks.isEmpty)
  #expect(!timeline.isCommandRunning)
}

@Test("命令时间线支持上一条和下一条命令导航")
func shellCommandTimelineNavigatesByAbsoluteRow() {
  var timeline = ShellCommandTimeline()
  for row in [5, 15, 25] {
    timeline.receive(.promptStart, at: TerminalGridPoint(column: 0, row: row))
    timeline.receive(.inputStart, at: TerminalGridPoint(column: 2, row: row))
    timeline.receive(.commandStart, at: TerminalGridPoint(column: 0, row: row + 1))
    timeline.receive(.commandFinished(exitStatus: 0), at: TerminalGridPoint(column: 0, row: row + 2))
  }

  #expect(timeline.previousCommand(beforeOrAt: 100)?.promptStart.row == 25)
  #expect(timeline.previousCommand(beforeOrAt: 24)?.promptStart.row == 15)
  #expect(timeline.nextCommand(after: 5)?.promptStart.row == 15)
  #expect(timeline.nextCommand(after: 25) == nil)
}

@Test("最近完成命令未提供退出码时不会沿用旧状态")
func shellCommandTimelineClearsUnavailableLatestExitStatus() {
  var timeline = ShellCommandTimeline()
  timeline.receive(.promptStart, at: TerminalGridPoint(column: 0, row: 0))
  timeline.receive(.inputStart, at: TerminalGridPoint(column: 2, row: 0))
  timeline.receive(.commandStart, at: TerminalGridPoint(column: 0, row: 1))
  timeline.receive(.commandFinished(exitStatus: 7), at: TerminalGridPoint(column: 0, row: 2))
  #expect(timeline.latestExitStatus == 7)

  timeline.receive(.promptStart, at: TerminalGridPoint(column: 0, row: 3))
  timeline.receive(.inputStart, at: TerminalGridPoint(column: 2, row: 3))
  timeline.receive(.commandStart, at: TerminalGridPoint(column: 0, row: 4))
  timeline.receive(.commandFinished(exitStatus: nil), at: TerminalGridPoint(column: 0, row: 5))

  #expect(timeline.latestExitStatus == nil)
}

@Test("zsh 与 fish 使用会话级注入，bash 保留受管启动文件入口")
func shellIntegrationLaunchPlansAreShellSpecific() {
  let root = "/Applications/Aster.app/Contents/Resources/shell-integration"
  let inherited = [
    "HOME": "/Users/test",
    "ZDOTDIR": "/Users/test/.config/zsh",
    "XDG_DATA_DIRS": "/opt/share:/usr/share",
  ]

  let zsh = ShellIntegrationLaunchPlan.make(
    shellPath: "/bin/zsh",
    enabled: true,
    resourceDirectory: root,
    inheritedEnvironment: inherited
  )
  #expect(zsh?.shell == .zsh)
  #expect(zsh?.environment["ZDOTDIR"] == "\(root)/zsh")
  #expect(zsh?.environment["ASTER_REAL_ZDOTDIR"] == "/Users/test/.config/zsh")
  #expect(zsh?.environment["ASTER_INTEGRATION"] == "1")

  let fish = ShellIntegrationLaunchPlan.make(
    shellPath: "/opt/homebrew/bin/fish",
    enabled: true,
    resourceDirectory: root,
    inheritedEnvironment: inherited
  )
  #expect(fish?.shell == .fish)
  #expect(fish?.environment["XDG_DATA_DIRS"] == "\(root)/fish:/opt/share:/usr/share")
  #expect(fish?.environment["ASTER_FISH_DATA_DIR"] == "\(root)/fish")

  let bash = ShellIntegrationLaunchPlan.make(
    shellPath: "/bin/bash",
    enabled: true,
    resourceDirectory: root,
    inheritedEnvironment: inherited
  )
  #expect(bash?.shell == .bash)
  #expect(bash?.environment["ZDOTDIR"] == "/Users/test/.config/zsh")
  #expect(bash?.environment["ASTER_SHELL_INTEGRATION_DIR"] == root)

  #expect(
    ShellIntegrationLaunchPlan.make(
      shellPath: "/bin/ksh",
      enabled: true,
      resourceDirectory: root,
      inheritedEnvironment: inherited
    ) == nil
  )
  #expect(
    ShellIntegrationLaunchPlan.make(
      shellPath: "/bin/zsh",
      enabled: true,
      resourceDirectory: root,
      inheritedEnvironment: inherited.merging(["ASTER_DISABLE_INTEGRATION": "1"]) { _, new in new }
    ) == nil
  )
}

@Test("提示符选区删除只接受当前输入行内的 ASCII 线性范围")
func promptSelectionDeletionPolicyRejectsAmbiguousRanges() {
  let inputStart = TerminalGridPoint(column: 2, row: 10)
  let cursor = TerminalGridPoint(column: 8, row: 10)
  let valid = PromptSelectionDeletionPolicy.plan(
    inputStart: inputStart,
    cursor: cursor,
    selectionStart: TerminalGridPoint(column: 4, row: 10),
    selectionEnd: TerminalGridPoint(column: 7, row: 10),
    selectedText: "abc",
    rectangular: false,
    commandRunning: false
  )
  #expect(valid == PromptSelectionDeletionPlan(horizontalMovement: -1, deleteCount: 3))

  #expect(
    PromptSelectionDeletionPolicy.plan(
      inputStart: inputStart,
      cursor: cursor,
      selectionStart: TerminalGridPoint(column: 1, row: 10),
      selectionEnd: TerminalGridPoint(column: 4, row: 10),
      selectedText: "$ a",
      rectangular: false,
      commandRunning: false
    ) == nil
  )
  #expect(
    PromptSelectionDeletionPolicy.plan(
      inputStart: inputStart,
      cursor: cursor,
      selectionStart: TerminalGridPoint(column: 4, row: 10),
      selectionEnd: TerminalGridPoint(column: 7, row: 10),
      selectedText: "密钥",
      rectangular: false,
      commandRunning: false
    ) == nil
  )
  #expect(
    PromptSelectionDeletionPolicy.plan(
      inputStart: inputStart,
      cursor: cursor,
      selectionStart: TerminalGridPoint(column: 4, row: 10),
      selectionEnd: TerminalGridPoint(column: 7, row: 10),
      selectedText: "abc",
      rectangular: true,
      commandRunning: false
    ) == nil
  )
  #expect(
    PromptSelectionDeletionPolicy.plan(
      inputStart: inputStart,
      cursor: cursor,
      selectionStart: TerminalGridPoint(column: 4, row: 10),
      selectionEnd: TerminalGridPoint(column: 7, row: 10),
      selectedText: "abc",
      rectangular: false,
      commandRunning: true
    ) == nil
  )
}

@Test("命令完成标记记录本地结束时间")
func shellCommandTimelineStampsFinishedAt() {
  var timeline = ShellCommandTimeline()
  timeline.receive(.promptStart, at: TerminalGridPoint(column: 0, row: 0))
  timeline.receive(.inputStart, at: TerminalGridPoint(column: 2, row: 0))
  timeline.receive(.commandStart, at: TerminalGridPoint(column: 0, row: 1))
  let before = Date()
  timeline.receive(.commandFinished(exitStatus: 0), at: TerminalGridPoint(column: 0, row: 4))
  let after = Date()

  let finishedAt = timeline.marks.last?.finishedAt
  #expect(finishedAt != nil)
  #expect(finishedAt.map { $0 >= before && $0 <= after } == true)
}
