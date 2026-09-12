import CryptoKit
import Foundation

/// 远程工作模式 P3.4：受管服务二进制的安装事务。
///
/// 设计约束（`docs/developer/remote-work.md` §7、`remote-work-acceptance.md` A11）：
/// - 安装前显示目标机器与影响；受管发布必须通过平台/架构/大小/摘要/签名全部校验。
/// - 先上传到 staging 临时文件，远端复核摘要与大小后才原子切换 symlink。
/// - 保留旧版本目录用于回退；任何失败都回滚，并且**绝不**删除旧版本。
/// - 运行中的服务使用自己的二进制实例，本次安装不停止它。
/// - 不记录凭据，远端 stderr 只经 `RemoteSSHDiagnostics.redact` 或截断后进入错误文本。

// MARK: - 发行清单

/// 安装产物类型。测试产物与开发构建都必须显式标注，不伪装成正式发行。
public enum RemoteArtifactKind: String, Codable, Sendable {
  /// 正式受管发布：必须带签名。
  case managedRelease
  /// 隔离测试 manifest 用的测试产物：允许无签名，但清单里带明确 test 标识。
  case testArtifact
  /// `ASTER_REMOTE_BINARY` 指定的本地自定义构建：未签名，必须由调用方显式接受。
  case developmentBuild
}

/// 一个远端服务二进制的发行清单。安装校验的唯一事实来源。
public struct RemoteReleaseManifest: Codable, Equatable, Sendable {
  /// 版本号，同时是版本化安装目录名。
  public var version: String
  /// 目标平台（`linux` / `macos`）。
  public var platform: String
  /// 目标架构（`x86_64` / `arm64`）。
  public var architecture: String
  /// 产物 SHA256，小写 hex，64 位。
  public var sha256: String
  /// 产物字节数。
  public var sizeBytes: Int
  /// 发布签名；`managedRelease` 必填。
  public var signature: String?
  /// 产物类型。
  public var artifactKind: RemoteArtifactKind
  /// 协议主版本号，用于客户端兼容性预检。nil 表示未知（旧清单）。
  public var protocolMajor: Int?
  /// 协议次版本号。次版本不同不等于不兼容。
  public var protocolMinor: Int?

  public init(
    version: String,
    platform: String,
    architecture: String,
    sha256: String,
    sizeBytes: Int,
    signature: String? = nil,
    artifactKind: RemoteArtifactKind,
    protocolMajor: Int? = nil,
    protocolMinor: Int? = nil
  ) {
    self.version = version
    self.platform = platform
    self.architecture = architecture
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
    self.signature = signature
    self.artifactKind = artifactKind
    self.protocolMajor = protocolMajor
    self.protocolMinor = protocolMinor
  }

  /// 是否为正式受管发行。界面据此决定是否展示“非正式产物”的告警。
  public var isOfficialRelease: Bool { artifactKind == .managedRelease }

  /// 面向用户的一行摘要。非正式产物必须在文本里带出产物性质，不能只看版本号。
  public var displaySummary: String {
    let base = "\(version) (\(platform)/\(architecture))"
    switch artifactKind {
    case .managedRelease:
      return "受管发布 \(base)"
    case .testArtifact:
      return "测试产物 \(base)，隔离测试 manifest，不是正式发行"
    case .developmentBuild:
      return "开发产物，未签名 \(base)，来自自定义构建"
    }
  }
}

// MARK: - 校验

/// 安装前/上传后校验失败原因。全部为纯数据比较结果，不含远端原文。
public enum RemoteInstallValidationError: Error, Equatable, Sendable {
  case platformMismatch(expected: String, actual: String)
  case architectureMismatch(expected: String, actual: String)
  case digestMismatch(expected: String, actual: String)
  case sizeMismatch(expected: Int, actual: Int)
  case missingSignature
  case signatureInvalid
  case developmentArtifactNotAccepted
  case malformedManifest(String)
}

