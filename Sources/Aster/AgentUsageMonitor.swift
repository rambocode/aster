import AsterCore
import Foundation

/// Codex 用量数据源：Pane 绑定 Codex session 后监听其 rollout JSONL，去抖后在后台读尾部
/// 交给 `CodexRolloutUsageParser`，结果回主线程。
///
/// rollout 文件可能晚于 SessionStart hook 出现（首条 prompt 后才创建），因此定位失败按
/// 退避重试；`locateTranscript` 会遍历整个 `~/.codex/sessions`，必须在后台执行。
@MainActor
final class CodexUsageFileMonitor {
  static let debounce: Duration = .milliseconds(300)
  static let locateRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8)]

  private let agentSessionID: String
  private let homeDirectory: URL
  private let onSnapshot: @MainActor (AgentUsageSnapshot?) -> Void
  private var locateTask: Task<Void, Never>?
  private var readTask: Task<Void, Never>?
  private var watcher: FileSystemDirectoryWatcher?
  private var fileURL: URL?
  private var stopped = false

  init(
    agentSessionID: String,
    homeDirectory: URL,
    onSnapshot: @escaping @MainActor (AgentUsageSnapshot?) -> Void
  ) {
    self.agentSessionID = agentSessionID
    self.homeDirectory = homeDirectory
    self.onSnapshot = onSnapshot
  }

  /// 后台定位 rollout 文件；找到后立即读一次并开始监听。
  func start() {
    guard locateTask == nil, !stopped else { return }
    let sessionID = agentSessionID
    let home = homeDirectory
    locateTask = Task { [weak self] in
      var attempt = 0
      while !Task.isCancelled {
        let located = await Task.detached(priority: .utility) {
          AgentTranscriptIngestion.locateTranscript(
            provider: .codex, agentSessionID: sessionID, homeDirectory: home)
        }.value
        if case .success(let url) = located {
          self?.attach(to: url)
          return
        }
        guard attempt < Self.locateRetryDelays.count else { return }
        try? await Task.sleep(for: Self.locateRetryDelays[attempt])
        attempt += 1
      }
    }
  }

  func stop() {
    stopped = true
    locateTask?.cancel()
    locateTask = nil
    readTask?.cancel()
    readTask = nil
    watcher?.stop()
    watcher = nil
  }

  private func attach(to url: URL) {
    guard !stopped else { return }
    fileURL = url
    let watcher = FileSystemDirectoryWatcher(file: url)
    do {
      try watcher.start { [weak self] in self?.scheduleRead() }
      self.watcher = watcher
    } catch {
      // 监听失败仍读一次，至少显示绑定时刻的用量。
    }
    scheduleRead()
  }

  /// 去抖：Codex 一轮里连续追加多行，只在安静 300ms 后读一次。
  private func scheduleRead() {
    readTask?.cancel()
    guard let fileURL, !stopped else { return }
    readTask = Task { [weak self] in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      let outcome = await Task.detached(priority: .utility) { Self.readTail(of: fileURL) }.value
      guard !Task.isCancelled, let self, !self.stopped else { return }
      switch outcome {
      case .missing:
        // 文件被删除或改名：条消失并停止监听，不猜别的文件。
        self.onSnapshot(nil)
        self.stop()
      case .tail(let data):
        if let snapshot = CodexRolloutUsageParser.parse(tail: data) {
          self.onSnapshot(snapshot)
        }
      }
    }
  }

  private enum TailOutcome {
    case missing
    case tail(Data)
  }

  /// 只读文件末尾 `tailBytes`；文件较小时整读。
  private nonisolated static func readTail(of url: URL) -> TailOutcome {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return .missing }
    let start = size > UInt64(CodexRolloutUsageParser.tailBytes)
      ? size - UInt64(CodexRolloutUsageParser.tailBytes) : 0
    guard (try? handle.seek(toOffset: start)) != nil,
      let data = try? handle.readToEnd()
    else { return .missing }
    return .tail(data)
  }
}

