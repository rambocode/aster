import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("CLI 请求目录通过文件系统事件唤醒消费者")
@MainActor
func asterCLIRequestWatcherUsesDirectoryEvents() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-cli-watcher-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }

  let watcher = FileSystemDirectoryWatcher(directory: directory)
  var eventCount = 0
  try watcher.start { eventCount += 1 }
  #expect(watcher.isWatching)

  try Data("request".utf8).write(to: directory.appendingPathComponent("event.request"))
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while eventCount == 0, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }

  #expect(eventCount > 0)
  watcher.stop()
  #expect(!watcher.isWatching)
}

@Test("Aster CLI 完整转发 capture 参数并同步返回输出与退出码")
@MainActor
func asterCLIForwardsCaptureAndReturnsSynchronousResponse() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let standardOutput = Pipe()
  let standardError = Pipe()
  let process = try fixture.makeProcess(
    arguments: [
      "--format", "json", "pane", "capture", "--pane", "pane with space", "--lines", "12",
    ],
    standardOutput: standardOutput,
    standardError: standardError
  )

  try process.run()
  let request = try waitForCLIRequest(from: fixture.service.cliRequestService)

  #expect(
    request.arguments == [
      "--format", "json", "pane", "capture", "--pane", "pane with space", "--lines", "12",
    ])
  // macOS 的 `/var` 是 `/private/var` 的符号链接；shell 的 PWD 可能返回规范路径，
  // 因此按真实目录比较，仍能验证带空格目录被完整转发。
  #expect(
    URL(fileURLWithPath: request.currentDirectory).resolvingSymlinksInPath()
      == fixture.workingDirectory.resolvingSymlinksInPath()
  )
  #expect(
    request.action
      == .capture(.init(selector: "pane with space", lines: 12, format: .json))
  )
  try fixture.service.cliRequestService.respond(
    to: request,
    response: AsterCLIResponse(
      standardOutput: Data("captured output\n".utf8),
      standardError: Data("capture warning\n".utf8),
      exitCode: 23
    )
  )
  process.waitUntilExit()

  #expect(process.terminationStatus == 23)
  #expect(
    String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      == "captured output\n")
  #expect(
    String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      == "capture warning\n")
}

@Test("Aster CLI 仅为 pane send-text --stdin 有界转发标准输入")
@MainActor
func asterCLIForwardsBoundedStandardInput() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let input = Pipe()
  input.fileHandleForWriting.write(Data("first line\nsecond line\n".utf8))
  try input.fileHandleForWriting.close()
  let process = try fixture.makeProcess(
    // WorkflowCLIParser 兼容可选的 `otty` 前缀，启动器也必须在此前缀下正确识别
    // `--stdin`，不能只转发参数却丢掉对应输入流。
    arguments: ["otty", "pane", "send-text", "--pane", "p_123", "--stdin"],
    standardInput: input
  )

  try process.run()
  let request = try waitForCLIRequest(from: fixture.service.cliRequestService)

  #expect(request.action == .send(.init(selector: "p_123", input: .standardInput)))
  #expect(request.standardInput == Data("first line\nsecond line\n".utf8))
  try fixture.service.cliRequestService.respond(to: request, response: .success())
  process.waitUntilExit()

  #expect(process.terminationStatus == 0)
}

@Test("请求服务启动时恢复崩溃遗留的 processing 请求")
@MainActor
func asterCLIRequestServiceRecoversOrphanedProcessingRequestOnStartup() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let state = fixture.service.cliRequestService.stateDirectory
  let requests = fixture.service.cliRequestService.requestsDirectory
  let processingURL = requests.appendingPathComponent("startup-orphan.processing")
  try cliRequestWireData(
    token: fixture.service.cliToken,
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: processingURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600], ofItemAtPath: processingURL.path)

  // 新服务实例代表应用崩溃后重启；启动完成前应主动结束旧请求，避免 CLI
  // 继续等待最长五分钟的客户端超时。
  let restartedService = try AsterCLIRequestService(baseDirectory: state)
  let responseURL = requests.appendingPathComponent("startup-orphan.response")
  let errorHex = Data("aster: previous CLI request was interrupted\n".utf8).hexEncodedString

  #expect(!FileManager.default.fileExists(atPath: processingURL.path))
  #expect(
    try String(contentsOf: responseURL, encoding: .utf8)
      == "ASTER_CLI_RESPONSE_V1\n70\n\n\(errorHex)\n"
  )
  #expect(try restartedService.takeNextRequest() == nil)
}

