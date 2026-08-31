import Foundation

// MARK: - 动态补全候选：只读磁盘，绝不执行被补全的工具
//
// Fig 规格里的参数生成器是一段命令行文本（`git branch --sort=-committerdate`、
// `brew formulae` …）。Aster **绝不执行**这些命令：补全 `brew install` 不该触发
// `brew update`，补全 `git checkout` 不该在用户仓库里跑 git。因此本文件把每个
// 受支持的生成器脚本映射成一种「读磁盘的意图」，再直接从已经存在于磁盘上的文件
// 里读出活数据（`.git/refs`、`.git/packed-refs`、`package.json`、Homebrew 的
// `Formula/` 目录）。读不出来就没有这个来源，绝不退化成 fork 进程。
//
// 这条约束由 `autocompleteDynamicReaderNeverSpawnsProcesses` 测试守护：它直接读本
// 文件的源码文本，断言其中不出现任何进程启动 API。因此本文件里也不要把那些 API 的
// 名字写进注释——测试是纯文本匹配，会把注释里的字样当成真正的调用。

/// 一种可以从磁盘直接读出的动态候选来源。
public enum AutocompleteDynamicSource: String, Sendable, CaseIterable, Hashable {
  case gitLocalBranches
  case gitAllBranches
  case gitRemoteBranches
  case gitTags
  case gitRemotes
  case gitStashes
  case gitAliases
  case npmScripts
  case makeTargets
  case brewFormulae
  case brewCasks
  case brewInstalledFormulae
  case brewInstalledCasks
  case brewTaps
}

/// 单条动态候选。`rankBonus` 让「最近切过的分支」排到前面，这正是 Otty 文档描述的
/// `git checkout` 行为；当前分支拿负加成，因为切到自己没有意义。
public struct AutocompleteDynamicItem: Equatable, Sendable {
  public let name: String
  public let description: String
  public let rankBonus: Double

  public init(name: String, description: String = "", rankBonus: Double = 0) {
    self.name = name
    self.description = description
    self.rankBonus = rankBonus
  }
}

/// 动态候选的读取接口。抽成协议是为了让服务层注入缓存实现、让测试注入临时目录替身。
public protocol AutocompleteDynamicReader: Sendable {
  func items(for source: AutocompleteDynamicSource, directory: String) -> [AutocompleteDynamicItem]
}

/// 引擎侧的查询闭包。引擎不关心缓存与目录解析，只在解析到参数槽位时按来源回调一次。
public struct AutocompleteDynamicProvider: Sendable {
  private let lookup: @Sendable (AutocompleteDynamicSource) -> [AutocompleteDynamicItem]

  public init(_ lookup: @escaping @Sendable (AutocompleteDynamicSource) -> [AutocompleteDynamicItem]) {
    self.lookup = lookup
  }

  public static let empty = AutocompleteDynamicProvider { _ in [] }

  public func items(for source: AutocompleteDynamicSource) -> [AutocompleteDynamicItem] {
    lookup(source)
  }
}

// MARK: - 脚本 → 来源映射

extension AutocompleteDynamicSource {
  /// 把一个参数槽位映射成受支持的动态来源。先按生成器脚本签名匹配，再用命令路径兜底。
  public static func sources(
    for argument: AutocompleteArgumentSpec, commandPath: [String]
  ) -> [AutocompleteDynamicSource] {
    var result: [AutocompleteDynamicSource] = []
    for script in argument.generatorScripts.prefix(8) {
      if let source = self.source(forScript: script), !result.contains(source) {
        result.append(source)
      }
    }
    if result.isEmpty, let fallback = fallbackSource(commandPath: commandPath, argument: argument) {
      result.append(fallback)
    }
    return result
  }

