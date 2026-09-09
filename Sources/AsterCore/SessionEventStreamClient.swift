import Darwin
import Foundation

/// P4.2 客户端半边：命名会话的事件流。
///
/// 依据 `SessionRuntime/protocol/contract.md`：事件带独立 `eventID`、`target`、
/// `sequence` 和 `revision`；sequence 属于**当前连接**且连续，revision 不得回退，
/// 连接代次改变或序列失配时必须重新取快照，未知事件不能被当成已应用的业务变更。
///
/// 传输面复用受管会话的既有形状：argv 由 `ManagedSessionCommand.eventSubscribe`
/// 集中生成，本机直接执行二进制，远端由 `RemoteManagedSessionClient` 经 SSH 转发，
/// 两条传输不各自拼参数。解析逻辑全部放在 `SessionEventStreamDecoder` 这个纯值类型里，
/// 所以行解码、序号缺口、身份校验都能在不启动任何进程的情况下单测。

/// 事件信封里的目标身份。三项必须与预期完全一致，否则事件属于另一个服务实例。
public struct RemoteSessionEventTarget: Equatable, Sendable {
  public var serverID: String
  public var serverEpoch: String
  public var sessionID: String

  public init(serverID: String, serverEpoch: String, sessionID: String) {
    self.serverID = serverID
    self.serverEpoch = serverEpoch
    self.sessionID = sessionID
  }
}

/// 事件种类。未知类型保留原名，**不丢弃**：丢弃会让客户端以为自己是最新的。
public enum RemoteSessionEventKind: Equatable, Sendable {
  case workspaceChanged
  case tabChanged
  case paneChanged
  case terminalCreated
  case terminalUpdated
  case terminalExited
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue {
    case "workspace.changed": self = .workspaceChanged
    case "tab.changed": self = .tabChanged
    case "pane.changed": self = .paneChanged
    case "terminal.created": self = .terminalCreated
    case "terminal.updated": self = .terminalUpdated
    case "terminal.exited": self = .terminalExited
    default: self = .unknown(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .workspaceChanged: return "workspace.changed"
    case .tabChanged: return "tab.changed"
    case .paneChanged: return "pane.changed"
    case .terminalCreated: return "terminal.created"
    case .terminalUpdated: return "terminal.updated"
    case .terminalExited: return "terminal.exited"
    case .unknown(let name): return name
    }
  }

  /// 未知事件必须触发重新取快照，而不是被当成已应用的业务变更。
  public var isUnknown: Bool {
    if case .unknown = self { return true }
    return false
  }
}

/// 一条已校验的事件。`body` 保存事件体的 JSON 字节，方便跨线程传递并保持 `Sendable`。
public struct RemoteSessionEvent: Equatable, Sendable {
  public var kind: RemoteSessionEventKind
  public var eventID: String
  public var target: RemoteSessionEventTarget
  public var sequence: UInt64
  public var revision: UInt64
  public var body: Data

  public init(
    kind: RemoteSessionEventKind,
    eventID: String,
    target: RemoteSessionEventTarget,
    sequence: UInt64,
    revision: UInt64,
    body: Data
  ) {
    self.kind = kind
    self.eventID = eventID
    self.target = target
    self.sequence = sequence
    self.revision = revision
    self.body = body
  }

  /// 事件体的动态解码。调用方只在需要读字段时才付出解析成本。
  public func decodedBody() -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: body) as? [String: Any]
  }
}

/// 订阅进程的首行握手。带基线 revision，客户端据此判断自己是否已经落后。
public struct RemoteSessionSubscription: Equatable, Sendable {
  public var target: RemoteSessionEventTarget
  public var revision: UInt64

  public init(target: RemoteSessionEventTarget, revision: UInt64) {
    self.target = target
    self.revision = revision
  }
}

