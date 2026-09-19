import Foundation
import Testing

@testable import AsterCore

/// 远端 Agent 状态类型的单元测试（P5）。
@Suite("RemoteAgentState")
struct RemoteAgentStateTests {

  // MARK: - RemoteAgentInfo JSON 解码

  @Test("从标准 JSON 解码 RemoteAgentInfo")
  func decodeAgentInfoFromJSON() throws {
    let json = """
      {
        "terminalID": "t-001",
        "provider": "claudeCode",
        "state": "working",
        "name": "my-session",
        "nativeSession": "sess-abc123",
        "source": "hook",
        "unread": true
      }
      """
    let data = Data(json.utf8)
    let info = try JSONDecoder().decode(RemoteAgentInfo.self, from: data)
    #expect(info.terminalID == "t-001")
    #expect(info.provider == .claudeCode)
    #expect(info.state == .working)
    #expect(info.name == "my-session")
    #expect(info.nativeSession == "sess-abc123")
    #expect(info.source == .hook)
    #expect(info.unread == true)
  }

  @Test("从最小 JSON 解码 RemoteAgentInfo（可选字段缺失）")
  func decodeAgentInfoMinimalJSON() throws {
    let json = """
      {
        "terminalID": "t-002",
        "provider": "codex",
        "state": "idle",
        "source": "heuristic",
        "unread": false
      }
      """
    let data = Data(json.utf8)
    let info = try JSONDecoder().decode(RemoteAgentInfo.self, from: data)
    #expect(info.terminalID == "t-002")
    #expect(info.provider == .codex)
    #expect(info.state == .idle)
    #expect(info.name == nil)
    #expect(info.nativeSession == nil)
    #expect(info.source == .heuristic)
    #expect(info.unread == false)
  }

  @Test("RemoteAgentInfo 编码后可往返解码")
  func agentInfoRoundTrip() throws {
    let original = RemoteAgentInfo(
      terminalID: "t-003",
      provider: .openCode,
      state: .blocked,
      name: "test",
      nativeSession: "s-xyz",
      source: .screen,
      unread: true
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RemoteAgentInfo.self, from: data)
    #expect(decoded == original)
  }

  // MARK: - RemoteAgentStateAggregator 优先级排序

  @Test("聚合结果按 blocked > working > done(unread) > done > idle > unknown 排序")
  func aggregatorPriorityOrdering() {
    let aggregator = RemoteAgentStateAggregator()
    let machineID = UUID()
    let agents: [RemoteAgentInfo] = [
      RemoteAgentInfo(terminalID: "t-idle", provider: .claudeCode, state: .idle),
      RemoteAgentInfo(terminalID: "t-unknown", provider: .codex, state: .unknown),
      RemoteAgentInfo(
        terminalID: "t-done-unread", provider: .openCode, state: .done, unread: true),
      RemoteAgentInfo(terminalID: "t-working", provider: .pi, state: .working),
      RemoteAgentInfo(terminalID: "t-blocked", provider: .omp, state: .blocked),
      RemoteAgentInfo(terminalID: "t-done", provider: .cursorCLI, state: .done, unread: false),
    ]
    let summaries = aggregator.aggregate(machineID: machineID, agents: agents)
    let ids = summaries.map(\.agent.terminalID)
    #expect(ids == ["t-blocked", "t-working", "t-done-unread", "t-done", "t-idle", "t-unknown"])
  }

  @Test("多台机器的 Agent 按统一优先级排序")
  func aggregatorCrossMachineOrdering() {
    let aggregator = RemoteAgentStateAggregator()
    let machine1 = UUID()
    let machine2 = UUID()
    _ = aggregator.aggregate(machineID: machine1, agents: [
      RemoteAgentInfo(terminalID: "m1-idle", provider: .claudeCode, state: .idle)
    ])
    let summaries = aggregator.aggregate(machineID: machine2, agents: [
      RemoteAgentInfo(terminalID: "m2-blocked", provider: .codex, state: .blocked)
    ])
    // blocked 排在 idle 前面
    #expect(summaries.first?.agent.terminalID == "m2-blocked")
    #expect(summaries.last?.agent.terminalID == "m1-idle")
  }

