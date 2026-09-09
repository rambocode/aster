import Foundation

/// 远端平台、候选二进制与运行中服务的探测（P3.3）。
///
/// 三类信息**分别记录**，不互相推断：
/// 1. 平台/架构：决定哪个发行产物可用，也决定「不匹配平台的本地二进制不得复制到远端」。
/// 2. 候选二进制：按 PATH → Aster 私有安装目录 → 已知包管理器目录的顺序发现，
///    每个候选都单独执行协议探测，不因为第一个能跑就跳过其余。
/// 3. 运行中服务：只探测和连接，**不安装、不替换、不重启**（§4.1「后台连接仅探测和连接」）。

/// 远端平台标识。未知值原样保留，用于诊断，不猜测。
public struct RemotePlatform: Equatable, Sendable {
  /// `uname -s` 归一后的值：`linux` / `macos` / 其它原文。
  public var os: String
  /// `uname -m` 归一后的值：`x86_64` / `arm64` / 其它原文。
  public var architecture: String
  /// 远端 `$HOME`，用于推导私有安装目录与测试目录。
  public var homeDirectory: String

  public init(os: String, architecture: String, homeDirectory: String) {
    self.os = os
    self.architecture = architecture
    self.homeDirectory = homeDirectory
  }

  /// `uname` 输出归一。只做已知别名映射，未知值原样保留。
  public static func normalizeOS(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "linux": "linux"
    case "darwin": "macos"
    case let other: other
    }
  }

  public static func normalizeArchitecture(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "x86_64", "amd64": "x86_64"
    case "arm64", "aarch64": "arm64"
    case let other: other
    }
  }
}

/// 单个候选二进制的探测结果。发行版本、协议版本、能力集合分开记录。
public struct RemoteBinaryCandidate: Equatable, Sendable {
  /// 远端绝对路径。
  public var path: String
  /// 发现来源，用于界面说明与 A11 证据。
  public var source: RemoteBinarySource
  /// `--version` 报出的发行版本；无法解析时为 nil。
  public var releaseVersion: String?
  /// 协议主版本。
  public var protocolMajor: Int?
  /// 协议次版本。
  public var protocolMinor: Int?
  /// 该候选在探测时报出的能力集合（只有握手成功才有值）。
  public var capabilities: [String]
  /// 探测失败原因（已脱敏）。
  public var failure: String?

  public init(
    path: String,
    source: RemoteBinarySource,
    releaseVersion: String? = nil,
    protocolMajor: Int? = nil,
    protocolMinor: Int? = nil,
    capabilities: [String] = [],
    failure: String? = nil
  ) {
    self.path = path
    self.source = source
    self.releaseVersion = releaseVersion
    self.protocolMajor = protocolMajor
    self.protocolMinor = protocolMinor
    self.capabilities = capabilities
    self.failure = failure
  }
}

/// 候选二进制的发现来源，顺序即发现顺序。
public enum RemoteBinarySource: String, Equatable, Sendable, CaseIterable {
  case path
  case asterPrivateInstall
  case packageManager
  case explicitOverride
}

/// 客户端要求的协议主版本与必需能力。
public enum RemoteProtocolContract {
  /// 当前客户端实现的协议主版本。主版本不同即不兼容，直接拒绝。
  public static let clientProtocolMajor = 1
  /// P3 阶段的必需能力集合。
  ///
  /// 与 `SessionRuntime/src/terminal_attach.zig` 的 `negotiateRequired` 完全一致：
  /// 显示桥真正依赖的就是这三项。设计草案 §5 还列了 `session_snapshot`，但那是
  /// workspace/tab 共享结构（P4.2）才使用的能力，当前服务也不广播它；P3 若把它
  /// 列为必需，会把可用服务误判成不兼容。P4 接入共享工作区时再加入本集合。
  public static let requiredCapabilities = [
    "terminal_control", "surface_interest", "health_check",
  ]
  /// 可选能力：缺失只禁用对应动作，不阻断连接。
  public static let optionalCapabilities = [
    "server_lifecycle", "terminal_observe", "session_snapshot", "screen_history", "upload",
    "agent_recovery", "handoff",
  ]
}

/// 兼容性判定结果。次版本不同**不等于**不兼容。
public enum RemoteCompatibility: Equatable, Sendable {
  /// 可直接连接。`missingOptional` 只禁用对应动作。
  case compatible(missingOptional: [String])
  /// 协议主版本不同，必须显式处理（替换服务），后台不得自动停止它。
  case incompatibleMajor(remote: Int, client: Int)
  /// 必需能力缺失。
  case missingRequiredCapability([String])
  /// 探测失败，结果未知；不得当作「可以安装覆盖」。
  case unknown(String)