/// 需要重新取快照的原因。每一种都意味着本地缓存**不能**被标成最新。
public enum RemoteSessionStreamFault: Equatable, Sendable {
  /// 序号出现缺口：期望 `expected`，实际收到 `received`。
  case sequenceGap(expected: UInt64, received: UInt64)
  /// 事件身份与预期的服务实例不符（多半是对端换了 epoch）。
  case staleTarget(RemoteSessionEventTarget)
  /// revision 回退，服务端状态与本地推断已经不可调和。
  case revisionRewind(current: UInt64, received: UInt64)
  /// 收到未知事件类型，无法确定影响面。
  case unknownEvent(String)
  /// 行本身不是合法的事件信封。
  case malformedLine(String)
}

/// 订阅结束的原因。任何一种都要求上层执行 `connectionLost` 语义。
public enum RemoteSessionStreamTermination: Equatable, Sendable {
  /// 调用方主动停止。
  case stopped
  /// 订阅进程退出（含被对端断开）。
  case processExited(status: Int32, diagnostics: String)
  /// 无法启动订阅进程。
  case launchFailed(String)
}

/// 解码器的一次输出。
public enum RemoteSessionStreamOutcome: Equatable, Sendable {
  case subscribed(RemoteSessionSubscription)
  case event(RemoteSessionEvent)
  case resynchronize(RemoteSessionStreamFault)
}

/// 事件流的纯值解码状态机。
///
/// 有意不做任何 I/O：喂给它一行字节就得到一个结论，所以序号缺口、身份不符、
/// 未知事件这些分支可以被确定性地单测，不需要真实服务。
public struct SessionEventStreamDecoder: Sendable {
  /// 期望的目标身份。nil 表示以首行握手为准（首次订阅还不知道 epoch）。
  private var expected: RemoteSessionEventTarget?
  private var lastSequence: UInt64 = 0
  private var lastRevision: UInt64 = 0
  private var handshakeSeen = false

  public init(expected: RemoteSessionEventTarget? = nil) {
    self.expected = expected
  }

  /// 已确认的目标身份；握手之前为 nil。
  public var target: RemoteSessionEventTarget? { expected }
  /// 当前已投递到的序号。
  public var sequence: UInt64 { lastSequence }
  /// 当前已知的 revision。
  public var revision: UInt64 { lastRevision }

  /// 解析一行 JSON Lines 记录。
  ///
  /// 一旦返回 `.resynchronize`，本地缓存就是不可信的：调用方必须重新取快照，
  /// 不能把带缺口的状态标成最新。故意不在这里自动重置游标——重置发生在重连时，
  /// 因为 sequence 属于连接，不属于会话。
  public mutating func consume(line: Data) -> RemoteSessionStreamOutcome {
    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let type = json["type"] as? String
    else { return .resynchronize(.malformedLine(preview(line))) }

    if type == "subscribed" || type == "hello" {
      guard let target = Self.target(json), let revision = Self.number(json["revision"]) else {
        return .resynchronize(.malformedLine(preview(line)))
      }
      // 新连接重置序号游标：绝不沿用上一条连接的 afterSequence。
      if let expected, expected != target { return .resynchronize(.staleTarget(target)) }
      expected = target
      handshakeSeen = true
      lastSequence = 0
      lastRevision = revision
      return .subscribed(RemoteSessionSubscription(target: target, revision: revision))
    }

    guard type == "event",
      let name = json["event"] as? String,
      let eventID = json["eventID"] as? String,
      let target = Self.target(json),
      let sequence = Self.number(json["sequence"]),
      let revision = Self.number(json["revision"]),
      let body = json["body"]
    else { return .resynchronize(.malformedLine(preview(line))) }

    // 身份先于顺序：来自别的服务实例的事件根本不该进入本地序号计数。
    guard handshakeSeen, let expected, expected == target else {
      return .resynchronize(.staleTarget(target))
    }
    guard sequence == lastSequence + 1 else {
      return .resynchronize(.sequenceGap(expected: lastSequence + 1, received: sequence))
    }
    guard revision >= lastRevision else {
      return .resynchronize(.revisionRewind(current: lastRevision, received: revision))
    }
    let kind = RemoteSessionEventKind(rawValue: name)
    // 未知类型仍然推进序号（它确实占用了这条连接的一个序号），但不当成已应用的
    // 业务变更：调用方收到 .unknownEvent 之后必须重新取快照。
    lastSequence = sequence
    lastRevision = revision
    guard !kind.isUnknown else { return .resynchronize(.unknownEvent(name)) }
    let encoded = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    return .event(
      RemoteSessionEvent(
        kind: kind, eventID: eventID, target: target,
        sequence: sequence, revision: revision, body: encoded))
  }

