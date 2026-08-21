import Darwin
import Foundation

/// 在 GUI 精简环境中定位 Agent CLI。搜索只访问确定、有界的 bin 目录，不启动登录
/// shell，避免设置页执行用户 rc 文件或被缓慢、交互式的 shell 初始化阻塞。
struct AgentExecutableLocator {
  let searchDirectories: [URL]

  init(searchDirectories: [URL]) {
    self.searchDirectories = Self.deduplicated(searchDirectories)
  }

  init(
    homeDirectory: URL,
    environment: [String: String],
    fileManager: FileManager
  ) {
    self.searchDirectories = Self.defaultSearchDirectories(
      homeDirectory: homeDirectory,
      environment: environment,
      fileManager: fileManager
    )
  }

  /// 返回首个可执行普通文件的入口路径。保留 symlink 路径，设置页才能展示用户实际
  /// 通过 Homebrew、nvm 等安装并加入命令搜索路径的位置。
  func path(for name: String) -> String? {
    searchDirectories.lazy.compactMap { directory -> String? in
      let candidate = directory.appendingPathComponent(name, isDirectory: false)
      var info = stat()
      // 目录的搜索权限也会令 access(X_OK) 成功，因此必须同时验证最终目标是普通文件。
      guard stat(candidate.path, &info) == 0,
        info.st_mode & S_IFMT == S_IFREG,
        access(candidate.path, X_OK) == 0
      else { return nil }
      return candidate.path
    }.first
  }

  private static func defaultSearchDirectories(
    homeDirectory: URL,
    environment: [String: String],
    fileManager: FileManager
  ) -> [URL] {
    var directories: [URL] = []
    func appendPathList(_ value: String?) {
      for component in value?.split(separator: ":", omittingEmptySubsequences: true) ?? [] {
        directories.append(URL(fileURLWithPath: String(component), isDirectory: true))
      }
    }
    func appendEnvironmentDirectory(_ key: String, suffix: String? = nil) {
      guard let value = environment[key], value.hasPrefix("/") else { return }
      let base = URL(fileURLWithPath: value, isDirectory: true)
      directories.append(
        suffix.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
      )
    }
    func appendVersionedBins(root: URL, suffix: String) {
      guard let versions = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else { return }
      // GUI 没有“当前 nvm 版本”环境信息；自然排序优先最高版本，同时保留旧版本，
      // 兼容 CLI 只安装在某个历史 Node 版本中的情况。
      for version in versions.sorted(by: {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
      }) {
        let values = try? version.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { continue }
        directories.append(version.appendingPathComponent(suffix, isDirectory: true))
      }
    }

    appendPathList(environment["PATH"])
    appendEnvironmentDirectory("NVM_BIN")
    appendEnvironmentDirectory("PNPM_HOME")
    appendEnvironmentDirectory("VOLTA_HOME", suffix: "bin")
    appendEnvironmentDirectory("BUN_INSTALL", suffix: "bin")

    for relativePath in [
      ".local/bin", "bin", ".npm-global/bin", ".bun/bin", ".volta/bin", ".asdf/shims",
      ".local/share/mise/shims", ".local/share/pnpm", "Library/pnpm",
    ] {
      directories.append(homeDirectory.appendingPathComponent(relativePath, isDirectory: true))
    }
    for path in [
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ] {
      directories.append(URL(fileURLWithPath: path, isDirectory: true))
    }

    appendVersionedBins(
      root: homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true),
      suffix: "bin"
    )
    for relativeRoot in [".fnm/node-versions", ".local/share/fnm/node-versions"] {
      appendVersionedBins(
        root: homeDirectory.appendingPathComponent(relativeRoot, isDirectory: true),
        suffix: "installation/bin"
      )
    }
    appendVersionedBins(
      root: homeDirectory.appendingPathComponent(".asdf/installs/nodejs", isDirectory: true),
      suffix: "bin"
    )
    appendVersionedBins(
      root: homeDirectory.appendingPathComponent(".local/share/mise/installs/node", isDirectory: true),
      suffix: "bin"
    )
    return deduplicated(directories)
  }

  private static func deduplicated(_ directories: [URL]) -> [URL] {
    var seen: Set<String> = []
    return directories.compactMap { directory in
      let standardized = directory.standardizedFileURL
      return seen.insert(standardized.path).inserted ? standardized : nil
    }
  }
}
