import Foundation
import OSLog

/// 应用级诊断事件的严重程度。日志只记录稳定事件码和经审查的属性，不记录终端正文、
/// 路径或错误的本地化描述，避免反馈包意外携带用户工作内容。
enum DiagnosticLevel: String, Codable, Sendable {
  case debug
  case info
  case notice
  case warning
  case error
  case fault

  var osLogType: OSLogType {
    switch self {
    case .debug: .debug
    case .info: .info
    case .notice: .default
    case .warning: .error
    case .error: .error
    case .fault: .fault
    }
  }
}

/// 诊断分类对应可独立过滤的 Unified Logging category；不得以 Pane、路径或用户输入生成分类。
enum DiagnosticCategory: String, Codable, Sendable {
  case lifecycle
  case terminal
  case workspace
  case storage
  case integration
  case feedback
}

/// 反馈页展示的本地日志概览。它不读取日志正文，因此打开反馈页不会暴露或解析终端数据。
struct DiagnosticLogSummary: Sendable {
  let fileCount: Int
  let totalBytes: Int
  let oldestDate: Date?
  let newestDate: Date?
}

/// 诊断中心是 Aster 的唯一日志入口。调用方只需要给出稳定事件码、有限属性及可选错误；
/// 文件轮转、权限、脱敏、Unified Logging 和反馈归档均隐藏在实现内部。
final class DiagnosticsCenter: @unchecked Sendable {
  static let shared = DiagnosticsCenter()

  private struct BuildInfo: Codable {
    let productVersion: String
    let buildVersion: String
    let configuration: String
    let operatingSystem: String
    let architecture: String
  }

  private struct ErrorSummary: Codable {
    let type: String
    let domain: String
    let code: Int
  }

  private struct Record: Codable {
    let timestamp: Date
    let sequence: UInt64
    let sessionID: UUID
    let level: DiagnosticLevel
    let category: DiagnosticCategory
    let event: String
    let attributes: [String: String]
    let error: ErrorSummary?
    let source: String?
  }

  private struct FeedbackManifest: Codable {
    let formatVersion: Int
    let createdAt: Date
    let build: BuildInfo
    let logFileCount: Int
    let logBytes: Int
    let privacy: String
  }

  private let queue = DispatchQueue(label: "io.local.aster-terminal.diagnostics")
  private let fileManager: FileManager
  private let rootDirectory: URL
  private let sessionID = UUID()
  private let encoder: JSONEncoder
  private var didStart = false
  private var sequence: UInt64 = 0
  private var segment = 0
  private var activeURL: URL?
  private var activeHandle: FileHandle?
  private var activeBytes = 0

  private static let maximumFileBytes = 5 * 1_024 * 1_024
  private static let maximumTotalBytes = 20 * 1_024 * 1_024
  private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
  private static let maximumAttributeLength = 256
  private static let maximumEventLength = 96

  init(
    rootDirectory: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  }

  /// 显式启动用于应用入口；重复调用安全。启动失败只写 Unified Logging，不能阻止终端启动。
  func start() {
    queue.sync { startIfNeeded() }
  }

  /// 记录一个结构化事件。该调用不抛出异常，属性会过滤敏感键和控制字符。
  func record(
    _ event: String,
    level: DiagnosticLevel = .info,
    category: DiagnosticCategory,
    attributes: [String: String] = [:],
    error: Error? = nil,
    file: StaticString = #fileID,
    line: UInt = #line,
    function: StaticString = #function
  ) {
    let safeEvent = Self.normalizedEvent(event)
    let safeAttributes = Self.sanitizedAttributes(attributes)
    let errorSummary = error.map(Self.summarize)
    let source = Self.sourceLocation(file: file, line: line, function: function)
    let logger = Logger(subsystem: "io.local.aster-terminal", category: category.rawValue)
    logger.log(level: level.osLogType, "\(safeEvent, privacy: .public)")

    queue.async { [weak self] in
      guard let self else { return }
      self.startIfNeeded()
      self.sequence &+= 1
      let record = Record(
        timestamp: Date(), sequence: self.sequence, sessionID: self.sessionID,
        level: level, category: category, event: safeEvent, attributes: safeAttributes,
        error: errorSummary, source: source
      )
      self.append(record)
    }
  }

  /// 在退出路径刷新文件。即便没有磁盘权限，结束事件仍会进入 Unified Logging。
  func finish(reason: String) {
    record("application.finished", level: .notice, category: .lifecycle, attributes: ["reason": reason])
    queue.sync { self.activeHandle?.synchronizeFile() }
  }