  private func preview(_ line: Data) -> String {
    String(decoding: line.prefix(256), as: UTF8.self)
  }

  private static func target(_ json: [String: Any]) -> RemoteSessionEventTarget? {
    // 握手行把三项摊平在顶层，事件行放在 target 段里；两种形状都接受。
    let source = (json["target"] as? [String: Any]) ?? json
    guard let serverID = source["serverID"] as? String,
      let serverEpoch = source["serverEpoch"] as? String,
      let sessionID = source["sessionID"] as? String
    else { return nil }
    return RemoteSessionEventTarget(
      serverID: serverID, serverEpoch: serverEpoch, sessionID: sessionID)
  }

  private static func number(_ value: Any?) -> UInt64? {
    (value as? NSNumber)?.uint64Value
  }
}

/// 可注入的「按行到达的字节源」。把「进程」抽象掉，解码逻辑才能脱离真实服务被测。
public protocol SessionEventLineSource: AnyObject, Sendable {
  /// 启动来源。`onLine` 每次交付一条不含换行符的完整记录；
  /// `onFinish` 只调用一次，表示这条流已经结束。
  func start(
    onLine: @escaping @Sendable (Data) -> Void,
    onFinish: @escaping @Sendable (RemoteSessionStreamTermination) -> Void
  ) throws
  /// 幂等停止。停止之后不再交付任何行。
  func stop()
}

/// 事件流客户端：把一条行来源接到解码状态机上，并把结论回调出去。
public final class SessionEventStreamClient: @unchecked Sendable {
  /// 回调集合。全部在行来源自己的队列上触发，调用方负责跳回自己的隔离域。
  public struct Callbacks: Sendable {
    public var onSubscribed: @Sendable (RemoteSessionSubscription) -> Void
    public var onEvent: @Sendable (RemoteSessionEvent) -> Void
    public var onResynchronize: @Sendable (RemoteSessionStreamFault) -> Void
    public var onConnectionLost: @Sendable (RemoteSessionStreamTermination) -> Void

    public init(
      onSubscribed: @escaping @Sendable (RemoteSessionSubscription) -> Void = { _ in },
      onEvent: @escaping @Sendable (RemoteSessionEvent) -> Void = { _ in },
      onResynchronize: @escaping @Sendable (RemoteSessionStreamFault) -> Void = { _ in },
      onConnectionLost: @escaping @Sendable (RemoteSessionStreamTermination) -> Void = { _ in }
    ) {
      self.onSubscribed = onSubscribed
      self.onEvent = onEvent
      self.onResynchronize = onResynchronize
      self.onConnectionLost = onConnectionLost
    }
  }

  private let source: any SessionEventLineSource
  private let callbacks: Callbacks
  private let lock = NSLock()
  private var decoder: SessionEventStreamDecoder
  private var running = false
  private var finished = false

  public init(
    source: any SessionEventLineSource,
    expectedTarget: RemoteSessionEventTarget? = nil,
    callbacks: Callbacks
  ) {
    self.source = source
    self.callbacks = callbacks
    self.decoder = SessionEventStreamDecoder(expected: expectedTarget)
  }

