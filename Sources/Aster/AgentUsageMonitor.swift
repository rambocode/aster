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
