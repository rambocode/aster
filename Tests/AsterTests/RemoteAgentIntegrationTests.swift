import AsterCore
import Foundation
import Testing

@testable import Aster

/// 远端 Agent 集成：同一套 `AgentSetupService` 规则跑在抽象文件系统上，以及 SSH 文件系统原语解析。

/// 纯内存文件系统：模拟远端 home 树，记录写入以便断言。
private final class MemoryFileSystem: AgentSetupFileSystem, @unchecked Sendable {
  private let lock = NSLock()
  var files: [String: Data] = [:]
  var directories: Set<String>
  var permissions: [String: NSNumber] = [:]
  private(set) var writes: [String] = []

  init(directories: Set<String>) { self.directories = directories }

  func node(atPath path: String) throws -> AgentSetupNode? {
    lock.lock(); defer { lock.unlock() }
    if let data = files[path] { return AgentSetupNode(kind: .regularFile, size: data.count) }
    if directories.contains(path) { return AgentSetupNode(kind: .directory, size: 0) }
    return nil
  }
  func readFile(atPath path: String) throws -> Data {
    lock.lock(); defer { lock.unlock() }
    guard let data = files[path] else { throw CocoaError(.fileNoSuchFile) }
    return data
  }
  func permissions(atPath path: String) throws -> NSNumber? { permissions[path] }
  func createDirectory(atPath path: String) throws {
    lock.lock(); defer { lock.unlock() }
    var current = ""
    for component in path.split(separator: "/") {
      current += "/" + component
      directories.insert(current)
    }
  }
  func writeFile(_ data: Data, atPath path: String, permissions: NSNumber?) throws {
    lock.lock(); defer { lock.unlock() }
    files[path] = data
    writes.append(path)
    if let permissions { self.permissions[path] = permissions }
  }
  func removeFile(atPath path: String) throws {
    lock.lock(); defer { lock.unlock() }
    files.removeValue(forKey: path)
  }
}

private let remoteHome = "/root"
private let remoteHook = RemoteAgentIntegrationInstaller.hookScriptPath(homeDirectory: remoteHome)

private func makeRemoteService(_ fs: MemoryFileSystem, installed: Set<AgentProvider>)
  -> AgentSetupService
{
  AgentSetupService(
    homeDirectory: URL(fileURLWithPath: remoteHome, isDirectory: true),
    integrationScriptURL: URL(fileURLWithPath: remoteHook),
    fileSystem: fs,
    executableResolver: { installed.contains($0) ? $0.commandName : nil })
}

@Test("远端 home 上安装 Claude Code hook：写入远端 settings.json，命令指向远端 hook 脚本")
func remoteAgentSetupInstallsClaudeHooksAgainstRemoteHome() throws {
  let fs = MemoryFileSystem(directories: [remoteHome, "/root/.local", "/root/.local/share"])
  fs.files[remoteHook] = Data("#!/bin/sh\n".utf8)
  let service = makeRemoteService(fs, installed: [.claudeCode])

  let before = try service.status(for: .claudeCode)
  #expect(before.executablePath == "claude")
  #expect(!before.managedIntegrationInstalled)

  let after = try service.install(.claudeCode)
  #expect(after.managedIntegrationInstalled)
  let settings = try #require(fs.files["/root/.claude/settings.json"])
  // JSONSerialization 会把 `/` 写成 `\/`，按解码后的结构断言而不是按原文。
  let root = try #require(try JSONSerialization.jsonObject(with: settings) as? [String: Any])
  let hooks = try #require(root["hooks"] as? [String: Any])
  let commands = hooks.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
    .compactMap { entry -> String? in
      guard entry["_aster"] as? Bool == true else { return nil }
      let inner = entry["hooks"] as? [[String: Any]] ?? []
      return inner.first?["command"] as? String
    }
  #expect(!commands.isEmpty)
  #expect(commands.contains("/bin/sh '\(remoteHook)' processing claudeCode"))
  #expect(commands.allSatisfy { $0.contains(remoteHook) })
  // 目录按需创建在远端 home 下，不碰别处。
  #expect(fs.directories.contains("/root/.claude"))
  #expect(fs.writes == ["/root/.claude/settings.json"])

  // 卸载只摘掉 Aster 条目。
  _ = try service.uninstall(.claudeCode)
  #expect(!(try service.status(for: .claudeCode).managedIntegrationInstalled))
}