  // MARK: - RemoteAgentStateAggregator 去重

  @Test("相同事件 key 第二次记录返回 true（已见过）")
  func aggregatorEventDedup() {
    let aggregator = RemoteAgentStateAggregator()
    let key = RemoteAgentEventKey(serverID: "s1", epoch: "e1", eventID: "ev1")
    // 第一次：未见过
    #expect(aggregator.checkAndRecordEvent(key) == false)
    // 第二次：已见过
    #expect(aggregator.checkAndRecordEvent(key) == true)
  }

  @Test("不同事件 key 互不影响")
  func aggregatorDifferentEventsIndependent() {
    let aggregator = RemoteAgentStateAggregator()
    let key1 = RemoteAgentEventKey(serverID: "s1", epoch: "e1", eventID: "ev1")
    let key2 = RemoteAgentEventKey(serverID: "s1", epoch: "e1", eventID: "ev2")
    #expect(aggregator.checkAndRecordEvent(key1) == false)
    #expect(aggregator.checkAndRecordEvent(key2) == false)
  }

  // MARK: - RemoteAgentStateAggregator markRead / staleAll

  @Test("markRead 将指定终端的 unread 标记清除")
  func aggregatorMarkRead() {
    let aggregator = RemoteAgentStateAggregator()
    let machineID = UUID()
    _ = aggregator.aggregate(machineID: machineID, agents: [
      RemoteAgentInfo(terminalID: "t1", provider: .claudeCode, state: .done, unread: true)
    ])
    aggregator.markRead(machineID: machineID, terminalID: "t1")
    _ = aggregator.aggregate(machineID: machineID, agents: [
      RemoteAgentInfo(terminalID: "t1", provider: .claudeCode, state: .done, unread: true)
    ])
    // aggregate 用新数据覆盖，所以这里重新测试 markRead 效果
    aggregator.markRead(machineID: machineID, terminalID: "t1")
    // 直接验证：再聚合一次（不传新数据），用已有状态
    let afterMark = aggregator.aggregate(machineID: UUID(), agents: [])
    // 原 machine 的 t1 应该已 markRead
    let t1 = afterMark.first(where: { $0.agent.terminalID == "t1" })
    #expect(t1?.agent.unread == false)
  }

  @Test("staleAllForMachine 将该机器所有 Agent 标记为 unknown")
  func aggregatorStaleAll() {
    let aggregator = RemoteAgentStateAggregator()
    let machineID = UUID()
    _ = aggregator.aggregate(machineID: machineID, agents: [
      RemoteAgentInfo(terminalID: "t1", provider: .claudeCode, state: .working),
      RemoteAgentInfo(terminalID: "t2", provider: .codex, state: .blocked),
    ])
    aggregator.staleAllForMachine(machineID: machineID)
    // 聚合后验证状态
    let summaries = aggregator.aggregate(machineID: UUID(), agents: [])
    let machineAgents = summaries.filter { $0.machineID == machineID }
    for summary in machineAgents {
      #expect(summary.agent.state == .unknown)
    }
  }

  // MARK: - RemoteAgentSessionReference 校验

  @Test("合法的 nativeSession 引用通过校验")
  func validateValidSessionReference() {
    let result = RemoteAgentSessionReference.validate(
      provider: .claudeCode,
      nativeSession: "session-abc-123",
      machineID: UUID()
    )
    #expect(result == true)
  }

  @Test("空 nativeSession 不通过校验")
  func validateEmptySessionReference() {
    let result = RemoteAgentSessionReference.validate(
      provider: .claudeCode,
      nativeSession: "",
      machineID: UUID()
    )
    #expect(result == false)
  }

  @Test("含空字节的 nativeSession 不通过校验")
  func validateNullByteSessionReference() {
    let result = RemoteAgentSessionReference.validate(
      provider: .claudeCode,
      nativeSession: "sess\0ion",
      machineID: UUID()
    )
    #expect(result == false)
  }

  @Test("不支持 resumeSession 的 provider 不通过校验")
  func validateProviderWithoutResume() {
    // gemini 没有 resumeSession 能力
    let result = RemoteAgentSessionReference.validate(
      provider: .gemini,
      nativeSession: "valid-session",
      machineID: UUID()
    )
    #expect(result == false)
  }