@Test("请求服务轮询时恢复启动后出现的遗留 processing 请求")
@MainActor
func asterCLIRequestServiceRecoversOrphanedProcessingRequestWhilePolling() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let service = fixture.service.cliRequestService
  let requests = service.requestsDirectory
  let processingURL = requests.appendingPathComponent("polling-orphan.processing")
  try cliRequestWireData(
    token: fixture.service.cliToken,
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: processingURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600], ofItemAtPath: processingURL.path)

  #expect(try service.takeNextRequest() == nil)

  #expect(!FileManager.default.fileExists(atPath: processingURL.path))
  let response = try String(
    contentsOf: requests.appendingPathComponent("polling-orphan.response"), encoding: .utf8)
  #expect(response.split(separator: "\n", omittingEmptySubsequences: false)[1] == "70")
}

@Test("请求服务轮询时不回收当前实例仍在执行的请求")
@MainActor
func asterCLIRequestServiceKeepsCurrentInFlightRequestWhilePolling() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let service = fixture.service.cliRequestService
  let requests = service.requestsDirectory
  let requestURL = requests.appendingPathComponent("in-flight.request")
  try cliRequestWireData(
    token: fixture.service.cliToken,
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: requestURL)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)

  let request = try #require(try service.takeNextRequest())
  #expect(try service.takeNextRequest() == nil)

  let processingURL = requests.appendingPathComponent("in-flight.processing")
  #expect(FileManager.default.fileExists(atPath: processingURL.path))
  #expect(
    !FileManager.default.fileExists(
      atPath: requests.appendingPathComponent("in-flight.response").path)
  )
  try service.respond(to: request, response: .success())
}

@Test("遗留 processing 请求恢复仍执行 token 鉴权")
@MainActor
func asterCLIRequestServiceAuthenticatesOrphanedProcessingRequest() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let service = fixture.service.cliRequestService
  let requests = service.requestsDirectory
  let processingURL = requests.appendingPathComponent("unauthenticated-orphan.processing")
  try cliRequestWireData(
    token: String(repeating: "0", count: 64),
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: processingURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600], ofItemAtPath: processingURL.path)

  #expect(try service.takeNextRequest() == nil)

  #expect(!FileManager.default.fileExists(atPath: processingURL.path))
  let response = try String(
    contentsOf: requests.appendingPathComponent("unauthenticated-orphan.response"),
    encoding: .utf8
  )
  #expect(response.split(separator: "\n", omittingEmptySubsequences: false)[1] == "77")
}

@Test("遗留 processing 请求恢复拒绝超限文件")
@MainActor
func asterCLIRequestServiceRejectsOversizedOrphanedProcessingRequest() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let service = fixture.service.cliRequestService
  let requests = service.requestsDirectory
  let processingURL = requests.appendingPathComponent("oversized-orphan.processing")
  try Data(repeating: 0x41, count: AsterCLIRequestService.maximumRequestBytes + 1)
    .write(to: processingURL)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600], ofItemAtPath: processingURL.path)

  #expect(try service.takeNextRequest() == nil)

  #expect(!FileManager.default.fileExists(atPath: processingURL.path))
  let response = try String(
    contentsOf: requests.appendingPathComponent("oversized-orphan.response"), encoding: .utf8)
  #expect(response.split(separator: "\n", omittingEmptySubsequences: false)[1] == "65")
}

