import AsterCore
import AsterMemory
import Foundation

/// 进程级 Session Memory 存储入口。
///
/// 单写者约定要求整个应用进程只存在一个 `EventWriter`：记录管线、Memory 管理 UI、
/// Task 编辑都必须经由 `MemoryStoreAccess.writer`，任何地方再 `EventWriter(location:)`
/// 都会引入第二个写连接并造成锁竞争与写丢失。
///
/// 只读侧相反：`makeReader()` 每次返回新的只读连接，调用方用完即弃。
/// 只读连接与写连接可安全并发（WAL + busy_timeout）。
enum MemoryStoreAccess {
  /// 存储位置。测试可经 `ASTER_MEMORY_DIR` 覆盖，避免污染真实用户数据。
  static let location: MemoryStoreLocation = {
    if let override = ProcessInfo.processInfo.environment["ASTER_MEMORY_DIR"], !override.isEmpty {
      return MemoryStoreLocation(rootDirectory: URL(fileURLWithPath: override, isDirectory: true))
    }
    return .standard()
  }()

  /// 全进程唯一的写入者。
  static let writer = EventWriter(location: location)

  /// 创建一个只读连接。数据库尚未建立（用户从未开启过记录）时返回 nil，
  /// 调用方据此显示「暂无记录」而不是报错。
  static func makeReader() -> MemoryStoreReader? {
    try? MemoryStoreReader(location: location)
  }
}
