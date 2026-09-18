// 远端 Shell 集成的探测与安装：marker、rc 追加块、幂等安装脚本与探测输出解析。

import Foundation

// MARK: - 模型

/// 支持安装远端集成的 Shell。
public enum RemoteShellIntegrationShell: String, CaseIterable, Equatable, Sendable {
  case bash
  case zsh
  case fish
}

/// 单个 Shell 的安装状态。
public enum RemoteShellIntegrationState: String, Equatable, Sendable {
  /// rc 里已有 marker（fish 为 conf.d 文件已存在）。
  case installed
  /// rc 存在但没有 marker。
  case absent
  /// rc 文件不存在。
  case noRC
}

/// 远端集成探测结果。
public struct RemoteShellIntegrationStatus: Equatable, Sendable {
  /// 远端 `$HOME`。
  public var home: String
  /// 远端 `$SHELL`，可能为空字符串。
  public var loginShell: String
  public var bash: RemoteShellIntegrationState
  public var zsh: RemoteShellIntegrationState
  public var fish: RemoteShellIntegrationState

  public init(
    home: String,
    loginShell: String,
    bash: RemoteShellIntegrationState,
    zsh: RemoteShellIntegrationState,
    fish: RemoteShellIntegrationState
  ) {
    self.home = home
    self.loginShell = loginShell
    self.bash = bash
    self.zsh = zsh
    self.fish = fish
  }

  /// 取指定 Shell 的状态。
  public func state(for shell: RemoteShellIntegrationShell) -> RemoteShellIntegrationState {
    switch shell {
    case .bash: return bash
    case .zsh: return zsh
    case .fish: return fish
    }
  }

  /// 登录 Shell 对应的枚举；`$SHELL` 不是三者之一时返回 nil。
  public var loginShellKind: RemoteShellIntegrationShell? {
    for shell in RemoteShellIntegrationShell.allCases where loginShell.hasSuffix("/" + shell.rawValue) {
      return shell
    }
    return nil
  }
}

// MARK: - 安装与探测

/// 生成远端集成的探测 / 安装脚本，并解析探测输出。所有远端路径都以 `$HOME` 展开，不在本地拼绝对路径。
public enum RemoteShellIntegrationInstall {
  /// rc 块起始 marker；幂等判断只认这一行。
  public static let beginMarker = "# >>> aster remote integration v1 >>>"
  /// rc 块结束 marker。
  public static let endMarker = "# <<< aster remote integration <<<"

  /// 远端集成脚本落地路径（脚本内文本，含未展开的 `$HOME`）。
  public static func remoteScriptPath(for shell: RemoteShellIntegrationShell) -> String {
    switch shell {
    case .bash: return "$HOME/.config/aster/shell-integration.bash"
    case .zsh: return "$HOME/.config/aster/shell-integration.zsh"
    // fish 天然支持 conf.d 自动加载，脚本直接落在那里，不需要改任何 rc。
    case .fish: return "$HOME/.config/fish/conf.d/aster.fish"
    }
  }

  /// 需要追加 marker 块的 rc 路径；fish 不改 rc，返回 nil。
  public static func rcPath(for shell: RemoteShellIntegrationShell) -> String? {
    switch shell {
    case .bash: return "$HOME/.bashrc"
    case .zsh: return "${ZDOTDIR:-$HOME}/.zshrc"
    case .fish: return nil
    }
  }

  /// rc 追加块。只做一次条件 source，保持 rc 内容最小且可直接读懂。
  public static func rcBlock(for shell: RemoteShellIntegrationShell) -> String? {
    guard rcPath(for: shell) != nil else { return nil }
    let path = remoteScriptPath(for: shell)
    return """
      \(beginMarker)
      [ -f "\(path)" ] && . "\(path)"
      \(endMarker)
      """
  }

  /// 安装会改动的远端路径，用于安装前的确认列表。
  public static func plannedPaths(for shells: [RemoteShellIntegrationShell], home: String) -> [String] {
    var paths: [String] = []
    for shell in shells {
      paths.append(expand(remoteScriptPath(for: shell), home: home))
      if let rc = rcPath(for: shell) { paths.append(expand(rc, home: home)) }
    }
    return paths
  }

  /// 把脚本里的 `$HOME` / `${ZDOTDIR:-$HOME}` 换成实际家目录，只用于展示。
  private static func expand(_ path: String, home: String) -> String {
    path
      .replacingOccurrences(of: "${ZDOTDIR:-$HOME}", with: home)
      .replacingOccurrences(of: "$HOME", with: home)
  }

  // MARK: 探测

  /// 探测命令 argv：`["/bin/sh", "-c", <script>, "sh"]`。
  public static func inspectCommand() -> [String] {
    ["/bin/sh", "-c", inspectScript, "sh"]
  }

