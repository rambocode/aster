// 每个 Agent 的本地 token 数据源都实现这个协议；扫描引擎只认协议，不认具体格式。
import Foundation

/// 一个待扫描的数据文件。`size` + `modified` 是缓存身份：两者都没变就不再打开文件。
public struct TokenSourceFile: Equatable, Sendable {
  public var path: String
  public var size: Int64
  /// `contentModificationDate` 的 `timeIntervalSince1970`。
  public var modified: Double

  public init(path: String, size: Int64, modified: Double) {
    self.path = path
    self.size = size
    self.modified = modified
  }
}

/// 解析时的共享上下文：本地日换算与项目归属。实现必须可以在后台线程调用。
public protocol TokenScanContext: AnyObject {
  /// 把 Unix 秒换算成本地日（自 1970-01-01 起的天数）。
  func localDay(forEpochSeconds seconds: Int64) -> Int
  /// 把工作目录归一成项目键（git 主仓库根；找不到就用目录本身）。结果按目录缓存。
  func projectKey(forWorkingDirectory path: String) -> String
}

/// 某个 Agent 的本地 token 数据源。
///
/// 约束：只读；不联网；不读对话正文；畸形或写了一半的行直接跳过，不抛错；
/// 数据目录不存在时 `discoverFiles` 返回空数组。全部方法在后台线程调用。
public protocol TokenUsageSource: Sendable {
  var provider: AgentProvider { get }
  /// 列出当前存在的数据文件。SQLite 类数据源返回单个 db 文件，
  /// `size` / `modified` 需要把 `-wal` 一并计入，否则 WAL 里的新数据触发不了重扫。
  func discoverFiles(homeDirectory: URL) -> [TokenSourceFile]
  /// 解析一个文件，返回按（日，项目）聚合后的 bucket。
  func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket]
}