/// Claude 用量数据源：statusLine 包装器按 pane UUID 把 `AgentUsage=…` 一行写进
/// `~/Library/Application Support/Aster/agent-usage/<pane-uuid>.usage`，本仓库监听该目录并
/// 把更新分发给对应的 `TerminalSession`。
///
/// 为什么不用 OSC：Claude 启动 statusLine 命令时脱离控制终端（进程无 TTY，`/dev/tty` 打不开），
/// lifecycle hook 那条 `/dev/tty` 通道对 statusLine 不可用。文件由 Aster 自己的目录承载，
/// pane 结束时删除；Aster 崩溃遗留的旧文件靠 mtime 早于订阅时刻来忽略。
@MainActor
final class AgentUsageFileStore {
  static let shared = AgentUsageFileStore(directory: defaultDirectory)
  nonisolated static let fileExtension = "usage"
  nonisolated static let maximumFiles = 256
  nonisolated static let maximumFileBytes = 512
  static let debounce: Duration = .milliseconds(200)
  /// 超过该时长未更新的文件视为遗留，扫描时删除。
  nonisolated static let staleAge: TimeInterval = 7 * 24 * 3600

  static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Aster/agent-usage", isDirectory: true)
  }

  struct Update: Equatable {
    let directive: AgentUsageDirective
    let modifiedAt: Date
  }

  let directory: URL
  private var handlers: [UUID: @MainActor (Update) -> Void] = [:]
  private var lastDelivered: [UUID: Update] = [:]
  private var watcher: FileSystemDirectoryWatcher?
  private var scanTask: Task<Void, Never>?

  init(directory: URL) {
    self.directory = directory
  }

  /// 注册 pane 的更新回调；首次注册时创建目录并开始监听，随后立即扫描一次。
  func subscribe(paneID: UUID, onUpdate: @escaping @MainActor (Update) -> Void) {
    handlers[paneID] = onUpdate
    lastDelivered[paneID] = nil
    startWatchingIfNeeded()
    scheduleScan()
  }

  func unsubscribe(paneID: UUID) {
    handlers[paneID] = nil
    lastDelivered[paneID] = nil
  }

  /// pane 的 Agent 结束：删掉它的用量文件，避免下次同一 pane UUID 启动 shell 时被当成仍在跑。
  func remove(paneID: UUID) {
    lastDelivered[paneID] = nil
    try? FileManager.default.removeItem(at: fileURL(for: paneID))
  }

  func fileURL(for paneID: UUID) -> URL {
    directory.appendingPathComponent(paneID.uuidString).appendingPathExtension(Self.fileExtension)
  }

  private func startWatchingIfNeeded() {
    guard watcher == nil else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let watcher = FileSystemDirectoryWatcher(directory: directory)
    do {
      try watcher.start { [weak self] in self?.scheduleScan() }
      self.watcher = watcher
    } catch {
      // 监听失败只影响实时性；订阅时的一次扫描仍会执行。
    }
  }

  /// 目录事件可能合并，去抖后在后台读全部文件再回主线程分发。
  private func scheduleScan() {
    scanTask?.cancel()
    let directory = directory
    scanTask = Task { [weak self] in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      let entries = await Task.detached(priority: .utility) { Self.readAll(in: directory) }.value
      guard !Task.isCancelled, let self else { return }
      for (paneID, update) in entries {
        guard let handler = self.handlers[paneID], self.lastDelivered[paneID] != update else { continue }
        self.lastDelivered[paneID] = update
        handler(update)
      }
    }
  }

  /// 读取目录里全部 `<uuid>.usage`；只接受普通文件、有界大小、能通过 directive 解析的内容。
  nonisolated static func readAll(in directory: URL) -> [UUID: Update] {
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    guard let urls = try? manager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    else { return [:] }
    var result: [UUID: Update] = [:]
    let now = Date()
    for url in urls.prefix(maximumFiles) where url.pathExtension == fileExtension {
      guard let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size <= maximumFileBytes,
        let modifiedAt = values.contentModificationDate,
        let paneID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
      else { continue }
      if now.timeIntervalSince(modifiedAt) > staleAge {
        try? manager.removeItem(at: url)
        continue
      }
      guard let data = try? Data(contentsOf: url),
        let line = String(data: data, encoding: .utf8)?
          .split(separator: "\n", omittingEmptySubsequences: true).first,
        let directive = AgentUsageDirective(payload: String(line))
      else { continue }
      result[paneID] = Update(directive: directive, modifiedAt: modifiedAt)
    }
    return result
  }
}