@Test("远端 grok：TOML 受管区块写入 ~/.grok/config.toml，保留用户已有内容")
func remoteAgentSetupInstallsGrokTOMLBlock() throws {
  let fs = MemoryFileSystem(directories: [remoteHome, "/root/.grok"])
  fs.files[remoteHook] = Data("#!/bin/sh\n".utf8)
  fs.files["/root/.grok/config.toml"] = Data("[model]\nname = \"grok-4\"\n".utf8)
  fs.permissions["/root/.grok/config.toml"] = NSNumber(value: 0o600)
  let service = makeRemoteService(fs, installed: [.grokBuild])

  _ = try service.install(.grokBuild)
  let text = String(decoding: try #require(fs.files["/root/.grok/config.toml"]), as: UTF8.self)
  #expect(text.hasPrefix("[model]\nname = \"grok-4\"\n"))
  #expect(text.contains(AgentSetupService.managedTOMLStartMarker))
  #expect(text.contains("[[hooks.SessionStart]]"))
  #expect(text.contains("'\(remoteHook)' idle grokBuild"))
  // 原文件权限位原样带回。
  #expect(fs.permissions["/root/.grok/config.toml"] == NSNumber(value: 0o600))
  #expect(try service.status(for: .grokBuild).managedIntegrationInstalled)
}

@Test("远端未装的 CLI 不可安装；hook 脚本缺失时报资源不可用而不是乱写配置")
func remoteAgentSetupRefusesWithoutExecutableOrHook() throws {
  let fs = MemoryFileSystem(directories: [remoteHome])
  let service = makeRemoteService(fs, installed: [])
  #expect(throws: AgentSetupServiceError.executableUnavailable("claude")) {
    try service.install(.claudeCode)
  }
  let withCLI = makeRemoteService(fs, installed: [.grokBuild])
  #expect(throws: AgentSetupServiceError.integrationResourceUnavailable) {
    try withCLI.install(.grokBuild)
  }
  #expect(fs.writes.isEmpty)
}

/// 脚本化 ssh：按顺序返回预置结果并记录 argv。
private final class ScriptedRunner: RemoteSSHRunning, @unchecked Sendable {
  private let lock = NSLock()
  var results: [RemoteSSHResult]
  private(set) var invocations: [[String]] = []
  init(_ results: [RemoteSSHResult]) { self.results = results }
  func run(arguments: [String], timeout: TimeInterval) throws -> RemoteSSHResult {
    lock.lock(); defer { lock.unlock() }
    invocations.append(arguments)
    guard !results.isEmpty else { throw ManagedSessionError.runtimeUnavailable("脚本已用尽") }
    return results.removeFirst()
  }
}

@Test("SSH 文件系统原语：lstat 输出、权限位与读取都按位置参数传路径，不做 Shell 拼接")
func remoteAgentSetupFileSystemParsesShellOutput() throws {
  let transport = RemoteSessionTransport(
    target: try RemoteSSHTarget.parse("root@ubuntu@orb"),
    policy: RemoteSSHPolicy.fromEnvironment([:]), managedConfiguration: nil)
  let runner = ScriptedRunner([
    RemoteSSHResult(exitStatus: 0, standardOutput: "file 42\n", standardError: ""),
    RemoteSSHResult(exitStatus: 0, standardOutput: "missing 0\n", standardError: ""),
    RemoteSSHResult(exitStatus: 0, standardOutput: "symlink 0\n", standardError: ""),
    RemoteSSHResult(exitStatus: 0, standardOutput: "600\n", standardError: ""),
    RemoteSSHResult(exitStatus: 0, standardOutput: "hello\n", standardError: ""),
    RemoteSSHResult(exitStatus: 1, standardOutput: "", standardError: "cat: no such file"),
  ])
  let fs = RemoteAgentSetupFileSystem(transport: transport, runner: runner)
  let path = "/root/.claude/it's here.json"
  #expect(try fs.node(atPath: path) == AgentSetupNode(kind: .regularFile, size: 42))
  #expect(try fs.node(atPath: path) == nil)
  #expect(try fs.node(atPath: path)?.kind == .symbolicLink)
  #expect(try fs.permissions(atPath: path) == NSNumber(value: 0o600))
  #expect(try fs.readFile(atPath: path) == Data("hello\n".utf8))
  #expect(throws: AgentSetupServiceError.self) { try fs.readFile(atPath: path) }
  // ssh 把远端命令合成一个已引用的字符串：路径只出现在末尾的位置参数里（已做 Shell 引用），
  // 含单引号也不影响脚本本身。
  let quotedPath = RemoteSSHInvocation.quote(path)
  for argv in runner.invocations {
    let remote = try #require(argv.last)
    #expect(remote.hasSuffix(quotedPath))
    #expect(remote.hasPrefix("'/bin/sh' '-c' "))
  }
}
