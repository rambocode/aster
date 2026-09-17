// 远端目录列表：POSIX sh 采集脚本、记录模型与字节级解析器。纯逻辑，不依赖 AppKit 与网络。

import Foundation

// MARK: - 模型

/// 远端目录项的类型。`symlink` 指链接自身；链接目标是否为目录由 `targetIsDirectory` 表达。
public enum RemoteDirectoryEntryKind: String, Equatable, Sendable {
  case file
  case directory
  case symlink
  case other

  /// 把远端脚本输出的单字符类型码映射成枚举；未知码一律归为 `other`。
  public static func from(typeCode: String) -> RemoteDirectoryEntryKind {
    switch typeCode {
    case "f": return .file
    case "d": return .directory
    case "l": return .symlink
    default: return .other
    }
  }
}

/// 远端目录中的一项。所有字段都来自远端脚本的一条记录，本地不再访问文件系统。
public struct RemoteDirectoryEntry: Equatable, Sendable {
  /// 文件名（不含目录部分）。非法 UTF-8 已有损解码，见 `nameDecodedLossy`。
  public var name: String
  /// 条目自身的类型（不跟随符号链接）。
  public var kind: RemoteDirectoryEntryKind
  /// 跟随符号链接后目标是否为目录；非链接时等价于 `kind == .directory`。
  public var targetIsDirectory: Bool
  /// 条目自身的字节大小（符号链接为链接本身的大小）。
  public var size: Int64
  /// 修改时间，秒级精度。
  public var modifiedAt: Date
  /// 权限位（八进制低三位，如 `0o755`）。
  public var mode: UInt16
  /// 是否为点开头的隐藏项；是否显示由调用方决定。
  public var isHidden: Bool
  /// 名字含非法 UTF-8 字节并经过有损解码；此类条目禁止进入或下载。
  public var nameDecodedLossy: Bool

  public init(
    name: String,
    kind: RemoteDirectoryEntryKind,
    targetIsDirectory: Bool,
    size: Int64,
    modifiedAt: Date,
    mode: UInt16,
    isHidden: Bool,
    nameDecodedLossy: Bool
  ) {
    self.name = name
    self.kind = kind
    self.targetIsDirectory = targetIsDirectory
    self.size = size
    self.modifiedAt = modifiedAt
    self.mode = mode
    self.isHidden = isHidden
    self.nameDecodedLossy = nameDecodedLossy
  }

  /// 双击是否应当进入：目录或指向目录的链接，且名字可靠。
  public var isNavigable: Bool {
    targetIsDirectory && !nameDecodedLossy
  }
}

/// 一次目录列表的结果。`totalCount` 是远端在截断前统计的近似总数。
public struct RemoteDirectoryListing: Equatable, Sendable {
  /// 远端解析后的绝对目录（`pwd -P`）。
  public var directory: String
  /// 已解析出的条目，含隐藏项；顺序与远端输出一致，排序由 UI 负责。
  public var entries: [RemoteDirectoryEntry]
  /// 远端统计的条目总数（截断前）。
  public var totalCount: Int
  /// 结果被任一层上限截断（远端字节上限、解析条目上限或记录被切断）。
  public var isTruncated: Bool

  public init(directory: String, entries: [RemoteDirectoryEntry], totalCount: Int, isTruncated: Bool) {
    self.directory = directory
    self.entries = entries
    self.totalCount = totalCount
    self.isTruncated = isTruncated
  }
}

/// 目录列表失败原因。远端 `error=` 码与本地解析失败都归到这里。
public enum RemoteDirectoryListingError: Error, Equatable, Sendable {
  /// 路径不存在。
  case missing
  /// 路径存在但不是目录。
  case notDirectory
  /// 无权进入或读取目录。
  case permissionDenied
  /// 输出不符合协议（缺首行、缺 `dir=`、分隔符错误等）。
  case malformed(String)
  /// 远端报了一个本地不认识的 `error=` 码。
  case remoteFailure(String)
}

// MARK: - 脚本