@Test("遗留 processing 请求恢复不跟随符号链接且不删除目录")
@MainActor
func asterCLIRequestServiceIgnoresUnsafeOrphanedProcessingEntries() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let service = fixture.service.cliRequestService
  let requests = service.requestsDirectory
  let external = fixture.root.appendingPathComponent("external-processing")
  try cliRequestWireData(
    token: fixture.service.cliToken,
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: external)
  let linkedProcessing = requests.appendingPathComponent("linked-orphan.processing")
  try FileManager.default.createSymbolicLink(at: linkedProcessing, withDestinationURL: external)
  let directoryProcessing = requests.appendingPathComponent(
    "directory-orphan.processing", isDirectory: true)
  try FileManager.default.createDirectory(at: directoryProcessing, withIntermediateDirectories: false)

  #expect(try service.takeNextRequest() == nil)

  #expect(try external.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
  #expect(try linkedProcessing.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
  #expect(
    try directoryProcessing.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
  #expect(
    !FileManager.default.fileExists(
      atPath: requests.appendingPathComponent("linked-orphan.response").path)
  )
  #expect(
    !FileManager.default.fileExists(
      atPath: requests.appendingPathComponent("directory-orphan.response").path)
  )
}

@Test("请求服务不覆盖预先放置的 response 符号链接")
@MainActor
func asterCLIRequestServiceDoesNotReplaceResponseSymbolicLink() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let requests = fixture.service.cliRequestService.requestsDirectory
  let requestURL = requests.appendingPathComponent("response-link.request")
  try cliRequestWireData(
    token: fixture.service.cliToken,
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: requestURL)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
  let request = try #require(try fixture.service.cliRequestService.takeNextRequest())
  let external = fixture.root.appendingPathComponent("must-not-change")
  try "original".write(to: external, atomically: true, encoding: .utf8)
  let responseURL = requests.appendingPathComponent("response-link.response")
  try FileManager.default.createSymbolicLink(at: responseURL, withDestinationURL: external)

  #expect(throws: AsterCLIRequestServiceError.self) {
    try fixture.service.cliRequestService.respond(
      to: request,
      response: .success(standardOutput: Data("replacement".utf8))
    )
  }
  #expect(try String(contentsOf: external, encoding: .utf8) == "original")
  #expect(try responseURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
}

@Test("请求服务拒绝错误 token 且不跟随请求符号链接")
@MainActor
func asterCLIRequestServiceRejectsUnauthenticatedAndSymbolicLinkRequests() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let requests = fixture.service.cliRequestService.requestsDirectory
  let invalidRequest = requests.appendingPathComponent("invalid-token.request")
  try cliRequestWireData(
    token: String(repeating: "0", count: 64),
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: invalidRequest)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600], ofItemAtPath: invalidRequest.path)
  let external = fixture.root.appendingPathComponent("external-request")
  try cliRequestWireData(
    token: fixture.service.cliToken,
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: external)
  try FileManager.default.createSymbolicLink(
    at: requests.appendingPathComponent("linked.request"), withDestinationURL: external)

  #expect(try fixture.service.cliRequestService.takeNextRequest() == nil)
  #expect(FileManager.default.fileExists(atPath: requests.appendingPathComponent("invalid-token.response").path))
  #expect(FileManager.default.fileExists(atPath: requests.appendingPathComponent("linked.request").path))

  let response = try String(
    contentsOf: requests.appendingPathComponent("invalid-token.response"), encoding: .utf8)
  #expect(response.split(separator: "\n", omittingEmptySubsequences: false)[1] == "77")
}

@Test("请求服务拒绝含控制字符的当前目录")
@MainActor
func asterCLIRequestServiceRejectsInvalidCurrentDirectory() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let requests = fixture.service.cliRequestService.requestsDirectory
  let requestURL = requests.appendingPathComponent("invalid-directory.request")
  try cliRequestWireData(
    token: fixture.service.cliToken,
    currentDirectory: "/tmp/valid-prefix\nforged-line",
    arguments: ["pane", "capture"]
  ).write(to: requestURL)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)

  #expect(try fixture.service.cliRequestService.takeNextRequest() == nil)
  let response = try String(
    contentsOf: requests.appendingPathComponent("invalid-directory.response"), encoding: .utf8)
  #expect(response.split(separator: "\n", omittingEmptySubsequences: false)[1] == "65")
}