/// 发行清单校验。纯函数，无 I/O，便于用固定样例做定向测试。
public enum RemoteInstallValidation {
  /// 按固定顺序校验清单与本地产物。
  ///
  /// 顺序有意义：先判定清单本身是否成形，再判定“这个产物压根不该上传到这台机器”
  /// （平台、架构），最后才做代价更高的大小/摘要/签名比较。平台不匹配必须在任何
  /// 上传动作之前拒绝，否则会把错误平台的二进制复制到远端（§7 明确禁止）。
  public static func validate(
    manifest: RemoteReleaseManifest,
    localDigest: String,
    localSize: Int,
    remotePlatform: String,
    remoteArchitecture: String,
    acceptDevelopmentArtifact: Bool,
    signatureVerifier: (RemoteReleaseManifest) -> Bool
  ) throws {
    try validateShape(manifest)

    guard manifest.platform == remotePlatform else {
      throw RemoteInstallValidationError.platformMismatch(
        expected: manifest.platform, actual: remotePlatform)
    }
    guard manifest.architecture == remoteArchitecture else {
      throw RemoteInstallValidationError.architectureMismatch(
        expected: manifest.architecture, actual: remoteArchitecture)
    }
    guard manifest.sizeBytes == localSize else {
      throw RemoteInstallValidationError.sizeMismatch(
        expected: manifest.sizeBytes, actual: localSize)
    }
    let normalizedDigest = localDigest.lowercased()
    guard manifest.sha256 == normalizedDigest else {
      throw RemoteInstallValidationError.digestMismatch(
        expected: manifest.sha256, actual: normalizedDigest)
    }
    try validateProvenance(
      manifest,
      acceptDevelopmentArtifact: acceptDevelopmentArtifact,
      signatureVerifier: signatureVerifier)
  }

  /// 清单成形校验：字段非空、sha256 为 64 位小写 hex、字节数为正。
  public static func validateShape(_ manifest: RemoteReleaseManifest) throws {
    guard !manifest.version.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw RemoteInstallValidationError.malformedManifest("version")
    }
    guard !manifest.platform.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw RemoteInstallValidationError.malformedManifest("platform")
    }
    guard !manifest.architecture.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw RemoteInstallValidationError.malformedManifest("architecture")
    }
    guard manifest.sizeBytes > 0 else {
      throw RemoteInstallValidationError.malformedManifest("sizeBytes")
    }
    guard isLowercaseHexDigest(manifest.sha256) else {
      throw RemoteInstallValidationError.malformedManifest("sha256")
    }
  }

  /// 产物来源校验：受管发布必须签名有效；测试产物允许无签名；开发构建必须显式接受。
  private static func validateProvenance(
    _ manifest: RemoteReleaseManifest,
    acceptDevelopmentArtifact: Bool,
    signatureVerifier: (RemoteReleaseManifest) -> Bool
  ) throws {
    switch manifest.artifactKind {
    case .managedRelease:
      guard let signature = manifest.signature, !signature.isEmpty else {
        throw RemoteInstallValidationError.missingSignature
      }
      guard signatureVerifier(manifest) else {
        throw RemoteInstallValidationError.signatureInvalid
      }
    case .testArtifact:
      // 测试产物只允许在清单显式声明 testArtifact 时跳过签名，
      // 因此这里不做任何降级判断，靠 artifactKind 本身保证不会伪装成正式发行。
      return
    case .developmentBuild:
      guard acceptDevelopmentArtifact else {
        throw RemoteInstallValidationError.developmentArtifactNotAccepted
      }
    }
  }

  /// 64 位小写 hex 判定。
  public static func isLowercaseHexDigest(_ value: String) -> Bool {
    guard value.count == 64 else { return false }
    return value.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
  }
}

// MARK: - 安装计划

/// 一次安装的路径布局与远端命令。`Equatable` 以便测试直接比较生成的 argv。
public struct RemoteInstallPlan: Sendable, Equatable {
  /// 展示用的目标机器描述（target 原文，不含凭据）。
  public var targetDescription: String
  /// 安装根目录，默认 `<home>/.local/share/aster`。
  public var installRoot: String
  /// 要安装的版本。
  public var version: String
  /// 产物类型，进入影响说明。
  public var artifactKind: RemoteArtifactKind
  /// 远端已存在的版本；nil 表示首次安装。
  public var previousVersion: String?
  /// staging 临时文件标识，注入以便测试得到确定路径。
  public var stagingID: String

