// JSONL 文件的零拷贝行切分与字节层预筛工具。移植自 jettoai/tally（MIT）的 TokenStatsParser 字节辅助部分。
import Foundation

/// 按行读取 JSONL 的底层工具：内存映射 + `memchr` 切行 + `memmem` 预筛。
///
/// 所有数据源共用这一套：先用子串测试挡掉约 95% 不含 token 计数的行，再做结构化解析。
/// 全程只传 `UnsafeRawBufferPointer` 的下标范围，不构造 String，也不复制字节。
public enum TokenLineReader {
  /// 以 `mappedIfSafe` 映射文件并把整段字节交给 `body`。文件读不到或为空时返回 nil。
  ///
  /// 映射而不是读入：语料可能有若干 GB，逐个文件 `Data(contentsOf:)` 会把它们全部拷进常驻内存。
  public static func withMappedBytes<R>(
    atPath path: String, _ body: (UnsafeRawBufferPointer) -> R
  ) -> R? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
      !data.isEmpty
    else { return nil }
    return data.withUnsafeBytes { raw in body(raw) }
  }

  /// 按换行切分缓冲区，不复制。空行直接跳过。
  public static func forEachLine(_ raw: UnsafeRawBufferPointer, _ body: (Range<Int>) -> Void) {
    guard let base = raw.baseAddress else { return }
    var start = 0
    while start < raw.count {
      let remaining = raw.count - start
      let newline = memchr(base + start, 0x0A, remaining)
      let end = newline.map { UnsafeRawPointer($0) - base } ?? raw.count
      if end > start { body(start..<end) }
      start = end + 1
    }
  }

  /// 某段字节里是否出现过某个字面量子串。用于在结构化解析之前快速排除整行。
  public static func contains(
    _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ needle: StaticString
  ) -> Bool {
    guard let base = raw.baseAddress, range.count >= needle.utf8CodeUnitCount else { return false }
    return memmem(base + range.lowerBound, range.count, needle.utf8Start, needle.utf8CodeUnitCount)
      != nil
  }

  /// 值的原始字节与字面量（含引号）完全相等。这样判断字符串值不需要先把它构造成 String。
  public static func matches(
    _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ literal: StaticString
  ) -> Bool {
    guard range.count == literal.utf8CodeUnitCount, let base = raw.baseAddress else { return false }
    return memcmp(base + range.lowerBound, literal.utf8Start, range.count) == 0
  }

  /// 某段字节的 64 位 FNV-1a 指纹，用作 `message.id` 的去重 key。
  ///
  /// 就地哈希是为了避免给上百万条 usage 记录各造一个 String；单文件里只有几千个 id，
  /// 撞哈希的概率远低于一次磁盘错误。
  public static func fingerprint(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for i in range {
      hash ^= UInt64(raw[i])
      hash &*= 0x0000_0100_0000_01b3
    }
    return hash
  }
}
