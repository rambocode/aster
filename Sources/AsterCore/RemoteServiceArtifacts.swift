import Foundation

/// 本机可用于安装到远端的 `aster-session` 服务产物（P3.4 安装事务的输入侧）。
///
/// 来源只有两种，优先级固定：
/// 1. `ASTER_REMOTE_BINARY` 指定的自定义构建（开发产物，未签名，必须由用户显式接受）；
/// 2. App 包内 `Contents/Resources/remote-service/<platform>-<arch>/` 下的产物与发布清单。
///
/// 平台/架构不匹配的产物**不得**上传到远端（`docs/developer/remote-work.md` §7），
/// 所以这里在任何远端动作之前就按目标平台筛选，筛不到就明确返回 nil。
public struct RemoteServiceArtifact: Equatable, Sendable {
  /// 本地产物绝对路径。
  public var localPath: String
  /// 安装校验的唯一事实来源。
  public var manifest: RemoteReleaseManifest

  public init(localPath: String, manifest: RemoteReleaseManifest) {
    self.localPath = localPath
    self.manifest = manifest
  }
}

/// 产物目录访问失败原因。全部可直接展示。
public enum RemoteServiceArtifactError: Error, Equatable, Sendable {
  /// `ASTER_REMOTE_BINARY` 指向的文件不存在或不可读。
  case overrideUnreadable(String)
  /// `ASTER_REMOTE_BINARY` 不是可识别的 ELF / Mach-O 可执行文件。
  case overrideUnrecognized(String)
  /// `ASTER_REMOTE_BINARY` 的平台/架构与目标机器不符。
  case overridePlatformMismatch(expected: String, actual: String)
  /// 包内清单存在但无法解析。
  case bundledManifestInvalid(String)
}

/// 从可执行文件头识别目标平台与架构，不需要在本机执行它。
///
/// 只认两种容器：ELF（Linux）与 64 位 Mach-O（macOS）。识别的目的不是安全校验，
/// 而是把「把 macOS 二进制传到 Linux 远端」这类错误挡在上传之前。
public enum RemoteBinaryFormat {
  public struct Identity: Equatable, Sendable {
    public var platform: String
    public var architecture: String
  }

  /// 读文件头识别；无法识别返回 nil。
  public static func detect(at path: String) -> Identity? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: 32), header.count >= 20 else { return nil }
    return detect(header: header)
  }

  /// 纯函数版本，便于用合成的文件头做定向测试。
  public static func detect(header: Data) -> Identity? {
    let bytes = [UInt8](header)
    guard bytes.count >= 20 else { return nil }
    // ELF: 0x7f 'E' 'L' 'F'；e_machine 在偏移 18（2 字节，按 EI_DATA 决定端序）。
    if bytes[0] == 0x7f, bytes[1] == 0x45, bytes[2] == 0x4c, bytes[3] == 0x46 {
      let littleEndian = bytes[5] == 1
      let machine =
        littleEndian
        ? UInt16(bytes[18]) | (UInt16(bytes[19]) << 8)
        : (UInt16(bytes[18]) << 8) | UInt16(bytes[19])
      switch machine {
      case 0x3E: return Identity(platform: "linux", architecture: "x86_64")
      case 0xB7: return Identity(platform: "linux", architecture: "arm64")
      default: return nil
      }
    }
    // Mach-O 64 位：magic 0xfeedfacf（小端写入为 cf fa ed fe）；cputype 在偏移 4。
    if bytes[0] == 0xcf, bytes[1] == 0xfa, bytes[2] == 0xed, bytes[3] == 0xfe {
      let cpuType =
        UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16)
        | (UInt32(bytes[7]) << 24)
      switch cpuType {
      case 0x0100_0007: return Identity(platform: "macos", architecture: "x86_64")
      case 0x0100_000C: return Identity(platform: "macos", architecture: "arm64")
      default: return nil
      }
    }
    return nil
  }
}

/// 服务产物目录：按目标平台/架构挑出可安装的本地产物。
public struct RemoteServiceArtifactCatalog: Sendable {
  /// 包内产物根目录（`remote-service/`）；nil 表示当前不是打包运行。
  public var bundledDirectory: URL?
  /// 进程环境；只读 `ASTER_REMOTE_BINARY`。
  public var environment: [String: String]

  /// 环境变量键。与 App 侧 `RemoteEnvironmentKeys.remoteBinary` 字面量相同。
  public static let overrideEnvironmentKey = "ASTER_REMOTE_BINARY"
  /// 包内产物目录名与清单文件名。打包脚本与运行时必须使用同一份字面量。
  public static let bundledDirectoryName = "remote-service"
  public static let manifestFileName = "manifest.json"
  public static let binaryFileName = "aster-session"

