import Foundation
import Testing

@testable import AsterCore

/// 控制协议信封与参数结构的线格式测试。
struct AsterControlProtocolTests {
  private func decodeRequest(_ json: String) throws -> AsterControlRequest {
    try JSONDecoder().decode(AsterControlRequest.self, from: Data(json.utf8))
  }

  private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  @Test("请求信封往返：id 数字 / 字符串 / null / 缺省都原样保留")
  func requestEnvelopeRoundTripsIdentifiers() throws {
    let numeric = try decodeRequest(#"{"id":1,"method":"server.ping","protocol":1}"#)
    #expect(numeric.id == .number(1))
    #expect(numeric.method == "server.ping")
    #expect(numeric.protocolVersion == 1)
    #expect(try numeric.resolvedMethod() == .serverPing)

    let string = try decodeRequest(#"{"id":"abc","method":"agent.list"}"#)
    #expect(string.id == .string("abc"))
    #expect(string.protocolVersion == nil)

    let null = try decodeRequest(#"{"id":null,"method":"agent.list"}"#)
    #expect(null.id == .null)

    let missing = try decodeRequest(#"{"method":"agent.list"}"#)
    #expect(missing.id == nil)

    // 响应侧：数字 id 不能变成 1.0，字符串保持字符串，缺省写 null。
    #expect(
      try encodeJSON(AsterControlResponse(id: .number(1), result: ["ok": true]))
        == #"{"id":1,"result":{"ok":true}}"#)
    #expect(
      try encodeJSON(AsterControlResponse(id: .string("abc"), result: .null))
        == #"{"id":"abc","result":null}"#)
    #expect(
      try encodeJSON(
        AsterControlResponse(
          id: nil, error: AsterControlError(code: .parseError, message: "bad")))
        == #"{"error":{"code":"parse_error","message":"bad"},"id":null}"#)
  }

  @Test("响应信封：error 与 result 互斥；解码端能识别两种形态")
  func responseEnvelopeIsExclusive() throws {
    let okData = try JSONEncoder().encode(
      AsterControlResponse(id: .number(7), encoding: ServerPingResult(version: "1.0", pid: 42)))
    let ok = try JSONDecoder().decode(AsterControlResponse.self, from: okData)
    #expect(ok.error == nil)
    #expect(ok.result?["protocol"]?.intValue == 1)
    #expect(ok.result?["pid"]?.intValue == 42)

    let errorData = Data(#"{"id":7,"error":{"code":"agent_blocked","message":"x"}}"#.utf8)
    let failed = try JSONDecoder().decode(AsterControlResponse.self, from: errorData)
    #expect(failed.error?.code == .agentBlocked)
    #expect(failed.result == nil)
  }

  @Test("未知 method 抛 method_not_found；所有方法 rawValue 可逆")
  func unknownMethodIsRejected() throws {
    let request = try decodeRequest(#"{"id":1,"method":"agent.explode"}"#)
    #expect(throws: AsterControlError(code: .methodNotFound, message: "未知方法: agent.explode")) {
      try request.resolvedMethod()
    }
    for method in AsterControlMethod.allCases {
      #expect(AsterControlMethod(rawValue: method.rawValue) == method)
    }
    #expect(AsterControlMethod.agentPrompt.isWrite)
    #expect(!AsterControlMethod.paneFocus.isWrite)
    #expect(AsterControlMethod.paneSendText.isWrite)
    #expect(!AsterControlMethod.agentRead.isWrite)
    #expect(!AsterControlMethod.serverPing.isWrite)
    #expect(AsterControlMethod.agentWait.isWait)
  }

  @Test("错误码字符串与 herdr 语义一致")
  func errorCodesUseSnakeCase() {
    #expect(AsterControlErrorCode.sensitiveSessionNotAllowed.rawValue == "sensitive_session_not_allowed")
    #expect(AsterControlErrorCode.paneNotTerminal.rawValue == "pane_not_terminal")
    #expect(AsterControlErrorCode.allCases.count == 23)
  }

  @Test("params 解码：snake_case 键、缺省值与 invalid_params 包装")
  func paramsDecodeWithSnakeCaseKeys() throws {
    let request = try decodeRequest(
      #"{"id":1,"method":"agent.prompt","params":{"target":"w1:p2","text":"hi","wait":{"until":["done"],"timeout_ms":500}}}"#
    )
    let params = try request.decodeParams(AgentPromptParams.self)
    #expect(params == AgentPromptParams(target: "w1:p2", text: "hi", wait: .init(until: [.done], timeoutMs: 500)))
    try params.validate()

    let read = try decodeRequest(#"{"method":"agent.read","params":{"target":"builder"}}"#)
    #expect(try read.decodeParams(AgentReadParams.self).source == .visible)

    let missing = try decodeRequest(#"{"method":"agent.read","params":{}}"#)
    #expect(throws: AsterControlError.self) { try missing.decodeParams(AgentReadParams.self) }
    do {
      _ = try missing.decodeParams(AgentReadParams.self)
    } catch let error as AsterControlError {
      #expect(error.code == .invalidParams)
    }

    let start = try decodeRequest(#"{"method":"agent.start","params":{"kind":"codex","timeout_ms":1000}}"#)
    let startParams = try start.decodeParams(AgentStartParams.self)
    #expect(startParams.args.isEmpty)
    #expect(startParams.timeoutMs == 1000)
  }

  @Test("上限校验：lines / text / keys / until / match-regex / notification")
  func validationEnforcesLimits() {
    func code(_ body: () throws -> Void) -> AsterControlErrorCode? {
      do {
        try body()
        return nil
      } catch let error as AsterControlError {
        return error.code
      } catch {
        return .internalError
      }
    }
    #expect(code { try AgentReadParams(target: "w1:p1", lines: 10_000).validate() } == nil)
    #expect(code { try AgentReadParams(target: "w1:p1", lines: 10_001).validate() } == .invalidParams)
    #expect(code { try AgentReadParams(target: "w1:p1", lines: 0).validate() } == .invalidParams)
    #expect(code { try AgentReadParams(target: "Bad Name", lines: 1).validate() } == .invalidParams)

    let big = String(repeating: "x", count: 64 * 1024 + 1)
    #expect(code { try AgentPromptParams(target: "w1:p1", text: big).validate() } == .invalidParams)
    #expect(code { try AgentPromptParams(target: "w1:p1", text: "").validate() } == .invalidParams)
    #expect(code { try PaneSendTextParams(pane: "current", text: "", enter: true).validate() } == nil)

    #expect(code { try AgentSendKeysParams(target: "w1:p1", keys: Array(repeating: "enter", count: 65)).validate() } == .invalidParams)
    #expect(code { try AgentSendKeysParams(target: "w1:p1", keys: ["bogus"]).validate() } == .invalidParams)
    #expect(code { try AgentSendKeysParams(target: "w1:p1", keys: ["C-c", "Enter"]).validate() } == nil)

    #expect(code { try AgentWaitParams(target: "w1:p1", until: [.unknown]).validate() } == .invalidParams)
    #expect(code { try AgentWaitParams(target: "w1:p1", timeoutMs: -1).validate() } == .invalidParams)
    #expect(code { try AgentWaitParams(target: "w1:p1", timeoutMs: 10_000_000).validate() } == nil)
    #expect(AsterControlProtocol.clampedTimeout(10_000_000, default: 1) == 600_000)
    #expect(AsterControlProtocol.clampedTimeout(nil, default: 30_000) == 30_000)

    #expect(code { try PaneWaitForOutputParams(pane: "w1:p1").validate() } == .invalidParams)
    #expect(code { try PaneWaitForOutputParams(pane: "w1:p1", match: "a", regex: "b").validate() } == .invalidParams)
    #expect(code { try PaneWaitForOutputParams(pane: "w1:p1", regex: "[").validate() } == .invalidParams)
    #expect(code { try PaneWaitForOutputParams(pane: "w1:p1", regex: "^\\$ $").validate() } == nil)

    #expect(code { try NotificationShowParams(title: "").validate() } == .invalidParams)
    #expect(code { try NotificationShowParams(title: "t", body: String(repeating: "b", count: 1025)).validate() } == .invalidParams)
    #expect(code { try WorkflowExecuteParams(argv: ["open", "."], cwd: "relative").validate() } == .invalidParams)
    #expect(code { try WorkflowExecuteParams(argv: [], cwd: "/tmp").validate() } == .invalidParams)
    #expect(code { try WorkflowExecuteParams(argv: ["open"], cwd: "/tmp", stdinBase64: "!!").validate() } == .invalidParams)
    #expect(code { try AgentStartParams(kind: "", name: nil).validate() } == .invalidParams)
    #expect(code { try AgentStartParams(kind: "codex", name: "Bad").validate() } == .invalidParams)
  }

  @Test("结果与事件按 snake_case 编码")
  func resultsAndEventsEncodeSnakeCase() throws {
    let info = AgentInfo(
      paneID: "w1:p3", tabID: "w1:t1", windowID: "w1", name: "builder", agent: "claudeCode",
      agentStatus: .working, detection: .hook, sessionID: "s", focused: false, stateChangeSeq: 9)
    let json = try encodeJSON(info)
    #expect(json.contains(#""pane_id":"w1:p3""#))
    #expect(json.contains(#""agent_status":"working""#))
    #expect(json.contains(#""state_change_seq":9"#))
    #expect(json.contains(#""session_id":"s""#))
    let decoded = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
    #expect(decoded == info)

    let event = try AsterControlEvent(
      sequence: 3, event: .paneAgentStatusChanged,
      encoding: AsterControlEvent.AgentStatusChange(
        paneID: "w1:p3", previous: .working, status: .done, detection: .screen, stateChangeSeq: 10))
    let eventJSON = try encodeJSON(event)
    #expect(eventJSON.hasPrefix(#"{"data":{"detection":"screen","pane_id":"w1:p3","previous":"working""#))
    #expect(eventJSON.contains(#""event":"pane.agent_status_changed""#))
    #expect(eventJSON.contains(#""sequence":3"#))

    let snapshot = SessionSnapshot(
      windows: [
        .init(
          windowID: "w1", focused: true,
          tabs: [
            .init(
              tabID: "w1:t1", focused: true,
              panes: [
                PaneInfo(paneID: "w1:p1", tabID: "w1:t1", windowID: "w1", kind: .terminal, focused: true, running: true)
              ])
          ])
      ], sequence: 0)
    let snapshotJSON = try encodeJSON(snapshot)
    #expect(snapshotJSON.contains(#""window_id":"w1""#))
    #expect(snapshotJSON.contains(#""tab_id":"w1:t1""#))
    #expect(try encodeJSON(WorkflowExecuteResult(stdout: "", stderr: "", exitCode: 0)).contains(#""exit_code":0"#))
    #expect(try encodeJSON(ServerPingResult(version: "1", pid: 1)).contains(#""protocol":1"#))
  }

  @Test("JSONValue 字面量与整数编码")
  func jsonValueLiteralsAndIntegers() throws {
    let value: JSONValue = ["a": 1, "b": [true, nil, "s"], "c": 1.5]
    #expect(value["a"]?.intValue == 1)
    #expect(value["b"]?.arrayValue?.count == 3)
    let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    #expect(json.contains(#""a":1"#))
    #expect(json.contains("1.5"))
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) == value)
  }

  @Test("默认 socket 路径：覆盖、常规、超长 home 回退 TMPDIR")
  func defaultSocketPath() {
    #expect(AsterControlProtocol.defaultSocketPath(environment: ["ASTER_CONTROL_SOCKET_PATH": "/tmp/x.sock"], homeDirectory: "/Users/a") == "/tmp/x.sock")
    #expect(AsterControlProtocol.defaultSocketPath(environment: ["ASTER_CONTROL_SOCKET_PATH": "relative"], homeDirectory: "/Users/a")
      == "/Users/a/Library/Application Support/Aster/Control/aster.sock")
    let longHome = "/Users/" + String(repeating: "n", count: 80)
    #expect(AsterControlProtocol.defaultSocketPath(environment: ["TMPDIR": "/tmp/t"], homeDirectory: longHome) == "/tmp/t/aster-control.sock")
    #expect(AsterControlProtocol.defaultSocketPath(environment: [:], homeDirectory: "/Users/a").utf8.count <= AsterControlProtocol.maximumSocketPathBytes)
    #expect(AsterControlSocketLocation.defaultPath(environment: [:], home: longHome, tmpdir: "/tmp/x") == "/tmp/x/aster-control.sock")
    #expect(AsterControlSocketLocation.defaultPath(environment: ["ASTER_CONTROL_SOCKET_PATH": "/s.sock"], home: "/h") == "/s.sock")
  }

  @Test("标题归一化：剥掉 spinner / 盲文前缀，其它保持原样")
  func titleNormalizer() {
    #expect(AsterControlTitleNormalizer.stripped("✳ Claude Code") == "Claude Code")
    #expect(AsterControlTitleNormalizer.stripped("⠋  Thinking") == "Thinking")
    #expect(AsterControlTitleNormalizer.stripped("◐") == "")
    #expect(AsterControlTitleNormalizer.stripped("✳Claude") == "✳Claude")
    #expect(AsterControlTitleNormalizer.stripped("zsh") == "zsh")
    #expect(AsterControlTitleNormalizer.stripped("") == "")
  }
}