/// 生成远端目录列表脚本的 argv。目录只经 `$1` 传入，绝不拼进脚本文本。
public enum RemoteDirectoryListingScript {
  /// 远端输出字节上限（`head -c`），与解析器的条目上限共同构成三层截断保护。
  public static let remoteByteLimit = 1_048_576

  /// 返回 `["/bin/sh", "-c", <script>, "sh", <directory>]`。
  ///
  /// 目录放在 `$1`：远端登录 Shell 只看到脚本文本与一个独立参数，任何文件名字符
  /// （引号、`$`、换行）都不可能被二次解析成命令。
  public static func command(directory: String) -> [String] {
    ["/bin/sh", "-c", script, "sh", directory]
  }

  /// 采集脚本。GNU `find -printf` 是主路径，BSD/macOS 用 `stat -f` 回退；
  /// 记录以 NUL 分隔、名字放最后，因此文件名里的 tab 与换行都不会破坏分帧。
  public static let script = #"""
  dir=$1
  [ -n "$dir" ] || dir=.
  printf 'ASTER_LS_V1\n'
  if [ ! -e "$dir" ]; then printf 'error=missing\n'; exit 2; fi
  if [ ! -d "$dir" ]; then printf 'error=notdir\n'; exit 2; fi
  cd -P -- "$dir" 2>/dev/null || { printf 'error=denied\n'; exit 2; }
  [ -r . ] || { printf 'error=denied\n'; exit 2; }
  printf 'dir=%s\n' "$(pwd -P)"
  if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
    total=$(find . -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c)
    printf 'count=%s\n---\n' "$((total))"
    find . -mindepth 1 -maxdepth 1 -printf '%y\t%Y\t%s\t%T@\t%m\t%f\0' 2>/dev/null | head -c 1048576
  else
    total=$(find . -mindepth 1 -maxdepth 1 -exec sh -c 'printf "%.0s." "$@"' sh {} + 2>/dev/null | wc -c)
    printf 'count=%s\n---\n' "$((total))"
    find . -mindepth 1 -maxdepth 1 -exec sh -c '
  tab=$(printf "\t")
  for p in "$@"; do
    n=${p#./}
    if [ -h "$p" ]; then t=l
    elif [ -d "$p" ]; then t=d
    elif [ -f "$p" ]; then t=f
    else t=o
    fi
    if [ -d "$p" ]; then y=d
    elif [ -f "$p" ]; then y=f
    else y=o
    fi
    meta=$(stat -f "%z${tab}%m${tab}%Lp" "$p" 2>/dev/null) || meta=""
    [ -n "$meta" ] || meta="0${tab}0${tab}0"
    printf "%s\t%s\t%s\t%s\0" "$t" "$y" "$meta" "$n"
  done' sh {} + 2>/dev/null | head -c 1048576
  fi
  """#
}

// MARK: - 解析

/// 把远端脚本输出的字节流解析成 `RemoteDirectoryListing`。
///
/// 全程按字节处理：文件名可能不是合法 UTF-8，先分帧再解码，避免解码失败带走整条记录。
public enum RemoteDirectoryListingParser {
  /// 本地解析的条目上限；超过即视为截断。
  public static let maximumEntryCount = 2000

  private static let newline: UInt8 = 0x0A
  private static let tab: UInt8 = 0x09
  private static let nul: UInt8 = 0x00

  public static func parse(_ data: Data) throws -> RemoteDirectoryListing {
    let (header, bodyStart) = splitHeader(data)
    guard header.first == "ASTER_LS_V1" else {
      throw RemoteDirectoryListingError.malformed("missing header")
    }
    if let code = header.first(where: { $0.hasPrefix("error=") })?.dropFirst("error=".count) {
      throw error(for: String(code))
    }
    guard let directory = header.first(where: { $0.hasPrefix("dir=") })?.dropFirst("dir=".count) else {
      throw RemoteDirectoryListingError.malformed("missing dir")
    }
    guard let bodyStart else {
      throw RemoteDirectoryListingError.malformed("missing separator")
    }
    let totalCount = header
      .first(where: { $0.hasPrefix("count=") })
      .flatMap { Int($0.dropFirst("count=".count)) } ?? 0

    var entries: [RemoteDirectoryEntry] = []
    var truncated = false
    var cursor = bodyStart
    while cursor < data.endIndex {
      guard let terminator = data[cursor...].firstIndex(of: nul) else {
        // 没有收尾 NUL 说明远端字节上限切在记录中间，这条不完整必须丢弃。
        if data[cursor...].contains(where: { $0 != newline }) { truncated = true }
        break
      }
      let record = data[cursor..<terminator]
      cursor = data.index(after: terminator)
      if record.isEmpty { continue }
      if entries.count >= maximumEntryCount {
        truncated = true
        break
      }
      if let entry = parseRecord(record) { entries.append(entry) }
    }

    return RemoteDirectoryListing(
      directory: String(directory),
      entries: entries,
      totalCount: max(totalCount, entries.count),
      isTruncated: truncated || entries.count < totalCount
    )
  }

  /// 按行切出 `---` 之前的头部；返回正文起点，缺分隔行时为 nil。
  private static func splitHeader(_ data: Data) -> (header: [String], bodyStart: Data.Index?) {
    var header: [String] = []
    var cursor = data.startIndex
    while cursor < data.endIndex {
      guard let lineEnd = data[cursor...].firstIndex(of: newline) else {
        header.append(decodeLossy(data[cursor...]))
        return (header, nil)
      }
      let line = decodeLossy(data[cursor..<lineEnd])
      cursor = data.index(after: lineEnd)
      if line == "---" { return (header, cursor) }
      header.append(line)
    }
    return (header, nil)
  }

  /// 一条记录：前 5 个 tab 切出固定字段，其余全部是文件名。
  private static func parseRecord(_ record: Data) -> RemoteDirectoryEntry? {
    var fields: [String] = []
    var cursor = record.startIndex
    for _ in 0..<5 {
      guard let separator = record[cursor...].firstIndex(of: tab) else { return nil }
      fields.append(decodeLossy(record[cursor..<separator]))
      cursor = record.index(after: separator)
    }
    let nameBytes = record[cursor...]
    guard !nameBytes.isEmpty else { return nil }
    let (name, lossy) = decodeName(nameBytes)
    // `.`、`..` 与含 `/` 的名字不可能是正常的单层条目，出现即说明输出被污染。
    guard name != ".", name != "..", !name.contains("/") else { return nil }

    let kind = RemoteDirectoryEntryKind.from(typeCode: fields[0])
    let targetIsDirectory = fields[1] == "d"
    let size = Int64(fields[2]) ?? 0
    // GNU `%T@` 是 `秒.纳秒`，只取整数秒；BSD `stat -f %m` 本来就是整数。
    let seconds = Double(fields[3].split(separator: ".").first.map(String.init) ?? fields[3]) ?? 0
    let mode = UInt16(fields[4], radix: 8) ?? 0

    return RemoteDirectoryEntry(
      name: name,
      kind: kind,
      targetIsDirectory: targetIsDirectory,
      size: size,
      modifiedAt: Date(timeIntervalSince1970: seconds),
      mode: mode,
      isHidden: name.hasPrefix("."),
      nameDecodedLossy: lossy
    )
  }

  /// 文件名解码：合法 UTF-8 原样返回，否则有损解码并打标记。
  private static func decodeName(_ bytes: Data) -> (String, Bool) {
    if let text = String(data: Data(bytes), encoding: .utf8) { return (text, false) }
    return (String(decoding: Data(bytes), as: UTF8.self), true)
  }

  private static func decodeLossy(_ bytes: Data) -> String {
    String(decoding: Data(bytes), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
  }

  private static func error(for code: String) -> RemoteDirectoryListingError {
    switch code {
    case "missing": return .missing
    case "notdir": return .notDirectory
    case "denied": return .permissionDenied
    default: return .remoteFailure(code)
    }
  }
}