  /// 启动订阅。启动失败也会走 `onConnectionLost`，调用方只需要处理一条结束路径。
  public func start() {
    lock.lock()
    guard !running, !finished else {
      lock.unlock()
      return
    }
    running = true
    lock.unlock()
    do {
      try source.start(
        onLine: { [weak self] line in self?.handle(line: line) },
        onFinish: { [weak self] termination in self?.finish(termination) })
    } catch {
      finish(.launchFailed(String(describing: error)))
    }
  }

  /// 主动停止。仍然会以 `.stopped` 触发一次连接结束回调。
  public func stop() {
    lock.lock()
    let active = running && !finished
    lock.unlock()
    guard active else { return }
    source.stop()
    finish(.stopped)
  }

  private func handle(line: Data) {
    lock.lock()
    guard running, !finished else {
      lock.unlock()
      return
    }
    let outcome = decoder.consume(line: line)
    lock.unlock()
    switch outcome {
    case .subscribed(let subscription): callbacks.onSubscribed(subscription)
    case .event(let event): callbacks.onEvent(event)
    case .resynchronize(let fault): callbacks.onResynchronize(fault)
    }
  }

  /// 结束只上报一次：进程退出与主动停止可能同时发生。
  private func finish(_ termination: RemoteSessionStreamTermination) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    running = false
    lock.unlock()
    callbacks.onConnectionLost(termination)
  }
}

/// 真实实现：把 `aster-session event subscribe`（本机或经 SSH）当成一个长命子进程读。
///
/// 与 `LocalManagedSessionClient.executeStructured` 的一问一答不同，这里绝不能把
/// stdout 攒起来等进程退出——订阅进程本来就不会退出。
public final class ProcessSessionEventLineSource: SessionEventLineSource, @unchecked Sendable {
  private let invocation: ManagedSessionInvocation
  private let maximumLineBytes: Int
  private let lock = NSLock()
  private let process = Process()
  /// 两条管道保存成属性，而不是只活在 `start` 的局部作用域里。
  ///
  /// `readabilityHandler` 背后是一个 dispatch 源，只要不显式清空就会带着 FileHandle
  /// 一直活着。原来只在 `terminationHandler` 里清空，于是「没人调 stop 就被释放」
  /// 或「子进程先于回调退出」这两条路径上会留下无主的读源。收尾必须能确定地摘掉它们。
  private var output: Pipe?
  private var errors: Pipe?
  private var framing: NDJSONFraming
  private var diagnostics = Data()
  private var started = false
  private var stopped = false

  /// SIGTERM 之后的有界宽限期；到点仍在跑就补一次 SIGKILL。
  ///
  /// 收尾**绝不能**用 `waitUntilExit()`：它在主线程会重新进入 AppKit 事件循环，
  /// 把在途的界面回调重入到调用点上（实测会崩在 CoreAnimation 的提交里）。
  private static let terminationGrace: DispatchTimeInterval = .milliseconds(1_500)
  /// 兜底回收的共享串行队列；调用方（多半是主线程）一秒都不必等。
  private static let reaper = DispatchQueue(label: "io.local.aster.session-event-reaper")

  public init(invocation: ManagedSessionInvocation, maximumLineBytes: Int = 4 * 1024 * 1024) {
    self.invocation = invocation
    self.maximumLineBytes = maximumLineBytes
    self.framing = NDJSONFraming(maximumLineBytes: maximumLineBytes)
  }

  /// 兜底收尾：没人调用 `stop()` 就被释放时，订阅子进程和读源都必须跟着结束，
  /// 否则会留下孤儿 `ssh` 和一个无主的 dispatch 读源。
  deinit {
    stop()
  }

