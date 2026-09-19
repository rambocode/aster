// 运行中 Agent 会话的标题跟踪：决定「什么时候」去读标题，读本身交给 AgentSessionTitleProbe。

import AsterCore
import Foundation

/// 按 Pane 调度单会话标题探测，并缓存已解析的标题。
///
/// 时机规则（对应 Claude Code 的行为：标题在首条 prompt 之后几秒才生成，没有 prompt 就没有标题）：
/// - prompt 刚提交（状态翻到 processing）：按递增间隔重试，拿到标题立即停；
/// - 其它时机（绑定变化、任务结束）：只读一次，用来接住 `/rename` 和恢复的旧会话；
/// - 空闲会话不产生任何事件，因此完全不读盘。
/// 读盘全部在后台任务里，结果按发起时的 provider + session ID 回写，过期结果直接丢弃。
@MainActor
final class AgentSessionTitleTracker {
  /// 某个 Pane 当前绑定的会话。
  struct Binding: Equatable {
    var provider: AgentProvider
    var sessionID: String
    var workingDirectory: String
    var homeDirectory: URL
  }

  /// prompt 提交后的重试间隔。累计约 80 秒；标题通常在前两次内就能读到。测试会缩短它。
  var retryDelays: [Duration] = [
    .seconds(2), .seconds(3), .seconds(5), .seconds(10), .seconds(20), .seconds(40),
  ]
  /// 读 Pane 的当前绑定；Pane 已关闭、Agent 已退出或不在本机时返回 nil，探测随即停止。
  var bindingProvider: (UUID) -> Binding? = { _ in nil }
  /// 有标题新解析出来或发生变化。
  var onTitlesChanged: () -> Void = {}
  /// 重试用尽仍没有 provider 标题（旧版本 Claude、标题功能被关掉）。
  var onRetriesExhausted: (UUID) -> Void = { _ in }

  private var titles: [String: String] = [:]
  /// 每个 Pane 在跑的探测任务。`token` 区分先后两代任务，`sessionKey` 记录它为哪个会话而跑。
  private struct Running {
    var token: UUID
    var sessionKey: String
    var retrying: Bool
    var task: Task<Void, Never>
  }
  private var tasks: [UUID: Running] = [:]

  /// 已缓存的 provider 标题；没探测到过返回 nil。
  func title(provider: AgentProvider, sessionID: String) -> String? {
    titles[Self.key(provider, sessionID)]
  }

  /// 为某个 Pane 发起探测。同一 Pane 同时只有一个任务。已有任务只在两种情况下被替换：
  /// 会话换了（`/clear` 之后旧任务可能还在睡，不能让它挡住新会话），或「单次 → 重试」升级
  /// （首条 prompt 与绑定上报几乎同时到达，不能让单次探测把重试序列挤掉）。
  func probe(paneID: UUID, retrying: Bool) {
    guard let binding = bindingProvider(paneID), AgentSessionTitleProbe.supports(binding.provider)
    else { return }
    let sessionKey = Self.key(binding.provider, binding.sessionID)
    if let running = tasks[paneID] {
      let upgrades = retrying && !running.retrying
      guard running.sessionKey != sessionKey || upgrades else { return }
      running.task.cancel()
    }
    let token = UUID()
    let delays = retrying ? retryDelays : [.zero]
    let task = Task { @MainActor [weak self] in
      await self?.run(paneID: paneID, binding: binding, delays: delays, retrying: retrying)
      // 任务可能已被新任务替换；只清理属于自己的登记。
      if self?.tasks[paneID]?.token == token { self?.tasks.removeValue(forKey: paneID) }
    }
    tasks[paneID] = Running(token: token, sessionKey: sessionKey, retrying: retrying, task: task)
  }

  /// 逐次探测直到拿到标题、绑定变化或被取消。
  private func run(
    paneID: UUID, binding: Binding, delays: [Duration], retrying: Bool
  ) async {
    for delay in delays {
      if delay > .zero {
        do { try await Task.sleep(for: delay) } catch { return }
      }
      // 每轮重新读绑定：目录可能已变，session 换了（`/clear`）则本任务作废。
      guard let current = bindingProvider(paneID), Self.sameSession(current, binding) else { return }
      let title = await AgentSessionTitleProbe.title(
        provider: current.provider, sessionID: current.sessionID,
        workingDirectory: current.workingDirectory, homeDirectory: current.homeDirectory)
      guard !Task.isCancelled, let latest = bindingProvider(paneID),
        Self.sameSession(latest, binding)
      else { return }
      guard let title else { continue }
      let key = Self.key(binding.provider, binding.sessionID)
      if titles[key] != title {
        titles[key] = title
        onTitlesChanged()
      }
      return
    }
    // 单次探测落空很正常（还没发 prompt）；只有完整重试序列用尽才值得上报。
    if retrying { onRetriesExhausted(paneID) }
  }

  private static func sameSession(_ lhs: Binding, _ rhs: Binding) -> Bool {
    lhs.provider == rhs.provider && lhs.sessionID == rhs.sessionID
  }

  private static func key(_ provider: AgentProvider, _ sessionID: String) -> String {
    "\(provider.rawValue):\(sessionID)"
  }
}
