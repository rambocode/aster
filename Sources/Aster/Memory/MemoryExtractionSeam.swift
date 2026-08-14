import AsterCore
import Foundation

/// Session 结束后把事件流提炼成 Memory 的抽象边界。
///
/// 存在两个实现：规则式（纯本地、永远可用、作为保底）与 CLI Agent 增强式
/// （调用本机已安装的 Agent CLI 做叙述性提炼）。记录管线只依赖本协议，
/// 不关心背后是否发生了进程调用或网络请求。
protocol SessionMemoryExtracting: Sendable {
  /// 提炼一个 session。返回 nil 表示不值得生成 Memory（如没有任何命令）。
  /// 实现必须自行处理超时与失败：抛错会被调用方吞掉，但不应长时间阻塞。
  func extract(
    session: RecordedSessionDescriptor,
    events: [RecordedEvent]
  ) async -> ExtractedMemory?
}

/// 提炼结果：Memory 本体 + 来源回链（PRD §31，保证可追溯）。
struct ExtractedMemory: Sendable {
  let memory: MemoryRecord
  let sources: [MemorySourceRef]

  init(memory: MemoryRecord, sources: [MemorySourceRef]) {
    self.memory = memory
    self.sources = sources
  }
}

/// 规则式提炼：把 AsterCore 的纯函数结果包装成 Memory。
/// 零外发、零进程调用，任何情况下都可用，是 CLI 提炼失败时的回落路径。
struct RuleBasedMemoryExtractor: SessionMemoryExtracting {
  func extract(
    session: RecordedSessionDescriptor,
    events: [RecordedEvent]
  ) async -> ExtractedMemory? {
    guard let draft = RuleBasedSessionMemoryExtractor.extract(session: session, events: events)
    else { return nil }
    // Memory id 沿用 session id：同一 session 重复提炼是幂等替换，不会堆积副本。
    let memory = MemoryRecord(
      id: session.id,
      projectPath: draft.projectPath,
      sessionID: session.id,
      taskID: session.taskID,
      type: .session,
      title: draft.title,
      content: draft.content,
      summary: draft.title,
      extractor: .ruleBased
    )
    var sources: [MemorySourceRef] = [.init(kind: .session, identifier: session.id.uuidString)]
    if let taskID = session.taskID {
      sources.append(.init(kind: .task, identifier: taskID.uuidString))
    }
    return ExtractedMemory(memory: memory, sources: sources)
  }
}

/// 全局提炼入口。装配层在启动时替换 `provider` 即可切换实现；
/// 默认值保证任何时刻调用都有可用的保底提炼。
enum MemoryExtraction {
  /// 当前生效的提炼器。仅在应用启动装配阶段写入，运行期只读。
  nonisolated(unsafe) static var provider: any SessionMemoryExtracting = RuleBasedMemoryExtractor()
}
