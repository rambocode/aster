import AppKit
import AsterCore

/// 把运行态标签（目录、前台命令、Agent、SSH 端点、程序标题）投影成 `TabTitleContext`，
/// 并按当前「视图」配置解析别名 / 图标 / 标题模板。展示层（侧栏行、横向标签栏、
/// 详情面板自定义视图）共用这一个入口，规则语义只在 AsterCore 里定义一次。
@MainActor
enum TabTitleRuleService {
  /// git 分支按目录缓存 2s：标签行在 OSC 标题变化时会高频重算标题，不能每次都读文件。
  private static var branchCache: [String: (branch: String?, at: Date)] = [:]

  /// 组装标签上下文。`index` 从 1 开始，与 Otty `${index}` 语义一致。
  static func context(for tab: TerminalTabItem, index: Int) -> TabTitleContext {
    let session = tab.activeSession
    let endpoint = session?.sshRemoteEndpoint
    let filePane = tab.activeRuntime?.descriptor
    let file = filePane?.kind == .terminal ? nil : filePane?.resourcePath
    let cwd = tab.workingDirectory
    return TabTitleContext(
      cwd: cwd,
      file: file,
      command: session?.foregroundCommandName,
      agent: session?.activeAgentProvider?.commandName,
      host: endpoint?.hostName,
      user: endpoint?.user,
      branch: currentBranch(in: cwd),
      programTitle: tab.title,
      shell: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").lastPathComponent,
      index: index,
      homeDirectory: NSHomeDirectory()
    )
  }

  /// 解析结果与已渲染标题。`renderedTitle` 为 nil 表示没有标题规则命中或模板渲染为空。
  struct Outcome {
    var resolution: TabTitleResolution
    var renderedTitle: String?
  }

  static func resolve(tab: TerminalTabItem, index: Int, configuration: ViewConfiguration) -> Outcome {
    let rules = configuration.resolvedTabRules
    guard !rules.isEmpty else { return Outcome(resolution: TabTitleResolution(), renderedTitle: nil) }
    let context = context(for: tab, index: index)
    let resolution = TabTitleRuleResolver.resolve(rules: rules, context: context)
    let rendered = resolution.titleTemplate.flatMap {
      TabTitleRuleResolver.render(template: $0, context: context, alias: resolution.alias)
    }
    return Outcome(resolution: resolution, renderedTitle: rendered)
  }

  /// 只读 `.git/HEAD`（向上最多 8 层查找仓库根），不派生 git 子进程。分离 HEAD 返回短 SHA。
  static func currentBranch(in directory: String) -> String? {
    if let cached = branchCache[directory], Date().timeIntervalSince(cached.at) < 2 {
      return cached.branch
    }
    var branch: String?
    var url = URL(fileURLWithPath: directory)
    for _ in 0..<8 {
      let head = url.appendingPathComponent(".git/HEAD")
      if let data = try? Data(contentsOf: head), let text = String(data: data, encoding: .utf8) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        branch = line.hasPrefix("ref: refs/heads/")
          ? String(line.dropFirst("ref: refs/heads/".count))
          : String(line.prefix(7))
        break
      }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { break }
      url = parent
    }
    branchCache[directory] = (branch, Date())
    return branch
  }
}

/// 标签图标渲染：图标集 SVG 按模板着色，emoji 直接用文本绘制。两者都落在 16pt 方槽内。
@MainActor
enum TabIconArtwork {
  private static var imageCache: [String: NSImage] = [:]

  /// 图标集目录：与设置页共用 `settings-ui/tab-icons`，网页端 `<img>` 与原生端读同一份文件。
  static func iconsDirectory() -> URL? {
    AsterResourceLocations.resourcesDirectory()?
      .appendingPathComponent("settings-ui/tab-icons", isDirectory: true)
  }

  /// 图标集里的全部名称（不含扩展名），按字母排序；设置页快照据此渲染选择器。
  static func availableIconNames() -> [String] {
    guard let directory = iconsDirectory(),
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return names.filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) }.sorted()
  }

  /// 图标集 SVG 源文本（按名称索引）。设置页用它内联渲染选择器，避免 file:// 下 CSS
  /// 图片加载受 CSP 限制；文件来自应用自身资源，不含用户输入。
  static func iconSVGTexts() -> [String: String] {
    guard let directory = iconsDirectory() else { return [:] }
    var result: [String: String] = [:]
    for name in availableIconNames() {
      guard let text = try? String(contentsOf: directory.appendingPathComponent("\(name).svg"), encoding: .utf8),
        text.utf8.count <= 16_384
      else { continue }
      result[name] = text
    }
    return result
  }

  /// 图标集变体（对齐 Otty 的两套目录）：`tab` 带底色块，用于设置页选择器；
  /// `view` 是无底色的线稿，用于侧栏行与标题胶囊这种小尺寸场景，不会糊成一团。
  enum Variant: String {
    case tab = "tab-icons"
    case view = "view-icons"
  }

  /// 图标名只允许 `[a-z0-9-]`，杜绝用规则文件拼出目录穿越路径。
  /// `view` 变体缺图时回退到 `tab` 变体，保证任何图标名都有图可用。
  static func image(named name: String, variant: Variant = .view) -> NSImage? {
    guard !name.isEmpty, name.utf8.count <= 64,
      name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).contains($0) }),
      let resources = AsterResourceLocations.resourcesDirectory()
    else { return nil }
    let cacheKey = "\(variant.rawValue)/\(name)"
    if let cached = imageCache[cacheKey] { return cached }
    let directory = resources.appendingPathComponent("settings-ui/\(variant.rawValue)", isDirectory: true)
    guard let image = NSImage(contentsOf: directory.appendingPathComponent("\(name).svg")) else {
      return variant == .view ? image(named: name, variant: .tab) : nil
    }
    image.isTemplate = true
    image.size = NSSize(width: 14, height: 14)
    imageCache[cacheKey] = image
    return image
  }

  /// 生成 14pt 的图标视图；emoji 优先于图标集名称（用户在选择器里二选一时后写者胜）。
  static func makeView(for icon: TabRuleIcon, fallbackTint: NSColor) -> NSView? {
    let tint = icon.color.map { NSColor($0) } ?? fallbackTint
    if let emoji = icon.emoji, !emoji.isEmpty {
      let label = NSTextField(labelWithString: emoji)
      label.font = .systemFont(ofSize: 12)
      label.alignment = .center
      label.setAccessibilityLabel("标签图标 \(emoji)")
      return label
    }
    guard let name = icon.name, let image = image(named: name) else { return nil }
    let view = NSImageView()
    view.image = image
    view.contentTintColor = tint
    view.imageScaling = .scaleProportionallyDown
    view.setAccessibilityLabel("标签图标 \(name)")
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 14).isActive = true
    view.heightAnchor.constraint(equalToConstant: 14).isActive = true
    return view
  }
}