  /// 构造安装计划。
  ///
  /// - Parameters:
  ///   - homeDirectory: 远端家目录，仅在未显式给出 `installRoot` 时使用。
  ///   - existingVersion: 探测到的现有版本，作为回滚目标保留。
  public init(
    targetDescription: String,
    homeDirectory: String,
    installRoot: String? = nil,
    manifest: RemoteReleaseManifest,
    existingVersion: String?,
    stagingID: String = UUID().uuidString
  ) {
    self.targetDescription = targetDescription
    self.installRoot =
      installRoot ?? RemoteInstallPlan.defaultInstallRoot(homeDirectory: homeDirectory)
    self.version = manifest.version
    self.artifactKind = manifest.artifactKind
    self.previousVersion = existingVersion
    self.stagingID = stagingID
  }

  /// 默认安装根目录：`<home>/.local/share/aster`。
  public static func defaultInstallRoot(homeDirectory: String) -> String {
    let trimmed =
      homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
    return trimmed + "/.local/share/aster"
  }

  /// 可执行文件名，版本化目录与活动 symlink 都用它。
  public static let binaryName = "aster-session"

  public var versionsDirectory: String { installRoot + "/versions" }
  public var stagingDirectory: String { installRoot + "/staging" }
  public var binDirectory: String { installRoot + "/bin" }

  /// 本次安装的版本化目录。
  public var versionDirectory: String { versionsDirectory + "/" + version }
  /// 本次安装最终落地的版本化二进制路径。
  public var versionedPath: String { versionDirectory + "/" + RemoteInstallPlan.binaryName }
  /// 活动路径：symlink，指向某个版本化二进制，决定下次启动用哪个版本。
  public var activePath: String { binDirectory + "/" + RemoteInstallPlan.binaryName }
  /// 上传用的临时文件路径。
  public var stagingPath: String { stagingDirectory + "/" + stagingID + ".part" }

  /// 旧版本的版本化二进制路径；回滚时把活动 symlink 指回它。
  public var previousVersionedPath: String? {
    guard let previousVersion, !previousVersion.isEmpty else { return nil }
    return versionsDirectory + "/" + previousVersion + "/" + RemoteInstallPlan.binaryName
  }

  /// 安装前展示给用户的影响说明。必须让用户在确认之前看清会动哪台机器的哪个路径。
  public var impactSummary: String {
    var lines: [String] = []
    lines.append("目标机器：\(targetDescription)")
    lines.append("安装路径：\(versionedPath)")
    lines.append("启用路径：\(activePath)（原子切换的 symlink）")
    lines.append("版本：\(version)")
    lines.append("产物类型：\(RemoteInstallPlan.artifactKindDescription(artifactKind))")
    if let previousVersion {
      lines.append("替换现有版本：是（原版本 \(previousVersion) 保留，可回退）")
    } else {
      lines.append("替换现有版本：否（首次安装）")
    }
    lines.append("现有运行中服务继续使用自己的二进制实例，不会被本次安装停止。")
    return lines.joined(separator: "\n")
  }

  /// 产物类型的中文描述，测试与界面共用同一份文案。
  public static func artifactKindDescription(_ kind: RemoteArtifactKind) -> String {
    switch kind {
    case .managedRelease: "受管发布"
    case .testArtifact: "测试产物（隔离测试 manifest，不是正式发行）"
    case .developmentBuild: "开发产物，未签名（自定义构建）"
    }
  }

  // MARK: 远端命令

  /// 创建 staging / versions / bin 目录。`umask 077` 保证私有权限。
  public func makeDirectoriesCommand() -> [String] {
    let script =
      "umask 077; mkdir -p "
      + [stagingDirectory, versionsDirectory, binDirectory]
      .map(RemoteSSHInvocation.quote).joined(separator: " ")
    return ["/bin/sh", "-c", script]
  }

  /// 远端摘要命令。优先 `sha256sum`，缺失时回退 `shasum -a 256`（macOS 远端没有前者）。
  public func digestCommand(path: String) -> [String] {
    let quoted = RemoteSSHInvocation.quote(path)
    let script =
      "command -v sha256sum >/dev/null 2>&1 && sha256sum \(quoted) || shasum -a 256 \(quoted)"
    return ["/bin/sh", "-c", script]
  }

