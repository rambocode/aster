import AsterCore
import Foundation

/// Context Receipt 的写入面。这是单写者约定的**唯一例外**：MCP server 是独立进程，
/// 需要在每次 tools/call 后留痕。为把冲突面压到最小，这里只：
/// - 打开短生命周期的读写连接，写一行后立刻关闭；
/// - 只触碰 `context_receipts` 一张表，不参与任何其它写入；
/// - 失败静默返回（留痕失败绝不能让 Agent 的查询失败）。
public enum ContextReceiptWriter {
  /// 追加一条 receipt。数据库不存在或被占用时直接放弃。
  public static func append(_ receipt: ContextReceipt, location: MemoryStoreLocation) {
    guard FileManager.default.fileExists(atPath: location.databaseURL.path) else { return }
    guard let database = try? MemoryDatabase(path: location.databaseURL.path) else { return }
    // schema 不匹配时不写：宁可缺一条 receipt，也不要往未知结构里塞数据。
    guard let version = try? database.userVersion(), version == MemorySchema.currentVersion
    else { return }
    try? database.run(
      """
      INSERT OR REPLACE INTO context_receipts
        (id, project_path, task_id, session_id, at, trigger, query, memory_ids,
         token_estimate, delivery_method)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(receipt.id.uuidString),
        receipt.projectPath.map(MemoryDatabase.Value.text) ?? .null,
        receipt.taskID.map { MemoryDatabase.Value.text($0.uuidString) } ?? .null,
        receipt.sessionID.map { MemoryDatabase.Value.text($0.uuidString) } ?? .null,
        .real(receipt.timestamp.timeIntervalSince1970),
        .text(receipt.trigger),
        receipt.query.map(MemoryDatabase.Value.text) ?? .null,
        .text(receipt.memoryIDs.joined(separator: ",")),
        .integer(Int64(receipt.tokenEstimate)),
        .text(receipt.deliveryMethod),
      ]
    )
  }
}
