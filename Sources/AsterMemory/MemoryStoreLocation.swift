import Foundation

/// Session Memory 的磁盘位置与权限。独立于 DiagnosticsCenter 的日志目录：
/// 两个通道的脱敏策略不同，绝不共享文件或互相引用。
public struct MemoryStoreLocation: Sendable {
  public let rootDirectory: URL

  /// 数据库文件路径（WAL 模式会伴生 -wal/-shm 文件，同目录同权限）。
  public var databaseURL: URL {
    rootDirectory.appendingPathComponent("memory.sqlite", isDirectory: false)
  }

  /// 生产位置：`~/Library/Application Support/Aster/Memory/`。
  public static func standard(fileManager: FileManager = .default) -> MemoryStoreLocation {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support", isDirectory: true)
    return MemoryStoreLocation(
      rootDirectory:
        base
        .appendingPathComponent("Aster", isDirectory: true)
        .appendingPathComponent("Memory", isDirectory: true)
    )
  }

  public init(rootDirectory: URL) {
    self.rootDirectory = rootDirectory
  }

  /// 创建目录并收紧权限（目录 0700）。记录内容可能包含命令与输出摘录，
  /// 与 Autocomplete/Diagnostics 目录采用同一防线：仅当前用户可读。
  public func prepareDirectory(fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
  }
}
