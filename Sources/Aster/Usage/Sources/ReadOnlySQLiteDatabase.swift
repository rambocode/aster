// SQLite 数据源共用的只读连接封装：打不开或被占用就放弃，绝不阻塞终端。
import AsterCore
import Foundation
import SQLite3

/// 一个只读的 SQLite 连接。
///
/// 故意不用 `immutable=1`：opencode 的库正被它自己以 WAL 模式使用，
/// `immutable` 会跳过 `-wal`、读到过期快照。`SQLITE_OPEN_READONLY` 配合 `-shm`
/// 正常参与 WAL 读取，又保证我们一个字节都不会写进去。
struct ReadOnlySQLiteDatabase {
  private let handle: OpaquePointer

  /// 打开数据库；文件不存在、无权限或不是合法数据库时返回 `nil`。
  ///
  /// `busyTimeoutMilliseconds` 刻意设得很短：用量统计是非核心功能，
  /// 宁可这一轮扫不出数据，也不能为等锁把扫描线程挂住。
  init?(path: String, busyTimeoutMilliseconds: Int32 = 250) {
    guard
      let opened = Self.open(
        path, flags: SQLITE_OPEN_READONLY, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
    else { return nil }
    handle = opened
  }

  /// 打开一个「对方没在用时就静止」的 WAL 库：没有 `-wal` 时按不可变文件读，有就走普通只读。
  ///
  /// 为什么要分两路：WAL 模式的库在没有 `-wal` / `-shm` 时，普通只读连接必须先在对方目录里
  /// **创建** `-shm` 才能读——目录不可写就直接打不开（实测 agy 的会话库报 `SQLITE_CANTOPEN`），
  /// 可写则会往别家的数据目录里留文件。没有 `-wal` 说明所有内容都已合进主库，此时
  /// `immutable=1` 读到的就是完整数据，且不建任何伴生文件。有 `-wal` 时反过来：`immutable`
  /// 会跳过它读到旧快照，所以退回普通只读（此时 `-shm` 已由写入方建好）。
  init?(quiescentWALDatabaseAtPath path: String, busyTimeoutMilliseconds: Int32 = 250) {
    var filename = path
    var flags = SQLITE_OPEN_READONLY
    if !FileManager.default.fileExists(atPath: path + "-wal") {
      // URI 文件名里 `?` `#` `%` 有特殊含义，路径必须先百分号编码。
      var allowed = CharacterSet.urlPathAllowed
      allowed.remove(charactersIn: "?#%")
      guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
        return nil
      }
      filename = "file:\(encoded)?immutable=1"
      flags |= SQLITE_OPEN_URI
    }
    guard
      let opened = Self.open(
        filename, flags: flags, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
    else { return nil }
    handle = opened
  }

  /// 两个构造器共用的打开步骤：失败时收掉半开的句柄并返回 nil。
  private static func open(
    _ filename: String, flags: Int32, busyTimeoutMilliseconds: Int32
  ) -> OpaquePointer? {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(filename, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
      if let opened = handle { sqlite3_close_v2(opened) }
      return nil
    }
    sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
    return opened
  }

  func close() {
    sqlite3_close_v2(handle)
  }

  /// 执行一条查询并逐行回调。准备语句失败（例如表不存在）或中途出错时返回 `false`。
  func forEachRow(_ sql: String, _ body: (OpaquePointer) -> Void) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
      let prepared = statement
    else {
      if let statement { sqlite3_finalize(statement) }
      return false
    }
    defer { sqlite3_finalize(prepared) }
    while true {
      switch sqlite3_step(prepared) {
      case SQLITE_ROW: body(prepared)
      case SQLITE_DONE: return true
      default: return false
      }
    }
  }

  /// 读取整数列；NULL 与非数值列都返回 0。
  static func int64(_ statement: OpaquePointer, _ column: Int32) -> Int64 {
    max(0, sqlite3_column_int64(statement, column))
  }

  /// 读取文本列；NULL 返回 `nil`。
  static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let bytes = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: bytes)
  }

  /// 读取 BLOB 列的全部字节；NULL 与空值返回空数组。
  static func bytes(_ statement: OpaquePointer, _ column: Int32) -> [UInt8] {
    // SQLite 要求先取指针再取长度：反过来调用时类型转换可能让先拿到的长度失效。
    guard let pointer = sqlite3_column_blob(statement, column) else { return [] }
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0 else { return [] }
    return Array(UnsafeRawBufferPointer(start: pointer, count: count))
  }

  /// 把主库与它的 `-wal` 合成一个缓存身份：大小相加、修改时间取较晚的一个。
  ///
  /// 只看主库会漏掉还留在 WAL 里的新写入，导致新数据永远触发不了重扫。
  static func sourceFile(atDatabasePath path: String) -> TokenSourceFile? {
    let manager = FileManager.default
    guard let main = try? manager.attributesOfItem(atPath: path),
      let size = main[.size] as? NSNumber, let modified = main[.modificationDate] as? Date
    else { return nil }
    var totalSize = size.int64Value
    var latest = modified.timeIntervalSince1970
    if let wal = try? manager.attributesOfItem(atPath: path + "-wal") {
      totalSize += (wal[.size] as? NSNumber)?.int64Value ?? 0
      if let walModified = wal[.modificationDate] as? Date {
        latest = max(latest, walModified.timeIntervalSince1970)
      }
    }
    return TokenSourceFile(path: path, size: totalSize, modified: latest)
  }
}