  func summary() -> DiagnosticLogSummary {
    queue.sync {
      startIfNeeded()
      let files = diagnosticFiles()
      return DiagnosticLogSummary(
        fileCount: files.count,
        totalBytes: files.reduce(0) { $0 + ($1.size ?? 0) },
        oldestDate: files.compactMap(\.modified).min(),
        newestDate: files.compactMap(\.modified).max()
      )
    }
  }

  /// 返回日志目录，并确保目录存在。调用方可用 Finder 打开它，但不会取得其它应用文件。
  func logsDirectory() throws -> URL {
    try queue.sync {
      startIfNeeded()
      guard fileManager.fileExists(atPath: rootDirectory.path) else {
        throw CocoaError(.fileNoSuchFile)
      }
      return rootDirectory
    }
  }

  /// 创建仅含 Aster 自有日志和脱敏清单的 ZIP。调用方应在后台任务执行该方法。
  func makeFeedbackArchive(note: String) throws -> URL {
    let snapshot: ([DiagnosticFile], BuildInfo) = queue.sync {
      startIfNeeded()
      activeHandle?.synchronizeFile()
      return (diagnosticFiles(), Self.buildInfo())
    }
    let files = snapshot.0
    let totalBytes = files.reduce(0) { $0 + ($1.size ?? 0) }
    guard totalBytes <= Self.maximumTotalBytes else { throw CocoaError(.fileReadTooLarge) }

    let identifier = UUID().uuidString.lowercased()
    let staging = fileManager.temporaryDirectory.appendingPathComponent(
      "Aster-Diagnostics-Staging-\(identifier)", isDirectory: true)
    let contents = staging.appendingPathComponent("Aster-Diagnostics", isDirectory: true)
    let archive = fileManager.temporaryDirectory.appendingPathComponent(
      "Aster-Diagnostics-\(Self.archiveTimestamp())-\(identifier.prefix(8)).zip")
    defer { try? fileManager.removeItem(at: staging) }

    try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: contents.path)
    for file in files {
      try Self.validateOwnedLog(file.url, fileManager: fileManager)
      let destination = contents.appendingPathComponent(file.url.lastPathComponent)
      try fileManager.copyItem(at: file.url, to: destination)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    let manifest = FeedbackManifest(
      formatVersion: 1, createdAt: Date(), build: snapshot.1, logFileCount: files.count, logBytes: totalBytes,
      privacy: "No terminal input/output, commands, paths, URLs, environment variables, configuration, or crash reports are included."
    )
    try writeJSON(manifest, to: contents.appendingPathComponent("manifest.json"))
    let sanitizedNote = Self.sanitizedNote(note)
    if !sanitizedNote.isEmpty {
      let noteURL = contents.appendingPathComponent("user-note.txt")
      try sanitizedNote.write(to: noteURL, atomically: true, encoding: .utf8)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noteURL.path)
    }

