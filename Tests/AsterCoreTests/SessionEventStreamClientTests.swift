import Foundation
import Testing

@testable import AsterCore

/// P4.2 事件流客户端的定向单测。
///
/// 这里刻意不启动任何真实服务：行来源被抽象成可注入的 `SessionEventLineSource`，
/// 因此行解码、序号缺口、身份不符、未知事件与连接结束这些分支都能被确定性地覆盖。
/// 真实服务 + 真实订阅进程的证据在 `SessionRuntime/tests/event_stream.py`，
/// 真实两客户端一致性的证据在 `Tests/AsterTests/RemoteWorkP4MachineAppTests.swift`。

private let sampleServerID = "11111111-1111-4111-8111-111111111111"
private let sampleEpoch = "22222222-2222-4222-8222-222222222222"
private let sampleSessionID = "33333333-3333-4333-8333-333333333333"

private func sampleTarget(epoch: String = sampleEpoch) -> RemoteSessionEventTarget {
  RemoteSessionEventTarget(
    serverID: sampleServerID, serverEpoch: epoch, sessionID: sampleSessionID)
}

/// 生成一行与 `protocol/events.schema.json` 同形的事件信封。
private func eventLine(
  _ name: String,
  sequence: UInt64,
  revision: UInt64,
  epoch: String = sampleEpoch,
  body: [String: Any] = ["workspaceID": "44444444-4444-4444-8444-444444444444"]
) -> Data {
  let envelope: [String: Any] = [
    "type": "event",
    "event": name,
    "eventID": "55555555-5555-4555-8555-555555555555",
    "target": [
      "serverID": sampleServerID, "serverEpoch": epoch, "sessionID": sampleSessionID,
    ],
    "sequence": sequence,
    "revision": revision,
    "body": body,
  ]
  return try! JSONSerialization.data(withJSONObject: envelope)
}

private func handshakeLine(revision: UInt64, epoch: String = sampleEpoch) -> Data {
  let envelope: [String: Any] = [
    "type": "subscribed",
    "protocolMajor": 1,
    "protocolMinor": 0,
    "serverID": sampleServerID,
    "serverEpoch": epoch,
    "sessionID": sampleSessionID,
    "revision": revision,
  ]
  return try! JSONSerialization.data(withJSONObject: envelope)
}

/// 受控行来源：测试自己决定什么时候交付哪一行、什么时候结束。
private final class ScriptedLineSource: SessionEventLineSource, @unchecked Sendable {
  private let lock = NSLock()
  private var line: (@Sendable (Data) -> Void)?
  private var finish: (@Sendable (RemoteSessionStreamTermination) -> Void)?
  private(set) var stopCount = 0
  var launchError: (any Error)?

  func start(
    onLine: @escaping @Sendable (Data) -> Void,
    onFinish: @escaping @Sendable (RemoteSessionStreamTermination) -> Void
  ) throws {
    if let launchError { throw launchError }
    lock.lock()
    line = onLine
    finish = onFinish
    lock.unlock()
  }

  func stop() {
    lock.lock()
    stopCount += 1
    lock.unlock()
  }

  func emit(_ data: Data) {
    lock.lock()
    let handler = line
    lock.unlock()
    handler?(data)
  }

  func end(_ termination: RemoteSessionStreamTermination) {
    lock.lock()
    let handler = finish
    lock.unlock()
    handler?(termination)
  }
}

private struct ScriptedLaunchFailure: Error {}

/// 收集回调结果的记录器。
private final class StreamRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var subscriptions: [RemoteSessionSubscription] = []
  private(set) var events: [RemoteSessionEvent] = []
  private(set) var faults: [RemoteSessionStreamFault] = []
  private(set) var terminations: [RemoteSessionStreamTermination] = []

  var callbacks: SessionEventStreamClient.Callbacks {
    SessionEventStreamClient.Callbacks(
      onSubscribed: { value in
        self.lock.lock()
        self.subscriptions.append(value)
        self.lock.unlock()
      },
      onEvent: { value in
        self.lock.lock()
        self.events.append(value)
        self.lock.unlock()
      },
      onResynchronize: { value in
        self.lock.lock()
        self.faults.append(value)
        self.lock.unlock()
      },
      onConnectionLost: { value in
        self.lock.lock()
        self.terminations.append(value)
        self.lock.unlock()
      })
  }
}

@Test func sessionEventStreamDecodesHandshakeThenOrderedEvents() {
  var decoder = SessionEventStreamDecoder(expected: sampleTarget())
  #expect(decoder.consume(line: handshakeLine(revision: 7)) == .subscribed(
    RemoteSessionSubscription(target: sampleTarget(), revision: 7)))
  #expect(decoder.sequence == 0)

  guard case .event(let created) = decoder.consume(
    line: eventLine("terminal.created", sequence: 1, revision: 8))
  else {
    Issue.record("第一条事件必须被投递")
    return
  }
  #expect(created.kind == .terminalCreated)
  #expect(created.sequence == 1)
  #expect(created.revision == 8)
  #expect(created.target == sampleTarget())

  guard case .event(let changed) = decoder.consume(
    line: eventLine("workspace.changed", sequence: 2, revision: 8))
  else {
    Issue.record("第二条事件必须被投递")
    return
  }
  #expect(changed.kind == .workspaceChanged)
  #expect(changed.decodedBody()?["workspaceID"] as? String == "44444444-4444-4444-8444-444444444444")
  #expect(decoder.sequence == 2)
  #expect(decoder.revision == 8)
}