  /// 归一化后按 token 数组做前缀/相等比较。**不用正则**：脚本文本来自可远端更新的
  /// JSON 规格文件，正则回溯是一条不必要的攻击面。
  static func source(forScript script: [String]) -> AutocompleteDynamicSource? {
    let tokens = normalized(script)
    guard !tokens.isEmpty else { return nil }
    func matches(_ pattern: [String]) -> Bool {
      tokens.count >= pattern.count && Array(tokens.prefix(pattern.count)) == pattern
    }
    switch true {
    case matches(["git", "branch", "-a"]), matches(["git", "branch", "--all"]):
      return .gitAllBranches
    case matches(["git", "branch", "-r"]), matches(["git", "branch", "--remotes"]):
      return .gitRemoteBranches
    case matches(["git", "branch"]):
      return .gitLocalBranches
    case matches(["git", "tag"]):
      return .gitTags
    case matches(["git", "remote"]):
      return .gitRemotes
    case matches(["git", "stash", "list"]):
      return .gitStashes
    case matches(["git", "config", "--get-regexp", "^alias."]):
      return .gitAliases
    case tokens.contains("package.json") && tokens.contains("cat"):
      return .npmScripts
    case matches(["brew", "formulae"]):
      return .brewFormulae
    case matches(["brew", "casks"]):
      return .brewCasks
    case matches(["brew", "list", "--cask"]):
      return .brewInstalledCasks
    case matches(["brew", "list"]), matches(["brew", "outdated"]):
      return .brewInstalledFormulae
    case matches(["brew", "tap"]):
      return .brewTaps
    default:
      return nil
    }
  }

  /// 剥掉外壳、噪声 flag 与排序/格式参数，只留下能表达「要什么数据」的骨架。
  static func normalized(_ script: [String]) -> [String] {
    var tokens: [String] = []
    for raw in script.prefix(24) {
      let value = raw.lowercased()
      // `bash -c "<一整行>"` 的写法要先拆成词，否则整条命令会挤在一个 token 里。
      let pieces = value.contains(" ") ? value.split(separator: " ").map(String.init) : [value]
      tokens.append(contentsOf: pieces)
    }
    let shells: Set<String> = ["bash", "sh", "zsh", "command", "env", "-c"]
    let noise: Set<String> = [
      "--no-optional-locks", "--no-color", "--no-pager", "-q", "--quiet", "-1", "--list",
      "-v", "--verbose", "--porcelain",
    ]
    return tokens.filter { token in
      guard !shells.contains(token), !noise.contains(token) else { return false }
      guard !token.hasPrefix("--sort="), !token.hasPrefix("--format") else { return false }
      return !token.isEmpty
    }
  }

  /// 命令路径兜底表。`make` 的 target 参数在 Fig 规格里根本没有 generatorScript
  /// （只有 `{"name": "target"}`），只能靠命令名 + 参数名识别。表刻意保持很短。
  static func fallbackSource(
    commandPath: [String], argument: AutocompleteArgumentSpec
  ) -> AutocompleteDynamicSource? {
    let command = commandPath.first?.lowercased() ?? ""
    let name = argument.name.lowercased()
    switch command {
    case "make", "gmake":
      return name.contains("target") ? .makeTargets : nil
    default:
      return nil
    }
  }
}

// MARK: - 读取预算

/// 所有磁盘读取共享的上限。补全跑在主线程的 150ms 防抖窗口里，任何一次读取都不能
/// 因为病态仓库或超大文件而失控。
public struct AutocompleteDynamicLimits: Sendable {
  public var maximumItems = 2_000
  public var maximumBrewItems = 5_000
  public var maximumFileBytes = 1 << 20
  public var maximumReflogTailBytes = 64 * 1_024
  public var maximumRefDepth = 8
  public var maximumEnumeratedEntries = 20_000
  public var maximumParentWalk = 24

  public init() {}
}

// MARK: - 磁盘读取器

/// 从磁盘读取动态候选。环境变量按构造参数注入（不读全局 `ProcessInfo`），
/// 便于测试用临时目录完全替身。
public struct AutocompleteDiskDynamicReader: AutocompleteDynamicReader {
  private let environment: [String: String]
  private let limits: AutocompleteDynamicLimits
  /// `FileManager` 不是 `Sendable`,但这里只用 `contentsOfDirectory` 这类无状态读取,
  /// 且实例在构造后不再变更,因此显式标注为跨并发域安全。
  private nonisolated(unsafe) let fileManager: FileManager

  public init(
    environment: [String: String] = [:],
    limits: AutocompleteDynamicLimits = AutocompleteDynamicLimits(),
    fileManager: FileManager = .default
  ) {
    self.environment = environment
    self.limits = limits
    self.fileManager = fileManager
  }

