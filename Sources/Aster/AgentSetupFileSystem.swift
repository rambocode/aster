import AsterCore
import Foundation

/// `AgentSetupService` 触碰文件系统的全部原语。
///
/// 抽出来的原因：远端机器上的 Agent hook 安装要走 SSH，但 JSON/TOML 合并、所有权标记、
/// 原子替换与回滚这套规则和本机完全一样，不能再抄一份。服务只依赖这几个原语，本机用
/// `FileManager`/`lstat`，远端用 `sh` + 上传实现，规则层一个字节不改。
protocol AgentSetupFileSystem: Sendable {
  /// `lstat` 语义：不跟随 symlink；路径不存在返回 nil。
  func node(atPath path: String) throws -> AgentSetupNode?
  /// 读取普通文件全部内容。调用方已经用 `node` 校验过类型与大小。
  func readFile(atPath path: String) throws -> Data
  /// POSIX 权限位；取不到返回 nil。
  func permissions(atPath path: String) throws -> NSNumber?
  /// 递归创建目录；已存在不报错。
  func createDirectory(atPath path: String) throws
  /// 原子写入（临时文件 + rename）；`permissions` 非 nil 时同时恢复权限位。
  func writeFile(_ data: Data, atPath path: String, permissions: NSNumber?) throws
  func removeFile(atPath path: String) throws
}

/// 一个路径节点的类型与大小（`lstat` 结果）。
struct AgentSetupNode: Equatable, Sendable {
  enum Kind: Equatable, Sendable { case directory, regularFile, symbolicLink, other }
  var kind: Kind
  var size: Int
}

/// 本机实现：与抽象之前的行为逐一对应。
struct LocalAgentSetupFileSystem: AgentSetupFileSystem {
  // FileManager 本身线程安全但未标 Sendable；这里只做同步文件调用，不跨任务共享可变状态。
  nonisolated(unsafe) let fileManager: FileManager

  init(fileManager: FileManager = .default) { self.fileManager = fileManager }

  func node(atPath path: String) throws -> AgentSetupNode? {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw CocoaError(.fileReadUnknown)
    }
    let kind: AgentSetupNode.Kind =
      switch info.st_mode & S_IFMT {
      case S_IFDIR: .directory
      case S_IFREG: .regularFile
      case S_IFLNK: .symbolicLink
      default: .other
      }
    return AgentSetupNode(kind: kind, size: Int(info.st_size))
  }

  func readFile(atPath path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
  }

  func permissions(atPath path: String) throws -> NSNumber? {
    try fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
  }

  func createDirectory(atPath path: String) throws {
    try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
  }

  func writeFile(_ data: Data, atPath path: String, permissions: NSNumber?) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    if let permissions {
      try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }
  }

  func removeFile(atPath path: String) throws {
    try fileManager.removeItem(atPath: path)
  }
}

/// 远端实现：每个原语一次 ssh 往返，命令全部走 `/bin/sh -c` + 位置参数，路径不做 Shell 拼接。
///
/// `lstat` 用 `[ -L ]` 先于 `[ -d ]`/`[ -f ]` 判定（后两者会跟随链接）；大小用 `wc -c`；
/// 权限位先试 GNU `stat -c %a`，再退 BSD `stat -f %Lp`（macOS 远端）。写入先 `umask 077`
/// 上传到同目录临时文件，再 `mv -f` 走 rename(2) 原子替换，与本机 `.atomic` 语义一致。
struct RemoteAgentSetupFileSystem: AgentSetupFileSystem {
  let transport: RemoteSessionTransport
  let runner: any RemoteSSHRunning
  let timeout: TimeInterval

  init(
    transport: RemoteSessionTransport,
    runner: any RemoteSSHRunning = RemoteSSHProcessRunner(),
    timeout: TimeInterval = 30
  ) {
    self.transport = transport
    self.runner = runner
    self.timeout = timeout
  }

  /// 在远端跑一段 `sh -c` 脚本，`$1…` 是位置参数。非零退出抛错，stderr 经脱敏进入错误文本。
  private func shell(_ script: String, _ arguments: [String]) throws -> String {
    let result = try runner.run(
      arguments: transport.sshArguments(remoteCommand: ["/bin/sh", "-c", script, "sh"] + arguments),
      timeout: timeout)
    guard result.exitStatus == 0 else {
      throw AgentSetupServiceError.remoteCommandFailed(
        RemoteSSHDiagnostics.redact(result.standardError).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return result.standardOutput
  }

  func node(atPath path: String) throws -> AgentSetupNode? {
    let output = try shell(
      """
      p="$1"
      if [ -L "$p" ]; then echo symlink 0
      elif [ -d "$p" ]; then echo directory 0
      elif [ -f "$p" ]; then printf 'file %s\\n' "$(wc -c < "$p" | tr -d ' ')"
      elif [ -e "$p" ]; then echo other 0
      else echo missing 0
      fi
      """, [path])
    let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard parts.count == 2, let size = Int(parts[1]) else {
      throw AgentSetupServiceError.remoteCommandFailed(L("无法识别远端 stat 输出"))
    }
    switch parts[0] {
    case "missing": return nil
    case "symlink": return AgentSetupNode(kind: .symbolicLink, size: size)
    case "directory": return AgentSetupNode(kind: .directory, size: size)
    case "file": return AgentSetupNode(kind: .regularFile, size: size)
    default: return AgentSetupNode(kind: .other, size: size)
    }
  }

  func readFile(atPath path: String) throws -> Data {
    // 配置文件全是文本；`RemoteSSHResult` 以 UTF-8 解码，非 UTF-8 内容本来就会被服务拒绝。
    Data(try shell("cat -- \"$1\"", [path]).utf8)
  }

  func permissions(atPath path: String) throws -> NSNumber? {
    let output = try shell(
      "stat -c %a -- \"$1\" 2>/dev/null || stat -f %Lp -- \"$1\" 2>/dev/null || true", [path])
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int(text, radix: 8) else { return nil }
    return NSNumber(value: value)
  }

  func createDirectory(atPath path: String) throws {
    _ = try shell("mkdir -p -- \"$1\"", [path])
  }

  func writeFile(_ data: Data, atPath path: String, permissions: NSNumber?) throws {
    // 先落到本机临时文件，再用安装事务同一条 `cat >` 通道上传到远端同目录临时文件。
    let local = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-agent-setup-\(UUID().uuidString)")
    try data.write(to: local, options: .atomic)
    defer { try? FileManager.default.removeItem(at: local) }
    let staging = path + ".aster-\(UUID().uuidString.prefix(8)).tmp"
    try RemoteSSHInstallExecutor(transport: transport, runner: runner)
      .upload(localPath: local.path, remotePath: staging)
    let mode = permissions.map { String($0.intValue, radix: 8) } ?? ""
    _ = try shell(
      """
      staging="$1"; target="$2"; mode="$3"
      if [ -n "$mode" ]; then chmod "$mode" -- "$staging"; fi
      mv -f -- "$staging" "$target"
      """, [staging, path, mode])
  }

  func removeFile(atPath path: String) throws {
    _ = try shell("rm -f -- \"$1\"", [path])
  }
}
