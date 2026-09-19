// 各 Agent 的 JSONL / JSON 数据源共用的逐行扫描、取数与时间换算工具。
import Foundation

/// JSONL 数据源的公共读取工具。全部为静态方法，无状态，可在后台线程自由调用。
enum JSONLTokenScanner {
  /// 逐行遍历文件，把每一行的字节切片交给 `body`。读不到文件时静默返回。
  ///
  /// 用 `.mappedIfSafe` 而不是整体读进堆：Pi 的会话目录有上千个文件、合计上百 MB，
  /// 映射后按行切片可以让未命中预筛的行完全不进入解码路径。
  static func forEachLine(inFileAt path: String, _ body: (Data) -> Void) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    else { return }
    var start = data.startIndex
    while start < data.endIndex {
      let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
      if end > start { body(data[start..<end]) }
      start = end < data.endIndex ? data.index(after: end) : data.endIndex
    }
  }

  /// 廉价的字节子串预筛：`line` 是否包含 `needle`。
  ///
  /// 先用它挡掉无关行，再做 `JSONSerialization`；反序列化一行 JSON 比扫一遍字节贵得多，
  /// 而这些文件里绝大多数行（工具输出、正文分片）都不带用量字段。
  static func contains(_ line: Data, _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, line.count >= needle.count else { return false }
    // 走裸指针而不是 Data 的下标：这段代码要扫过上百 MB，Data 的索引校验开销会主导耗时。
    return line.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
      let first = needle[0]
      let limit = raw.count - needle.count
      var index = 0
      while index <= limit {
        if base[index] == first {
          var offset = 1
          while offset < needle.count, base[index + offset] == needle[offset] { offset += 1 }
          if offset == needle.count { return true }
        }
        index += 1
      }
      return false
    }
  }

  /// 把一行 JSON 解码成字典；畸形或写了一半的行返回 `nil`，不抛错。
  static func object(_ line: Data) -> [String: Any]? {
    guard let any = try? JSONSerialization.jsonObject(with: line) else { return nil }
    return any as? [String: Any]
  }

  /// 读取嵌套字典。
  static func dictionary(_ container: [String: Any]?, _ key: String) -> [String: Any]? {
    container?[key] as? [String: Any]
  }

  /// 把 JSON 数字取成 `Int64`；缺失、类型不符或负数一律归零，保证累加不被脏数据拉穿。
  static func int64(_ value: Any?) -> Int64 {
    switch value {
    case let number as NSNumber: return max(0, number.int64Value)
    case let text as String: return max(0, Int64(text) ?? 0)
    default: return 0
    }
  }

  /// 解析 `2026-06-20T17:21:35.633Z` 形式的时间戳，返回 Unix 秒。
  ///
  /// 不用 `ISO8601DateFormatter`：它要为每个数据源各建一份实例（非 Sendable），
  /// 且单条解析开销远高于这里的定长切分，而本机要过的记录是十万量级。
  static func epochSeconds(iso8601 text: String) -> Int64? {
    let bytes = Array(text.utf8)
    guard bytes.count >= 19 else { return nil }
    func number(_ range: Range<Int>) -> Int? {
      var value = 0
      for index in range {
        let digit = Int(bytes[index]) - 48
        guard (0...9).contains(digit) else { return nil }
        value = value * 10 + digit
      }
      return value
    }
    guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
      let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
      (1...12).contains(month)
    else { return nil }
    var seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
    seconds += Int64(hour * 3600 + minute * 60 + second)
    // 时区后缀：`Z` 或 `±HH:MM`。偏移量要反向加回，把本地时刻还原成 UTC。
    if let signIndex = bytes.lastIndex(where: { $0 == 0x2B || $0 == 0x2D }), signIndex >= 19,
      bytes.count >= signIndex + 6, let offsetHour = number((signIndex + 1)..<(signIndex + 3)),
      let offsetMinute = number((signIndex + 4)..<(signIndex + 6))
    {
      let offset = Int64(offsetHour * 3600 + offsetMinute * 60)
      seconds += bytes[signIndex] == 0x2B ? -offset : offset
    }
    return seconds
  }

  /// Howard Hinnant 的 days_from_civil：把公历日期换成自 1970-01-01 起的天数。
  private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
    let shiftedYear = year - (month <= 2 ? 1 : 0)
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return Int64(era) * 146_097 + Int64(dayOfEra) - 719_468
  }

  /// 按 URL 读取大小与修改时间，组装成缓存身份。读不到属性时返回 `nil`。
  static func sourceFile(at url: URL) -> TokenSourceFile? {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard let size = values?.fileSize, let modified = values?.contentModificationDate else {
      return nil
    }
    return TokenSourceFile(
      path: url.path, size: Int64(size), modified: modified.timeIntervalSince1970)
  }

  /// 列出目录下的直接子项；目录不存在时返回空数组。
  static func entries(of directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
      ?? []
  }

  /// `entries(of:)` 的子目录版本。Grok 会在 `sessions/` 下混放 sqlite 文件，必须过滤。
  static func subdirectories(of directory: URL) -> [URL] {
    entries(of: directory).filter {
      (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
  }

  /// 把 (日 → 四列) 的中间结果摊平成 bucket 数组，丢掉全零项。
  static func buckets(from totalsByDay: [Int: TokenTotals], project: String) -> [TokenBucket] {
    totalsByDay.compactMap { day, totals in
      totals.isEmpty ? nil : TokenBucket(day: day, project: project, totals: totals)
    }
  }
}