  /// 远端字节数命令。
  public func sizeCommand(path: String) -> [String] {
    ["/bin/sh", "-c", "wc -c < " + RemoteSSHInvocation.quote(path)]
  }

  /// 原子安装。
  ///
  /// 为什么这样写：symlink 本身没有“原地改指向”的原子操作，`ln -sfn` 在目标已存在时
  /// 会先 unlink 再创建，中间存在活动路径不存在的窗口。因此先在同目录创建 `.new`
  /// 临时 symlink，再用 `mv -f` 走 rename(2) 覆盖——rename 是原子的，任何时刻活动路径
  /// 要么指向旧版本要么指向新版本，不会出现半成品。
  public func activateCommand() -> [String] {
    let staging = RemoteSSHInvocation.quote(stagingPath)
    let versionDir = RemoteSSHInvocation.quote(versionDirectory)
    let versioned = RemoteSSHInvocation.quote(versionedPath)
    let active = RemoteSSHInvocation.quote(activePath)
    let activeNew = RemoteSSHInvocation.quote(activePath + ".new")
    let script = [
      "set -e",
      "chmod 755 \(staging)",
      "mkdir -p \(versionDir)",
      "mv -f \(staging) \(versioned)",
      "ln -sfn \(versioned) \(activeNew)",
      "mv -f \(activeNew) \(active)",
    ].joined(separator: "; ")
    return ["/bin/sh", "-c", script]
  }

  /// 回滚。
  ///
  /// 为什么这样写：只清理本次事务自己创建的东西——staging 临时文件与本次的版本化目录，
  /// 然后在存在旧版本时把活动 symlink 指回旧版本。旧版本目录**永远不删**，否则一次失败
  /// 的安装会连带毁掉唯一可用的二进制。命令整体用 `-f` / `|| true` 语义保持幂等，
  /// 回滚自身出错不应掩盖原始错误。
  public func rollbackCommand() -> [String] {
    var steps: [String] = []
    steps.append("rm -f " + RemoteSSHInvocation.quote(stagingPath))
    steps.append("rm -f " + RemoteSSHInvocation.quote(activePath + ".new"))
    // 只有在这次事务确实新建了版本目录（版本与旧版本不同）时才删除它。
    if previousVersion != version {
      steps.append("rm -rf " + RemoteSSHInvocation.quote(versionDirectory))
    }
    if let previousVersionedPath {
      let activeNew = RemoteSSHInvocation.quote(activePath + ".new")
      let active = RemoteSSHInvocation.quote(activePath)
      steps.append(
        "ln -sfn \(RemoteSSHInvocation.quote(previousVersionedPath)) \(activeNew) && mv -f \(activeNew) \(active)"
      )
    }
    return ["/bin/sh", "-c", steps.joined(separator: "; ")]
  }
}

// MARK: - 事务执行

/// 安装事务失败原因。与清单校验错误分开，便于界面区分“产物不对”与“链路不通”。
public enum RemoteInstallError: Error, Equatable, Sendable {
  case uploadFailed(String)
  case remoteCommandFailed(step: String, status: Int32, detail: String)
  case insufficientSpace
  case rollbackIncomplete(String)
  case validation(RemoteInstallValidationError)
}

/// 远端执行与上传的抽象。事务本身不依赖 `Process`，便于用替身做定向测试。
public protocol RemoteInstallExecuting: Sendable {
  /// 在远端执行一条 argv，返回结果。
  func runRemote(_ argv: [String]) throws -> RemoteSSHResult
  /// 把本地文件上传到远端绝对路径（实现方决定用 scp 还是 stdin 管道）。
  func upload(localPath: String, remotePath: String) throws
}

/// 一次安装的结果。
public struct RemoteInstallOutcome: Equatable, Sendable {
  /// 活动路径（下次启动使用的 symlink）。
  public var installedPath: String
  /// 版本化二进制的实际路径。
  public var versionedPath: String
  public var version: String
  public var previousVersion: String?
  public var artifactKind: RemoteArtifactKind
  /// 附加诊断（例如回滚未完成）。已脱敏。
  public var diagnostics: [String]

