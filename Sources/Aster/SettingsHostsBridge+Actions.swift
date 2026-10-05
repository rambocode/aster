import AppKit
import AsterCore
import Foundation

// 「主机」分类的动作：保存、复制、删除、忘记口令、添加为机器、导入与编辑 ~/.ssh/config。
// 每个动作都以 `complete(succeeded)` 结束，SettingsViewController 据此给网页发回执。

/// 主机动作失败的原因。文案直接给用户看。
enum SettingsHostsError: Error, Equatable {
  case invalidPayload
  case unknownHost
  case invalidProfile([String])
  case noTextEditor

  var message: String {
    switch self {
    case .invalidPayload: L("主机参数无效")
    case .unknownHost: L("主机不存在，可能已被删除")
    case .invalidProfile(let reasons): L("主机配置无效：\(reasons.joined(separator: "；"))")
    case .noTextEditor: L("找不到可以打开纯文本文件的编辑器")
    }
  }
}

extension SettingsHostsBridge {
  /// 网页回传的主机对象最大字节数；远大于任何正常配置，只挡异常输入。
  static let maximumPayloadBytes = 64 * 1024
  static let maximumForwards = 64
  /// 私钥文件与 known_hosts 文件各自的最多行数。
  static let maximumIdentityFiles = 16