@Test func sessionEventStreamCoversEveryBroadcastEventKind() {
  var decoder = SessionEventStreamDecoder()
  _ = decoder.consume(line: handshakeLine(revision: 0))
  let names = [
    "workspace.changed", "tab.changed", "pane.changed",
    "terminal.created", "terminal.updated", "terminal.exited",
  ]
  let expected: [RemoteSessionEventKind] = [
    .workspaceChanged, .tabChanged, .paneChanged,
    .terminalCreated, .terminalUpdated, .terminalExited,
  ]
  for (index, name) in names.enumerated() {
    let outcome = decoder.consume(
      line: eventLine(name, sequence: UInt64(index + 1), revision: UInt64(index)))
    guard case .event(let event) = outcome else {
      Issue.record("\(name) 必须被识别为已知事件")
      continue
    }
    #expect(event.kind == expected[index])
    #expect(event.kind.rawValue == name)
    #expect(!event.kind.isUnknown)
  }
}

@Test func sessionEventStreamReportsSequenceGapWithoutMarkingCacheFresh() {
  var decoder = SessionEventStreamDecoder(expected: sampleTarget())
  _ = decoder.consume(line: handshakeLine(revision: 1))
  _ = decoder.consume(line: eventLine("tab.changed", sequence: 1, revision: 2))
  let outcome = decoder.consume(line: eventLine("tab.changed", sequence: 4, revision: 5))
  #expect(outcome == .resynchronize(.sequenceGap(expected: 2, received: 4)))
  // 缺口不推进游标：带缺口的缓存绝不能被当成最新。
  #expect(decoder.sequence == 1)
  #expect(decoder.revision == 2)
}

@Test func sessionEventStreamRejectsRevisionRewind() {
  var decoder = SessionEventStreamDecoder(expected: sampleTarget())
  _ = decoder.consume(line: handshakeLine(revision: 0))
  _ = decoder.consume(line: eventLine("tab.changed", sequence: 1, revision: 9))
  let outcome = decoder.consume(line: eventLine("tab.changed", sequence: 2, revision: 8))
  #expect(outcome == .resynchronize(.revisionRewind(current: 9, received: 8)))
}

@Test func sessionEventStreamRejectsForeignTargetWithoutDelivering() {
  let foreign = "99999999-9999-4999-8999-999999999999"
  var decoder = SessionEventStreamDecoder(expected: sampleTarget())
  // 换 epoch 的握手先被拦下：服务实例已经不是当初握手的那一个。
  #expect(
    decoder.consume(line: handshakeLine(revision: 3, epoch: foreign))
      == .resynchronize(.staleTarget(sampleTarget(epoch: foreign))))

  var accepted = SessionEventStreamDecoder(expected: sampleTarget())
  _ = accepted.consume(line: handshakeLine(revision: 3))
  let outcome = accepted.consume(
    line: eventLine("pane.changed", sequence: 1, revision: 4, epoch: foreign))
  #expect(outcome == .resynchronize(.staleTarget(sampleTarget(epoch: foreign))))
  #expect(accepted.sequence == 0)
}

@Test func sessionEventStreamTreatsUnknownEventAsResynchronization() {
  var decoder = SessionEventStreamDecoder(expected: sampleTarget())
  _ = decoder.consume(line: handshakeLine(revision: 0))
  // 使用一个真正未知的事件类型（agent.changed 已在 P5 加入已知枚举）
  let outcome = decoder.consume(line: eventLine("upload.progress", sequence: 1, revision: 1))
  #expect(outcome == .resynchronize(.unknownEvent("upload.progress")))
  // 序号确实被这条事件占用了，所以游标推进；但它不算已应用的业务变更。
  #expect(decoder.sequence == 1)
  #expect(RemoteSessionEventKind(rawValue: "upload.progress").isUnknown)
}

@Test func sessionEventStreamRejectsMalformedAndEventsBeforeHandshake() {
  var decoder = SessionEventStreamDecoder(expected: sampleTarget())
  #expect(decoder.consume(line: Data("not json".utf8)) == .resynchronize(.malformedLine("not json")))
  // 握手之前的事件没有可信基线，只能要求重新同步。
  guard case .resynchronize = decoder.consume(
    line: eventLine("tab.changed", sequence: 1, revision: 1))
  else {
    Issue.record("握手之前不得投递事件")
    return
  }
  #expect(decoder.sequence == 0)
}