  public func items(
    for source: AutocompleteDynamicSource, directory: String
  ) -> [AutocompleteDynamicItem] {
    switch source {
    case .gitLocalBranches: gitRefs(directory: directory, scopes: ["heads"])
    case .gitAllBranches: gitRefs(directory: directory, scopes: ["heads", "remotes"])
    case .gitRemoteBranches: gitRefs(directory: directory, scopes: ["remotes"])
    case .gitTags: gitRefs(directory: directory, scopes: ["tags"])
    case .gitRemotes: gitRemotes(directory: directory)
    case .gitStashes: gitStashes(directory: directory)
    case .gitAliases: gitAliases(directory: directory)
    case .npmScripts: npmScripts(directory: directory)
    case .makeTargets: makeTargets(directory: directory)
    case .brewFormulae: brewNames(kind: .formula, installedOnly: false)
    case .brewCasks: brewNames(kind: .cask, installedOnly: false)
    case .brewInstalledFormulae: brewNames(kind: .formula, installedOnly: true)
    case .brewInstalledCasks: brewNames(kind: .cask, installedOnly: true)
    case .brewTaps: brewTaps()
    }
  }

  // MARK: git

  /// 向上查找 `.git`。worktree 里 `.git` 是一个 `gitdir: <path>` 文本文件而不是目录，
  /// 本仓库的 `.worktrees/*` 正是这种形态，必须解析。
  func gitDirectory(for directory: String) -> URL? {
    var current = URL(fileURLWithPath: directory).standardizedFileURL
    for _ in 0..<limits.maximumParentWalk {
      let candidate = current.appendingPathComponent(".git")
      if let values = try? candidate.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ]) {
        if values.isSymbolicLink == true { return nil }
        if values.isDirectory == true { return candidate }
        if values.isRegularFile == true,
          let data = readFile(at: candidate, maximumBytes: 4_096),
          let line = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        {
          let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
          guard path.hasPrefix("/") else { return nil }
          let resolved = URL(fileURLWithPath: path).standardizedFileURL
          guard isDirectory(resolved) else { return nil }
          return resolved
        }
        return nil
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
    return nil
  }

  private func gitRefs(directory: String, scopes: [String]) -> [AutocompleteDynamicItem] {
    guard let gitDir = gitDirectory(for: directory) else { return [] }
    // 引用与 config 存在共享目录里；HEAD 与 reflog 是每个 worktree 私有的。
    let commonDir = gitCommonDirectory(gitDir)
    var names: [String] = []
    var seen: Set<String> = []
    func add(_ name: String) {
      guard !name.isEmpty, seen.insert(name).inserted, names.count < limits.maximumItems else {
        return
      }
      names.append(name)
    }

    for scope in scopes {
      // linked worktree 自己的 refs/ 只放 bisect/rewrite 之类的私有引用，分支要去
      // 共享目录里找；两边都扫一遍，普通仓库下两个路径相同，去重后没有副作用。
      for root in Set([gitDir, commonDir].map { $0.appendingPathComponent("refs/\(scope)").path }) {
        for name in looseRefs(under: URL(fileURLWithPath: root)) { add(name) }
      }
    }
    // 打包引用只接受这三个命名空间：真实仓库里会有 `refs/codex/turn-diffs/...`
    // 这类第三方工具写入的巨量命名空间，不做前缀白名单会把它们全当成分支列出来。
    let allowed = scopes.map { "refs/\($0)/" }
    if let data = readFile(
      at: commonDir.appendingPathComponent("packed-refs"), maximumBytes: limits.maximumFileBytes)
    {
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        // `^<sha>` 是 peeled tag 行，不是引用本身。
        guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
        guard let ref = line.split(separator: " ").dropFirst().first else { continue }
        guard let prefix = allowed.first(where: { ref.hasPrefix($0) }) else { continue }
        add(String(ref.dropFirst(prefix.count)))
      }
    }

