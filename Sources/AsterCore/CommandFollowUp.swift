import Foundation

/// 一条成功命令之后「最可能的下一步」。控制器在下一条空 prompt 把 `command` 作为
/// ghost 首选；`requiredPath` 存在时先核对磁盘（目录或文件），避免推荐一条必然失败的命令。
public struct CommandFollowUp: Equatable, Sendable {
  /// 建议的语义类别，只用于挑选面板里的说明文案。
  public enum Kind: Equatable, Sendable {
    case enterClonedRepository
    case enterCreatedDirectory
    case enterExtractedDirectory
    case activateVirtualEnvironment
    case extractDownloadedArchive
    case pushCommit
    case runExecutable
    case runImage
  }

  public let command: String
  public let kind: Kind
  /// 相对当前目录（或绝对）的路径；nil 表示无法也无需校验。
  public let requiredPath: String?
  /// `requiredPath` 必须是目录（true）还是普通文件（false）。
  public let requiresDirectory: Bool

  public init(command: String, kind: Kind, requiredPath: String?, requiresDirectory: Bool) {
    self.command = command
    self.kind = kind
    self.requiredPath = requiredPath
    self.requiresDirectory = requiresDirectory
  }
}

/// 只解析命令文本（不读取输出）推断下一步。规则宁缺毋滥：复合命令、改变工作目录的
/// 选项（`git -C`、`tar -C`、`unzip -d`、`wget -P`）以及无法确定目标名的形态一律返回 nil。
public enum CommandFollowUpParser {
  private static let shellOperators: Set<String> = ["&&", "||", ";", "|", ">", ">>", "<", "&"]
  private static let tarSuffixes = [
    ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".tar",
  ]

  public static func suggestion(command: String, exitStatus: Int) -> CommandFollowUp? {
    guard exitStatus == 0, command.utf8.count <= 4_096 else { return nil }
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard tokens.count >= 2, !tokens.contains(where: shellOperators.contains) else { return nil }
    // `/usr/bin/git` 与 `git` 同样处理；`sudo`/`env` 等前缀命令不猜。
    let executable = URL(fileURLWithPath: tokens[0]).lastPathComponent
    let arguments = Array(tokens.dropFirst())
    switch executable {
    case "git": return gitFollowUp(arguments)
    case "mkdir": return enterDirectory(mkdirTarget(arguments), kind: .enterCreatedDirectory)
    case "tar": return enterDirectory(tarExtractedDirectory(arguments), kind: .enterExtractedDirectory)
    case "unzip": return enterDirectory(unzipExtractedDirectory(arguments), kind: .enterExtractedDirectory)
    case "virtualenv":
      return activateVenv(positionals(arguments, valueOptions: ["-p", "--python", "--prompt"]).first)
    case "uv": return uvFollowUp(arguments)
    case "curl": return extractArchive(curlDownloadedFile(arguments))
    case "wget": return extractArchive(wgetDownloadedFile(arguments))
    case "chmod": return chmodFollowUp(arguments)
    case "docker", "podman", "nerdctl": return imageFollowUp(runtime: executable, arguments)
    case "gcc", "g++", "clang", "clang++", "cc", "c++", "rustc", "zig":
      return runBinary(optionValue(arguments, names: ["-o"]))
    case "go":
      guard arguments.first == "build" else { return nil }
      return runBinary(optionValue(Array(arguments.dropFirst()), names: ["-o"]))
    default:
      if executable.hasPrefix("python") {
        return pythonFollowUp(arguments)
      }
      return enterDirectory(scaffoldTarget(executable: executable, arguments: arguments),
        kind: .enterCreatedDirectory)
    }
  }

  // MARK: - git

  /// clone / init / worktree add → cd；commit → git push（--amend 不推 push，避免误推改写历史）。
  private static func gitFollowUp(_ arguments: [String]) -> CommandFollowUp? {
    guard let subcommand = arguments.first else { return nil }
    let rest = Array(arguments.dropFirst())
    switch subcommand {
    case "clone":
      return enterDirectory(cloneDestination(arguments: rest), kind: .enterClonedRepository)
    case "init":
      let directory = positionals(
        rest, valueOptions: ["--template", "--separate-git-dir", "-b", "--initial-branch",
          "--object-format", "--ref-format"]
      ).first
      return enterDirectory(directory, kind: .enterCreatedDirectory)
    case "worktree":
      guard rest.first == "add" else { return nil }
      let path = positionals(
        Array(rest.dropFirst()), valueOptions: ["-b", "-B", "--reason", "--orphan"]
      ).first
      return enterDirectory(path, kind: .enterCreatedDirectory)
    case "commit":
      guard !rest.contains("--amend") else { return nil }
      return CommandFollowUp(command: "git push", kind: .pushCommit, requiredPath: nil,
        requiresDirectory: false)
    default:
      return nil
    }
  }