    try? fileManager.removeItem(at: archive)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--keepParent", contents.path, archive.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0, fileManager.fileExists(atPath: archive.path) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
    record("feedback.archive_created", level: .notice, category: .feedback, attributes: ["files": "\(files.count)"])
    return archive
  }

  /// 清理上一次分享或进程意外中断遗留的临时 ZIP；仅匹配本模块自己的固定前缀。
  func cleanStaleFeedbackArchives() {
    let temporary = fileManager.temporaryDirectory
    guard let entries = try? fileManager.contentsOfDirectory(
      at: temporary, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles])
    else { return }
    let deadline = Date().addingTimeInterval(-24 * 60 * 60)
    for url in entries where url.lastPathComponent.hasPrefix("Aster-Diagnostics-")
      && url.pathExtension == "zip"
    {
      guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
        values.isRegularFile == true, (values.contentModificationDate ?? .distantFuture) < deadline
      else { continue }
      try? fileManager.removeItem(at: url)
    }
  }

  private func startIfNeeded() {
    guard !didStart else { return }
    didStart = true
    do {
      try prepareRootDirectory()
      cleanExpiredFiles()
      try openNextSegment()
    } catch {
      Logger(subsystem: "io.local.aster-terminal", category: "diagnostics").error(
        "Unable to initialize local diagnostic logging")
    }
  }

  private func prepareRootDirectory() throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory) {
      let values = try rootDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
        throw CocoaError(.fileWriteInvalidFileName)
      }
    } else {
      try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
  }

  private func openNextSegment() throws {
    activeHandle?.closeFile()
    let name = "aster-\(sessionID.uuidString.lowercased())-\(segment).jsonl"
    segment += 1
    let url = rootDirectory.appendingPathComponent(name)
    guard fileManager.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    activeURL = url
    activeHandle = try FileHandle(forWritingTo: url)
    activeBytes = 0
  }

  private func append(_ record: Record) {
    guard let data = try? encoder.encode(record) else { return }
    let line = data + Data([0x0A])
    guard line.count <= 8 * 1_024 else { return }
    do {
      if activeHandle == nil { try openNextSegment() }
      if activeBytes + line.count > Self.maximumFileBytes { try openNextSegment() }
      try activeHandle?.write(contentsOf: line)
      activeBytes += line.count
      if record.level == .error || record.level == .fault { activeHandle?.synchronizeFile() }
      cleanExpiredFiles()
    } catch {
      Logger(subsystem: "io.local.aster-terminal", category: "diagnostics").error(
        "Unable to append a local diagnostic record")
    }
  }

  private struct DiagnosticFile {
    let url: URL
    let size: Int?
    let modified: Date?
  }

  private func diagnosticFiles() -> [DiagnosticFile] {
    guard let urls = try? fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles])
    else { return [] }
    return urls.compactMap { url in
      guard url.lastPathComponent.hasPrefix("aster-"), url.pathExtension == "jsonl",
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
        values.isRegularFile == true, values.isSymbolicLink != true
      else { return nil }
      return DiagnosticFile(url: url, size: values.fileSize, modified: values.contentModificationDate)
    }.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
  }

  private func cleanExpiredFiles() {
    let deadline = Date().addingTimeInterval(-Self.maximumAge)
    var files = diagnosticFiles()
    for file in files where (file.modified ?? .distantPast) < deadline && file.url != activeURL {
      try? fileManager.removeItem(at: file.url)
    }
    files = diagnosticFiles()
    var total = files.reduce(0) { $0 + ($1.size ?? 0) }
    for file in files where total > Self.maximumTotalBytes && file.url != activeURL {
      if let size = file.size { total -= size }
      try? fileManager.removeItem(at: file.url)
    }
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func defaultRootDirectory(fileManager: FileManager) -> URL {
    let library = (try? fileManager.url(
      for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? fileManager.temporaryDirectory
    return library.appendingPathComponent("Logs/Aster", isDirectory: true)
  }

  private static func normalizedEvent(_ event: String) -> String {
    let filtered = event.unicodeScalars.filter { $0.properties.generalCategory != .control }.map(String.init).joined()
    return String(filtered.prefix(maximumEventLength)).isEmpty ? "diagnostics.invalid_event" : String(filtered.prefix(maximumEventLength))
  }

  private static func sanitizedAttributes(_ attributes: [String: String]) -> [String: String] {
    let forbidden = ["path", "command", "content", "prompt", "clipboard", "environment", "token", "secret", "url", "host", "user"]
    return attributes.reduce(into: [:]) { result, entry in
      let key = entry.key.lowercased()
      guard key.utf8.count <= 64,
        key.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || "._-".unicodeScalars.contains($0)) }),
        !forbidden.contains(where: { key.contains($0) })
      else { return }
      let value = entry.value.unicodeScalars.filter { $0.properties.generalCategory != .control }.map(String.init).joined()
      result[key] = String(value.prefix(maximumAttributeLength))
    }
  }

  private static func summarize(_ error: Error) -> ErrorSummary {
    let nsError = error as NSError
    return ErrorSummary(type: String(reflecting: Swift.type(of: error)), domain: nsError.domain, code: nsError.code)
  }

  private static func sourceLocation(file: StaticString, line: UInt, function: StaticString) -> String? {
    #if DEBUG
      return "\(file):\(line) \(function)"
    #else
      return nil
    #endif
  }

  private static func sanitizedNote(_ note: String) -> String {
    String(note.unicodeScalars.filter {
      $0.properties.generalCategory != .control || $0.value == 10 || $0.value == 9
    }.map(String.init).joined().prefix(4 * 1_024))
  }

  private static func validateOwnedLog(_ url: URL, fileManager: FileManager) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? 0) <= maximumFileBytes
    else { throw CocoaError(.fileReadCorruptFile) }
  }

  private static func archiveTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  private static func buildInfo() -> BuildInfo {
    #if DEBUG
      let configuration = "debug"
    #else
      let configuration = "release"
    #endif
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    return BuildInfo(
      productVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
      buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
      configuration: configuration,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architecture
    )
  }
}
