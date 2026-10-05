import Foundation

// 把 `aster-ssh config list --json` 的结果合并进已保存主机（对应 tty7 `merge_imported`，Apache-2.0）。
//
// 纯函数：输入现有主机与解析结果，输出新的完整列表与汇总；不读写文件，由调用方决定是否保存。
// 导入的主机都放在 `SSHHostProfile.importedGroup` 组里，按名称（alias）在组内去重：
// 已存在就更新 ssh_config 能表达的字段，保留用户在 Aster 里另设的认证方式、代理与校验开关。

/// 一条无法映射成 `jumpHostID` 的 ProxyJump。
public struct SSHConfigUnresolvedJump: Equatable, Sendable {
  /// 设了 ProxyJump 的主机名（alias）。
  public var host: String
  /// ssh_config 里的原始 ProxyJump 值。
  public var proxyJump: String

  public init(host: String, proxyJump: String) {
    self.host = host
    self.proxyJump = proxyJump
  }
}

/// 一台因参数非法而没有导入的主机。
public struct SSHConfigRejectedHost: Equatable, Sendable {
  public var alias: String
  /// `SSHHostStore.validate` 给出的原因（去掉了下标前缀）。
  public var reasons: [String]

  public init(alias: String, reasons: [String]) {
    self.alias = alias
    self.reasons = reasons
  }
}

/// 一次导入的结果：合并后的完整列表与给用户看的汇总。
public struct SSHConfigImportResult: Equatable, Sendable {
  /// 合并后的全部主机（含默认项与未导入的主机），可直接交给 `SSHHostStore.save`。
  public var hosts: [SSHHostProfile]
  public var added: Int
  public var updated: Int
  public var unchanged: Int
  /// 第一跳不是已导入 alias 的 ProxyJump。
  public var unresolvedJumps: [SSHConfigUnresolvedJump]
  /// 参数非法、整条跳过的主机。
  public var rejected: [SSHConfigRejectedHost]
  /// 解析器忽略的选项（原样转交）。
  public var ignored: [SSHConfigIgnoredOption]
}

/// ssh_config 导入规则。
public enum SSHConfigImport {
  /// 合并一次解析结果。
  ///
  /// - Parameters:
  ///   - listing: `aster-ssh config list` 的输出。
  ///   - existing: 当前全部主机（含默认项）。
  ///   - makeID: 新主机的 ID 生成器，测试可注入固定值。
  /// - Returns: 新的完整列表与汇总；`existing` 里非导入组的主机原样保留、顺序不变。
  public static func merge(
    _ listing: SSHConfigListing,
    into existing: [SSHHostProfile],
    makeID: () -> UUID = UUID.init
  ) -> SSHConfigImportResult {
    var hosts = existing
    var originals: [UUID: SSHHostProfile] = [:]
    var added = 0
    var rejected: [SSHConfigRejectedHost] = []
    var jumpRequests: [(id: UUID, name: String, raw: String)] = []
    var seenAliases: Set<String> = []

    for entry in listing.hosts {
      let alias = entry.alias.trimmingCharacters(in: .whitespacesAndNewlines)
      // 通配模式不是一台具体主机；同名 alias 按 ssh 的「第一个匹配生效」只取第一次出现。
      guard !alias.isEmpty, !isPattern(alias), seenAliases.insert(alias).inserted else { continue }

      let index = hosts.firstIndex { $0.group == SSHHostProfile.importedGroup && $0.name == alias }
      var profile =
        index.map { hosts[$0] }
        ?? SSHHostProfile(id: makeID(), name: alias, group: SSHHostProfile.importedGroup)
      apply(entry, alias: alias, to: &profile)

      // 单条先校验（跳板稍后映射，这里不带），一台主机写错不能拖垮整次导入。
      var probe = profile
      probe.jumpHostID = nil
      let reasons = SSHHostStore.validate([.emptyDefaults(), probe]).map(stripIndexTag)
      guard reasons.isEmpty else {
        rejected.append(SSHConfigRejectedHost(alias: alias, reasons: reasons))
        continue
      }

      if let index {
        originals[profile.id] = hosts[index]
        hosts[index] = profile
      } else {
        hosts.append(profile)
        added += 1
      }
      if let raw = entry.proxyJump?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
        jumpRequests.append((profile.id, alias, raw))
      }
    }