  public func start(
    onLine: @escaping @Sendable (Data) -> Void,
    onFinish: @escaping @Sendable (RemoteSessionStreamTermination) -> Void
  ) throws {
    lock.lock()
    guard !started else {
      lock.unlock()
      return
    }
    started = true
    let output = Pipe()
    let errors = Pipe()
    self.output = output
    self.errors = errors
    lock.unlock()

    process.executableURL = URL(fileURLWithPath: invocation.executablePath)
    process.arguments = invocation.arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      // 源对象已经释放时顺手把读源摘掉，避免它继续空转在一个无主的 FileHandle 上。
      guard let self else {
        handle.readabilityHandler = nil
        return
      }
      let data = handle.availableData
      guard !data.isEmpty else { return }
      for line in self.frame(data) { onLine(line) }
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      guard let self else {
        handle.readabilityHandler = nil
        return
      }
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self.lock.lock()
      // 诊断只保留开头，避免一条坏掉的远端命令把内存写满。
      if self.diagnostics.count < 4096 { self.diagnostics.append(data) }
      self.lock.unlock()
    }
    process.terminationHandler = { [weak self] finished in
      // 先摘读回调再收尾：处理残留字节期间不能再有新的读事件并发进来。
      // 退出瞬间管道里可能还有最后几条事件，读干净再上报结束。
      let tail = self?.releaseHandles(drainingOutput: true) ?? Data()
      if let self, !tail.isEmpty {
        for line in self.frame(tail) { onLine(line) }
      }
      let text = self?.takeDiagnostics() ?? ""
      onFinish(.processExited(status: finished.terminationStatus, diagnostics: text))
    }
    do {
      try process.run()
    } catch {
      lock.lock()
      stopped = true
      lock.unlock()
      releaseHandles(drainingOutput: false)
      throw error
    }
  }

  public func stop() {
    lock.lock()
    let shouldSignal = started && !stopped
    stopped = true
    lock.unlock()
    guard shouldSignal else { return }
    // 停止之后绝不能再交付任何行，所以先摘读回调；调用方已经不要残留字节了，不排空。
    releaseHandles(drainingOutput: false)
    guard process.isRunning else { return }
    // SIGTERM 是订阅进程约定的干净退出信号；不 kill，让它自己关连接。
    // 事件订阅只是一条**只读**控制连接，结束它不会结束远端任何终端进程。
    process.terminate()
    // 有界兜底：宽限期到点还没退出就补一次 SIGKILL。只针对这一个 pid，
    // **绝不**发给进程组——同一个组里还有别的受管进程。整个过程不阻塞调用方。
    let child = process
    let pid = child.processIdentifier
    guard pid > 0 else { return }
    Self.reaper.asyncAfter(deadline: .now() + Self.terminationGrace) {
      guard child.isRunning else { return }
      _ = Darwin.kill(pid, SIGKILL)
    }
  }

  /// 摘掉两条管道的读回调并关闭读端；`drainingOutput` 为真时先把 stdout 残留读干净。
  ///
  /// 幂等：`stop()` 与 `terminationHandler` 谁先到都可以，第二次只会拿到 nil。
  /// 只有在子进程**已经退出**（terminationHandler 里）才排空，那时读一定会立即遇到
  /// EOF；停止路径上不排空，收尾必须是有界的。
  @discardableResult
  private func releaseHandles(drainingOutput: Bool) -> Data {
    lock.lock()
    let output = self.output
    let errors = self.errors
    self.output = nil
    self.errors = nil
    lock.unlock()
    output?.fileHandleForReading.readabilityHandler = nil
    errors?.fileHandleForReading.readabilityHandler = nil
    var tail = Data()
    if drainingOutput, let handle = output?.fileHandleForReading {
      tail = (try? handle.readToEnd()) ?? Data()
    }
    // 刻意**不**显式 close 读端：摘掉 readabilityHandler 只是取消 dispatch 源，
    // 已经排队的读事件仍可能落到 handler 上，那时 fd 已关会直接抛异常崩掉。
    // 丢掉 Pipe 引用就够了——本对象释放时 Process 与 Pipe 一起走，fd 随之关闭。
    return tail
  }

  private func frame(_ data: Data) -> [Data] {
    lock.lock()
    defer { lock.unlock() }
    return (try? framing.append(data)) ?? []
  }

  private func takeDiagnostics() -> String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: diagnostics.prefix(4096), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
