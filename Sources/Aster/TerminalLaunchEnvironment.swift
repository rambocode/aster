import AsterCore
import Foundation
import SwiftTerm

struct TerminalLaunchEnvironmentResult {
  let environment: [String: String]
  let resolution: TerminalIdentityResolution
  let programIdentity: TerminalProgramIdentity
}

/// 组合终端身份、terminfo 搜索路径与 Shell 集成环境。所有外部探测都经闭包注入，
/// Pane 启动只消费最终字典，不需要知道配置回退或不同 Shell 的加载机制。
enum TerminalLaunchEnvironmentBuilder {
  static func make(
    inherited: [String: String],
    configuredTerm: String,
    shellPath: String,
    shellIntegrationEnabled: Bool,
    paneIdentifier: String,
    version: String,
    resourcesDirectory: String?,
    terminfoEntryExists: (String, [String: String]) -> Bool
  ) -> TerminalLaunchEnvironmentResult {
    let terminfoDirectory = resourcesDirectory.map { "\($0)/terminfo" }
    let provisional = TerminalIdentityPolicy.environment(
      inherited: inherited,
      term: TerminalIdentityPolicy.fallbackTerm,
      version: version,
      paneIdentifier: paneIdentifier,
      bundledTerminfoDirectory: terminfoDirectory
    )
    let resolution = TerminalIdentityPolicy.resolve(configuredName: configuredTerm) {
      terminfoEntryExists($0, provisional)
    }
    var environment = TerminalIdentityPolicy.environment(
      inherited: inherited,
      term: resolution.term,
      version: version,
      paneIdentifier: paneIdentifier,
      bundledTerminfoDirectory: terminfoDirectory
    )
    if let resourcesDirectory,
      let plan = ShellIntegrationLaunchPlan.make(
        shellPath: shellPath,
        enabled: shellIntegrationEnabled,
        resourceDirectory: "\(resourcesDirectory)/shell-integration",
        inheritedEnvironment: environment
      )
    {
      environment = plan.environment
    }
    let productVersion = TerminalProductVersion(version)
    return TerminalLaunchEnvironmentResult(
      environment: environment,
      resolution: resolution,
      programIdentity: TerminalProgramIdentity(
        name: "aster",
        version: version,
        deviceAttributesVersion: productVersion.deviceAttributesValue
      )
    )
  }
}

/// 只通过固定的 `/usr/bin/infocmp` 和参数数组探测 terminfo，配置值不会进入 Shell。
/// 标准输出直接丢弃，避免大条目填满 Pipe；退出状态 0 是唯一成功条件。
enum SystemTerminfoChecker {
  static func entryExists(_ name: String, environment: [String: String]) -> Bool {
    guard TerminalIdentityPolicy.isSyntacticallyValid(name),
      FileManager.default.isExecutableFile(atPath: "/usr/bin/infocmp")
    else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
    process.arguments = ["-x", name]
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationReason == .exit && process.terminationStatus == 0
    } catch {
      return false
    }
  }
}

enum AsterResourceLocations {
  /// 打包应用优先使用签名 Bundle；`swift run`/测试构建才回退到当前仓库 Resources。
  static func resourcesDirectory(
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> URL? {
    if let bundled = bundle.resourceURL,
      fileManager.fileExists(atPath: bundled.appendingPathComponent("shell-integration").path),
      fileManager.fileExists(atPath: bundled.appendingPathComponent("autocomplete/fig-specs.json").path)
    {
      return bundled
    }
    let development = URL(fileURLWithPath: fileManager.currentDirectoryPath)
      .appendingPathComponent("Resources", isDirectory: true)
    guard fileManager.fileExists(atPath: development.appendingPathComponent("shell-integration").path),
      fileManager.fileExists(atPath: development.appendingPathComponent("autocomplete/fig-specs.json").path)
    else { return nil }
    return development
  }

  static func productVersion(bundle: Bundle = .main) -> String {
    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  static func shellIntegrationInstaller(
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> ShellIntegrationInstaller? {
    guard let resources = resourcesDirectory(bundle: bundle, fileManager: fileManager) else {
      return nil
    }
    return ShellIntegrationInstaller(
      resourceDirectory: resources.appendingPathComponent("shell-integration"),
      fileManager: fileManager
    )
  }
}