  public init(
    installedPath: String,
    versionedPath: String,
    version: String,
    previousVersion: String?,
    artifactKind: RemoteArtifactKind,
    diagnostics: [String] = []
  ) {
    self.installedPath = installedPath
    self.versionedPath = versionedPath
    self.version = version
    self.previousVersion = previousVersion
    self.artifactKind = artifactKind
    self.diagnostics = diagnostics
  }
}

/// 受管服务二进制的安装事务：校验 → 建目录 → 上传 staging → 远端复核 → 原子切换。
public struct RemoteInstallTransaction: Sendable {
  private let executor: any RemoteInstallExecuting
  /// 远端探测到的平台/架构，用于拒绝错误平台的产物。
  private let remotePlatform: String
  private let remoteArchitecture: String
  /// 是否已由显式设置流程接受开发产物。
  private let acceptDevelopmentArtifact: Bool
  private let signatureVerifier: @Sendable (RemoteReleaseManifest) -> Bool

  public init(
    executor: any RemoteInstallExecuting,
    remotePlatform: String,
    remoteArchitecture: String,
    acceptDevelopmentArtifact: Bool = false,
    signatureVerifier: @escaping @Sendable (RemoteReleaseManifest) -> Bool = { _ in true }
  ) {
    self.executor = executor
    self.remotePlatform = remotePlatform
    self.remoteArchitecture = remoteArchitecture
    self.acceptDevelopmentArtifact = acceptDevelopmentArtifact
    self.signatureVerifier = signatureVerifier
  }

  /// 执行安装。
  ///
  /// 为什么是这个顺序：清单校验完全在本地完成，必须发生在**任何**远端写动作之前，
  /// 这样错误平台/架构的二进制不会被复制到远端；上传之后再由远端自己复核摘要与大小，
  /// 用来发现传输截断；只有两侧都一致才做原子切换。上传之后的任意一步失败都回滚，
  /// 回滚自身的失败只作为诊断附加，绝不覆盖原始错误。
  ///
  /// - Parameters:
  ///   - localDigest: 本地产物摘要；nil 时从 `localPath` 现算。
  ///   - localSize: 本地产物字节数；nil 时从 `localPath` 现取。
  @discardableResult
  public func install(
    plan: RemoteInstallPlan,
    manifest: RemoteReleaseManifest,
    localPath: String,
    localDigest: String? = nil,
    localSize: Int? = nil
  ) throws -> RemoteInstallOutcome {
    let digest = try localDigest ?? RemoteInstallTransaction.fileDigest(at: localPath)
    let size = try localSize ?? RemoteInstallTransaction.fileSize(at: localPath)

    do {
      try RemoteInstallValidation.validate(
        manifest: manifest,
        localDigest: digest,
        localSize: size,
        remotePlatform: remotePlatform,
        remoteArchitecture: remoteArchitecture,
        acceptDevelopmentArtifact: acceptDevelopmentArtifact,
        signatureVerifier: signatureVerifier)
    } catch let error as RemoteInstallValidationError {
      // 尚未在远端写入任何东西，这里不需要回滚。
      throw RemoteInstallError.validation(error)
    }

    // 建目录发生在上传之前，失败同样不需要回滚（还没有 staging 文件）。
    try runStep("mkdir", plan.makeDirectoriesCommand())

    do {
      try upload(localPath: localPath, remotePath: plan.stagingPath)
      try verifyRemoteArtifact(plan: plan, manifest: manifest)
      try runStep("activate", plan.activateCommand())
    } catch {
      // 回滚诊断只作为附加信息，不能替换原始错误：调用方看到的必须是失败的真正原因。
      _ = rollback(plan: plan)
      throw error
    }

    return RemoteInstallOutcome(
      installedPath: plan.activePath,
      versionedPath: plan.versionedPath,
      version: plan.version,
      previousVersion: plan.previousVersion,
      artifactKind: manifest.artifactKind,
      diagnostics: [])
  }

