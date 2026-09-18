import Foundation
import Testing

@testable import AsterCore

/// 远端 Shell 集成：rc 块与 marker、安装脚本在真实 sh 下的幂等性、探测解析与脚本转义往返。

// MARK: - 夹具

/// 仓库根目录。用 `#filePath` 反推，避免依赖测试进程的工作目录。
private var repositoryRoot: URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

/// 读取仓库里的远端集成脚本原文。
private func remoteScriptContents(_ name: String) throws -> String {
  let url = repositoryRoot
    .appendingPathComponent("Resources/shell-integration/remote")
    .appendingPathComponent(name)
  return try String(contentsOf: url, encoding: .utf8)
}

/// 跑一条 argv 并返回退出码与 stdout；环境变量完全由调用方给定。
@discardableResult
private func run(_ argv: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: argv[0])
  process.arguments = Array(argv.dropFirst())
  process.environment = environment
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = Pipe()
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func makeHome() throws -> URL {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-remote-home-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}

private func sampleScripts() -> [RemoteShellIntegrationShell: String] {
  [.bash: "# bash payload\n", .zsh: "# zsh payload\n", .fish: "# fish payload\n"]
}

// MARK: - rc 块

@Test func remoteShellIntegrationRCBlockCarriesMarkers() throws {
  let block = try #require(RemoteShellIntegrationInstall.rcBlock(for: .bash))
  #expect(block.hasPrefix(RemoteShellIntegrationInstall.beginMarker))
  #expect(block.hasSuffix(RemoteShellIntegrationInstall.endMarker))
  #expect(block.contains("$HOME/.config/aster/shell-integration.bash"))

  let zshBlock = try #require(RemoteShellIntegrationInstall.rcBlock(for: .zsh))
  #expect(zshBlock.contains("$HOME/.config/aster/shell-integration.zsh"))
  #expect(RemoteShellIntegrationInstall.rcPath(for: .zsh) == "${ZDOTDIR:-$HOME}/.zshrc")

  // fish 用 conf.d 自动加载，不碰任何 rc。
  #expect(RemoteShellIntegrationInstall.rcBlock(for: .fish) == nil)
  #expect(RemoteShellIntegrationInstall.rcPath(for: .fish) == nil)
  #expect(
    RemoteShellIntegrationInstall.remoteScriptPath(for: .fish)
      == "$HOME/.config/fish/conf.d/aster.fish"
  )
}

@Test func remoteShellIntegrationPlannedPathsExpandHome() {
  let paths = RemoteShellIntegrationInstall.plannedPaths(for: [.bash, .fish], home: "/root")
  #expect(
    paths == [
      "/root/.config/aster/shell-integration.bash",
      "/root/.bashrc",
      "/root/.config/fish/conf.d/aster.fish",
    ]
  )
}

@Test func remoteShellIntegrationInstallScriptUsesStagingAndIdempotentAppend() {
  let script = RemoteShellIntegrationInstall.installScript(scripts: sampleScripts())
  #expect(script.hasPrefix("umask 077"))
  #expect(script.contains("mkdir -p \"$HOME/.config/aster\""))
  #expect(script.contains("mkdir -p \"$HOME/.config/fish/conf.d\""))
  // 先写 staging 再 mv -f：rc 不可能 source 到写了一半的文件。
  #expect(script.contains(".shell-integration.bash.aster-staging"))
  #expect(script.contains("mv -f"))
  #expect(script.contains("grep -qF \"$marker\""))
  // bash 的 rc 不存在时要看 $SHELL 才决定是否新建。
  #expect(script.contains("case \"${SHELL:-}\" in */bash)"))
  #expect(!script.contains("conf.d/aster.fish\" >>"))
}

// MARK: - 真实 sh 下的安装

@Test func remoteShellIntegrationInstallCreatesFilesAndAppendsOnce() throws {
  let home = try makeHome()
  defer { try? FileManager.default.removeItem(at: home) }
  try Data("# user bashrc\n".utf8).write(to: home.appendingPathComponent(".bashrc"))
  // .zshrc 预先存在：rc 已存在的 Shell 无论登录 Shell 是谁都要追加。
  try Data("# user zshrc\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
  let environment = ["HOME": home.path, "SHELL": "/bin/bash", "PATH": "/usr/bin:/bin"]

  let argv = RemoteShellIntegrationInstall.installCommand(scripts: sampleScripts())
  let first = try run(argv, environment: environment)
  #expect(first.status == 0)
  #expect(first.output.contains(RemoteShellIntegrationInstall.installSuccessMarker))

  let bashScript = home.appendingPathComponent(".config/aster/shell-integration.bash")
  #expect(try String(contentsOf: bashScript, encoding: .utf8) == "# bash payload\n")
  #expect(
    try String(
      contentsOf: home.appendingPathComponent(".config/fish/conf.d/aster.fish"), encoding: .utf8
    ) == "# fish payload\n"
  )
  // staging 文件必须已经被 mv 掉，不能留残留。
  #expect(
    !FileManager.default.fileExists(
      atPath: home.appendingPathComponent(".config/aster/.shell-integration.bash.aster-staging").path
    )
  )

  func markerCount(_ path: String) throws -> Int {
    let text = try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    return text.components(separatedBy: RemoteShellIntegrationInstall.beginMarker).count - 1
  }
  #expect(try markerCount(".bashrc") == 1)
  #expect(try markerCount(".zshrc") == 1)

  // 再装一次不能重复追加。
  let second = try run(argv, environment: environment)
  #expect(second.status == 0)
  #expect(try markerCount(".bashrc") == 1)
  #expect(try markerCount(".zshrc") == 1)
}

