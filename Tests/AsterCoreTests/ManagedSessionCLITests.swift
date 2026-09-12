import Foundation
import Testing

@testable import AsterCore

// 远程工作模式 P2.8：`aster session terminals | detach | end` 的解析、分类与参数校验。
// 这三个动作直接决定后台受管进程的去留，语法错误必须在解析阶段就被拒绝，
// 不能带着含糊的目标发到服务端。

/// 解析辅助：argv 不含程序名，返回完整解析结果。
private func parseSessionCLI(_ argv: [String]) throws -> AsterCLIArguments {
  try AsterCLIArguments.parse(argv)
}

/// 解析辅助：只取子命令。
private func sessionCLICommand(_ argv: [String]) throws -> AsterCLICommand {
  try AsterCLIArguments.parse(argv).command
}

@Test("session terminals / detach / end 解析成对应子命令")
func managedSessionCLIParsesVerbs() throws {
  #expect(try sessionCLICommand(["session", "terminals"]) == .sessionTerminals)
  #expect(
    try sessionCLICommand(["session", "detach", "w1:p2"])
      == .sessionDetach(ManagedTerminalTargetParams(pane: "w1:p2")))
  #expect(
    try sessionCLICommand(["session", "end", "w1:p2"])
      == .sessionEnd(ManagedTerminalTargetParams(pane: "w1:p2")))
  // `--current` 与 agent/pane 命令同义：目标是调用者所在 pane。
  #expect(
    try sessionCLICommand(["session", "detach", "--current"])
      == .sessionDetach(ManagedTerminalTargetParams(pane: "current")))
  // 既有 snapshot 不受影响。
  #expect(try sessionCLICommand(["session", "snapshot"]) == .sessionSnapshot)
}

@Test("三个动词都支持 --json / --format json（前置与后置写法都可）")
func managedSessionCLIAcceptsJSONFormat() throws {
  #expect(try parseSessionCLI(["session", "terminals", "--json"]).format == .json)
  #expect(try parseSessionCLI(["--json", "session", "terminals"]).format == .json)
  #expect(try parseSessionCLI(["session", "detach", "w1:p2", "--json"]).format == .json)
  #expect(try parseSessionCLI(["session", "end", "w1:p2", "--format", "json"]).format == .json)
  // 摘走格式选项后子命令本身不受影响。
  #expect(
    try sessionCLICommand(["session", "end", "w1:p2", "--json"])
      == .sessionEnd(ManagedTerminalTargetParams(pane: "w1:p2")))
  #expect(try parseSessionCLI(["session", "terminals"]).format == .text)
}

@Test("缺参数、多参数与未知子命令都被拒绝")
func managedSessionCLIRejectsBadArguments() throws {
  // detach/end 缺目标：不允许猜一个 pane。
  #expect(throws: AsterCLIArgumentError.self) { try sessionCLICommand(["session", "detach"]) }
  #expect(throws: AsterCLIArgumentError.self) { try sessionCLICommand(["session", "end"]) }
  // 多个目标。
  #expect(throws: AsterCLIArgumentError.self) {
    try sessionCLICommand(["session", "detach", "w1:p1", "w1:p2"])
  }
  // 目标与 --current 同时给出。
  #expect(throws: AsterCLIArgumentError.self) {
    try sessionCLICommand(["session", "end", "w1:p1", "--current"])
  }
  // terminals 不接受参数。
  #expect(throws: AsterCLIArgumentError.self) {
    try sessionCLICommand(["session", "terminals", "w1:p1"])
  }
  // 非法 selector。
  #expect(throws: AsterCLIArgumentError.self) { try sessionCLICommand(["session", "detach", "!!"]) }
  // 未知子命令与未知选项。
  #expect(throws: AsterCLIArgumentError.self) { try sessionCLICommand(["session", "kill", "w1:p1"]) }
  #expect(throws: AsterCLIArgumentError.self) {
    try sessionCLICommand(["session", "detach", "w1:p1", "--force"])
  }
}

@Test("detach/end 需要 ASTER_ENV，只读的 terminals 不需要")
func managedSessionCLIRequiresAsterEnvForWrites() throws {
  #expect(try parseSessionCLI(["session", "detach", "w1:p1"]).requiresAsterEnv)
  #expect(try parseSessionCLI(["session", "end", "w1:p1"]).requiresAsterEnv)
  #expect(!(try parseSessionCLI(["session", "terminals"]).requiresAsterEnv))
  #expect(!(try parseSessionCLI(["session", "snapshot"]).requiresAsterEnv))
}

@Test("方法名与写/等待分类：detach/end 走写门禁，terminals 只读且都不挂起")
func managedSessionCLIMethodClassification() {
  #expect(AsterControlMethod.sessionTerminals.rawValue == "session.terminals")
  #expect(AsterControlMethod.sessionDetach.rawValue == "session.detach")
  #expect(AsterControlMethod.sessionEnd.rawValue == "session.end")
  #expect(AsterControlMethod.sessionDetach.isWrite)
  #expect(AsterControlMethod.sessionEnd.isWrite)
  #expect(!AsterControlMethod.sessionTerminals.isWrite)
  #expect(!AsterControlMethod.sessionDetach.isWait)
  #expect(!AsterControlMethod.sessionEnd.isWait)
  #expect(!AsterControlMethod.sessionTerminals.isWait)
}

@Test("params 校验：非法或空 selector 报 invalid_params，合法 selector 通过")
func managedSessionCLIValidatesTarget() throws {
  #expect(throws: Never.self) { try ManagedTerminalTargetParams(pane: "w1:p3").validate() }
  #expect(throws: Never.self) { try ManagedTerminalTargetParams(pane: "current").validate() }
  for invalid in ["", "!!", String(repeating: "a", count: 200)] {
    do {
      try ManagedTerminalTargetParams(pane: invalid).validate()
      Issue.record("selector \(invalid) 应当被拒绝")
    } catch let error as AsterControlError {
      #expect(error.code == .invalidParams)
    }
  }
}

@Test("session.* 结果结构使用 snake_case 键并保留 detached 状态")
func managedSessionCLIResultEncoding() throws {
  let info = ManagedTerminalInfo(
    paneID: "w1:p2", terminalID: "t-1", serverID: "s-1", sessionID: "sess-1", state: .detached,
    pid: 4242)
  let json = try JSONValue(encoding: ManagedTerminalActionResult(terminal: info, disposition: .detached))
  #expect(json["disposition"]?.stringValue == "detached")
  #expect(json["terminal"]?["pane_id"]?.stringValue == "w1:p2")
  #expect(json["terminal"]?["terminal_id"]?.stringValue == "t-1")
  #expect(json["terminal"]?["server_id"]?.stringValue == "s-1")
  #expect(json["terminal"]?["session_id"]?.stringValue == "sess-1")
  #expect(json["terminal"]?["state"]?.stringValue == "detached")
  #expect(json["terminal"]?["pid"]?.intValue == 4242)
  // 分离与结束必须是两种可区分的状态。
  #expect(ManagedTerminalControlState.allCases.count == 4)
  let list = try JSONValue(encoding: ManagedTerminalListResult(terminals: [info]))
  #expect(try list.decoded(as: ManagedTerminalListResult.self).terminals == [info])
}
