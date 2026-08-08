import AsterCore
import Darwin
import Foundation

enum AsterCLIRequestServiceError: Error, LocalizedError, Equatable {
  case invalidStateDirectory
  case tokenUnavailable
  case unsafeRequestFile(String)
  case malformedRequest
  case responseTooLarge
  case invalidResponseTarget

  var errorDescription: String? {
    switch self {
    case .invalidStateDirectory:
      "Aster CLI 状态目录不可用。"
    case .tokenUnavailable:
      "Aster CLI token 不存在、权限不安全或内容无效。"
    case .unsafeRequestFile(let path):
      "拒绝读取非普通、非私有或超限的 CLI 请求：\(path)"
    case .malformedRequest:
      "Aster CLI 请求格式无效。"
    case .responseTooLarge:
      "Aster CLI 响应超过大小限制。"
    case .invalidResponseTarget:
      "Aster CLI 响应目标不属于当前请求目录。"
    }
  }
}

/// 已通过 token 鉴权并由 `WorkflowCLIParser` 校验的本机 CLI 请求。`arguments`
/// 保留 shell 传入的原始参数边界，交付层可据此记录诊断信息；业务执行应使用
/// `action`，避免不同调用方重复解析产生行为差异。
struct AsterCLIRequest: Equatable, Sendable {
  let identifier: String
  let currentDirectory: String
  let arguments: [String]
  let standardInput: Data
  let action: WorkflowCLIAction

  fileprivate let processingURL: URL
}

/// CLI 同步响应。stdout 与 stderr 分开编码，启动器按原通道无损写回；退出码限制
/// 为 shell 可表达的 0...255，确保 `pane capture` 等同步命令可直接参与脚本判断。
struct AsterCLIResponse: Equatable, Sendable {
  let standardOutput: Data
  let standardError: Data
  let exitCode: Int32

  init(standardOutput: Data, standardError: Data, exitCode: Int32) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.exitCode = exitCode
  }

  static func success(
    standardOutput: Data = Data(),
    standardError: Data = Data()
  ) -> AsterCLIResponse {
    AsterCLIResponse(
      standardOutput: standardOutput,
      standardError: standardError,
      exitCode: 0
    )
  }
}

/// 基于私有目录普通文件的本机请求/响应传输。它不监听网络或 socket：CLI 将请求
/// 原子提交到固定 `requests/` 目录，应用取得并解析请求后写入同名 response。
/// 所有读操作使用 `O_NOFOLLOW` + `fstat`，所有写操作以 0600 新文件原子发布。
final class AsterCLIRequestService {
  static let maximumStandardInputBytes = 1 * 1_024 * 1_024
  static let maximumRequestBytes = 3 * 1_024 * 1_024
  static let maximumResponseStreamBytes = 2 * 1_024 * 1_024

  let stateDirectory: URL
  let requestsDirectory: URL

  private static let requestMagic = "ASTER_CLI_REQUEST_V1"
  private static let responseMagic = "ASTER_CLI_RESPONSE_V1"
  private static let tokenFileName = "cli-token"
  private static let readyFileName = "cli-server-ready"
  private static let maximumIdentifierBytes = 64

  private let fileManager: FileManager
  private let token: String
  private let readyURL: URL
  private let readyContents: Data
  private var activeProcessingIdentifiers: Set<String> = []

  init(baseDirectory: URL, fileManager: FileManager = .default) throws {
    self.fileManager = fileManager
    stateDirectory = baseDirectory.standardizedFileURL
    requestsDirectory = stateDirectory.appendingPathComponent("requests", isDirectory: true)
    readyURL = stateDirectory.appendingPathComponent(Self.readyFileName)

    try Self.preparePrivateDirectory(stateDirectory, fileManager: fileManager)
    try Self.preparePrivateDirectory(requestsDirectory, fileManager: fileManager)
    token = try Self.loadPrivateToken(
      at: stateDirectory.appendingPathComponent(Self.tokenFileName),
      fileManager: fileManager
    )
    readyContents = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
    try recoverInterruptedRequests()
    try Self.replacePrivateFile(readyContents, at: readyURL, fileManager: fileManager)
  }

  deinit {
    // 多实例测试或快速重启时，只删除仍由本实例写入的就绪标记，避免旧实例析构
    // 时误删新进程的标记。失败仅意味着下次 CLI 会重新唤起应用，不影响数据。
    if let data = try? Self.readPrivateRegularFile(
      at: readyURL,
      maximumBytes: 64,
      fileManager: fileManager
    ), data == readyContents {
      try? fileManager.removeItem(at: readyURL)
    }
  }