  /// 分发一个 `hosts.` 前缀的动作。未知动作 toast 报错并回执失败。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) {
    switch action {
    case "hosts.save": save(payload, complete: complete)
    case "hosts.duplicate": duplicate(payload, complete: complete)
    case "hosts.delete": delete(payload, complete: complete)
    case "hosts.forgetPassword": forgetPassword(payload, complete: complete)
    case "hosts.addMachine": addMachine(payload, complete: complete)
    case "hosts.import": importSSHConfig(complete: complete)
    case "hosts.editSSHConfig": editSSHConfig(complete: complete)
    default:
      toast(L("“\(action)”尚无可用的 macOS 操作"), true)
      complete(false)
    }
  }

  // MARK: - 保存

  /// 新增或更新一台主机（含默认项）。先整份校验，失败时 toast 原因且不落盘。
  private func save(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let profile = try Self.decodeProfile(payload["profile"])
      var candidate = directory.hosts
      if let index = candidate.firstIndex(where: { $0.id == profile.id }) {
        candidate[index] = profile
      } else {
        candidate.append(profile)
      }
      try Self.validate(profile, in: candidate)
      try directory.upsert(profile)
      pushSnapshot()
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  /// 解码网页回传的主机对象，并做只属于边界的限制（大小、条目数、控制字符）。
  static func decodeProfile(_ raw: Any?) throws -> SSHHostProfile {
    guard let object = raw as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
      throw SettingsHostsError.invalidPayload
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    guard data.count <= maximumPayloadBytes else { throw SettingsHostsError.invalidPayload }
    var profile: SSHHostProfile
    do { profile = try JSONDecoder().decode(SSHHostProfile.self, from: data) } catch {
      throw SettingsHostsError.invalidPayload
    }
    // 空 known_hosts 列表与 nil 同义（都继承默认项），统一存成 nil，文件里不留空数组。
    if profile.knownHostsFiles?.isEmpty == true { profile.knownHostsFiles = nil }
    // 空白的 identityAgent 同理存成 nil（继承），前后空白不属于路径。
    let identityAgent = profile.identityAgent?.trimmingCharacters(in: .whitespaces) ?? ""
    profile.identityAgent = identityAgent.isEmpty ? nil : identityAgent
    guard profile.forwards.count <= maximumForwards,
      profile.identityFiles.count <= maximumIdentityFiles,
      (profile.knownHostsFiles?.count ?? 0) <= maximumIdentityFiles
    else { throw SettingsHostsError.invalidPayload }
    // `SSHHostStore.validate` 只查 host/user/group 的换行；这里补齐其余会进入 argv 或
    // 配置文件的文本字段，任何控制字符都拒绝。
    let texts =
      [
        profile.name, profile.host, profile.user, profile.group ?? "", profile.proxyCommand ?? "",
        profile.identityAgent ?? "",
      ]
      + profile.identityFiles + (profile.knownHostsFiles ?? [])
      + [profile.socksProxy?.host ?? "", profile.httpProxy?.host ?? ""]
      + profile.forwards.flatMap { [$0.bind.host, $0.target.host, $0.description] }
    let hasControl = texts.contains { text in
      text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    if hasControl { throw SettingsHostsError.invalidProfile([L("不能包含换行或控制字符")]) }
    return profile
  }

  /// 按存储规则校验候选列表，只报告与这台主机相关的原因；再确认跳板链可以解析。
  static func validate(_ profile: SSHHostProfile, in candidate: [SSHHostProfile]) throws {
    let normalized = SSHHostStore.normalized(candidate)
    let reasons = SSHHostStore.validate(normalized)
    if !reasons.isEmpty {
      let tag = normalized.firstIndex(where: { $0.id == profile.id }).map { "[\($0)]" }
      let own = reasons.filter { tag.map($0.hasPrefix) ?? true }
      throw SettingsHostsError.invalidProfile((own.isEmpty ? reasons : own).map(friendlyReason))
    }
    guard !profile.isDefaults else { return }
    // validate 只挡「跳板是自己」；更长的环与过深的链要靠解析才能发现。
    do {
      _ = try SSHHostResolver.resolve(profile.id, in: normalized)
    } catch SSHHostResolutionError.jumpCycle {
      throw SettingsHostsError.invalidProfile([L("跳板机形成了循环")])
    } catch SSHHostResolutionError.jumpTooDeep {
      throw SettingsHostsError.invalidProfile(
        [L("跳板链超过 \(SSHHostResolver.maximumJumpDepth) 层")])
    } catch {
      throw SettingsHostsError.invalidProfile([L("主机无法解析：\(String(describing: error))")])
    }
  }

  /// 把 `SSHHostStore.validate` 的英文原因换成给用户看的中文。
  static func friendlyReason(_ reason: String) -> String {
    switch SSHConfigImport.stripIndexTag(reason) {
    case "empty name": L("名称不能为空")
    case "empty host": L("主机不能为空")
    case "newline in host/user": L("主机和用户名不能换行")
    case "invalid group": L("分组名过长或包含换行")
    case "invalid port": L("端口必须在 1–65535 之间")
    case "invalid proxy": L("代理地址不能为空，端口必须在 1–65535 之间")
    case "invalid forward": L("端口转发的端口无效")
    case "invalid jumpHostID": L("跳板机无效：不能选自己，也不能选已删除的主机")
    case "negative timing": L("keepalive 与超时不能是负数")
    case "duplicate id": L("主机 ID 重复")
    case let other: other
    }
  }

  // MARK: - 复制、删除、忘记口令

  /// 复制一台主机：新 ID、名称加「副本」。导入组归 ssh_config 管，副本放到未分组。
  private func duplicate(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let source = try savedHost(payload)
      // `id` 是 let，只能逐字段构造新值。
      let copy = SSHHostProfile(
        name: L("\(source.name) 副本"),
        group: source.group == SSHHostProfile.importedGroup ? nil : source.group,
        host: source.host, port: source.port, user: source.user, jumpHostID: source.jumpHostID,
        proxyCommand: source.proxyCommand, socksProxy: source.socksProxy, httpProxy: source.httpProxy,
        auth: source.auth, identityFiles: source.identityFiles,
        identitiesOnly: source.identitiesOnly, knownHostsFiles: source.knownHostsFiles,
        identityAgent: source.identityAgent,
        agentForward: source.agentForward, forwards: source.forwards,
        keepaliveInterval: source.keepaliveInterval, keepaliveCountMax: source.keepaliveCountMax,
        connectTimeout: source.connectTimeout, verifyHostKeys: source.verifyHostKeys)
      try directory.upsert(copy)
      pushSnapshot()
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  /// 删除一台主机。只有没有其它主机共用同一 endpoint 时，才顺带删掉钥匙串里的口令。
  private func delete(_ payload: [String: Any], complete: (Bool) -> Void) {
    let profile: SSHHostProfile
    do { profile = try savedHost(payload) } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    let hosts = directory.hosts
    // 删除之前算：删完就解析不到它的 endpoint 了。
    let endpoint = Self.credentialEndpoints(hosts)[profile.id]
    let sharing = SSHHostStore.hostsSharingCredential(with: profile.id, in: hosts)
    do {
      try directory.remove(profile.id)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    if let endpoint, sharing.isEmpty, dependencies.passwords.hasPassword(for: endpoint) {
      do {
        try dependencies.passwords.deletePassword(for: endpoint)
      } catch {
        toast(L("主机已删除，但没能从钥匙串删除口令：\(Self.describe(error))"), true)
      }
    }
    pushSnapshot()
    complete(true)
  }

  /// 忘记这台主机 endpoint 的口令。共用 endpoint 的主机会一起失去口令，确认框已提示。
  private func forgetPassword(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let profile = try savedHost(payload)
      guard let endpoint = Self.credentialEndpoints(directory.hosts)[profile.id] else {
        throw SettingsHostsError.invalidProfile([L("主机无法解析，找不到对应的口令")])
      }
      try dependencies.passwords.deletePassword(for: endpoint)
      toast(L("已忘记“\(profile.name)”的口令"), false)
      pushSnapshot()
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  // MARK: - 添加为机器

  /// 以这台主机为预填值弹出「添加机器」流程。流程本身异步，回执只表示已经弹出。
  private func addMachine(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let profile = try savedHost(payload)
      dependencies.addMachine(
        MachineSetupFlow.Prefill(label: profile.name, hostID: profile.id), window())
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  // MARK: - ~/.ssh/config

  /// 从 `~/.ssh/config` 导入：合并进导入组，保存后把汇总发给网页显示。
  private func importSSHConfig(complete: @escaping (Bool) -> Void) {
    guard !isImporting else {
      complete(false)
      return
    }
    isImporting = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isImporting = false }
      do {
        let listing = try await self.dependencies.configListing()
        // 合并基于读取完成那一刻的列表，等待期间其它窗口的修改不会被覆盖。
        let current = self.directory.hosts
        let result = SSHConfigImport.merge(listing, into: current)
        if result.hosts != current {
          try self.directory.store.save(result.hosts)
          self.directory.reload()
        }
        self.postMessage(["type": "hostsImportReport", "report": Self.reportJSON(result)])
        self.pushSnapshot()
        complete(true)
      } catch {
        self.toast(L("无法导入 ~/.ssh/config：\(Self.describe(error))"), true)
        complete(false)
      }
    }
  }

  /// 导入汇总的网页形状。
  static func reportJSON(_ result: SSHConfigImportResult) -> [String: Any] {
    [
      "added": result.added,
      "updated": result.updated,
      "unchanged": result.unchanged,
      "ignored": result.ignored.map {
        ["file": $0.file, "line": $0.line, "option": $0.option, "reason": $0.reason] as [String: Any]
      },
      "unresolvedJumps": result.unresolvedJumps.map { ["host": $0.host, "proxyJump": $0.proxyJump] },
      "rejected": result.rejected.map {
        ["alias": $0.alias, "reasons": $0.reasons.map(friendlyReason)] as [String: Any]
      },
    ]
  }

  /// 用默认编辑器打开 `~/.ssh/config`；文件不存在时先建目录（0700）和空文件（0600）。
  private func editSSHConfig(complete: @escaping (Bool) -> Void) {
    let url = dependencies.sshConfigURL
    do {
      try Self.ensureSSHConfigFile(at: url)
    } catch {
      toast(L("无法创建 ~/.ssh/config：\(Self.describe(error))"), true)
      complete(false)
      return
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.dependencies.openInEditor(url)
        complete(true)
      } catch {
        self.toast(L("无法打开 ~/.ssh/config：\(Self.describe(error))"), true)
        complete(false)
      }
    }
  }

  /// 确保配置文件存在。已存在的文件（可能是指向 dotfiles 的软链）不改权限、不改内容。
  static func ensureSSHConfigFile(at url: URL, fileManager: FileManager = .default) throws {
    guard !fileManager.fileExists(atPath: url.path) else { return }
    let directory = url.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: directory.path) {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    guard fileManager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
  }

  // MARK: - 工具

  /// 按 payload 里的 `id` 找一台已保存主机（不含默认项）。
  private func savedHost(_ payload: [String: Any]) throws -> SSHHostProfile {
    guard let raw = payload["id"] as? String, let id = UUID(uuidString: raw) else {
      throw SettingsHostsError.invalidPayload
    }
    guard let profile = directory.host(id), !profile.isDefaults else {
      throw SettingsHostsError.unknownHost
    }
    return profile
  }

  /// 把各类错误转成一句给用户看的话。
  static func describe(_ error: Error) -> String {
    switch error {
    case let error as SettingsHostsError: return error.message
    case SSHHostStoreError.invalidHosts(let reasons):
      return L("主机配置无效：\(reasons.map(friendlyReason).joined(separator: "；"))")
    case SSHHostStoreError.corrupted(let detail): return L("hosts.json 已损坏：\(detail)")
    case SSHHostStoreError.ioFailure(let detail): return L("读写 hosts.json 失败：\(detail)")
    case SSHBrokerError.executableMissing:
      return L("找不到 aster-ssh，请重新构建 Aster.app")
    case SSHBrokerError.startFailed(let detail): return L("aster-ssh 启动失败：\(detail)")
    default: return error.localizedDescription
    }
  }
}