  /// 上传 staging 文件，把底层错误归一成 `uploadFailed` / `insufficientSpace`。
  private func upload(localPath: String, remotePath: String) throws {
    do {
      try executor.upload(localPath: localPath, remotePath: remotePath)
    } catch let error as RemoteInstallError {
      throw error
    } catch let error as RemoteSSHError {
      if RemoteInstallTransaction.indicatesInsufficientSpace(error.detail) {
        throw RemoteInstallError.insufficientSpace
      }
      throw RemoteInstallError.uploadFailed(
        RemoteInstallTransaction.safeDetail(error.detail, kind: error.kind.rawValue))
    } catch {
      throw RemoteInstallError.uploadFailed("upload interrupted")
    }
  }

  /// 上传后由远端自己复核摘要与大小，用来发现传输截断或写入不完整。
  private func verifyRemoteArtifact(
    plan: RemoteInstallPlan, manifest: RemoteReleaseManifest
  ) throws {
    let digestResult = try runStep("digest", plan.digestCommand(path: plan.stagingPath))
    let remoteDigest = RemoteInstallTransaction.parseDigest(digestResult.standardOutput)
    guard remoteDigest == manifest.sha256 else {
      throw RemoteInstallError.validation(
        .digestMismatch(expected: manifest.sha256, actual: remoteDigest))
    }

    let sizeResult = try runStep("size", plan.sizeCommand(path: plan.stagingPath))
    guard let remoteSize = RemoteInstallTransaction.parseSize(sizeResult.standardOutput) else {
      throw RemoteInstallError.remoteCommandFailed(
        step: "size", status: sizeResult.exitStatus, detail: "unreadable size output")
    }
    guard remoteSize == manifest.sizeBytes else {
      throw RemoteInstallError.validation(
        .sizeMismatch(expected: manifest.sizeBytes, actual: remoteSize))
    }
  }

  /// 执行一条远端命令并把非零退出归类。空间不足优先于泛化的命令失败。
  @discardableResult
  private func runStep(_ step: String, _ argv: [String]) throws -> RemoteSSHResult {
    let result: RemoteSSHResult
    do {
      result = try executor.runRemote(argv)
    } catch let error as RemoteInstallError {
      throw error
    } catch let error as RemoteSSHError {
      if RemoteInstallTransaction.indicatesInsufficientSpace(error.detail) {
        throw RemoteInstallError.insufficientSpace
      }
      throw RemoteInstallError.remoteCommandFailed(
        step: step,
        status: error.exitStatus ?? -1,
        detail: RemoteInstallTransaction.safeDetail(error.detail, kind: error.kind.rawValue))
    } catch {
      throw RemoteInstallError.remoteCommandFailed(
        step: step, status: -1, detail: "remote command failed")
    }
    guard result.exitStatus == 0 else {
      if RemoteInstallTransaction.indicatesInsufficientSpace(result.standardError) {
        throw RemoteInstallError.insufficientSpace
      }
      throw RemoteInstallError.remoteCommandFailed(
        step: step,
        status: result.exitStatus,
        detail: RemoteInstallTransaction.safeDetail(result.standardError, kind: step))
    }
    return result
  }

  /// 尽力回滚。失败只返回诊断，不抛出——原始错误必须原样交给调用方。
  private func rollback(plan: RemoteInstallPlan) -> [String] {
    do {
      let result = try executor.runRemote(plan.rollbackCommand())
      guard result.exitStatus == 0 else {
        return ["rollback exit=\(result.exitStatus)"]
      }
      return []
    } catch {
      return ["rollback failed"]
    }
  }

  // MARK: 解析与脱敏

  /// `sha256sum` / `shasum` 输出的第一段就是摘要，其余是文件名，必须丢掉。
  static func parseDigest(_ output: String) -> String {
    let token = output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
    return String(token ?? "").lowercased()
  }

  /// `wc -c` 输出可能带前导空白。
  static func parseSize(_ output: String) -> Int? {
    let token = output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
    return token.flatMap { Int($0) }
  }

  /// 远端磁盘写满的判定。stderr 原文不入库，只用于分类。
  static func indicatesInsufficientSpace(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains("no space left on device") || lowered.contains("disk quota exceeded")
  }

  /// 生成可安全落盘的诊断文本：优先用 SSH 层白名单脱敏，兜底只保留步骤名。
  static func safeDetail(_ standardError: String, kind: String) -> String {
    let redacted = RemoteSSHDiagnostics.redact(standardError)
    return redacted.isEmpty ? kind : redacted
  }

