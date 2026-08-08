import Foundation
import Testing

@testable import AsterCore

@Test("CLI 解析 open、view、edit、watch、jump、learn 和 ignore 的稳定动作")
func workflowCLIParsesDocumentedTopLevelActions() throws {
  let parser = WorkflowCLIParser(currentDirectory: "/work/project")

  #expect(
    try parser.parse(["otty", "open", ".", "--command", "npm run dev", "--title", "API"])
      == .open(.init(path: "/work/project", command: "npm run dev", title: "API"))
  )
  #expect(
    try parser.parse(["view", "README.md"])
      == .openTarget(
        .init(
          target: .localPath("/work/project/README.md"),
          mode: .view,
          placement: .newTab
        ))
  )
  #expect(
    try parser.parse(["edit", "notes.md", "--right"])
      == .openTarget(
        .init(
          target: .localPath("/work/project/notes.md"),
          mode: .edit,
          placement: .split(.right)
        ))
  )
  #expect(
    try parser.parse(["watch", "-q", "--", "make", "test"])
      == .watch(.init(command: ["make", "test"], postsNotification: false))
  )
  #expect(try parser.parse(["jump", "api", "--no-cd"]) == .jump(.init(query: "api", noCD: true)))
  #expect(
    try parser.parse(["learn", "-y", "~/src"]) == .learn(.init(target: "~/src", assumeYes: true)))
  #expect(try parser.parse(["ignore", "~/tmp"]) == .ignore(.init(target: "~/tmp")))
}

@Test("CLI 解析 Pane send、run、exec、capture，并标明写入权限边界")
func workflowCLIParsesPaneAutomationWithoutExecutingIt() throws {
  let parser = WorkflowCLIParser(currentDirectory: "/work")

  let send = try parser.parse([
    "pane", "send-text", "--pane", "p_123", "git status\\n",
  ])
  #expect(
    send
      == .send(
        .init(selector: "p_123", input: .text("git status\\n"))
      ))
  #expect(send.requiresIPCAllowSendKeys)

  #expect(
    try parser.parse(["pane", "run", "--pane", "p_123", "--", "npm", "test"])
      == .run(.init(selector: "p_123", command: ["npm", "test"], format: .text))
  )
  #expect(
    try parser.parse([
      "--format", "json", "pane", "exec", "--pane", "p_123", "--", "cargo", "build",
    ])
      == .exec(
        .init(selector: "p_123", command: ["cargo", "build"], format: .json)
      )
  )
  let capture = try parser.parse(["pane", "capture", "--pane", "p_123", "--lines", "50"])
  #expect(capture == .capture(.init(selector: "p_123", lines: 50, format: .text)))
  #expect(!capture.requiresIPCAllowSendKeys)
}

@Test("CLI 在解析阶段拒绝无界参数、冲突位置和空执行命令")
func workflowCLIRejectsUnsafeOrAmbiguousArguments() {
  let parser = WorkflowCLIParser(currentDirectory: "/work")

  #expect(throws: WorkflowCLIParseError.conflictingPlacement) {
    try parser.parse(["view", "a.txt", "--left", "--new-window"])
  }
  #expect(throws: WorkflowCLIParseError.commandRequired("run")) {
    try parser.parse(["pane", "run", "--pane", "p_1", "--"])
  }
  #expect(throws: WorkflowCLIParseError.valueOutOfRange("--lines")) {
    try parser.parse(["pane", "capture", "--lines", "10001"])
  }
  #expect(throws: WorkflowCLIParseError.tooManyArguments) {
    try parser.parse(["watch"] + Array(repeating: "x", count: 256))
  }
  #expect(throws: WorkflowCLIParseError.invalidValue("target")) {
    try parser.parse(["ignore", ""])
  }
  #expect(throws: WorkflowCLIParseError.commandRequired("watch")) {
    try parser.parse(["watch", ""])
  }
}

@Test("otty 深链只描述 Window、Tab、Pane 聚焦，不携带命令或文件动作")
func workflowDeepLinksDescribeFocusOnlyActions() throws {
  #expect(
    try WorkflowDeepLink.parse("otty://window/title:API%20Server")
      == .focusWindow(.title("API Server"))
  )
  #expect(try WorkflowDeepLink.parse("otty://tab/2") == .focusTab(.index(2)))
  #expect(try WorkflowDeepLink.parse("otty://pane/p_123") == .focusPane(.identifier("p_123")))
  #expect(
    try WorkflowDeepLink.parse("otty://pane/session-abc")
      == .focusPane(.sessionIdentifier("session-abc"))
  )

  #expect(throws: WorkflowDeepLinkError.unexpectedURLComponent) {
    try WorkflowDeepLink.parse("otty://pane/p_123?command=rm")
  }
  #expect(throws: WorkflowDeepLinkError.invalidSelector) {
    try WorkflowDeepLink.parse("otty://tab/current")
  }
}
