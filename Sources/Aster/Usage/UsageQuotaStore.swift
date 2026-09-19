// 配额页与状态栏共用的账号快照来源：合并 Claude（官方 usage 接口）与 Codex（最新 rollout）。
import AsterCore
import Combine
import Foundation

/// 账号配额的唯一发布点。
///
/// `start()` 之后才有任何开销；`stop()` 之后不留轮询。Claude 侧复用
/// `ClaudeAccountQuotaService.shared` 的共享请求时间线，绝不另起第二条。
@MainActor
final class UsageQuotaStore: ObservableObject {
  /// 有数据的账号。没有任何窗口的 provider 不出现。
  @Published private(set) var accounts: [UsageAccountSnapshot] = []

  init() {}

  /// 功能开启：开始被动轮询。可重复调用。
  func start() {
    // 骨架：由「配额与开关」任务实现。
  }

  /// 功能关闭：停止一切轮询。可重复调用。
  func stop() {
    // 骨架：由「配额与开关」任务实现。
  }

  /// 浮动窗打开时调用：立即重读一次本地的 Codex 数据（不发网络请求）。
  func refreshLocalSources() {
    // 骨架：由「配额与开关」任务实现。
  }
}