  /// 原子取得按文件名排序的下一条合法请求。无效请求会得到固定失败响应并被消费；
  /// 符号链接或非普通文件完全忽略，既不读取目标，也不删除用户可见的外部对象。
  func takeNextRequest() throws -> AsterCLIRequest? {
    try recoverInterruptedRequests()
    let candidates = try fileManager.contentsOfDirectory(
      at: requestsDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    ).filter { $0.pathExtension == "request" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    for candidate in candidates {
      let identifier = candidate.deletingPathExtension().lastPathComponent
      guard Self.isValidIdentifier(identifier), Self.isPrivateRegularFile(candidate) else {
        continue
      }
      let processingURL = requestsDirectory.appendingPathComponent("\(identifier).processing")
      do {
        try fileManager.moveItem(at: candidate, to: processingURL)
      } catch {
        // 另一个消费者已取得请求属于正常竞争；继续寻找下一项。
        continue
      }

      do {
        let data = try Self.readPrivateRegularFile(
          at: processingURL,
          maximumBytes: Self.maximumRequestBytes,
          fileManager: fileManager
        )
        let decoded = try decodeRequest(data)
        guard Self.constantTimeEqual(decoded.token, token) else {
          try reject(identifier: identifier, processingURL: processingURL, exitCode: 77)
          continue
        }
        let action = try WorkflowCLIParser(currentDirectory: decoded.currentDirectory)
          .parse(decoded.arguments)
        guard Self.standardInputIsApplicable(decoded.standardInput, to: action) else {
          try reject(identifier: identifier, processingURL: processingURL, exitCode: 64)
          continue
        }
        // 只有完整校验并即将交给业务层的请求才属于当前实例；后续轮询必须跳过
        // 它，直到 `respond` 发布结果，避免把耗时执行误判为崩溃遗留。
        activeProcessingIdentifiers.insert(identifier)
        return AsterCLIRequest(
          identifier: identifier,
          currentDirectory: decoded.currentDirectory,
          arguments: decoded.arguments,
          standardInput: decoded.standardInput,
          action: action,
          processingURL: processingURL
        )
      } catch let error as AsterCLIRequestServiceError {
        try? reject(identifier: identifier, processingURL: processingURL, exitCode: 65)
        if error == .malformedRequest { continue }
        continue
      } catch is WorkflowCLIParseError {
        try? reject(identifier: identifier, processingURL: processingURL, exitCode: 64)
        continue
      } catch {
        try? reject(identifier: identifier, processingURL: processingURL, exitCode: 70)
        continue
      }
    }
    return nil
  }

  /// 发布请求的最终响应。先校验大小与退出码，再写 response，最后删除 processing；
  /// 因此客户端只会看到完整响应，应用崩溃时也不会误读半写文件。
  func respond(to request: AsterCLIRequest, response: AsterCLIResponse) throws {
    guard response.standardOutput.count <= Self.maximumResponseStreamBytes,
      response.standardError.count <= Self.maximumResponseStreamBytes,
      (0...255).contains(response.exitCode)
    else { throw AsterCLIRequestServiceError.responseTooLarge }
    guard Self.isValidIdentifier(request.identifier),
      request.processingURL.standardizedFileURL.deletingLastPathComponent()
        == requestsDirectory.standardizedFileURL,
      request.processingURL.lastPathComponent == "\(request.identifier).processing"
    else { throw AsterCLIRequestServiceError.invalidResponseTarget }

    try writeResponse(response, identifier: request.identifier)
    try? fileManager.removeItem(at: request.processingURL)
    activeProcessingIdentifiers.remove(request.identifier)
  }

  /// 应用崩溃后 `.processing` 不会再有执行方写回结果。服务在发布 ready 标记前及
  /// 每轮请求轮询时结束安全的遗留普通文件，使仍在等待的 CLI 立即收到失败响应。
  private func recoverInterruptedRequests() throws {
    let candidates = try fileManager.contentsOfDirectory(
      at: requestsDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    ).filter { $0.pathExtension == "processing" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    for candidate in candidates {
      let identifier = candidate.deletingPathExtension().lastPathComponent
      guard Self.isValidIdentifier(identifier),
        !activeProcessingIdentifiers.contains(identifier),
        Self.isPrivateRegularFile(candidate)
      else {
        continue
      }
      do {
        let data = try Self.readPrivateRegularFile(
          at: candidate,
          maximumBytes: Self.maximumRequestBytes,
          fileManager: fileManager
        )
        let decoded = try decodeRequest(data)
        guard Self.constantTimeEqual(decoded.token, token) else {
          try reject(identifier: identifier, processingURL: candidate, exitCode: 77)
          continue
        }
        try reject(
          identifier: identifier,
          processingURL: candidate,
          exitCode: 70,
          message: "aster: previous CLI request was interrupted\n"
        )
      } catch is AsterCLIRequestServiceError {
        // 与新请求相同，超限、截断或格式错误的安全普通文件得到固定数据错误，
        // 但符号链接、目录等对象已在读取前被过滤，绝不会被跟随或删除。
        try? reject(identifier: identifier, processingURL: candidate, exitCode: 65)
      } catch {
        try? reject(identifier: identifier, processingURL: candidate, exitCode: 70)
        continue
      }
    }
  }

  private func reject(
    identifier: String,
    processingURL: URL,
    exitCode: Int32,
    message explicitMessage: String? = nil
  ) throws {
    let message = explicitMessage ?? {
      switch exitCode {
      case 64: "aster: invalid CLI arguments\n"
      case 65: "aster: invalid CLI request\n"
      case 77: "aster: CLI authentication failed\n"
      default: "aster: CLI request failed\n"
      }
    }()
    try writeResponse(
      AsterCLIResponse(
        standardOutput: Data(),
        standardError: Data(message.utf8),
        exitCode: exitCode
      ),
      identifier: identifier
    )
    try? fileManager.removeItem(at: processingURL)
    activeProcessingIdentifiers.remove(identifier)
  }

  private func writeResponse(_ response: AsterCLIResponse, identifier: String) throws {
    let lines = [
      Self.responseMagic,
      String(response.exitCode),
      Self.encodeHex(response.standardOutput),
      Self.encodeHex(response.standardError),
    ]
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    // 两个流各自受限；该额外检查防止协议头或未来字段变化意外绕过总量约束。
    let maximumEncodedBytes = 4 * Self.maximumResponseStreamBytes + 1_024
    guard data.count <= maximumEncodedBytes else {
      throw AsterCLIRequestServiceError.responseTooLarge
    }
    let responseURL = requestsDirectory.appendingPathComponent("\(identifier).response")
    try Self.createPrivateFileAtomically(data, at: responseURL, fileManager: fileManager)
  }

  private func decodeRequest(_ data: Data) throws -> DecodedRequest {
    guard let text = String(data: data, encoding: .utf8) else {
      throw AsterCLIRequestServiceError.malformedRequest
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    guard lines.count >= 5,
      lines[0] == Self.requestMagic,
      Self.isValidToken(lines[1]),
      let currentDirectoryData = Self.decodeHex(lines[2], maximumBytes: 4_096),
      let currentDirectory = String(data: currentDirectoryData, encoding: .utf8),
      currentDirectory.hasPrefix("/"),
      !currentDirectory.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      }),
      let standardInput = Self.decodeHex(
        lines[3], maximumBytes: Self.maximumStandardInputBytes),
      let argumentCount = Int(lines[4]),
      (0...WorkflowCLIParser.maximumArguments).contains(argumentCount),
      lines.count == argumentCount + 5
    else { throw AsterCLIRequestServiceError.malformedRequest }

    var arguments: [String] = []
    arguments.reserveCapacity(argumentCount)
    for encoded in lines.dropFirst(5) {
      guard let bytes = Self.decodeHex(
        encoded, maximumBytes: WorkflowCLIParser.maximumArgumentBytes),
        let argument = String(data: bytes, encoding: .utf8),
        !argument.unicodeScalars.contains(where: { $0.value == 0 })
      else { throw AsterCLIRequestServiceError.malformedRequest }
      arguments.append(argument)
    }
    return DecodedRequest(
      token: lines[1],
      currentDirectory: currentDirectory,
      arguments: arguments,
      standardInput: standardInput
    )
  }

  private static func standardInputIsApplicable(
    _ standardInput: Data,
    to action: WorkflowCLIAction
  ) -> Bool {
    switch action {
    case .send(let send):
      if case .standardInput = send.input { return true }
      return standardInput.isEmpty
    default:
      return standardInput.isEmpty
    }
  }

  private struct DecodedRequest {
    let token: String
    let currentDirectory: String
    let arguments: [String]
    let standardInput: Data
  }

  private static func preparePrivateDirectory(
    _ url: URL,
    fileManager: FileManager
  ) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
        throw AsterCLIRequestServiceError.invalidStateDirectory
      }
    } else {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private static func loadPrivateToken(at url: URL, fileManager: FileManager) throws -> String {
    let data: Data
    do {
      data = try readPrivateRegularFile(at: url, maximumBytes: 128, fileManager: fileManager)
    } catch {
      throw AsterCLIRequestServiceError.tokenUnavailable
    }
    guard let token = String(data: data, encoding: .utf8), isValidToken(token) else {
      throw AsterCLIRequestServiceError.tokenUnavailable
    }
    return token
  }

  private static func isValidToken(_ token: String) -> Bool {
    token.utf8.count == 64 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func isValidIdentifier(_ identifier: String) -> Bool {
    guard !identifier.isEmpty, identifier.utf8.count <= maximumIdentifierBytes else { return false }
    return identifier.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
    }
  }

  private static func isPrivateRegularFile(_ url: URL) -> Bool {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return false }
    return metadata.st_mode & S_IFMT == S_IFREG
      && metadata.st_uid == geteuid()
      && metadata.st_mode & 0o077 == 0
  }

  private static func readPrivateRegularFile(
    at url: URL,
    maximumBytes: Int,
    fileManager: FileManager
  ) throws -> Data {
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw AsterCLIRequestServiceError.unsafeRequestFile(url.path)
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(),
      metadata.st_mode & 0o077 == 0,
      metadata.st_size >= 0,
      metadata.st_size <= maximumBytes
    else { throw AsterCLIRequestServiceError.unsafeRequestFile(url.path) }

    var data = Data()
    data.reserveCapacity(min(Int(metadata.st_size), maximumBytes))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while data.count <= maximumBytes {
      let requested = min(buffer.count, maximumBytes - data.count + 1)
      let count = Darwin.read(descriptor, &buffer, requested)
      guard count >= 0 else {
        throw AsterCLIRequestServiceError.unsafeRequestFile(url.path)
      }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count <= maximumBytes else {
      throw AsterCLIRequestServiceError.unsafeRequestFile(url.path)
    }
    return data
  }

  private static func replacePrivateFile(
    _ data: Data,
    at url: URL,
    fileManager: FileManager
  ) throws {
    if fileManager.fileExists(atPath: url.path) {
      guard isPrivateRegularFile(url) else {
        throw AsterCLIRequestServiceError.unsafeRequestFile(url.path)
      }
      try fileManager.removeItem(at: url)
    }
    try createPrivateFileAtomically(data, at: url, fileManager: fileManager)
  }

  private static func createPrivateFileAtomically(
    _ data: Data,
    at url: URL,
    fileManager: FileManager
  ) throws {
    let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = temporaryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
      throw AsterCLIRequestServiceError.unsafeRequestFile(temporaryURL.path)
    }
    defer {
      Darwin.close(descriptor)
      try? fileManager.removeItem(at: temporaryURL)
    }

    try data.withUnsafeBytes { bytes in
      guard var pointer = bytes.baseAddress else { return }
      var remaining = bytes.count
      while remaining > 0 {
        let written = Darwin.write(descriptor, pointer, remaining)
        guard written > 0 else {
          throw AsterCLIRequestServiceError.unsafeRequestFile(temporaryURL.path)
        }
        remaining -= written
        pointer = pointer.advanced(by: written)
      }
    }
    guard fsync(descriptor) == 0 else {
      throw AsterCLIRequestServiceError.unsafeRequestFile(temporaryURL.path)
    }
    // `link` 只在目标不存在时成功，既提供同文件系统内的原子发布，也不会像
    // `rename` 那样替换攻击者预先放置的 symlink/FIFO/普通文件。
    guard Darwin.link(temporaryURL.path, url.path) == 0 else {
      throw AsterCLIRequestServiceError.unsafeRequestFile(url.path)
    }
  }

  private static func encodeHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func decodeHex(_ value: String, maximumBytes: Int) -> Data? {
    guard value.count.isMultiple(of: 2), value.count <= maximumBytes * 2,
      value.allSatisfy(\.isHexDigit)
    else { return nil }
    var result = Data()
    result.reserveCapacity(value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
      result.append(byte)
      index = next
    }
    return result
  }

  private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let lhs = Array(left.utf8)
    let rhs = Array(right.utf8)
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    for index in 0..<max(lhs.count, rhs.count) {
      difference |= (index < lhs.count ? lhs[index] : 0) ^ (index < rhs.count ? rhs[index] : 0)
    }
    return difference == 0
  }
}