  /// 是否允许后台直接连接。
  public var allowsBackgroundConnect: Bool {
    if case .compatible = self { return true }
    return false
  }
}

/// 兼容性判定。纯函数，便于用固定样例做定向测试。
public enum RemoteCompatibilityCheck {
  /// 依据协议主版本与能力集合判定。
  ///
  /// 顺序重要：先判主版本，主版本不同就不该继续用它的能力集合下结论，
  /// 因为能力名在不同主版本之间没有可比性。
  public static func evaluate(protocolMajor: Int?, capabilities: [String]) -> RemoteCompatibility {
    guard let protocolMajor else { return .unknown("协议版本未知") }
    guard protocolMajor == RemoteProtocolContract.clientProtocolMajor else {
      return .incompatibleMajor(
        remote: protocolMajor, client: RemoteProtocolContract.clientProtocolMajor)
    }
    let present = Set(capabilities)
    let missingRequired = RemoteProtocolContract.requiredCapabilities.filter {
      !present.contains($0)
    }
    if !missingRequired.isEmpty { return .missingRequiredCapability(missingRequired) }
    let missingOptional = RemoteProtocolContract.optionalCapabilities.filter {
      !present.contains($0)
    }
    return .compatible(missingOptional: missingOptional)
  }

  /// 能力缺失时给用户的明确提示（P3.7）。不假装动作可用，只说明被禁用的范围。
  public static func unavailableActionMessage(missingOptional: [String]) -> String? {
    guard !missingOptional.isEmpty else { return nil }
    let names = missingOptional.map(actionDescription).joined(separator: "、")
    return "该远端服务缺少可选能力：\(names)。相关动作已禁用，其余终端功能不受影响。"
  }

  private static func actionDescription(_ capability: String) -> String {
    switch capability {
    case "server_lifecycle": "显式停止/替换服务"
    case "terminal_observe": "只读观察"
    case "session_snapshot": "共享工作区结构"
    case "screen_history": "屏幕历史"
    case "upload": "图片上传"
    case "agent_recovery": "Agent 原生恢复"
    case "handoff": "实时交接"
    default: capability
    }
  }
}

/// 一次完整探测的结果。
public struct RemoteProbeReport: Equatable, Sendable {
  public var platform: RemotePlatform
  /// 按发现顺序排列的候选。
  public var candidates: [RemoteBinaryCandidate]
  /// 目标命名会话上正在运行的服务身份；没有服务时为 nil。
  public var runningServer: SessionServerIdentity?
  /// 运行中服务的兼容性；没有服务时为 nil。
  public var runningCompatibility: RemoteCompatibility?

  public init(
    platform: RemotePlatform,
    candidates: [RemoteBinaryCandidate],
    runningServer: SessionServerIdentity? = nil,
    runningCompatibility: RemoteCompatibility? = nil
  ) {
    self.platform = platform
    self.candidates = candidates
    self.runningServer = runningServer
    self.runningCompatibility = runningCompatibility
  }

  /// 第一个协议主版本兼容的候选。没有则需要显式安装事务。
  ///
  /// 这里只能按协议主版本筛选：`--version` 探测拿不到能力集合（`capabilities` 恒为空），
  /// 能力必须等真正握手才有值。若在这里用 `RemoteCompatibilityCheck.evaluate`，
  /// 每个候选都会因为「必需能力缺失」被排除，永远返回 nil。最终兼容判定由
  /// `RemoteMachineSetup` 在握手之后完成。
  public var preferredCandidate: RemoteBinaryCandidate? {
    candidates.first { $0.protocolMajor == RemoteProtocolContract.clientProtocolMajor }
  }
}

/// 探测脚本生成与输出解析。脚本是纯 POSIX sh，不依赖远端安装任何工具。
public enum RemoteHostProbe {
  /// 探测输出的版本标记，防止把别的命令输出当成探测结果。
  public static let marker = "ASTER_PROBE_V1"

  /// Aster 私有安装目录下的二进制路径。
  public static func privateInstallPath(homeDirectory: String) -> String {
    "\(homeDirectory)/.local/share/aster/bin/aster-session"
  }

  /// 已知包管理器目录。顺序固定，便于证据复查。
  public static let packageManagerPaths = [
    "/usr/local/bin/aster-session",
    "/opt/homebrew/bin/aster-session",
    "/opt/aster/bin/aster-session",
  ]