  /// 按 git-clone 的参数语法找出目标目录：显式第二个位置参数优先，否则从仓库地址
  /// 推导（去掉尾部 `/`、`.git`；`--bare/--mirror` 时保留 `.git` 后缀）。
  static func cloneDestination(arguments: [String]) -> String? {
    let valueOptions: Set<String> = [
      "-b", "--branch", "-o", "--origin", "-u", "--upload-pack", "--template", "--reference",
      "--reference-if-able", "--depth", "--shallow-since", "--shallow-exclude", "-j", "--jobs",
      "--separate-git-dir", "-c", "--config", "--filter", "--server-option", "--bundle-uri",
    ]
    let found = positionals(arguments, valueOptions: valueOptions)
    let bare = arguments.contains("--bare") || arguments.contains("--mirror")
    guard let repository = found.first, !repository.isEmpty else { return nil }
    if found.count >= 2 { return found[1] }
    // 与 git 的 guess_dir_name 一致：去尾部斜杠 → 取最后一段（兼容 scp 语法的 `host:path`）
    // → 去掉 `.git` 后缀；`.git` 单独成段时再向前取一段。
    var path = repository
    while path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix("/.git") { path.removeLast(5) }
    var name = path.split(separator: "/").last.map(String.init) ?? ""
    if !path.contains("://"), let colon = name.lastIndex(of: ":") {
      name = String(name[name.index(after: colon)...])
    }
    if name.hasSuffix(".git") { name.removeLast(4) }
    guard !name.isEmpty else { return nil }
    return bare ? name + ".git" : name
  }

  // MARK: - 目录类

  /// `mkdir [-p] [-m mode] dir...` → 最后一个目录。
  private static func mkdirTarget(_ arguments: [String]) -> String? {
    positionals(arguments, valueOptions: ["-m", "--mode"]).last
  }