  @Test("超长 nativeSession 不通过校验")
  func validateTooLongSessionReference() {
    let longSession = String(repeating: "a", count: 600)
    let result = RemoteAgentSessionReference.validate(
      provider: .claudeCode,
      nativeSession: longSession,
      machineID: UUID()
    )
    #expect(result == false)
  }

  @Test("含非法字符的 nativeSession 不通过校验")
  func validateIllegalCharactersSessionReference() {
    let result = RemoteAgentSessionReference.validate(
      provider: .claudeCode,
      nativeSession: "session;rm -rf /",
      machineID: UUID()
    )
    #expect(result == false)
  }

  @Test("Store 校验并存储后可查找")
  func storeValidateAndLookup() {
    let store = RemoteAgentSessionReference.Store()
    let machineID = UUID()
    let ok = store.validateAndStore(
      provider: .claudeCode,
      nativeSession: "sess-001",
      machineID: machineID
    )
    #expect(ok == true)
    let ref = store.lookup(provider: .claudeCode, nativeSession: "sess-001", machineID: machineID)
    #expect(ref != nil)
    #expect(ref?.nativeSession == "sess-001")
  }

  @Test("Store removeAll 清除指定机器的引用")
  func storeRemoveAll() {
    let store = RemoteAgentSessionReference.Store()
    let machineID = UUID()
    _ = store.validateAndStore(
      provider: .claudeCode, nativeSession: "sess-001", machineID: machineID)
    store.removeAll(machineID: machineID)
    let ref = store.lookup(provider: .claudeCode, nativeSession: "sess-001", machineID: machineID)
    #expect(ref == nil)
  }

  // MARK: - RemoteAgentStateAuthority

  @Test("hook 覆盖完整生命周期的 provider 解析为 hook 权威")
  func authorityResolveHook() {
    // kimiCode 的 hook 覆盖完整生命周期（fullLifecycleHooks），hook 单独裁决状态
    #expect(RemoteAgentStateAuthority.resolve(for: .kimiCode) == .hook)
  }

  @Test("hook 只覆盖部分事件且有屏幕清单的 provider 以屏幕为权威")
  func authorityResolvePartialHookPrefersScreen() {
    // Claude Code / Grok Build 的 hook 没有完整生命周期：等待批准与回到空闲只能从屏幕看出，
    // 与本地 syncAgentScreenMonitor 的规则一致
    #expect(RemoteAgentStateAuthority.resolve(for: .claudeCode) == .screen)
    #expect(RemoteAgentStateAuthority.resolve(for: .grokBuild) == .screen)
  }

  @Test("只有屏幕检测的 provider 解析为 screen 权威")
  func authorityResolveScreen() {
    // gemini 没有 managedIntegration 但有 detectionManifestID
    let authority = RemoteAgentStateAuthority.resolve(for: .gemini)
    #expect(authority == .screen)
  }

  @Test("omp 有 hook 集成但无屏幕检测，解析为 hook 权威")
  func authorityResolveOmpHook() {
    // omp 有 managedIntegration（installationStep != nil）但 detectionManifestID == nil
    let authority = RemoteAgentStateAuthority.resolve(for: .omp)
    #expect(authority == .hook)
  }

  // MARK: - ManagedSessionCommand Agent 参数形状

  @Test("agentList 生成正确的命令参数")
  func agentListCommand() {
    let endpoint = ManagedSessionEndpoint(
      binaryPath: "/usr/bin/aster-session",
      stateParentPath: "/tmp/state",
      sessionName: "default"
    )
    let args = ManagedSessionCommand.agentList(endpoint)
    #expect(args == ["agent", "list", "/tmp/state", "default"])
  }

  @Test("agentExplain 生成正确的命令参数")
  func agentExplainCommand() {
    let endpoint = ManagedSessionEndpoint(
      binaryPath: "/usr/bin/aster-session",
      stateParentPath: "/tmp/state",
      sessionName: "default"
    )
    let args = ManagedSessionCommand.agentExplain(endpoint, terminalID: "t-001")
    #expect(args == ["agent", "explain", "/tmp/state", "default", "t-001"])
  }
}
