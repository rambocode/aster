import Foundation
import Testing

@testable import AsterCore

@Test("文件目标支持绝对、主目录、相对路径及行列后缀")
func targetResolverNormalizesDocumentedFileForms() throws {
  let resolver = TargetResolver(homeDirectory: URL(fileURLWithPath: "/Users/tester"))

  #expect(
    try resolver.resolve("/tmp/App.swift:12:7", currentDirectory: "/work")
      == .file(.init(path: "/tmp/App.swift", line: 12, column: 7)))
  #expect(
    try resolver.resolve("~/notes/readme.md:9", currentDirectory: "/work")
      == .file(.init(path: "/Users/tester/notes/readme.md", line: 9)))
  #expect(
    try resolver.resolve("Sources/../README.md", currentDirectory: "/work/project")
      == .file(.init(path: "/work/project/README.md")))
}

@Test("file URL 归一为文件目标，避免绕过统一的文件安全策略")
func targetResolverConvertsFileURLToFileTarget() throws {
  let resolver = TargetResolver(homeDirectory: URL(fileURLWithPath: "/Users/tester"))

  let target = try resolver.resolve(
    "file:///tmp/My%20File.txt",
    currentDirectory: "/work"
  )

  #expect(target == .file(.init(path: "/tmp/My File.txt")))
}

@Test("默认识别任意合法 scheme，自定义模式始终保留标准 scheme")
func targetResolverAppliesSchemeDetectionPolicy() throws {
  let resolver = TargetResolver(homeDirectory: URL(fileURLWithPath: "/Users/tester"))

  #expect(
    try resolver.resolve("codex://session/123", currentDirectory: "/work")
      == .url(.init(url: URL(string: "codex://session/123")!, scheme: "codex")))
  #expect(
    try resolver.resolve("tel:+123456", currentDirectory: "/work")
      == .url(.init(url: URL(string: "tel:+123456")!, scheme: "tel")))
  #expect(
    try resolver.resolve(
      "https://example.com/docs",
      currentDirectory: "/work",
      schemePolicy: .custom([])
    ) == .url(.init(url: URL(string: "https://example.com/docs")!, scheme: "https")))
  #expect(
    try resolver.resolve(
      "vscode://file/tmp/a.swift",
      currentDirectory: "/work",
      schemePolicy: .custom(["VSCODE"])
    ) == .url(.init(url: URL(string: "vscode://file/tmp/a.swift")!, scheme: "vscode")))
  #expect(throws: TargetResolutionError.schemeNotDetected("ssh")) {
    try resolver.resolve(
      "ssh://host.example",
      currentDirectory: "/work",
      schemePolicy: .custom(["vscode"])
    )
  }
}

@Test("OSC 8 显式链接不受自动检测 scheme 列表限制")
func targetResolverAlwaysRecognizesExplicitHyperlinks() throws {
  let resolver = TargetResolver(homeDirectory: URL(fileURLWithPath: "/Users/tester"))

  let target = try resolver.resolve(
    "ssh://host.example",
    currentDirectory: "/work",
    source: .osc8,
    schemePolicy: .custom([])
  )

  #expect(target == .url(.init(url: URL(string: "ssh://host.example")!, scheme: "ssh")))
  #expect(
    try resolver.resolve(
      "urn:isbn:9780131103627",
      currentDirectory: "/work",
      source: .osc8,
      schemePolicy: .custom([])
    ) == .url(.init(url: URL(string: "urn:isbn:9780131103627")!, scheme: "urn")))
  #expect(
    try resolver.resolve(
      "README.md:12",
      currentDirectory: "/work/project",
      source: .osc8,
      schemePolicy: .custom([])
    ) == .file(.init(path: "/work/project/README.md", line: 12)))
}

@Test("目标解析拒绝控制字符、超长输入、非法行列和相对 CWD")
func targetResolverRejectsUnsafeInputs() {
  let resolver = TargetResolver(homeDirectory: URL(fileURLWithPath: "/Users/tester"))

  #expect(throws: TargetResolutionError.controlCharacter) {
    try resolver.resolve("https://example.com\nmalicious", currentDirectory: "/work")
  }
  #expect(throws: TargetResolutionError.controlCharacter) {
    try resolver.resolve("https://example.com/%0Acommand", currentDirectory: "/work")
  }
  #expect(throws: TargetResolutionError.inputTooLong) {
    try resolver.resolve("/" + String(repeating: "a", count: 4_096), currentDirectory: "/work")
  }
  #expect(throws: TargetResolutionError.invalidURL) {
    try resolver.resolve("file:README.md", currentDirectory: "/work")
  }
  #expect(throws: TargetResolutionError.invalidLocation) {
    try resolver.resolve("README.md:0", currentDirectory: "/work")
  }
  #expect(throws: TargetResolutionError.invalidCurrentDirectory) {
    try resolver.resolve("README.md", currentDirectory: "relative")
  }
  #expect(throws: TargetResolutionError.invalidCurrentDirectory) {
    try resolver.resolve(
      "README.md",
      currentDirectory: "/" + String(repeating: "a", count: 4_096)
    )
  }
}

