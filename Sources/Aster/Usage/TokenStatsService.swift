// Token 页的后台扫描服务：串行、可取消、结果带缓存。
import AsterCore
import Foundation

/// 扫描并缓存各 Agent 的本地 token 用量。
///
/// 只在 Token 页可见时由页面触发，从不定时。扫描跑在 utility 优先级，逐文件检查取消。
actor TokenStatsService {
  init() {}

  /// 扫描（增量）并返回全部样本。`progress` 在任意线程回调。
  /// 任务被取消时返回目前已有的样本。
  func load(progress: @escaping @Sendable (TokenScanProgress) -> Void) async -> [TokenSample] {
    // 骨架：由「Token 页」任务实现。
    []
  }
}