@Test func remoteShellIntegrationInstallSkipsMissingBashRCForOtherLoginShells() throws {
  let home = try makeHome()
  defer { try? FileManager.default.removeItem(at: home) }
  let environment = ["HOME": home.path, "SHELL": "/usr/bin/zsh", "PATH": "/usr/bin:/bin"]

  let result = try run(
    RemoteShellIntegrationInstall.installCommand(scripts: sampleScripts()), environment: environment
  )
  #expect(result.status == 0)
  // 登录 Shell 不是 bash 且没有 .bashrc：不能凭空造一个让用户困惑的 rc。
  #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".bashrc").path))
  #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
}

// MARK: - 探测

@Test func remoteShellIntegrationInspectReportsPerShellState() throws {
  let home = try makeHome()
  defer { try? FileManager.default.removeItem(at: home) }
  try Data("# user zshrc\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
  let environment = ["HOME": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"]

  let before = try run(RemoteShellIntegrationInstall.inspectCommand(), environment: environment)
  let beforeStatus = try #require(RemoteShellIntegrationInstall.parseInspect(before.output))
  #expect(beforeStatus.home == home.path)
  #expect(beforeStatus.loginShell == "/bin/zsh")
  #expect(beforeStatus.loginShellKind == .zsh)
  #expect(beforeStatus.bash == .noRC)
  #expect(beforeStatus.zsh == .absent)
  #expect(beforeStatus.fish == .absent)

  _ = try run(
    RemoteShellIntegrationInstall.installCommand(scripts: sampleScripts()), environment: environment
  )
  let after = try run(RemoteShellIntegrationInstall.inspectCommand(), environment: environment)
  let afterStatus = try #require(RemoteShellIntegrationInstall.parseInspect(after.output))
  #expect(afterStatus.zsh == .installed)
  #expect(afterStatus.fish == .installed)
  #expect(afterStatus.state(for: .zsh) == .installed)
}

@Test func remoteShellIntegrationInspectParsingRejectsNoisyOutput() {
  // 远端登录 Shell 打了横幅，首行不是协议头，整条丢弃。
  #expect(RemoteShellIntegrationInstall.parseInspect("Welcome!\nASTER_RI_V1\nhome=/root\n") == nil)
  #expect(RemoteShellIntegrationInstall.parseInspect("") == nil)

  let status = try? #require(
    RemoteShellIntegrationInstall.parseInspect("ASTER_RI_V1\nhome=/root\nshell=/bin/sh\nbash=installed\n")
  )
  #expect(status?.bash == .installed)
  // 缺失的行按「未安装」处理，不臆测。
  #expect(status?.zsh == .absent)
  #expect(status?.loginShellKind == nil)
}

// MARK: - 远端脚本

@Test func remoteIntegrationScriptsSurviveShellQuotingRoundTrip() throws {
  for name in ["aster-remote.bash", "aster-remote.zsh", "aster-remote.fish"] {
    let contents = try remoteScriptContents(name)
    let quoted = RemoteSSHInvocation.quote(contents)
    // 安装脚本正是这样把内容交给远端 sh 的；转义出错会直接变成远端执行任意代码。
    let result = try run(
      ["/bin/sh", "-c", "printf '%s' \(quoted)"], environment: ["PATH": "/usr/bin:/bin"]
    )
    #expect(result.status == 0)
    #expect(result.output == contents)
  }
}

@Test func remoteIntegrationScriptsAreSyntacticallyValid() throws {
  let environment = ["PATH": "/usr/bin:/bin"]
  let bash = repositoryRoot.appendingPathComponent(
    "Resources/shell-integration/remote/aster-remote.bash"
  ).path
  #expect(try run(["/bin/bash", "-n", bash], environment: environment).status == 0)

  let zsh = repositoryRoot.appendingPathComponent(
    "Resources/shell-integration/remote/aster-remote.zsh"
  ).path
  if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
    #expect(try run(["/bin/zsh", "-n", zsh], environment: environment).status == 0)
  }
}

@Test func remoteIntegrationScriptsReportRemoteHostInOSC7() throws {
  for name in ["aster-remote.bash", "aster-remote.zsh", "aster-remote.fish"] {
    let contents = try remoteScriptContents(name)
    // OSC 7 必须带远端主机名；写死 localhost 会让本地误判成本机路径。
    #expect(contents.contains("]7;file://%s%s"))
    #expect(!contents.contains("file://localhost"))
    #expect(contents.contains("ASTER_REMOTE_INTEGRATION_DISABLE"))
    #expect(contents.contains("133;A"))
    #expect(contents.contains("133;C"))
  }
}

@Test("rc 不存在时只为登录 Shell 新建，不给其它 Shell 凭空造配置")
func installScriptCreatesMissingRCOnlyForLoginShell() {
  let script = RemoteShellIntegrationInstall.installScript(
    scripts: [.bash: "# bash", .zsh: "# zsh"])
  #expect(script.contains("*/bash) create=1"))
  #expect(script.contains("*/zsh) create=1"))
  // 两个 Shell 都要走同一道「文件存在或本机就是它」的门槛。
  #expect(script.components(separatedBy: "if [ -f \"$rc\" ] || [ \"$create\" = 1 ]").count == 3)
}