@Test("请求服务强制私有权限并拒绝超限响应")
@MainActor
func asterCLIRequestServiceEnforcesPermissionsAndResponseBounds() throws {
  let fixture = try makeCLITransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let state = fixture.service.cliRequestService.stateDirectory
  let requests = fixture.service.cliRequestService.requestsDirectory

  #expect(try permissions(of: state.appendingPathComponent("cli-token")) == 0o600)
  #expect(try permissions(of: requests) == 0o700)

  let requestURL = requests.appendingPathComponent("bounded.request")
  try cliRequestWireData(
    token: fixture.service.cliToken,
    currentDirectory: fixture.workingDirectory.path,
    arguments: ["pane", "capture"]
  ).write(to: requestURL)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
  let request = try #require(try fixture.service.cliRequestService.takeNextRequest())
  let oversized = Data(
    repeating: 0x41,
    count: AsterCLIRequestService.maximumResponseStreamBytes + 1
  )

  #expect(throws: AsterCLIRequestServiceError.responseTooLarge) {
    try fixture.service.cliRequestService.respond(
      to: request,
      response: AsterCLIResponse(standardOutput: oversized, standardError: Data(), exitCode: 0)
    )
  }
  #expect(
    !FileManager.default.fileExists(
      atPath: requests.appendingPathComponent("bounded.response").path)
  )
}

private struct CLITransportFixture {
  let root: URL
  let home: URL
  let workingDirectory: URL
  let executable: URL
  let service: AutocompleteService

  func makeProcess(
    arguments: [String],
    standardInput: Any? = nil,
    standardOutput: Any? = FileHandle.nullDevice,
    standardError: Any? = FileHandle.nullDevice
  ) throws -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = [
      "HOME": home.path,
      "PATH": "/usr/bin:/bin",
    ]
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError
    return process
  }
}

@MainActor
private func makeCLITransportFixture() throws -> CLITransportFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-cli-transport-\(UUID().uuidString)", isDirectory: true)
  let home = root.appendingPathComponent("home", isDirectory: true)
  let workingDirectory = root.appendingPathComponent("working directory", isDirectory: true)
  let state = home.appendingPathComponent(
    "Library/Application Support/Aster/Autocomplete", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
  let service = try AutocompleteService(
    baseDirectory: state,
    bundledSpecURL: repositoryCLITransportAutocompleteSpecURL
  )
  let executable = root.appendingPathComponent("aster")
  try AsterCLIScript.contents.write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return CLITransportFixture(
    root: root,
    home: home,
    workingDirectory: workingDirectory,
    executable: executable,
    service: service
  )
}

private func waitForCLIRequest(
  from service: AsterCLIRequestService,
  timeout: TimeInterval = 3
) throws -> AsterCLIRequest {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if let request = try service.takeNextRequest() { return request }
    Thread.sleep(forTimeInterval: 0.01)
  }
  Issue.record("等待 Aster CLI 请求超时")
  throw CocoaError(.fileReadUnknown)
}

private func cliRequestWireData(
  token: String,
  currentDirectory: String,
  arguments: [String],
  standardInput: Data = Data()
) -> Data {
  let lines = [
    "ASTER_CLI_REQUEST_V1",
    token,
    Data(currentDirectory.utf8).hexEncodedString,
    standardInput.hexEncodedString,
    String(arguments.count),
  ] + arguments.map { Data($0.utf8).hexEncodedString }
  return Data((lines.joined(separator: "\n") + "\n").utf8)
}

private func permissions(of url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private var repositoryCLITransportAutocompleteSpecURL: URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/autocomplete/fig-specs.json")
}

private extension Data {
  var hexEncodedString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