@Test("标准 URL 与普通文件可直接打开，非标准 scheme 和可执行文件需要确认")
func targetSecurityPolicyRequiresDocumentedConfirmations() {
  let policy = TargetSecurityPolicy()
  let web = DetectedTarget.url(
    .init(url: URL(string: "https://example.com")!, scheme: "https"))
  let custom = DetectedTarget.url(
    .init(url: URL(string: "codex://session/123")!, scheme: "codex"))
  let file = DetectedTarget.file(.init(path: "/tmp/readme.txt"))
  let executable = DetectedTarget.file(.init(path: "/tmp/tool"))

  #expect(policy.decision(for: web) == .allow)
  #expect(policy.decision(for: custom) == .confirm(.nonStandardScheme("codex")))
  #expect(policy.decision(for: file, fileKind: .regular(executable: false)) == .allow)
  #expect(
    policy.decision(for: executable, fileKind: .regular(executable: true))
      == .confirm(.executableFile("/tmp/tool")))
  #expect(
    policy.decision(for: .file(.init(path: "/tmp/Evil.app")), fileKind: .applicationBundle)
      == .confirm(.executableFile("/tmp/Evil.app")))
}

@Test("记住的 scheme 可直接打开，设备、管道和 socket 始终拒绝")
func targetSecurityPolicyHonorsRememberedSchemesAndRejectsSpecialFiles() {
  let policy = TargetSecurityPolicy(allowedNonStandardSchemes: ["CODEX"])
  let custom = DetectedTarget.url(
    .init(url: URL(string: "codex://session/123")!, scheme: "codex"))
  let file = DetectedTarget.file(.init(path: "/tmp/special"))

  #expect(policy.decision(for: custom) == .allow)
  #expect(
    policy.decision(for: file, fileKind: .namedPipe)
      == .deny(.unsupportedFileType(.namedPipe)))
  #expect(
    policy.decision(for: file, fileKind: .socket)
      == .deny(.unsupportedFileType(.socket)))
  #expect(
    policy.decision(for: file, fileKind: .device)
      == .deny(.unsupportedFileType(.device)))
}

@Test("文件检查器区分普通、可执行、目录、管道和不存在目标")
func targetFileInspectorClassifiesWithoutOpeningSpecialFiles() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let regular = root.appendingPathComponent("readme.txt")
  let executable = root.appendingPathComponent("tool")
  let pipe = root.appendingPathComponent("events.pipe")
  let application = root.appendingPathComponent("Evil.app", isDirectory: true)
  try Data("hello".utf8).write(to: regular)
  try Data("#!/bin/sh\n".utf8).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  #expect(mkfifo(pipe.path, 0o600) == 0)
  try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)

  #expect(TargetFileInspector.kind(atPath: regular.path) == .regular(executable: false))
  #expect(TargetFileInspector.kind(atPath: executable.path) == .regular(executable: true))
  #expect(TargetFileInspector.kind(atPath: root.path) == .directory)
  #expect(TargetFileInspector.kind(atPath: pipe.path) == .namedPipe)
  #expect(TargetFileInspector.kind(atPath: application.path) == .applicationBundle)
  #expect(TargetFileInspector.kind(atPath: root.appendingPathComponent("missing").path) == .missing)
}

@Test("OSC 8 payload 精确提取 URI，关闭标记和普通文字没有显式来源")
func osc8PayloadExtractsOnlyExplicitLink() {
  #expect(OSC8Payload.link(from: "id=docs;codex://session/123") == "codex://session/123")
  #expect(OSC8Payload.link(from: ";") == nil)
  #expect(OSC8Payload.link(from: "plain text") == nil)
}

@Test("行内 URL 检测器在 Unicode 前缀后命中任意 scheme 并去除尾部标点")
func inlineURLDetectorFindsCustomSchemesAtCharacterOffset() {
  let line = "打开：codex://session/123，然后继续"
  let offset = line.distance(from: line.startIndex, to: line.firstIndex(of: "s")!)

  let detected = InlineURLDetector.url(in: line, atCharacterOffset: offset)

  #expect(detected == "codex://session/123")
  #expect(InlineURLDetector.url(in: line, atCharacterOffset: 0) == nil)
  #expect(
    InlineURLDetector.url(
      in: "codex://session/very-long-fragment",
      atCharacterOffset: 10,
      rightBoundaryMayContinue: true
    ) == nil)
  let wrappedLines = ["前缀 codex://session/very-", "long-identifier 后缀"]
  #expect(
    InlineURLDetector.url(
      inPhysicalLines: wrappedLines,
      clickedLine: 0,
      atCharacterOffset: 12,
      finalBoundaryMayContinue: false
    ) == "codex://session/very-long-identifier")
  #expect(
    InlineURLDetector.url(
      inPhysicalLines: wrappedLines,
      clickedLine: 1,
      atCharacterOffset: 4,
      finalBoundaryMayContinue: false
    ) == "codex://session/very-long-identifier")
}