  /// `tar x… <archive>`（无 `-C`）→ 去掉压缩后缀的归档名；顶层目录是否真叫这个名字由
  /// 控制器的存在性校验兜底。
  private static func tarExtractedDirectory(_ arguments: [String]) -> String? {
    var extracting = false
    var archive: String?
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if argument == "-C" || argument == "--directory" || argument.hasPrefix("--directory=") {
        return nil
      }
      if argument == "--extract" || argument == "--get" { extracting = true; continue }
      if argument.hasPrefix("--file=") { archive = String(argument.dropFirst(7)); continue }
      if argument == "--file" || argument == "-f" {
        guard index < arguments.count else { return nil }
        archive = arguments[index]
        index += 1
        continue
      }
      if argument.hasPrefix("--") { continue }
      // 旧式 `xzf` 与 `-xzf` 都是模式簇：含 x 即解包；以 f 结尾则下一个参数是归档文件。
      let cluster = argument.hasPrefix("-") ? String(argument.dropFirst()) : argument
      let isCluster = !cluster.isEmpty && cluster.allSatisfy(\.isLetter)
        && (archive == nil || argument.hasPrefix("-"))
      if isCluster {
        if cluster.contains("C") { return nil }
        if cluster.contains("x") { extracting = true }
        if cluster.hasSuffix("f") {
          guard index < arguments.count else { return nil }
          archive = arguments[index]
          index += 1
        }
      }
    }
    guard extracting, let archive else { return nil }
    return strippingArchiveSuffix(archive, suffixes: tarSuffixes)
  }

  /// `unzip <file.zip>`（无 `-d`）→ 去掉 .zip 的名字。
  private static func unzipExtractedDirectory(_ arguments: [String]) -> String? {
    guard !arguments.contains("-d") else { return nil }
    guard let archive = positionals(arguments, valueOptions: ["-x", "-P"]).first,
      archive.lowercased().hasSuffix(".zip")
    else { return nil }
    return strippingArchiveSuffix(archive, suffixes: [".zip"])
  }

  /// 脚手架命令 → `cd <项目名>`。名字必须在命令里显式给出；交互式询问的形态无法推断。
  private static func scaffoldTarget(executable: String, arguments: [String]) -> String? {
    // 表：可执行名 → (子命令序列, 位置参数下标, 带值选项)。位置参数从子命令之后数。
    struct Rule {
      let subcommands: [String]
      let index: Int
      let valueOptions: Set<String>
    }
    let rules: [String: [Rule]] = [
      "cargo": [Rule(subcommands: ["new"], index: 0, valueOptions: ["--name", "--vcs", "--edition", "--registry"])],
      "rails": [Rule(subcommands: ["new"], index: 0, valueOptions: ["-d", "--database", "-m", "--template", "-j", "--javascript", "-c", "--css", "-a", "--asset-pipeline"])],
      "flutter": [Rule(subcommands: ["create"], index: 0, valueOptions: ["-t", "--template", "--org", "--project-name", "--platforms", "-a", "-i", "--description", "--sample"])],
      "django-admin": [Rule(subcommands: ["startproject"], index: 0, valueOptions: ["--template", "--extension", "-e", "--name", "-n"])],
      "nest": [Rule(subcommands: ["new", "n"], index: 0, valueOptions: ["-p", "--package-manager", "-l", "--language", "-c", "--collection"])],
      "ng": [Rule(subcommands: ["new", "n"], index: 0, valueOptions: ["--package-manager", "--style", "--prefix", "--collection", "-c", "--directory"])],
      "vue": [Rule(subcommands: ["create"], index: 0, valueOptions: ["-p", "--preset", "-m", "--packageManager", "-r", "--registry"])],
      "laravel": [Rule(subcommands: ["new"], index: 0, valueOptions: ["--database", "--stack"])],
      "mix": [Rule(subcommands: ["new"], index: 0, valueOptions: ["--app", "--module"]),
        Rule(subcommands: ["phx.new"], index: 0, valueOptions: ["--app", "--module", "--database"])],
      "poetry": [Rule(subcommands: ["new"], index: 0, valueOptions: ["--name"])],
      "deno": [Rule(subcommands: ["init"], index: 0, valueOptions: [])],
      "hugo": [Rule(subcommands: ["new", "site"], index: 0, valueOptions: ["-f", "--format"])],
      "composer": [Rule(subcommands: ["create-project"], index: 1, valueOptions: ["--repository", "--stability"])],
      "lein": [Rule(subcommands: ["new"], index: 1, valueOptions: [])],
      // `npm create vite@latest my-app`：initializer 之后第一个位置参数是目录。
      "npm": [Rule(subcommands: ["create"], index: 1, valueOptions: []),
        Rule(subcommands: ["init"], index: 1, valueOptions: [])],
      "yarn": [Rule(subcommands: ["create"], index: 1, valueOptions: []),
        Rule(subcommands: ["dlx"], index: 1, valueOptions: [])],
      "pnpm": [Rule(subcommands: ["create"], index: 1, valueOptions: []),
        Rule(subcommands: ["dlx"], index: 1, valueOptions: [])],
      "bun": [Rule(subcommands: ["create"], index: 1, valueOptions: [])],
      // `npx create-react-app my-app` / `bunx create-vite my-app`
      "npx": [Rule(subcommands: [], index: 1, valueOptions: ["-p", "--package"])],
      "bunx": [Rule(subcommands: [], index: 1, valueOptions: [])],
    ]
    guard let candidates = rules[executable] else { return nil }
    for rule in candidates where Array(arguments.prefix(rule.subcommands.count)) == rule.subcommands {
      let rest = Array(arguments.dropFirst(rule.subcommands.count))
      // `--` 之后是转给模板的参数，不再是项目名。
      let own = rest.prefix { $0 != "--" }
      let found = positionals(Array(own), valueOptions: rule.valueOptions)
      // npx/dlx/create 只认 create-* 或 initializer 形态，避免把 `npx prettier .` 当脚手架。
      if rule.index == 1 {
        guard let initializer = found.first else { return nil }
        // `npm create x` / `npm init x` / `composer create-project` / `lein new` 的第一个
        // 位置参数天然是 initializer；npx/dlx/bunx 则必须显式是 create-* 包。
        let creatorSubcommands: Set<String> = ["create", "init", "create-project", "new"]
        let isCreator = initializer.contains("create")
          || rule.subcommands.first.map(creatorSubcommands.contains) ?? false
        guard isCreator else { return nil }
      }
      guard found.count > rule.index else { return nil }
      return found[rule.index]
    }
    return nil
  }

  // MARK: - 虚拟环境

  /// `python -m venv <dir>` → `source <dir>/bin/activate`。
  private static func pythonFollowUp(_ arguments: [String]) -> CommandFollowUp? {
    guard let moduleIndex = arguments.firstIndex(of: "-m"),
      moduleIndex + 1 < arguments.count, arguments[moduleIndex + 1] == "venv"
    else { return nil }
    let rest = Array(arguments.dropFirst(moduleIndex + 2))
    return activateVenv(positionals(rest, valueOptions: ["--prompt"]).first)
  }

  /// `uv venv [dir]`（默认 .venv）→ 激活；`uv init <name>` → cd。
  private static func uvFollowUp(_ arguments: [String]) -> CommandFollowUp? {
    switch arguments.first {
    case "venv":
      let rest = Array(arguments.dropFirst())
      let directory = positionals(
        rest, valueOptions: ["-p", "--python", "--prompt", "--seed", "--cache-dir"]
      ).first
      return activateVenv(directory ?? ".venv")
    case "init":
      let rest = Array(arguments.dropFirst())
      let directory = positionals(rest, valueOptions: ["--name", "-p", "--python", "--build-backend"]).first
      return enterDirectory(directory, kind: .enterCreatedDirectory)
    default:
      return nil
    }
  }

  private static func activateVenv(_ directory: String?) -> CommandFollowUp? {
    guard let directory, isSafeTarget(directory) else { return nil }
    let script = (directory as NSString).appendingPathComponent("bin/activate")
    return CommandFollowUp(
      command: "source \(shellQuoted(script))", kind: .activateVirtualEnvironment,
      requiredPath: script, requiresDirectory: false)
  }

  // MARK: - 下载后解压

  /// `curl -O/-LO <url>` 或 `curl -o <file> <url>` 保存的文件名。
  private static func curlDownloadedFile(_ arguments: [String]) -> String? {
    let valueOptions: Set<String> = [
      "-o", "--output", "-H", "--header", "-d", "--data", "--data-raw", "--data-binary", "-X",
      "--request", "-u", "--user", "-A", "--user-agent", "-e", "--referer", "-b", "--cookie",
      "-c", "--cookie-jar", "-T", "--upload-file", "--connect-timeout", "--max-time", "-m",
      "--retry", "-x", "--proxy", "--cacert", "--cert", "--key", "-F", "--form", "-w",
      "--write-out", "--resolve", "--url", "--output-dir",
    ]
    if arguments.contains("--output-dir") { return nil }
    var remoteName = false
    var output: String?
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if argument == "--remote-name" { remoteName = true; continue }
      if argument == "-o" || argument == "--output" {
        guard index < arguments.count else { return nil }
        output = arguments[index]
        index += 1
        continue
      }
      if argument.hasPrefix("--output=") { output = String(argument.dropFirst(9)); continue }
      if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 {
        // 短选项簇：`-sSLO` 里的 O 是 remote-name；簇末尾的 o 吃下一个参数。
        let cluster = argument.dropFirst()
        if cluster.contains("O") { remoteName = true }
        if cluster.hasSuffix("o") {
          guard index < arguments.count else { return nil }
          output = arguments[index]
          index += 1
        } else if cluster.count == 1, valueOptions.contains(argument) {
          index += 1
        }
        continue
      }
      if valueOptions.contains(argument) { index += 1 }
    }
    if let output { return output }
    guard remoteName, let url = positionals(arguments, valueOptions: valueOptions).first
    else { return nil }
    return remoteFileName(url)
  }

  /// `wget <url>` 或 `wget -O <file> <url>` 保存的文件名；`-P` 改目录时放弃。
  private static func wgetDownloadedFile(_ arguments: [String]) -> String? {
    if arguments.contains("-P") || arguments.contains(where: { $0.hasPrefix("--directory-prefix") }) {
      return nil
    }
    if let output = optionValue(arguments, names: ["-O", "--output-document"]) { return output }
    let valueOptions: Set<String> = [
      "-o", "--output-file", "-a", "--append-output", "-U", "--user-agent", "--header", "-t",
      "--tries", "-T", "--timeout", "-w", "--wait", "--limit-rate", "--user", "--password",
      "-B", "--base", "-e", "--execute", "--referer", "--post-data", "--post-file",
    ]
    guard let url = positionals(arguments, valueOptions: valueOptions).first else { return nil }
    return remoteFileName(url)
  }

  /// URL 最后一段（去掉 query/fragment）。
  private static func remoteFileName(_ url: String) -> String? {
    let trimmed = url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? url
    let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
    return name.isEmpty || name.contains(":") ? nil : name
  }

  /// 压缩包 → `tar -xf` / `unzip`；不是压缩包的下载不建议。
  private static func extractArchive(_ file: String?) -> CommandFollowUp? {
    guard let file, isSafeTarget(file) else { return nil }
    let lowered = file.lowercased()
    let command: String
    if tarSuffixes.contains(where: lowered.hasSuffix) {
      command = "tar -xf \(shellQuoted(file))"
    } else if lowered.hasSuffix(".zip") {
      command = "unzip \(shellQuoted(file))"
    } else {
      return nil
    }
    return CommandFollowUp(
      command: command, kind: .extractDownloadedArchive, requiredPath: file,
      requiresDirectory: false)
  }

  // MARK: - 运行

  /// `chmod +x script.sh` → `./script.sh`。只处理单个目标且模式含 +x。
  private static func chmodFollowUp(_ arguments: [String]) -> CommandFollowUp? {
    let found = positionals(arguments, valueOptions: [])
    guard found.count == 2, found[0].contains("+x") else { return nil }
    return runBinary(found[1])
  }

  /// `docker build -t name .` → `docker run --rm -it name`。
  private static func imageFollowUp(runtime: String, _ arguments: [String]) -> CommandFollowUp? {
    guard arguments.first == "build" || Array(arguments.prefix(2)) == ["buildx", "build"],
      let image = optionValue(arguments, names: ["-t", "--tag"]), isSafeTarget(image)
    else { return nil }
    return CommandFollowUp(
      command: "\(runtime) run --rm -it \(shellQuoted(image))", kind: .runImage,
      requiredPath: nil, requiresDirectory: false)
  }

  /// 可执行文件 → `./name`（含路径分隔符的保持原样）。
  private static func runBinary(_ path: String?) -> CommandFollowUp? {
    guard let path, isSafeTarget(path), !path.hasSuffix("/") else { return nil }
    let command = path.contains("/") ? path : "./" + path
    return CommandFollowUp(
      command: shellQuoted(command), kind: .runExecutable, requiredPath: path,
      requiresDirectory: false)
  }

  // MARK: - 通用

  private static func enterDirectory(_ directory: String?, kind: CommandFollowUp.Kind) -> CommandFollowUp? {
    guard let directory, isSafeTarget(directory), directory != ".", directory != "..",
      directory != "./"
    else { return nil }
    return CommandFollowUp(
      command: "cd \(shellQuoted(directory))", kind: kind, requiredPath: directory,
      requiresDirectory: true)
  }

  /// 去掉压缩后缀；没有匹配后缀或去掉后为空时返回 nil。
  private static func strippingArchiveSuffix(_ archive: String, suffixes: [String]) -> String? {
    let name = archive.split(separator: "/").last.map(String.init) ?? archive
    let lowered = name.lowercased()
    guard let suffix = suffixes.first(where: lowered.hasSuffix) else { return nil }
    let stripped = String(name.dropLast(suffix.count))
    return stripped.isEmpty ? nil : stripped
  }

  /// 跳过选项（含带值选项的值）后的位置参数；`--` 之后全部视为位置参数。
  static func positionals(_ arguments: [String], valueOptions: Set<String>) -> [String] {
    var result: [String] = []
    var index = 0
    var optionsEnded = false
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
        result.append(argument)
        continue
      }
      if argument == "--" { optionsEnded = true; continue }
      // `--opt=value` 自带值；`-bmain` 这类粘连短选项也不消耗下一个参数。
      if argument.contains("=") { continue }
      if valueOptions.contains(argument) { index += 1 }
    }
    return result
  }

  /// `-o out` / `-o=out` / `--output=out` 形态的选项值。
  private static func optionValue(_ arguments: [String], names: Set<String>) -> String? {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if names.contains(argument) {
        return index < arguments.count ? arguments[index] : nil
      }
      for name in names where argument.hasPrefix(name + "=") {
        return String(argument.dropFirst(name.count + 1))
      }
    }
    return nil
  }

  private static func isSafeTarget(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1_024
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  /// 含空格或 shell 特殊字符时用单引号包住，保证一次 Tab 就能执行。
  static func shellQuoted(_ value: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/~+@:,%="))
    if value.unicodeScalars.allSatisfy(safe.contains) { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