    let current = currentBranch(gitDir: gitDir)
    let recency = checkoutRecency(gitDir: gitDir)
    return names.map { name in
      AutocompleteDynamicItem(
        name: name,
        description: name == current ? "当前分支" : "",
        // 切到当前分支没有意义，压到最后；最近 check out 过的往前提。
        rankBonus: name == current ? -40 : recency[name].map { 30 - Double($0) * 3 } ?? 0
      )
    }
  }

  /// linked worktree 的 gitdir 里有一个 `commondir` 文件（内容通常是 `../..`），
  /// 指向主仓库的 `.git`。分支、标签、remote 配置都存在那里，只有 HEAD、index 和
  /// reflog 是每个 worktree 私有的。普通仓库没有这个文件，直接返回原路径。
  func gitCommonDirectory(_ gitDir: URL) -> URL {
    guard let data = readFile(
      at: gitDir.appendingPathComponent("commondir"), maximumBytes: 4_096),
      let raw = String(decoding: data, as: UTF8.self)
        .split(separator: "\n").first?.trimmingCharacters(in: .whitespaces),
      !raw.isEmpty
    else { return gitDir }
    let resolved = raw.hasPrefix("/")
      ? URL(fileURLWithPath: raw)
      : gitDir.appendingPathComponent(raw)
    let standardized = resolved.standardizedFileURL
    return isDirectory(standardized) ? standardized : gitDir
  }

  private func looseRefs(under root: URL) -> [String] {
    guard isDirectory(root) else { return [] }
    var result: [String] = []
    // 用「相对片段」而不是字符串前缀裁剪来还原引用名：`contentsOfDirectory` 返回的
    // URL 可能已经把 `/var` 解析成 `/private/var`，按 root.path 的长度 dropFirst
    // 会切掉错误的字符数，得到 `s/heads/main` 这样的残缺名字。
    var stack: [(URL, [String], Int)] = [(root, [], 0)]
    var visited = 0
    while let (directory, prefix, depth) = stack.popLast() {
      guard depth <= limits.maximumRefDepth, result.count < limits.maximumItems else { continue }
      guard let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsSubdirectoryDescendants])
      else { continue }
      for entry in entries {
        visited += 1
        if visited > limits.maximumEnumeratedEntries { return result }
        guard let values = try? entry.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ]), values.isSymbolicLink != true
        else { continue }
        let name = entry.lastPathComponent
        if values.isDirectory == true {
          stack.append((entry, prefix + [name], depth + 1))
        } else if !name.isEmpty {
          result.append((prefix + [name]).joined(separator: "/"))
        }
      }
    }
    return result
  }

  private func currentBranch(gitDir: URL) -> String? {
    guard let data = readFile(at: gitDir.appendingPathComponent("HEAD"), maximumBytes: 4_096)
    else { return nil }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("ref: refs/heads/") else { return nil }
    return String(text.dropFirst("ref: refs/heads/".count))
  }

  /// 从 reflog 倒推最近切换过的分支。这是「浮出你最常切的分支」的纯读磁盘实现——
  /// 等价信息只能靠 `git reflog`，而我们不允许 fork。
  private func checkoutRecency(gitDir: URL) -> [String: Int] {
    guard let data = readFile(
      at: gitDir.appendingPathComponent("logs/HEAD"),
      maximumBytes: limits.maximumFileBytes, tailBytes: limits.maximumReflogTailBytes)
    else { return [:] }
    var ranks: [String: Int] = [:]
    let marker = "checkout: moving from "
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
      guard let range = line.range(of: marker) else { continue }
      let rest = line[range.upperBound...]
      guard let separator = rest.range(of: " to ") else { continue }
      let target = String(rest[separator.upperBound...])
      guard !target.isEmpty, ranks[target] == nil else { continue }
      ranks[target] = ranks.count
      if ranks.count >= 10 { break }
    }
    return ranks
  }

  private func gitRemotes(directory: String) -> [AutocompleteDynamicItem] {
    configEntries(directory: directory, section: "remote").map {
      AutocompleteDynamicItem(name: $0.name, description: $0.value)
    }
  }

  private func gitAliases(directory: String) -> [AutocompleteDynamicItem] {
    guard let gitDir = gitDirectory(for: directory) else { return [] }
    var result = aliasEntries(in: gitCommonDirectory(gitDir).appendingPathComponent("config"))
    if let home = environment["HOME"], home.hasPrefix("/") {
      result += aliasEntries(in: URL(fileURLWithPath: home).appendingPathComponent(".gitconfig"))
    }
    var seen: Set<String> = []
    return result.filter { seen.insert($0.name).inserted }
  }

  private func aliasEntries(in url: URL) -> [AutocompleteDynamicItem] {
    parseConfig(at: url, section: "alias").map {
      AutocompleteDynamicItem(name: $0.name, description: $0.value)
    }
  }

  private func configEntries(
    directory: String, section: String
  ) -> [(name: String, value: String)] {
    guard let gitDir = gitDirectory(for: directory) else { return [] }
    return parseConfig(
      at: gitCommonDirectory(gitDir).appendingPathComponent("config"), section: section)
  }

  /// 极简 git config 解析：只认 `[section "name"]` / `[section]` 头和 `key = value`。
  /// 够用即可——我们只需要 remote 名和 alias 名，不需要完整语义。
  private func parseConfig(at url: URL, section: String) -> [(name: String, value: String)] {
    guard let data = readFile(at: url, maximumBytes: limits.maximumFileBytes) else { return [] }
    var result: [(String, String)] = []
    var currentSubsection: String?
    var inSection = false
    for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("["), line.hasSuffix("]") {
        let header = line.dropFirst().dropLast()
        let parts = header.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
        let name = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        inSection = name == section
        currentSubsection = parts.count >= 2 ? String(parts[1]) : nil
        if inSection, let subsection = currentSubsection, !subsection.isEmpty {
          result.append((subsection, ""))
        }
        continue
      }
      guard inSection, let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if currentSubsection == nil {
        result.append((key, value))
      } else if key == "url", let index = result.lastIndex(where: { $0.0 == currentSubsection }) {
        result[index].1 = value
      }
      if result.count >= limits.maximumItems { break }
    }
    var seen: Set<String> = []
    return result.filter { seen.insert($0.0).inserted }.map { (name: $0.0, value: $0.1) }
  }

  private func gitStashes(directory: String) -> [AutocompleteDynamicItem] {
    guard let gitDir = gitDirectory(for: directory),
      let data = readFile(
        at: gitCommonDirectory(gitDir).appendingPathComponent("logs/refs/stash"),
        maximumBytes: limits.maximumFileBytes)
    else { return [] }
    let lines = String(decoding: data, as: UTF8.self)
      .split(separator: "\n").map(String.init)
    return lines.enumerated().prefix(limits.maximumItems).map { index, line in
      let message = line.split(separator: "\t").last.map(String.init) ?? ""
      return AutocompleteDynamicItem(name: "stash@{\(index)}", description: message)
    }
  }

  // MARK: npm / make

  private func npmScripts(directory: String) -> [AutocompleteDynamicItem] {
    var current = URL(fileURLWithPath: directory).standardizedFileURL
    for _ in 0..<8 {
      let manifest = current.appendingPathComponent("package.json")
      if let data = readFile(at: manifest, maximumBytes: limits.maximumFileBytes),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let scripts = object["scripts"] as? [String: Any]
      {
        return scripts.keys.sorted().prefix(500).map { key in
          let body = (scripts[key] as? String) ?? ""
          return AutocompleteDynamicItem(name: key, description: String(body.prefix(120)))
        }
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
    return []
  }

  private func makeTargets(directory: String) -> [AutocompleteDynamicItem] {
    let root = URL(fileURLWithPath: directory)
    for name in ["Makefile", "makefile", "GNUmakefile"] {
      guard let data = readFile(
        at: root.appendingPathComponent(name), maximumBytes: 512 * 1_024)
      else { continue }
      var result: [AutocompleteDynamicItem] = []
      var seen: Set<String> = []
      for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        // Tab 开头是配方行，不是目标声明。
        guard !rawLine.hasPrefix("\t"), let colon = rawLine.firstIndex(of: ":") else { continue }
        let left = rawLine[..<colon].trimmingCharacters(in: .whitespaces)
        let after = rawLine[rawLine.index(after: colon)...]
        // 排除 `X := y` / `X ::= y` 这类变量赋值。
        guard !left.isEmpty, !after.hasPrefix("="), !left.contains("=") else { continue }
        // `%.o:` 是模式规则，展开不出具体目标。
        guard !left.contains("%"), !left.contains("$") else { continue }
        // `.PHONY:` 本身不是目标，但它右边列的都是。
        if left == ".PHONY" || left == ".DEFAULT_GOAL" {
          for target in after.split(separator: " ") where !target.isEmpty {
            let name = String(target)
            if !name.hasPrefix("."), seen.insert(name).inserted {
              result.append(AutocompleteDynamicItem(name: name))
            }
          }
          continue
        }
        guard !left.hasPrefix(".") else { continue }
        for target in left.split(separator: " ") where !target.isEmpty {
          let name = String(target)
          if seen.insert(name).inserted { result.append(AutocompleteDynamicItem(name: name)) }
        }
        if result.count >= 300 { break }
      }
      return result
    }
    return []
  }

  // MARK: Homebrew

  private enum BrewKind { case formula, cask }

  /// Homebrew 4.x 默认走 JSON API，本机可能既没有 homebrew-core tap 也没有 API 缓存。
  /// 这里把所有能读到的磁盘来源并起来；全都缺失时只给已安装的包，绝不联网、绝不
  /// 触发 `brew update`。
  private func brewNames(kind: BrewKind, installedOnly: Bool) -> [AutocompleteDynamicItem] {
    guard let prefix = brewPrefix() else { return [] }
    var names: [String] = []
    var seen: Set<String> = []
    func add(_ name: String) {
      guard !name.isEmpty, seen.insert(name).inserted, names.count < limits.maximumBrewItems
      else { return }
      names.append(name)
    }

    let installedRoot = prefix.appendingPathComponent(kind == .formula ? "Cellar" : "Caskroom")
    for entry in directoryNames(at: installedRoot) { add(entry) }

    if !installedOnly {
      let taps = prefix.appendingPathComponent("Library/Taps")
      for owner in directoryURLs(at: taps) {
        for tap in directoryURLs(at: owner) {
          let folder = kind == .formula ? "Formula" : "Casks"
          for url in [tap.appendingPathComponent(folder), tap] {
            for name in fileNames(at: url, extension: "rb") { add(name) }
          }
        }
      }
      if let cache = brewCache() {
        let file = kind == .formula ? "formula_names.txt" : "cask_names.txt"
        if let data = readFile(
          at: cache.appendingPathComponent("api/\(file)"), maximumBytes: 4 << 20)
        {
          for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            add(String(line))
          }
        }
      }
    }
    return names.sorted().map { AutocompleteDynamicItem(name: $0) }
  }

  private func brewTaps() -> [AutocompleteDynamicItem] {
    guard let prefix = brewPrefix() else { return [] }
    let root = prefix.appendingPathComponent("Library/Taps")
    var result: [AutocompleteDynamicItem] = []
    for owner in directoryURLs(at: root) {
      for tap in directoryURLs(at: owner) {
        let name = tap.lastPathComponent
        guard name.hasPrefix("homebrew-") else { continue }
        result.append(
          AutocompleteDynamicItem(
            name: "\(owner.lastPathComponent)/\(name.dropFirst("homebrew-".count))"))
      }
    }
    return result.sorted { $0.name < $1.name }
  }

  private func brewPrefix() -> URL? {
    // 显式设置了 `HOMEBREW_PREFIX` 就只认它,**不再回落到默认路径**:用户指到别处
    // (或指到一个不存在的目录)时,悄悄去读 /opt/homebrew 会给出与其环境不符的候选。
    let candidates: [String]
    if let value = environment["HOMEBREW_PREFIX"], value.hasPrefix("/") {
      candidates = [value]
    } else {
      candidates = ["/opt/homebrew", "/usr/local/Homebrew", "/usr/local"]
    }
    for path in candidates {
      let url = URL(fileURLWithPath: path)
      if isDirectory(url.appendingPathComponent("Library/Taps"))
        || isDirectory(url.appendingPathComponent("Cellar"))
      {
        return url
      }
    }
    return nil
  }

  private func brewCache() -> URL? {
    if let value = environment["HOMEBREW_CACHE"], value.hasPrefix("/") {
      return URL(fileURLWithPath: value)
    }
    guard let home = environment["HOME"], home.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/Homebrew")
  }

  // MARK: 文件系统辅助

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
  }

  private func directoryURLs(at url: URL) -> [URL] {
    guard let entries = try? fileManager.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants])
    else { return [] }
    return entries.prefix(limits.maximumEnumeratedEntries).filter { entry in
      guard let values = try? entry.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey,
      ]) else { return false }
      return values.isDirectory == true && values.isSymbolicLink != true
    }
  }

  private func directoryNames(at url: URL) -> [String] {
    directoryURLs(at: url).map(\.lastPathComponent).filter { !$0.hasPrefix(".") }
  }

  private func fileNames(at url: URL, extension pathExtension: String) -> [String] {
    guard let entries = try? fileManager.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants])
    else { return [] }
    return entries.prefix(limits.maximumEnumeratedEntries).compactMap { entry in
      guard entry.pathExtension == pathExtension,
        let values = try? entry.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true
      else { return nil }
      return entry.deletingPathExtension().lastPathComponent
    }
  }

  /// 只读普通文件，拒绝符号链接与特殊文件，并施加字节上限。`tailBytes` 非空时只读
  /// 文件末尾——reflog 可以很大，而我们只关心最近的几次 checkout。
  private func readFile(at url: URL, maximumBytes: Int, tailBytes: Int? = nil) -> Data? {
    guard let values = try? url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]), values.isRegularFile == true, values.isSymbolicLink != true
    else { return nil }
    let size = values.fileSize ?? 0
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    if let tailBytes, size > tailBytes {
      try? handle.seek(toOffset: UInt64(size - tailBytes))
      return try? handle.read(upToCount: tailBytes)
    }
    guard size <= maximumBytes else { return nil }
    return try? handle.read(upToCount: maximumBytes)
  }
}