    // 跳板在全部主机落位之后再映射，这样 ProxyJump 指向文件里靠后的 alias 也能找到。
    var unresolved: [SSHConfigUnresolvedJump] = []
    for request in jumpRequests {
      guard let position = hosts.firstIndex(where: { $0.id == request.id }) else { continue }
      // `ProxyJump none` 是显式「不走跳板」，清掉即可，不算无法映射。
      guard let alias = firstHopAlias(request.raw) else {
        hosts[position].jumpHostID = nil
        continue
      }
      let target = hosts.first {
        $0.group == SSHHostProfile.importedGroup && $0.name == alias && $0.id != request.id
      }
      hosts[position].jumpHostID = target?.id
      if target == nil {
        unresolved.append(SSHConfigUnresolvedJump(host: request.name, proxyJump: request.raw))
      }
    }

    var updated = 0
    var unchanged = 0
    for (id, original) in originals {
      if hosts.first(where: { $0.id == id }) == original { unchanged += 1 } else { updated += 1 }
    }
    return SSHConfigImportResult(
      hosts: hosts, added: added, updated: updated, unchanged: unchanged,
      unresolvedJumps: unresolved, rejected: rejected, ignored: listing.ignored)
  }

  /// 把 ssh_config 能表达的字段写进主机；其余字段（认证方式、代理、校验开关等）保持原值。
  static func apply(_ entry: SSHConfigHostEntry, alias: String, to profile: inout SSHHostProfile) {
    let hostName = entry.hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    profile.name = alias
    profile.group = SSHHostProfile.importedGroup
    profile.host = hostName.isEmpty ? alias : hostName
    profile.port = entry.port
    profile.user = entry.user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    profile.identityFiles = entry.identityFiles
    profile.identitiesOnly = entry.identitiesOnly
    // 原文照搬（含 `none`、`$VAR`）；ssh_config 里没写就清掉，回到继承默认项。
    let identityAgent = entry.identityAgent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    profile.identityAgent = identityAgent.isEmpty ? nil : identityAgent
    // `none` 表示不使用任何 known_hosts；原样保留交给 broker 按 OpenSSH 语义处理。
    profile.knownHostsFiles = entry.userKnownHostsFiles.isEmpty ? nil : entry.userKnownHostsFiles
    let proxyCommand = entry.proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    profile.proxyCommand = proxyCommand.isEmpty ? nil : proxyCommand
    profile.forwards = entry.forwards
    profile.keepaliveInterval = entry.keepaliveInterval
    profile.keepaliveCountMax = entry.keepaliveCountMax
  }

  /// 取 ProxyJump 第一跳的主机部分：去掉 `ssh://`、`user@` 与 `:port`，保留 `[v6]` 里的地址。
  /// 返回 nil 表示第一跳为空或是 `none`。
  static func firstHopAlias(_ raw: String) -> String? {
    var hop = raw.split(separator: ",", maxSplits: 1).first.map(String.init) ?? raw
    hop = hop.trimmingCharacters(in: .whitespaces)
    if hop.lowercased().hasPrefix("ssh://") { hop.removeFirst(6) }
    if let at = hop.lastIndex(of: "@") { hop = String(hop[hop.index(after: at)...]) }
    if hop.hasPrefix("["), let close = hop.firstIndex(of: "]") {
      hop = String(hop[hop.index(after: hop.startIndex)..<close])
    } else if hop.filter({ $0 == ":" }).count == 1, let colon = hop.firstIndex(of: ":") {
      hop = String(hop[..<colon])
    }
    guard !hop.isEmpty, hop.lowercased() != "none" else { return nil }
    return hop
  }

  /// ssh_config 的 Host 模式字符（`*`、`?`、`!`）出现时，这一条不是具体主机。
  static func isPattern(_ alias: String) -> Bool {
    alias.contains { $0 == "*" || $0 == "?" || $0 == "!" }
  }

  /// 去掉 `SSHHostStore.validate` 原因前面的 `[下标] `。
  public static func stripIndexTag(_ reason: String) -> String {
    guard reason.hasPrefix("["), let close = reason.firstIndex(of: "]") else { return reason }
    return reason[reason.index(after: close)...].trimmingCharacters(in: .whitespaces)
  }
}