  /// 探测脚本。用 `grep -qF` 匹配 marker，不做正则，避免 marker 里的字符被当成模式。
  static let inspectScript: String = {
    let marker = RemoteSSHInvocation.quote(beginMarker)
    return """
      printf 'ASTER_RI_V1\\n'
      printf 'home=%s\\n' "$HOME"
      printf 'shell=%s\\n' "${SHELL:-}"
      marker=\(marker)
      rc="$HOME/.bashrc"
      if [ -f "$rc" ]; then
        if grep -qF "$marker" "$rc" 2>/dev/null; then printf 'bash=installed\\n'; else printf 'bash=absent\\n'; fi
      else
        printf 'bash=norc\\n'
      fi
      zrc="${ZDOTDIR:-$HOME}/.zshrc"
      if [ -f "$zrc" ]; then
        if grep -qF "$marker" "$zrc" 2>/dev/null; then printf 'zsh=installed\\n'; else printf 'zsh=absent\\n'; fi
      else
        printf 'zsh=norc\\n'
      fi
      if [ -f "$HOME/.config/fish/conf.d/aster.fish" ]; then
        printf 'fish=installed\\n'
      else
        printf 'fish=absent\\n'
      fi
      exit 0
      """
  }()

  /// 解析探测输出；缺 `ASTER_RI_V1` 首行返回 nil（多半是登录 Shell 往 stdout 打了横幅）。
  public static func parseInspect(_ text: String) -> RemoteShellIntegrationStatus? {
    var values: [String: String] = [:]
    var sawHeader = false
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if !sawHeader {
        guard line == "ASTER_RI_V1" else { return nil }
        sawHeader = true
        continue
      }
      guard let separator = line.firstIndex(of: "=") else { continue }
      values[String(line[line.startIndex..<separator])] = String(line[line.index(after: separator)...])
    }
    guard sawHeader else { return nil }
    return RemoteShellIntegrationStatus(
      home: values["home"] ?? "",
      loginShell: values["shell"] ?? "",
      bash: state(values["bash"]),
      zsh: state(values["zsh"]),
      fish: state(values["fish"])
    )
  }

  private static func state(_ text: String?) -> RemoteShellIntegrationState {
    switch text {
    case "installed": return .installed
    case "norc": return .noRC
    default: return .absent
    }
  }

  // MARK: 安装

  /// 安装命令 argv。`scripts` 是每个 Shell 的集成脚本原文，由调用方从应用包资源读出。
  ///
  /// 脚本内容全部经 `RemoteSSHInvocation.quote` 单引号转义后作为 `printf '%s'` 的参数，
  /// 远端 Shell 不会对内容做任何展开；先写 staging 再 `mv -f`，避免写一半的文件被 rc source 到。
  public static func installCommand(scripts: [RemoteShellIntegrationShell: String]) -> [String] {
    ["/bin/sh", "-c", installScript(scripts: scripts), "sh"]
  }

  static func installScript(scripts: [RemoteShellIntegrationShell: String]) -> String {
    var lines: [String] = []
    lines.append("umask 077")
    lines.append("mkdir -p \"$HOME/.config/aster\" || exit 1")
    if scripts[.fish] != nil {
      lines.append("mkdir -p \"$HOME/.config/fish/conf.d\" || exit 1")
    }
    lines.append("marker=\(RemoteSSHInvocation.quote(beginMarker))")

    // 固定顺序生成，保证同样的入参得到同样的脚本文本（便于测试与日志比对）。
    for shell in RemoteShellIntegrationShell.allCases {
      guard let contents = scripts[shell] else { continue }
      let target = remoteScriptPath(for: shell)
      let staging = stagingPath(for: shell)
      lines.append("printf '%s' \(RemoteSSHInvocation.quote(contents)) > \"\(staging)\" || exit 1")
      lines.append("mv -f \"\(staging)\" \"\(target)\" || exit 1")
      guard let rc = rcPath(for: shell), let block = rcBlock(for: shell) else { continue }
      lines.append("rc=\"\(rc)\"")
      let append =
        "grep -qF \"$marker\" \"$rc\" 2>/dev/null || printf '\\n%s\\n' \(RemoteSSHInvocation.quote(block)) >> \"$rc\" || exit 1"
      // rc 不存在时只为登录 Shell 新建：在一台只跑 bash 的机器上凭空造 .zshrc
      // （反之亦然）会让用户以为 Aster 改了不相干的配置。fish 走 conf.d，不改 rc。
      lines.append(
        "case \"${SHELL:-}\" in */\(shell.rawValue)) create=1 ;; *) create=0 ;; esac")
      lines.append("if [ -f \"$rc\" ] || [ \"$create\" = 1 ]; then")
      lines.append("  " + append)
      lines.append("fi")
    }
    lines.append("printf 'ASTER_RI_INSTALL_OK\\n'")
    lines.append("exit 0")
    return lines.joined(separator: "\n")
  }

  /// staging 文件名以点开头并带固定后缀，便于人工识别与清理残留。
  static func stagingPath(for shell: RemoteShellIntegrationShell) -> String {
    let target = remoteScriptPath(for: shell)
    guard let separator = target.lastIndex(of: "/") else { return target + ".aster-staging" }
    let directory = String(target[target.startIndex..<separator])
    let name = String(target[target.index(after: separator)...])
    return "\(directory)/.\(name).aster-staging"
  }

  /// 安装成功的哨兵行。
  public static let installSuccessMarker = "ASTER_RI_INSTALL_OK"
}