  public init(bundledDirectory: URL?, environment: [String: String]) {
    self.bundledDirectory = bundledDirectory
    self.environment = environment
  }

  /// 目标平台对应的产物。没有可用产物返回 nil；有产物但明显不可用（覆盖文件损坏、
  /// 平台不符、清单坏掉）时抛错，让用户看到确切原因而不是"没有产物"。
  public func artifact(forPlatform platform: String, architecture: String) throws
    -> RemoteServiceArtifact?
  {
    if let override = environment[Self.overrideEnvironmentKey], !override.isEmpty {
      return try overrideArtifact(path: override, platform: platform, architecture: architecture)
    }
    return try bundledArtifact(platform: platform, architecture: architecture)
  }

  /// 包内目录名：`<platform>-<arch>`，例如 `linux-x86_64`。
  public static func bundledSubdirectory(platform: String, architecture: String) -> String {
    "\(platform)-\(architecture)"
  }

  /// 自定义构建：不做签名，也无法在本机跑 `--version`，版本名用摘要前缀区分不同构建，
  /// 避免两次不同的开发构建落进同一个版本化目录互相覆盖。
  private func overrideArtifact(path: String, platform: String, architecture: String) throws
    -> RemoteServiceArtifact
  {
    guard FileManager.default.isReadableFile(atPath: path) else {
      throw RemoteServiceArtifactError.overrideUnreadable(path)
    }
    guard let identity = RemoteBinaryFormat.detect(at: path) else {
      throw RemoteServiceArtifactError.overrideUnrecognized(path)
    }
    let actual = "\(identity.platform)/\(identity.architecture)"
    let expected = "\(platform)/\(architecture)"
    guard actual == expected else {
      throw RemoteServiceArtifactError.overridePlatformMismatch(expected: expected, actual: actual)
    }
    let digest = try RemoteInstallTransaction.fileDigest(at: path)
    let size = try RemoteInstallTransaction.fileSize(at: path)
    let manifest = RemoteReleaseManifest(
      version: Self.developmentVersion(digest: digest),
      platform: identity.platform,
      architecture: identity.architecture,
      sha256: digest,
      sizeBytes: size,
      signature: nil,
      artifactKind: .developmentBuild,
      protocolMajor: RemoteProtocolContract.clientProtocolMajor)
    return RemoteServiceArtifact(localPath: path, manifest: manifest)
  }

  /// 开发产物的版本化目录名：`dev-<sha256 前 12 位>`。
  public static func developmentVersion(digest: String) -> String {
    "dev-" + String(digest.prefix(12))
  }

  private func bundledArtifact(platform: String, architecture: String) throws
    -> RemoteServiceArtifact?
  {
    guard let bundledDirectory else { return nil }
    let directory = bundledDirectory.appendingPathComponent(
      Self.bundledSubdirectory(platform: platform, architecture: architecture), isDirectory: true)
    let binary = directory.appendingPathComponent(Self.binaryFileName)
    let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
    guard FileManager.default.isReadableFile(atPath: binary.path),
      FileManager.default.isReadableFile(atPath: manifestURL.path)
    else { return nil }
    let manifest: RemoteReleaseManifest
    do {
      manifest = try JSONDecoder().decode(
        RemoteReleaseManifest.self, from: Data(contentsOf: manifestURL))
    } catch {
      throw RemoteServiceArtifactError.bundledManifestInvalid(String(describing: error))
    }
    // 清单声明的平台必须与目录一致；打包脚本放错目录时在这里拦下。
    guard manifest.platform == platform, manifest.architecture == architecture else {
      throw RemoteServiceArtifactError.bundledManifestInvalid(
        "manifest 声明 \(manifest.platform)/\(manifest.architecture)，目录是 \(platform)/\(architecture)")
    }
    return RemoteServiceArtifact(localPath: binary.path, manifest: manifest)
  }
}

/// 面向用户的产物错误文案。
extension RemoteServiceArtifactError {
  public var text: String {
    switch self {
    case .overrideUnreadable(let path):
      L("\(RemoteServiceArtifactCatalog.overrideEnvironmentKey) 指向的文件不可读：\(path)")
    case .overrideUnrecognized(let path):
      L("\(RemoteServiceArtifactCatalog.overrideEnvironmentKey) 不是可识别的 ELF/Mach-O 可执行文件：\(path)")
    case .overridePlatformMismatch(let expected, let actual):
      L("\(RemoteServiceArtifactCatalog.overrideEnvironmentKey) 是 \(actual) 产物，目标机器是 \(expected)，已拒绝上传。")
    case .bundledManifestInvalid(let detail):
      L("App 内置的远端服务清单无效：\(detail)")
    }
  }
}
