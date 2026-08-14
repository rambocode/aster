import Foundation

/// tools/call 参数的取值与清洗层。
///
/// MCP 参数完全来自外部 Agent（不可信输入），所以每个字符串在进入 SQL 查询或
/// 渲染文本之前都必须：剥离控制字符 → 去首尾空白 → 按 UTF-8 字节限长。
/// 参数缺失或非法一律抛 `ToolArgumentError`，由 dispatch 层转成 `isError` 结果。
enum MCPArguments {
  /// 路径类参数的上限，与 `DetectedTarget` 的 4096 字节上限同源。
  static let maximumPathBytes = 4_096
  /// 查询词上限：FTS 只取前 8 个 token，再长既无意义又会拖慢渲染。
  static let maximumQueryBytes = 512
  /// 工具名上限：足够长的合法名，同时挡住超长垃圾串进入错误文案。
  static let maximumNameBytes = 128

  /// 取字符串参数并清洗；缺失或清洗后为空时返回 nil（调用方决定是否必需）。
  static func string(
    _ arguments: JSONValue?, _ key: String, maximumBytes: Int = maximumPathBytes
  ) -> String? {
    guard let raw = arguments?[key]?.stringValue else { return nil }
    let cleaned = sanitize(raw, maximumBytes: maximumBytes)
    return cleaned.isEmpty ? nil : cleaned
  }

  /// 取必需字符串参数，缺失即抛错。
  static func requiredString(
    _ arguments: JSONValue?, _ key: String, maximumBytes: Int = maximumPathBytes
  ) throws -> String {
    guard let value = string(arguments, key, maximumBytes: maximumBytes) else {
      throw ToolArgumentError("missing required argument: \(key)")
    }
    return value
  }

  /// 取整数参数并夹到合法区间。Agent 偶尔会把数字写成字符串，两种形态都接受。
  static func integer(
    _ arguments: JSONValue?, _ key: String, default fallback: Int, minimum: Int, maximum: Int
  ) -> Int {
    let raw = arguments?[key]?.intValue ?? arguments?[key]?.stringValue.flatMap(Int.init)
    guard let raw else { return fallback }
    return min(max(raw, minimum), maximum)
  }

  /// 取 UUID 参数；存在但不是合法 UUID 时抛错，避免把垃圾串当作「查不到」静默返回。
  static func uuid(_ arguments: JSONValue?, _ key: String) throws -> UUID? {
    guard let raw = string(arguments, key, maximumBytes: 64) else { return nil }
    guard let value = UUID(uuidString: raw) else {
      throw ToolArgumentError("invalid \(key): expected a UUID, got \"\(raw)\"")
    }
    return value
  }

  /// 剥离全部控制字符（含 DEL）、trim，再按 UTF-8 字节截断。
  /// 参数是单行值，因此换行与制表符也一并去掉，防止污染渲染文本与错误文案。
  static func sanitize(_ raw: String, maximumBytes: Int) -> String {
    let filtered = String(
      String.UnicodeScalarView(
        raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    return truncated(
      filtered.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: maximumBytes)
  }

  /// 按 UTF-8 字节安全截断：逐个丢弃末尾 Character，绝不在多字节序列中间切断。
  static func truncated(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    var result = value
    while result.utf8.count > maximumBytes, !result.isEmpty {
      result.removeLast()
    }
    return result
  }
}

/// 参数层的可读错误。dispatch 层把它渲染成 MCP tool result 的 `isError` 文本，
/// 而不是 JSON-RPC 层错误 —— Agent 需要看到「哪个参数错了」并自行重试。
struct ToolArgumentError: Error {
  let message: String

  init(_ message: String) {
    self.message = message
  }
}