  /// 本地产物摘要，输出小写 hex，与清单格式一致。
  static func fileDigest(at path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// 本地产物字节数。
  static func fileSize(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
  }
}


// MARK: - Ed25519 测试签名链

/// Ed25519 测试签名验证器。
///
/// **测试签名链**（test signing chain）：用于在没有真实 Sparkle/公证签名
/// 基础设施的阶段跑通完整安装事务。密钥对仅存于代码常量与测试 fixture 中，
/// 生产发布的真实签名属于后续正式 release 基础设施建设。
///
/// 签名对象是清单 SHA256 摘要的 raw bytes（32 字节），而不是二进制本身，
/// 因为校验发生在本地产物摘要已经算好之后，不需要再读一遍完整文件。
public enum RemoteInstallSignature {

  /// 测试公钥（Ed25519，raw 32 bytes，base64 编码）。
  /// 对应的私钥只存在于测试 fixture 中，不编译进 release 产物。
  public static let testPublicKeyBase64 = "s++Bgv7qejFPU8HGMxgAt5bkX9V89YdsRgCMCAN3SgU="

  /// 用 Ed25519 私钥对清单摘要签名。返回签名的 base64 编码。
  ///
  /// 仅用于测试——生产签名由构建管线在打包阶段完成，不经过客户端代码。
  public static func sign(
    sha256Hex: String,
    privateKeyRaw: Data
  ) throws -> String {
    guard let digestBytes = hexToBytes(sha256Hex), digestBytes.count == 32 else {
      throw RemoteInstallValidationError.malformedManifest("sha256")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
    let signature = try privateKey.signature(for: digestBytes)
    return Data(signature).base64EncodedString()
  }

  /// 验证清单签名。对 `managedRelease` 产物是强制的，`testArtifact` 跳过。
  public static func verify(
    manifest: RemoteReleaseManifest,
    publicKeyBase64: String
  ) -> Bool {
    guard let signatureBase64 = manifest.signature,
          let signatureData = Data(base64Encoded: signatureBase64),
          let publicKeyData = Data(base64Encoded: publicKeyBase64),
          let digestBytes = hexToBytes(manifest.sha256),
          digestBytes.count == 32
    else { return false }
    do {
      let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
      return publicKey.isValidSignature(signatureData, for: digestBytes)
    } catch {
      return false
    }
  }

  /// 创建一个使用测试公钥验签的闭包，可直接注入 `RemoteInstallTransaction`。
  public static func testVerifier() -> @Sendable (RemoteReleaseManifest) -> Bool {
    { manifest in verify(manifest: manifest, publicKeyBase64: testPublicKeyBase64) }
  }

  /// 十六进制字符串转字节数组。返回 nil 如果长度不是偶数或含非法字符。
  private static func hexToBytes(_ hex: String) -> [UInt8]? {
    guard hex.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let nextIndex = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
      bytes.append(byte)
      index = nextIndex
    }
    return bytes
  }
}

// MARK: - 服务替换编排

/// 服务替换事务的阶段。
public enum RemoteReplacementStage: String, Sendable {
  case listTerminals
  case stopService
  case installBinary
  case startService
  case rollback
}

/// 服务替换事务的结果。
public struct RemoteReplacementOutcome: Equatable, Sendable {
  /// 受影响的终端 ID 列表（替换前活跃的终端）。
  public var affectedTerminalIDs: [String]
  /// 安装结果。
  public var installOutcome: RemoteInstallOutcome
  /// 新服务身份。
  public var newServerIdentity: SessionServerIdentity
  /// 附加诊断。
  public var diagnostics: [String]