  /// 生成探测脚本 argv。
  ///
  /// 一次 SSH 往返拿到平台、`$HOME` 与全部候选的 `--version`：往返次数直接决定
  /// 添加机器的等待时间，而每个候选单独一次 ssh 会把耗时放大到不可接受。
  /// 脚本对每个候选都执行 `--version`，不因为前一个成功就短路。
  public static func probeCommand(explicitPath: String?) -> [String] {
    let explicit = explicitPath.map { RemoteSSHInvocation.quote($0) } ?? "''"
    let script = """
      set -u
      printf '%s\\n' \(RemoteSSHInvocation.quote(marker))
      printf 'os=%s\\n' "$(uname -s 2>/dev/null || echo unknown)"
      printf 'arch=%s\\n' "$(uname -m 2>/dev/null || echo unknown)"
      printf 'home=%s\\n' "$HOME"
      explicit=\(explicit)
      candidates=""
      if [ -n "$explicit" ]; then candidates="$explicit"; fi
      onpath="$(command -v aster-session 2>/dev/null || true)"
      if [ -n "$onpath" ]; then candidates="$candidates
      $onpath"; fi
      candidates="$candidates
      $HOME/.local/share/aster/bin/aster-session
      /usr/local/bin/aster-session
      /opt/homebrew/bin/aster-session
      /opt/aster/bin/aster-session"
      printf '%s\\n' "$candidates" | while IFS= read -r c; do
        [ -n "$c" ] || continue
        if [ -x "$c" ]; then
          v="$("$c" --version 2>/dev/null | head -n 1 || true)"
          printf 'candidate=%s\\t%s\\n' "$c" "$v"
        fi
      done
      printf '%s\\n' 'end'
      """
    return ["/bin/sh", "-c", script]
  }

  /// 解析探测脚本输出。缺少标记即视为输出不可信，返回 nil。
  public static func parse(_ output: String, explicitPath: String?) -> RemoteProbeReport? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
      return nil
    }
    var os = "unknown"
    var architecture = "unknown"
    var home = ""
    var candidates: [RemoteBinaryCandidate] = []
    var seen = Set<String>()
    for line in lines {
      if let value = line.dropPrefixIfPresent("os=") {
        os = RemotePlatform.normalizeOS(value)
      } else if let value = line.dropPrefixIfPresent("arch=") {
        architecture = RemotePlatform.normalizeArchitecture(value)
      } else if let value = line.dropPrefixIfPresent("home=") {
        home = value.trimmingCharacters(in: .whitespaces)
      } else if let value = line.dropPrefixIfPresent("candidate=") {
        let parts = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? "")
        guard !path.isEmpty, seen.insert(path).inserted else { continue }
        let versionText = parts.count > 1 ? String(parts[1]) : ""
        let parsed = parseVersionLine(versionText)
        candidates.append(
          RemoteBinaryCandidate(
            path: path,
            source: source(for: path, explicitPath: explicitPath, homeDirectory: home),
            releaseVersion: parsed.release,
            protocolMajor: parsed.major,
            protocolMinor: parsed.minor,
            capabilities: [],
            failure: parsed.release == nil ? "无法解析 --version 输出" : nil
          ))
      }
    }
    return RemoteProbeReport(
      platform: RemotePlatform(os: os, architecture: architecture, homeDirectory: home),
      candidates: candidates
    )
  }

  /// 解析 `aster-session 0.1.0-dev protocol=1.0` 形式的版本行。
  public static func parseVersionLine(_ text: String) -> (
    release: String?, major: Int?, minor: Int?
  ) {
    let fields = text.split(separator: " ").map(String.init)
    guard fields.count >= 2, fields[0] == "aster-session" else { return (nil, nil, nil) }
    let release = fields[1]
    var major: Int?
    var minor: Int?
    for field in fields.dropFirst(2) where field.hasPrefix("protocol=") {
      let version = field.dropFirst("protocol=".count).split(separator: ".")
      major = version.count > 0 ? Int(version[0]) : nil
      minor = version.count > 1 ? Int(version[1]) : nil
    }
    return (release, major, minor)
  }

  private static func source(for path: String, explicitPath: String?, homeDirectory: String)
    -> RemoteBinarySource
  {
    if let explicitPath, explicitPath == path { return .explicitOverride }
    if !homeDirectory.isEmpty, path == privateInstallPath(homeDirectory: homeDirectory) {
      return .asterPrivateInstall
    }
    if packageManagerPaths.contains(path) { return .packageManager }
    return .path
  }
}

extension String {
  /// 去掉指定前缀；不匹配返回 nil。探测输出逐行解析用。
  fileprivate func dropPrefixIfPresent(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}