@Test func sessionEventStreamClientForwardsOutcomesAndReportsConnectionEnd() {
  let source = ScriptedLineSource()
  let recorder = StreamRecorder()
  let client = SessionEventStreamClient(
    source: source, expectedTarget: sampleTarget(), callbacks: recorder.callbacks)
  client.start()
  source.emit(handshakeLine(revision: 2))
  source.emit(eventLine("terminal.created", sequence: 1, revision: 3))
  source.emit(eventLine("tab.changed", sequence: 3, revision: 4))
  #expect(recorder.subscriptions.map(\.revision) == [2])
  #expect(recorder.events.map(\.sequence) == [1])
  #expect(recorder.faults == [.sequenceGap(expected: 2, received: 3)])

  source.end(.processExited(status: 1, diagnostics: "ServiceDisconnected"))
  #expect(recorder.terminations == [.processExited(status: 1, diagnostics: "ServiceDisconnected")])
  // 结束只上报一次，之后的行不再投递。
  source.emit(eventLine("tab.changed", sequence: 2, revision: 5))
  source.end(.stopped)
  #expect(recorder.terminations.count == 1)
  #expect(recorder.events.count == 1)
}

@Test func sessionEventStreamClientStopIsIdempotentAndReportsStopped() {
  let source = ScriptedLineSource()
  let recorder = StreamRecorder()
  let client = SessionEventStreamClient(
    source: source, expectedTarget: nil, callbacks: recorder.callbacks)
  client.start()
  client.stop()
  client.stop()
  #expect(source.stopCount == 1)
  #expect(recorder.terminations == [.stopped])
}

@Test func sessionEventStreamClientReportsLaunchFailureAsConnectionLoss() {
  let source = ScriptedLineSource()
  source.launchError = ScriptedLaunchFailure()
  let recorder = StreamRecorder()
  let client = SessionEventStreamClient(
    source: source, expectedTarget: nil, callbacks: recorder.callbacks)
  client.start()
  #expect(recorder.terminations.count == 1)
  guard case .launchFailed = recorder.terminations.first else {
    Issue.record("启动失败必须走连接结束回调")
    return
  }
}

@Test func sessionEventSubscribeArgvIsSharedByBothTransports() throws {
  let endpoint = ManagedSessionEndpoint(
    binaryPath: "/opt/aster/aster-session", stateParentPath: "/var/state", sessionName: "work1")
  #expect(
    ManagedSessionCommand.eventSubscribe(endpoint) == [
      "event", "subscribe", "/var/state", "work1",
    ])

  let local = LocalManagedSessionClient()
  let localInvocation = local.eventSubscribeInvocation(endpoint)
  #expect(localInvocation.executablePath == "/opt/aster/aster-session")
  #expect(localInvocation.arguments == ManagedSessionCommand.eventSubscribe(endpoint))

  let target = try RemoteSSHTarget.parse("root@ubuntu@orb")
  let remote = RemoteManagedSessionClient(
    transport: RemoteSessionTransport(target: target), runner: RemoteSSHProcessRunner())
  let remoteInvocation = remote.eventSubscribeInvocation(endpoint)
  #expect(remoteInvocation.executablePath == RemoteSSHInvocation.executablePath)
  // 远端转发必须仍然是同一份 argv，且不能分配 TTY。
  #expect(!remoteInvocation.arguments.contains("-tt"))
  let remoteCommand = try #require(remoteInvocation.arguments.last)
  #expect(remoteCommand.contains("event"))
  #expect(remoteCommand.contains("subscribe"))
  #expect(remoteCommand.contains("/var/state"))
  #expect(remoteCommand.contains("work1"))
  #expect(remoteCommand.contains("/opt/aster/aster-session"))
}

@Test func sessionEventStreamProcessSourceReadsRealChildProcessLines() async throws {
  // 真实子进程：证明进程实现确实按行增量交付，而不是等进程退出再一次性给。
  let script = """
    printf '{"type":"subscribed","serverID":"\(sampleServerID)","serverEpoch":"\(sampleEpoch)",\
    "sessionID":"\(sampleSessionID)","revision":5}\\n'
    printf '{"type":"event","event":"tab.changed","eventID":"55555555-5555-4555-8555-555555555555",\
    "target":{"serverID":"\(sampleServerID)","serverEpoch":"\(sampleEpoch)","sessionID":"\(sampleSessionID)"},\
    "sequence":1,"revision":6,"body":{"tabID":"66666666-6666-4666-8666-666666666666"}}\\n'
    exit 3
    """
  let source = ProcessSessionEventLineSource(
    invocation: ManagedSessionInvocation(
      executablePath: "/bin/sh", arguments: ["-c", script]))
  let recorder = StreamRecorder()
  let client = SessionEventStreamClient(
    source: source, expectedTarget: sampleTarget(), callbacks: recorder.callbacks)
  client.start()
  let deadline = Date().addingTimeInterval(20)
  while recorder.terminations.isEmpty && Date() < deadline {
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  #expect(recorder.subscriptions.map(\.revision) == [5])
  #expect(recorder.events.map(\.kind) == [.tabChanged])
  #expect(recorder.terminations == [.processExited(status: 3, diagnostics: "")])
}