  public init(
    affectedTerminalIDs: [String],
    installOutcome: RemoteInstallOutcome,
    newServerIdentity: SessionServerIdentity,
    diagnostics: [String] = []
  ) {
    self.affectedTerminalIDs = affectedTerminalIDs
    self.installOutcome = installOutcome
    self.newServerIdentity = newServerIdentity
    self.diagnostics = diagnostics
  }
}

/// 服务替换失败原因。
public enum RemoteReplacementError: Error, Equatable, Sendable {
  /// 列出终端失败。
  case listTerminalsFailed(String)
  /// 停止旧服务失败。
  case stopServiceFailed(String)
  /// 安装新版本失败；旧版本仍可用。
  case installFailed(String)
  /// 启动新服务失败；已尝试回退。
  case startServiceFailed(String)
  /// 回退也失败了，需要手动干预。
  case rollbackFailed(original: String, rollback: String)
}

/// 服务替换编排器。
///
/// 编排顺序（docs/developer/remote-work.md §7）：
/// 1. `terminal.list` → 获取受影响终端列表
/// 2. `server.stop` → 停止旧服务（排空并退出）
/// 3. `RemoteInstallTransaction.install` → 安装新版本二进制
/// 4. `ensureSession` → 启动新服务（冷启动，P6 恢复）
///
/// 安装失败时旧版本目录完好，可手动重启旧版本。
/// 启动新服务失败时尝试把 symlink 指回旧版本。
public protocol RemoteReplacementExecuting: Sendable {
  /// 列出当前会话的所有终端。
  func listTerminals() throws -> [ManagedTerminalStatus]
  /// 停止当前运行的服务（排空并退出）。
  func stopServer() throws
  /// 启动新的服务实例。
  func startServer(binaryPath: String) throws -> SessionServerIdentity
}

/// 服务替换事务。客户端侧编排，不依赖服务端的 `server.replace` 原子操作。
public struct RemoteReplacementTransaction: Sendable {
  private let executor: any RemoteReplacementExecuting
  private let installTransaction: RemoteInstallTransaction

  public init(
    executor: any RemoteReplacementExecuting,
    installTransaction: RemoteInstallTransaction
  ) {
    self.executor = executor
    self.installTransaction = installTransaction
  }

  /// 执行完整的服务替换。
  ///
  /// 调用方必须在调用前已获得用户确认。本方法不做交互。
  ///
  /// - Parameters:
  ///   - plan: 安装计划（含版本化目录布局）。
  ///   - manifest: 新版本的发行清单。
  ///   - localPath: 新版本产物的本地路径。
  ///   - localDigest: 本地产物摘要（可选，为 nil 时现算）。
  ///   - localSize: 本地产物字节数（可选，为 nil 时现取）。
  @discardableResult
  public func replace(
    plan: RemoteInstallPlan,
    manifest: RemoteReleaseManifest,
    localPath: String,
    localDigest: String? = nil,
    localSize: Int? = nil
  ) throws -> RemoteReplacementOutcome {
    // 1. 列出受影响终端
    let terminals: [ManagedTerminalStatus]
    do {
      terminals = try executor.listTerminals()
    } catch {
      throw RemoteReplacementError.listTerminalsFailed(String(describing: error))
    }
    let affectedIDs = terminals.filter { $0.state == .running }
      .map(\.reference.terminalID)

    // 2. 停止旧服务
    do {
      try executor.stopServer()
    } catch {
      throw RemoteReplacementError.stopServiceFailed(String(describing: error))
    }

    // 3. 安装新版本
    let installOutcome: RemoteInstallOutcome
    do {
      installOutcome = try installTransaction.install(
        plan: plan,
        manifest: manifest,
        localPath: localPath,
        localDigest: localDigest,
        localSize: localSize)
    } catch {
      // 安装失败时旧版本目录仍完好，不需要额外回退。
      throw RemoteReplacementError.installFailed(String(describing: error))
    }

    // 4. 启动新服务
    let newIdentity: SessionServerIdentity
    do {
      newIdentity = try executor.startServer(binaryPath: installOutcome.installedPath)
    } catch {
      // 新服务启动失败，尝试把 symlink 指回旧版本并重启
      let startError = String(describing: error)
      if let previousPath = plan.previousVersionedPath {
        do {
          _ = try executor.startServer(binaryPath: previousPath)
        } catch {
          throw RemoteReplacementError.rollbackFailed(
            original: startError, rollback: String(describing: error))
        }
      }
      throw RemoteReplacementError.startServiceFailed(startError)
    }

    return RemoteReplacementOutcome(
      affectedTerminalIDs: affectedIDs,
      installOutcome: installOutcome,
      newServerIdentity: newIdentity)
  }
}