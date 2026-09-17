import Foundation
import Testing

@testable import AsterCore

/// 远端目录列表：argv 形状、GNU / BSD 两种输出、错误码、截断判定与非法 UTF-8 名字。

// MARK: - 夹具

/// 拼一条 NUL 结尾的记录；名字放最后，允许含 tab 与换行。
private func listingRecord(
  type: String,
  target: String,
  size: String,
  mtime: String,
  mode: String,
  name: String
) -> Data {
  var data = Data([type, target, size, mtime, mode].joined(separator: "\t").utf8)
  data.append(0x09)
  data.append(Data(name.utf8))
  data.append(0x00)
  return data
}

/// 拼完整输出：头部 + `---` + 记录。
private func listingPayload(
  directory: String = "/home/mike",
  count: Int,
  records: [Data],
  dropFinalTerminator: Bool = false
) -> Data {
  var data = Data("ASTER_LS_V1\ndir=\(directory)\ncount=\(count)\n---\n".utf8)
  for record in records { data.append(record) }
  if dropFinalTerminator, data.last == 0x00 { data.removeLast() }
  return data
}

// MARK: - argv

@Test func remoteDirectoryListingScriptPassesDirectoryOnlyAsArgument() {
  let argv = RemoteDirectoryListingScript.command(directory: "/tmp/a b; rm -rf /")
  #expect(argv[0] == "/bin/sh")
  #expect(argv[1] == "-c")
  #expect(argv[2] == RemoteDirectoryListingScript.script)
  #expect(argv[3] == "sh")
  #expect(argv[4] == "/tmp/a b; rm -rf /")
  #expect(argv.count == 5)
  // 目录绝不能出现在脚本文本里，否则文件名就成了可执行代码。
  #expect(!RemoteDirectoryListingScript.script.contains("/tmp/a b"))
}

// MARK: - GNU 主路径

@Test func remoteDirectoryListingParsesGNUOutput() throws {
  let records = [
    listingRecord(type: "f", target: "f", size: "1024", mtime: "1700000000.1234", mode: "644", name: "a b"),
    listingRecord(type: "f", target: "f", size: "3", mtime: "1700000001.0", mode: "600", name: "x\ty"),
    listingRecord(type: "f", target: "f", size: "5", mtime: "1700000002.0", mode: "644", name: "新建\n文件"),
    listingRecord(type: "l", target: "d", size: "7", mtime: "1700000003.0", mode: "777", name: "link"),
    listingRecord(type: "l", target: "N", size: "9", mtime: "1700000004.0", mode: "777", name: "broken"),
    listingRecord(type: "d", target: "d", size: "4096", mtime: "1700000005.0", mode: "755", name: ".hidden"),
  ]
  let listing = try RemoteDirectoryListingParser.parse(listingPayload(count: 6, records: records))

  #expect(listing.directory == "/home/mike")
  #expect(listing.entries.count == 6)
  #expect(listing.isTruncated == false)

  #expect(listing.entries[0].name == "a b")
  #expect(listing.entries[0].kind == .file)
  #expect(listing.entries[0].size == 1024)
  #expect(listing.entries[0].mode == 0o644)
  // `%T@` 的小数部分要丢掉，只保留整数秒。
  #expect(listing.entries[0].modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
  #expect(listing.entries[0].isHidden == false)

  #expect(listing.entries[1].name == "x\ty")
  #expect(listing.entries[2].name == "新建\n文件")

  #expect(listing.entries[3].kind == .symlink)
  #expect(listing.entries[3].targetIsDirectory == true)
  #expect(listing.entries[3].isNavigable == true)
  #expect(listing.entries[4].kind == .symlink)
  #expect(listing.entries[4].targetIsDirectory == false)

  #expect(listing.entries[5].kind == .directory)
  #expect(listing.entries[5].isHidden == true)
  #expect(listing.entries[5].mode == 0o755)
}

@Test func remoteDirectoryListingDecodesInvalidUTF8NameLossily() throws {
  var record = Data("f\tf\t1\t1700000000\t644\t".utf8)
  record.append(contentsOf: [0x62, 0x61, 0x64, 0xFF, 0xFE])
  record.append(0x00)
  let listing = try RemoteDirectoryListingParser.parse(listingPayload(count: 1, records: [record]))

  #expect(listing.entries.count == 1)
  #expect(listing.entries[0].nameDecodedLossy == true)
  #expect(listing.entries[0].name.hasPrefix("bad"))
  // 名字不可靠的条目禁止进入或下载。
  #expect(listing.entries[0].isNavigable == false)
}

// MARK: - BSD 回退

@Test func remoteDirectoryListingParsesBSDOutput() throws {
  // BSD 回退用 `stat -f`：mtime 是整数秒，mode 是三位八进制，`./` 前缀已在远端剥掉。
  let records = [
    listingRecord(type: "d", target: "d", size: "64", mtime: "1789659892", mode: "755", name: "sub"),
    listingRecord(type: "l", target: "d", size: "3", mtime: "1789659892", mode: "755", name: "link-to-dir"),
    listingRecord(type: "o", target: "o", size: "0", mtime: "1789659892", mode: "660", name: "pipe"),
  ]
  let listing = try RemoteDirectoryListingParser.parse(
    listingPayload(directory: "/private/tmp/x", count: 3, records: records)
  )

  #expect(listing.directory == "/private/tmp/x")
  #expect(listing.entries.map(\.name) == ["sub", "link-to-dir", "pipe"])
  #expect(listing.entries[2].kind == .other)
  #expect(listing.entries[0].modifiedAt == Date(timeIntervalSince1970: 1_789_659_892))
}

// MARK: - 错误

