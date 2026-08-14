import Foundation

/// Session Recording 的纯函数支撑集：磁盘布局、限频判定、策略叠加与 payload 编解码。
///
/// 这些逻辑本身与 AppKit、文件系统、子进程都无关，放在 AsterCore 便于用真值表测试。
/// 记录层（`Sources/Aster/Memory`）只负责把它们串起来并承担 IO。

/// 命令输出正文在 Memory 根目录下的相对布局。
///
/// 相对路径是 artifact 表里唯一持久化的定位信息（`ArtifactRef.relativePath`），
/// 绝不能存绝对路径：家目录迁移或沙箱容器变化会让指针整体失效。
public enum MemoryTranscriptLayout {
  /// 所有命令输出正文的顶层目录名。
  public static let directoryName = "transcripts"

  /// 单个 Session 的正文目录（相对 Memory 根目录）。
  public static func sessionDirectory(sessionID: UUID) -> String {
    "\(directoryName)/\(sessionID.uuidString)"
  }

  /// 单条命令输出的正文文件（相对 Memory 根目录）。
  /// 序号取自 Session 内单调递增的事件序号，天然唯一且可与 events 表对齐。
  public static func relativePath(sessionID: UUID, sequence: Int) -> String {
    "\(sessionDirectory(sessionID: sessionID))/\(max(0, sequence)).txt"
  }
}

/// `.gitStateSnapshot` 事件的 payload。events 表只有一个通用 `payload` 文本列，
/// 各 kind 自带结构；这里固定为紧凑 JSON，读侧无需猜测格式。
public struct GitSnapshotPayload: Codable, Equatable, Sendable {
  public var branch: String?
  public var commit: String?
  /// 工作区脏文件数（含未跟踪）。只存计数不存文件名：路径本身可能泄露项目结构。
  public var dirtyFileCount: Int

  public init(branch: String? = nil, commit: String? = nil, dirtyFileCount: Int = 0) {
    self.branch = branch
    self.commit = commit
    self.dirtyFileCount = max(0, dirtyFileCount)
  }

  /// 是否值得落一条事件。分支、commit 全空且工作区干净时说明目录根本不是仓库，
  /// 记录只会制造噪音。
  public var isMeaningful: Bool {
    branch != nil || commit != nil || dirtyFileCount > 0
  }

  /// 编码为事件 payload 字符串。键排序固定，便于测试与人工比对。
  public func jsonString() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 从事件 payload 还原。格式漂移或非本 kind 的 payload 返回 nil，调用方按缺失处理。
  public static func decode(_ json: String) -> GitSnapshotPayload? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(GitSnapshotPayload.self, from: data)
  }
}

/// 最小间隔限频闸门。用于 git 快照这类「值得采集但不能每条命令都跑子进程」的动作。
///
/// 刻意做成值类型 + 显式 `now`：调用方（actor）持有状态，测试可以直接推进时间，
/// 不需要真的 sleep。
public struct RecordingThrottle: Equatable, Sendable {
  public let minimumInterval: TimeInterval
  private var lastFiredAt: Date?

  public init(minimumInterval: TimeInterval, lastFiredAt: Date? = nil) {
    self.minimumInterval = max(0, minimumInterval)
    self.lastFiredAt = lastFiredAt
  }

  /// 判定此刻是否放行；放行会同时记下时间戳（一次调用只能放行一次）。
  public mutating func allow(at now: Date = Date()) -> Bool {
    if let lastFiredAt, now.timeIntervalSince(lastFiredAt) < minimumInterval {
      return false
    }
    lastFiredAt = now
    return true
  }
}

/// artifact 目录配额的扫描闸门。
///
/// 配额裁剪要遍历全表并可能删文件，成本远高于写一条正文；按累计写入字节数触发，
/// 保证「写得多就扫得勤，写得少就几乎不扫」，而不是每条命令都扫一遍。
public struct ArtifactQuotaTracker: Equatable, Sendable {
  /// transcripts 目录总配额（PRD §Phase 1）。
  public static let defaultQuotaBytes = 512 * 1_024 * 1_024
  /// 两次配额扫描之间允许写入的字节数。
  public let bytesBetweenSweeps: Int
  private var accumulated: Int

  public init(bytesBetweenSweeps: Int = 8 * 1_024 * 1_024, accumulated: Int = 0) {
    self.bytesBetweenSweeps = max(1, bytesBetweenSweeps)
    self.accumulated = max(0, accumulated)
  }

  /// 累计本次写入的字节数并判定是否该做一次配额扫描；放行会清零累计值。
  public mutating func shouldSweep(afterWriting bytes: Int) -> Bool {
    accumulated += max(0, bytes)
    guard accumulated >= bytesBetweenSweeps else { return false }
    accumulated = 0
    return true
  }
}

/// 输出摘录的有界截取。events 表只保留尾部摘录供 FTS，全文走 artifact 文件。
public enum MemoryOutputExcerpt {
  /// 单条事件摘录的字节上限。
  public static let maximumBytes = 4_096

  /// 取文本尾部的有界摘录。错误信息几乎总在输出尾部，所以截尾不截头。
  ///
  /// 必须按 UTF-8 **字节**而不是 Character 截断：Character 计数在 CJK/emoji 下
  /// 会让一条摘录膨胀到数倍字节，撑爆 events 表的体积预期。截断后要跳过
  /// continuation 字节，否则会产出无效 UTF-8（解码成 U+FFFD 污染 FTS 索引）。
  public static func tail(of text: String, maximumBytes: Int = maximumBytes) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, maximumBytes > 0 else { return nil }
    let bytes = Array(trimmed.utf8)
    guard bytes.count > maximumBytes else { return trimmed }
    var start = bytes.count - maximumBytes
    while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
    let result = String(decoding: bytes[start...], as: UTF8.self)
    return result.isEmpty ? nil : result
  }
}

extension RecordingPolicy {
  /// 叠加 per-pane 临时隐身。
  ///
  /// 隐身是「本 Pane 本次会话」的覆盖，不写全局设置，也不改用户已配置的排除列表；
  /// 它只能收紧不能放松——全局 off 时把 Pane 设成非隐身不会开启记录。
  public func overriddenByIncognito(_ incognito: Bool) -> RecordingPolicy {
    guard incognito else { return self }
    var copy = self
    copy.mode = .incognito
    return copy
  }

  /// 记录是否真正落盘。`off` 与 `incognito` 都是零落盘，差别只在 UI 语义。
  public var writesToDisk: Bool { mode == .on }
}