@Test func remoteDirectoryListingMapsRemoteErrorCodes() {
  func failure(_ code: String) -> RemoteDirectoryListingError? {
    let data = Data("ASTER_LS_V1\nerror=\(code)\n".utf8)
    do {
      _ = try RemoteDirectoryListingParser.parse(data)
      return nil
    } catch let error as RemoteDirectoryListingError {
      return error
    } catch {
      return nil
    }
  }
  #expect(failure("missing") == .missing)
  #expect(failure("notdir") == .notDirectory)
  #expect(failure("denied") == .permissionDenied)
  #expect(failure("weird") == .remoteFailure("weird"))
}

@Test func remoteDirectoryListingRejectsOutputWithoutHeader() {
  // 登录 Shell 往 stdout 打横幅是最常见的污染来源，必须整条拒绝而不是硬解析。
  let data = Data("Welcome to Ubuntu\ndir=/home\ncount=0\n---\n".utf8)
  #expect(throws: RemoteDirectoryListingError.malformed("missing header")) {
    _ = try RemoteDirectoryListingParser.parse(data)
  }
}

@Test func remoteDirectoryListingRejectsOutputWithoutSeparator() {
  let data = Data("ASTER_LS_V1\ndir=/home\ncount=0\n".utf8)
  #expect(throws: RemoteDirectoryListingError.malformed("missing separator")) {
    _ = try RemoteDirectoryListingParser.parse(data)
  }
}

// MARK: - 截断

@Test func remoteDirectoryListingMarksTruncationWhenCountExceedsEntries() throws {
  let records = [
    listingRecord(type: "f", target: "f", size: "1", mtime: "1700000000", mode: "644", name: "a")
  ]
  let listing = try RemoteDirectoryListingParser.parse(listingPayload(count: 42, records: records))
  #expect(listing.entries.count == 1)
  #expect(listing.totalCount == 42)
  #expect(listing.isTruncated == true)
}

@Test func remoteDirectoryListingDropsRecordCutByByteLimit() throws {
  let records = [
    listingRecord(type: "f", target: "f", size: "1", mtime: "1700000000", mode: "644", name: "a"),
    listingRecord(type: "f", target: "f", size: "2", mtime: "1700000000", mode: "644", name: "bcd"),
  ]
  // 远端 `head -c` 可能切在记录中间：这条没有收尾 NUL，必须丢弃并标记截断。
  let listing = try RemoteDirectoryListingParser.parse(
    listingPayload(count: 2, records: records, dropFinalTerminator: true)
  )
  #expect(listing.entries.map(\.name) == ["a"])
  #expect(listing.isTruncated == true)
}

@Test func remoteDirectoryListingStopsAtEntryLimit() throws {
  let total = RemoteDirectoryListingParser.maximumEntryCount + 25
  let records = (0..<total).map {
    listingRecord(type: "f", target: "f", size: "1", mtime: "1700000000", mode: "644", name: "f\($0)")
  }
  let listing = try RemoteDirectoryListingParser.parse(listingPayload(count: total, records: records))
  #expect(listing.entries.count == RemoteDirectoryListingParser.maximumEntryCount)
  #expect(listing.isTruncated == true)
  #expect(listing.totalCount == total)
}

@Test func remoteDirectoryListingSkipsMalformedRecords() throws {
  var short = Data("f\tf\t1\n".utf8)
  short.append(0x00)
  let good = listingRecord(
    type: "f", target: "f", size: "1", mtime: "1700000000", mode: "644", name: "ok"
  )
  let listing = try RemoteDirectoryListingParser.parse(
    listingPayload(count: 1, records: [short, good])
  )
  #expect(listing.entries.map(\.name) == ["ok"])
}

// MARK: - 真实脚本（本机 BSD 回退路径）

@Test func remoteDirectoryListingScriptRunsAgainstRealShell() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-listing-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  try Data("hello".utf8).write(to: root.appendingPathComponent("a b"))
  try Data("12345".utf8).write(to: root.appendingPathComponent("x\ty"))
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("sub"), withIntermediateDirectories: true
  )
  try FileManager.default.createSymbolicLink(
    atPath: root.appendingPathComponent("link").path, withDestinationPath: "sub"
  )
  try Data().write(to: root.appendingPathComponent(".hidden"))

  let argv = RemoteDirectoryListingScript.command(directory: root.path)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: argv[0])
  process.arguments = Array(argv.dropFirst())
  let pipe = Pipe()
  process.standardOutput = pipe
  try process.run()
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  let listing = try RemoteDirectoryListingParser.parse(output)
  #expect(listing.totalCount == 5)
  #expect(listing.isTruncated == false)
  let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
  #expect(byName["a b"]?.size == 5)
  // 文件名里的 tab 不能破坏分帧：记录按前 5 个 tab 切，名字整段保留。
  #expect(byName["x\ty"]?.size == 5)
  #expect(byName["sub"]?.kind == .directory)
  #expect(byName["link"]?.kind == .symlink)
  #expect(byName["link"]?.targetIsDirectory == true)
  #expect(byName[".hidden"]?.isHidden == true)
}

@Test func remoteDirectoryListingScriptReportsMissingAndNotDirectory() throws {
  func run(_ path: String) throws -> Data {
    let argv = RemoteDirectoryListingScript.command(directory: path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return output
  }
  #expect(throws: RemoteDirectoryListingError.missing) {
    _ = try RemoteDirectoryListingParser.parse(try run("/no/such/path/aster"))
  }
  #expect(throws: RemoteDirectoryListingError.notDirectory) {
    _ = try RemoteDirectoryListingParser.parse(try run("/etc/hosts"))
  }
}
