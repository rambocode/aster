import AppKit
import AsterCore
import Combine
import CoreFoundation
import Foundation

struct TerminalFontVariants {
  let normal: NSFont
  let bold: NSFont
  let italic: NSFont
  let boldItalic: NSFont
}

/// 网页设置清单中尚未进入 Aster 运行时领域模型的兼容字段。
///
/// 这些值不是占位 UI：它们会按原始 JSON 类型持久化并参与导入、导出和跨平台往返。
/// macOS 当前不能应用的 Windows 字体渲染选项也保存在这里，避免打开设置后丢失配置。
enum SettingsCompatibilityValue: Codable, Equatable {
  case bool(Bool)
  case number(Double)
  case string(String)

  init?(jsonValue: Any) {
    // `NSNumber` 同时承载 JavaScript Boolean 与 Number，必须先通过 CoreFoundation
    // 类型标识区分，否则 true 会被错误保存为 1。
    if let number = jsonValue as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
    } else if let string = jsonValue as? String {
      self = .string(string)
    } else {
      return nil
    }
  }

  var jsonValue: Any {
    switch self {
    case .bool(let value): value
    case .number(let value): value
    case .string(let value): value
    }
  }
}

/// 九类设置共享的持久化配置入口。领域配置以单个 JSON 数据块保存，确保 Recipe、
/// 主题和布局字段可以原子迁移；AppKit 控制器通过 Combine 订阅变化并刷新原生控件。
@MainActor
final class AppPreferences: ObservableObject {
  enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var label: String {
      switch self {
      case .system: "跟随系统"
      case .light: "浅色"
      case .dark: "深色"
      }
    }
  }

  @Published var appearance: Appearance {
    didSet {
      defaults.set(appearance.rawValue, forKey: Keys.appearance)
      synchronizeThemeRuntime()
    }
  }

  @Published var configuration: AsterConfiguration {
    didSet {
      persistConfiguration()
      synchronizeThemeRuntime()
    }
  }

  @Published private(set) var themeLibrary: TerminalThemeLibrary {
    didSet {
      persistThemeLibrary()
      synchronizeThemeRuntime()
    }
  }

  /// 用户对各套主题的参数覆盖。颜色、ANSI 与主题字体都写在这里而不是复制整套主题，
  /// 内置真值表因此保持只读，主题列表也不会被一堆自动生成的「副本」淹没。
  @Published private(set) var themeOverrides: ThemeOverrideLibrary {
    didSet {
      persistThemeOverrides()
      synchronizeThemeRuntime()
    }
  }

  /// Aster 主题目录（`~/.config/aster/themes`）的解析快照，是主题的磁盘真值：
  /// 内置表在首次运行时物化到这里，用户直接编辑文件即可改主题。按 id / 名字遮蔽
  /// 内置表；id 取文件 stem（与内置 id 同形，如 `one-light`），既有的用户覆盖层
  /// （按 id 存储）因此无缝套用。
  @Published private(set) var diskThemes: [TerminalTheme] = []
  /// 主题目录指纹（文件名 → mtime）。刷新入口先轻量比对，未变化不重新解析。
  private var diskThemesFingerprint: [String: Date]?

  /// Otty 兼容清单中的扩展设置。字段逐步接入运行时后可从这里迁入强类型领域配置；
  /// 在此之前仍保证编辑、重启和跨平台往返不丢值。
  @Published private(set) var settingsCompatibility: [String: SettingsCompatibilityValue] {
    didSet { persistSettingsCompatibility() }
  }

  @Published var sidebarTabGrouping: SidebarTabGrouping {
    didSet { defaults.set(sidebarTabGrouping.rawValue, forKey: Keys.sidebarTabGrouping) }
  }

  @Published var sidebarTabOrder: SidebarTabOrder {
    didSet { defaults.set(sidebarTabOrder.rawValue, forKey: Keys.sidebarTabOrder) }
  }

  /// 侧栏分组的折叠集合。key 带分组模式前缀（如 `project:~/src/foo/`），
  /// 切换分组模式后各自的折叠记忆互不串扰。
  @Published private(set) var sidebarCollapsedGroups: Set<String> {
    didSet { defaults.set(Array(sidebarCollapsedGroups).sorted(), forKey: Keys.sidebarCollapsedGroups) }
  }

  /// 折叠 key = 分组模式 + 组标题；调用方不自行拼接，保证规则只有一处。
  func sidebarGroupKey(forTitle title: String) -> String {
    "\(sidebarTabGrouping.rawValue):\(title)"
  }

  func isSidebarGroupCollapsed(title: String) -> Bool {
    let key = sidebarGroupKey(forTitle: title)
    if sidebarCollapsedGroups.contains(key) { return true }
    // 旧版 local project 直接用完整路径作 title；新 identity 加入 `local:` 类型前缀。
    // 只读兼容旧 key，升级后用户原有折叠状态不会突然全部展开。
    guard sidebarTabGrouping == .project, title.hasPrefix("local:") else { return false }
    let legacyTitle = String(title.dropFirst("local:".count))
    return sidebarCollapsedGroups.contains(sidebarGroupKey(forTitle: legacyTitle))
  }

  func toggleSidebarGroupCollapsed(title: String) {
    let key = sidebarGroupKey(forTitle: title)
    if sidebarCollapsedGroups.contains(key) {
      sidebarCollapsedGroups.remove(key)
    } else if sidebarTabGrouping == .project, title.hasPrefix("local:") {
      let legacyTitle = String(title.dropFirst("local:".count))
      let legacyKey = sidebarGroupKey(forTitle: legacyTitle)
      if sidebarCollapsedGroups.contains(legacyKey) {
        // 第一次交互顺便消费旧 key；当前动作语义是从折叠切到展开。
        sidebarCollapsedGroups.remove(legacyKey)
      } else {
        sidebarCollapsedGroups.insert(key)
      }
    } else {
      sidebarCollapsedGroups.insert(key)
    }
  }

  /// 右侧详情面板的显隐与选中页属于轻量 UI 状态，随 UserDefaults 持久化但不进入
  /// 配置 JSON（与侧栏分组/排序同级）。刻意不用 @Published：显隐由
  /// `AppModel.inspectorPresentationChanged` 驱动内容区局部约束切换，选中页由面板
  /// 本地即时生效；这里仅落盘，不能触发工作区重建。
  var inspectorPresented: Bool {
    get { defaults.bool(forKey: Keys.inspectorPresented) }
    set { defaults.set(newValue, forKey: Keys.inspectorPresented) }
  }

  /// 详情面板选中页。上界随 `DetailsPanelViewController.Section` 的 case 数量增长：
  /// 新增 section 必须同步这里，否则新页永远无法从上次会话恢复。
  var inspectorSection: Int {
    get { min(max(defaults.integer(forKey: Keys.inspectorSection), 0), 4) }
    set { defaults.set(min(max(newValue, 0), 4), forKey: Keys.inspectorSection) }
  }

  // MARK: - Session Memory（记录与提炼）

  /// 记录总开关（PRD §69）。默认关闭：记录会持久化命令与输出摘录，必须用户主动开启。
  var memoryRecordingMode: RecordingMode {
    get {
      defaults.string(forKey: Keys.memoryRecordingMode)
        .flatMap(RecordingMode.init(rawValue:)) ?? .off
    }
    set { defaults.set(newValue.rawValue, forKey: Keys.memoryRecordingMode) }
  }

  /// 排除目录：这些路径下的活动完全不进记录管线。
  var memoryExcludedPaths: [String] {
    get { defaults.stringArray(forKey: Keys.memoryExcludedPaths) ?? [] }
    set { defaults.set(newValue, forKey: Keys.memoryExcludedPaths) }
  }

  /// 排除命令：首个 token 命中即整条命令与其输出都不记录（如 `op`、`vault`）。
  var memoryExcludedCommands: [String] {
    get { defaults.stringArray(forKey: Keys.memoryExcludedCommands) ?? [] }
    set { defaults.set(newValue, forKey: Keys.memoryExcludedCommands) }
  }

  /// 当前生效的记录策略（三项设置的组合投影 + 内置排除基线）。
  /// 基线在装配时并入而不落入用户偏好：设置页只展示、只保存用户自己加的项。
  var memoryRecordingPolicy: RecordingPolicy {
    Self.mergedRecordingPolicy(
      mode: memoryRecordingMode,
      userPaths: memoryExcludedPaths,
      userCommands: memoryExcludedCommands
    )
  }

  /// 是否允许调用本机 CLI Agent 提炼 Session Memory。默认关闭：
  /// 该操作会把会话摘要发送给对应 Agent 的云端（PRD §73）。
  var memoryExtractionEnabled: Bool {
    get { defaults.bool(forKey: Keys.memoryExtractionEnabled) }
    set { defaults.set(newValue, forKey: Keys.memoryExtractionEnabled) }
  }

  /// 用于提炼的 provider rawValue（如 `claudeCode`）。
  var memoryExtractionProvider: String? {
    get { defaults.string(forKey: Keys.memoryExtractionProvider) }
    set { defaults.set(newValue, forKey: Keys.memoryExtractionProvider) }
  }

  /// 用户是否已确认过外发提示。未确认时即便开关为真也不得发送。
  var memoryExtractionAcknowledged: Bool {
    get { defaults.bool(forKey: Keys.memoryExtractionAcknowledged) }
    set { defaults.set(newValue, forKey: Keys.memoryExtractionAcknowledged) }
  }

  /// 从任意 `UserDefaults` 读取记录策略。记录服务是进程级单例，不持有窗口级
  /// `AppPreferences` 实例；这里提供无实例读取，避免为一个只读设置引入装配依赖。
  static func memoryRecordingPolicy(from defaults: UserDefaults) -> RecordingPolicy {
    mergedRecordingPolicy(
      mode: defaults.string(forKey: Keys.memoryRecordingMode)
        .flatMap(RecordingMode.init(rawValue:)) ?? .off,
      userPaths: defaults.stringArray(forKey: Keys.memoryExcludedPaths) ?? [],
      userCommands: defaults.stringArray(forKey: Keys.memoryExcludedCommands) ?? []
    )
  }

  /// 用户排除列表 + 内置基线的合并装配：基线永远生效、用户项只能追加。
  /// 集中在这里保证实例属性与静态读取两条路径的策略语义一致。
  static func mergedRecordingPolicy(
    mode: RecordingMode, userPaths: [String], userCommands: [String]
  ) -> RecordingPolicy {
    RecordingPolicy(
      mode: mode,
      excludedPathPrefixes: mergedUnique(
        RecordingPolicy.baselineExcludedPathPrefixes(homeDirectory: NSHomeDirectory()),
        userPaths),
      excludedCommandPrefixes: mergedUnique(
        RecordingPolicy.baselineExcludedCommandPrefixes, userCommands)
    )
  }

  /// 顺序保持的去重合并（基线在前，用户项在后）。
  private static func mergedUnique(_ base: [String], _ extra: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for item in base + extra where seen.insert(item).inserted {
      result.append(item)
    }
    return result
  }

  /// 同上：提炼设置的无实例读取。`enabled` 与 `acknowledged` 必须同时为真才允许外发。
  static func memoryExtractionSettings(from defaults: UserDefaults)
    -> (enabled: Bool, provider: String?, acknowledged: Bool)
  {
    (
      defaults.bool(forKey: Keys.memoryExtractionEnabled),
      defaults.string(forKey: Keys.memoryExtractionProvider),
      defaults.bool(forKey: Keys.memoryExtractionAcknowledged)
    )
  }

  // MARK: - 软件更新

  /// 更新通道。Sparkle 只在每次检查时向 delegate 询问允许的 channel，自身不持久化
  /// 通道，因此这里是唯一真值。
  ///
  /// 刻意不进 `AsterConfiguration`：通道属于「这台机器上的这次安装」，不应随导出的
  /// settings.json 把别人也拉上预览分支（与 Session Memory 同样的隔离理由）。两个自动
  /// 更新开关反过来完全归 Sparkle（SUEnableAutomaticChecks / SUAutomaticallyUpdate），
  /// Aster 不留副本，避免用户在 Sparkle 自带对话框里改动后两边漂移。
  var updateChannel: UpdateChannel {
    get {
      defaults.string(forKey: Keys.updateChannel)
        .flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }
    set { defaults.set(newValue.rawValue, forKey: Keys.updateChannel) }
  }

  /// 从任意 `UserDefaults` 读取更新通道。`SPUUpdaterDelegate` 是进程级对象，不持有
  /// 窗口级 `AppPreferences`；与 `memoryRecordingPolicy(from:)` 同一模式。
  static func updateChannel(from defaults: UserDefaults) -> UpdateChannel {
    defaults.string(forKey: Keys.updateChannel)
      .flatMap(UpdateChannel.init(rawValue:)) ?? .stable
  }

  /// Git 页「在编辑器中打开」记住的目标 bundle ID。只是一个偏好指针：真正可用的编辑器
  /// 每次由 `WorkspaceEditorLocator` 重新探测，卸载后会自动回落到第一个已安装项。
  var inspectorGitEditorBundleIdentifier: String? {
    get { defaults.string(forKey: Keys.inspectorGitEditor) }
    set { defaults.set(newValue, forKey: Keys.inspectorGitEditor) }
  }

  private let defaults: UserDefaults
  /// 主题目录的可注入入口。生产环境固定使用 `~/.config/aster/themes`；测试传入
  /// 临时目录，避免颜色覆盖测试碰触用户正在使用的主题文件。
  private let themesDirectoryURL: URL?
  /// 菜单主题选择器的临时预览值。预览必须作用到完整工作区，但在用户点击或按回车
  /// 确认前不能写入配置；这样按 `Esc` 或点到面板外时可以无损回到原选择。
  private var previewedTheme: TerminalTheme?

  init(defaults: UserDefaults = .standard, themesDirectoryURL: URL? = nil) {
    self.defaults = defaults
    self.themesDirectoryURL = themesDirectoryURL
    appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
    if let data = defaults.data(forKey: Keys.configuration),
      let decoded = try? JSONDecoder().decode(AsterConfiguration.self, from: data)
    {
      configuration = decoded.normalized()
    } else {
      configuration = .default
    }
    if let data = defaults.data(forKey: Keys.themeLibrary),
      let decoded = try? JSONDecoder().decode(TerminalThemeLibrary.self, from: data)
    {
      themeLibrary = decoded
    } else {
      themeLibrary = TerminalThemeLibrary()
    }
    if let data = defaults.data(forKey: Keys.themeOverrides),
      let decoded = try? JSONDecoder().decode(ThemeOverrideLibrary.self, from: data)
    {
      themeOverrides = decoded
    } else {
      themeOverrides = ThemeOverrideLibrary()
    }
    if let data = defaults.data(forKey: Keys.settingsCompatibility),
      let decoded = try? JSONDecoder().decode(
        [String: SettingsCompatibilityValue].self,
        from: data
      )
    {
      settingsCompatibility = decoded
    } else {
      settingsCompatibility = [:]
    }
    sidebarTabGrouping =
      SidebarTabGrouping(rawValue: defaults.string(forKey: Keys.sidebarTabGrouping) ?? "") ?? .none
    sidebarTabOrder =
      SidebarTabOrder(rawValue: defaults.string(forKey: Keys.sidebarTabOrder) ?? "") ?? .createdTime
    sidebarCollapsedGroups = Set(
      defaults.stringArray(forKey: Keys.sidebarCollapsedGroups) ?? [])
    migrateControlCompatibilityValues()
    migrateLegacySidebarWidth()
    migrateMissingThemeSelections()
    synchronizeThemeRuntime()
  }

  /// 主题文件后缀。目录里只认这一种，读写共用 `TerminalThemeStore`。
  static let themeFileExtension = TerminalThemeStore.fileExtension

  /// 安装包内的主题种子目录：`Aster.app/Contents/Resources/themes`。由
  /// `build-app.sh` 从仓库的 `Resources/themes` 原样复制，因此用户机器上装没装
  /// Otty 都不影响首次初始化。开发期（`swift run`）没有这个目录，返回 nil。
  static func bundledThemeURL(forID id: String) -> URL? {
    guard let root = Bundle.main.resourceURL else { return nil }
    let url = root.appendingPathComponent("themes", isDirectory: true)
      .appendingPathComponent(id)
      .appendingPathExtension(themeFileExtension)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// 重新扫描主题目录并解析变化。损坏或不完整的文件跳过（回落内置表），
  /// 内容未变化时不触发发布，App 激活时可放心高频调用。
  /// 刻意不在 init 里调用：单测大量直接构造 AppPreferences，init 期扫描会把
  /// 用户机器上的真实主题目录混进测试环境，结果随机器状态漂移。
  func reloadDiskThemes() {
    guard let directory = try? themesDirectory() else { return }
    // 把内置主题物化成文件，磁盘真值始终完整；已存在的文件（用户改过的）绝不覆盖。安装包自带 `Contents/Resources/themes` 一份原始文件，
    // 优先直接拷贝：那才是随版本发布、逐字节可复核的主题；序列化只是 `swift run`
    // 和单测这类没有 Bundle 资源时的兜底，两条路产出的主题语义相同。
    for builtin in TerminalThemeCatalog.builtIns {
      let url = directory.appendingPathComponent(builtin.id)
        .appendingPathExtension(Self.themeFileExtension)
      guard !FileManager.default.fileExists(atPath: url.path) else { continue }
      if let seed = Self.bundledThemeURL(forID: builtin.id),
        (try? FileManager.default.copyItem(at: seed, to: url)) != nil
      {
        continue
      }
      try? ThemeFileSerializer.serialize(builtin)
        .write(to: url, atomically: true, encoding: .utf8)
    }
    let files = ((try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? [])
      .filter { $0.pathExtension.lowercased() == Self.themeFileExtension }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var fingerprint: [String: Date] = [:]
    for url in files {
      fingerprint[url.lastPathComponent] =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
    }
    guard fingerprint != diskThemesFingerprint else { return }
    diskThemesFingerprint = fingerprint
    var loaded: [TerminalTheme] = []
    for url in files {
      guard var theme = try? TerminalThemeStore.load(from: url) else { continue }
      theme.id = url.deletingPathExtension().lastPathComponent
      loaded.append(theme)
    }
    if diskThemes != loaded {
      diskThemes = loaded
      synchronizeThemeRuntime()
    }
  }

  /// 早期控制页把可运行字段临时放在 compatibility 字典中。升级后一次性迁入领域配置
  /// 并删除旧副本，避免同一设置存在两个真值；无法识别的值保持默认且不扩大权限。
  private func migrateControlCompatibilityValues() {
    var controls = configuration.controls
    var migratedKeys: Set<String> = []
    func string(_ key: String) -> String? {
      guard case .string(let value) = settingsCompatibility[key] else { return nil }
      migratedKeys.insert(key)
      return value
    }
    func bool(_ key: String) -> Bool? {
      guard case .bool(let value) = settingsCompatibility[key] else { return nil }
      migratedKeys.insert(key)
      return value
    }

    if let raw = string("controls.optionAsMetaMode") {
      let mapped = ["off": "false", "both": "true"][raw] ?? raw
      controls.optionAsMetaMode = OptionAsMetaMode(rawValue: mapped)
    }
    if let value = bool("controls.vtKeypadAppAllowed") { controls.vtKeypadAppAllowed = value }
    if let raw = string("controls.rightClickAction") {
      let mapped = ["contextMenu": "context-menu", "copyOrPaste": "copy-or-paste"][raw] ?? raw
      controls.rightClickAction = TerminalRightClickAction(rawValue: mapped)
    }
    if let value = bool("controls.mouseHideWhileTyping") { controls.mouseHideWhileTyping = value }
    if let raw = string("controls.bypassMouseReporting") {
      let mapped = [
        "control": "ctrl", "option": "alt", "controlShift": "ctrl+shift", "command": "super",
      ][raw] ?? raw
      controls.bypassMouseReporting = MouseReportingBypass(rawValue: mapped)
    }
    if let value = bool("controls.linkClickOverMouseMode") { controls.linkClickOverMouseMode = value }
    if let value = bool("controls.cursorClickToMove") { controls.cursorClickToMove = value }
    if let raw = string("controls.linkOpenWith") {
      controls.linkOpenWith = LinkOpenDestination(rawValue: ["system": "browser"][raw] ?? raw)
    }
    if let raw = string("controls.fileOpenWith") {
      controls.fileOpenWith = FileOpenDestination(rawValue: ["system": "default-app"][raw] ?? raw)
    }
    if let raw = string("controls.folderOpenWith") {
      controls.folderOpenWith = FolderOpenDestination(rawValue: ["finder": "default-app"][raw] ?? raw)
    }
    if let value = bool("controls.secureInputIndication") { controls.secureInputIndication = value }
    if let value = bool("controls.selectionBackspaceDeletes") { controls.selectionBackspaceDeletes = value }
    if let raw = string("controls.openWithApps") {
      controls.openWithApplications = raw.split(separator: ",").map { bundleIdentifier in
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenWithApplication(name: identifier, bundleIdentifier: identifier)
      }
    }
    guard !migratedKeys.isEmpty else { return }
    configuration.controls = controls
    settingsCompatibility = settingsCompatibility.filter { !migratedKeys.contains($0.key) }
  }

  var preferredAppearance: NSAppearance? {
    switch appearance {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  var fontSize: Double {
    get { configuration.appearance.fontSize }
    set { configuration.appearance.fontSize = min(max(newValue, 9), 32) }
  }

  /// 菜单字号命令与设置页共用同一个全局配置值。每次只移动 1pt，并继续经过属性边界
  /// 夹紧；`WorkspaceViewController` 的既有订阅会把结果同步到所有存活终端。
  func adjustFontSize(by delta: Double) {
    fontSize += delta
  }

  func resetFontSize() {
    fontSize = AsterConfiguration.default.appearance.fontSize
  }

  /// 0.4.x 全局侧栏宽度兼容字段。新窗口只在尚无 Panel 布局状态时读取它作为迁移
  /// 种子；运行期间的左右 Panel 宽度由窗口级 `WorkspacePanelLayoutStore` 管理。
  var sidebarWidth: Double {
    get { configuration.appearance.sidebarWidth }
    set { configuration.appearance.sidebarWidth = min(max(newValue, 180), 360) }
  }

  var tabBarLayout: TabBarLayout {
    get { configuration.tabBarLayout }
    set { configuration.tabBarLayout = newValue }
  }

  var optionAsMeta: Bool { configuration.controls.resolvedOptionAsMetaMode != .off }
  var allowMouseReporting: Bool { configuration.controls.allowMouseReporting }
  var terminalIdentity: String { configuration.appearance.terminalIdentity }

  var terminalFont: NSFont {
    terminalFontVariants.normal
  }

  /// 隐藏系统字体(以 "." 开头,如 `.AppleSystemUIFontMonospaced`)不是稳定 API,
  /// 也不该出现在用户可见配置里;历史版本曾把计算结果原样固化进配置,这里统一
  /// 视为未设置,让污染过的配置自愈回自动匹配。
  private func sanitizedFontName(_ name: String?) -> String? {
    guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty, !trimmed.hasPrefix(".")
    else { return nil }
    return trimmed
  }

  var terminalFontVariants: TerminalFontVariants {
    let appearance = configuration.appearance
    let globalFamily = sanitizedFontName(appearance.fontFamily) ?? ""
    let systemMonospaced = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    // Aster 启动时会按进程注册内置 JetBrains Mono，因此默认配置在所有支持的 macOS
    // 环境中都有相同字面。这里只处理资源损坏或用户指定字体缺失：不能静默落到隐藏
    // 的系统等宽 UI 字体，因为它在 Metal 路径下视觉偏重；先用具备完整样式的 Menlo，
    // 极端情况下 Menlo 也不可用才使用系统等宽字体。
    let unavailableFontFallback =
      NSFont(name: "Menlo-Regular", size: fontSize) ?? systemMonospaced
    let themeStyle = activeTheme.style
    let normal: NSFont
    if !globalFamily.isEmpty {
      normal =
        BundledFontRegistry.font(named: globalFamily, size: fontSize) ?? unavailableFontFallback
    } else if let candidates = themeStyle.fontFamilies, !candidates.isEmpty {
      // Otty 的 font-mono 是按顺序解析的字体栈；首项未安装不能直接退到系统字体，
      // 否则后面的 SF Mono / Menlo 永远没有机会生效。generic `monospace` 是栈终点。
      normal = candidates.lazy.compactMap { rawName -> NSFont? in
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if name.lowercased() == "monospace" { return systemMonospaced }
        return BundledFontRegistry.font(named: name, size: self.fontSize)
      }.first
        ?? BundledFontRegistry.font(named: "JetBrains Mono", size: fontSize)
        ?? unavailableFontFallback
    } else {
      normal = BundledFontRegistry.font(named: "JetBrains Mono", size: fontSize)
        ?? unavailableFontFallback
    }
    let manager = NSFontManager.shared
    // 逐样式解析链与主链一致:全局显式设置 → 主题逐样式 → 从常规字体自动匹配。
    func styleFont(_ globalName: String?, _ themeName: String?) -> NSFont? {
      (sanitizedFontName(globalName) ?? sanitizedFontName(themeName)).flatMap {
        BundledFontRegistry.font(named: $0, size: fontSize)
      }
    }
    let bold = styleFont(appearance.fontFamilyBold, themeStyle.fontFamilyBold)
      ?? manager.convert(normal, toHaveTrait: .boldFontMask)
    let italic = styleFont(appearance.fontFamilyItalic, themeStyle.fontFamilyItalic)
      ?? manager.convert(normal, toHaveTrait: .italicFontMask)
    let boldItalic = styleFont(appearance.fontFamilyBoldItalic, themeStyle.fontFamilyBoldItalic)
      ?? manager.convert(normal, toHaveTrait: [.boldFontMask, .italicFontMask])
    return TerminalFontVariants(
      normal: BundledFontRegistry.addingNerdSymbolsFallback(
        to: normal, additionalFamilies: appearance.resolvedFontFamilyFallback),
      bold: BundledFontRegistry.addingNerdSymbolsFallback(
        to: bold, additionalFamilies: appearance.resolvedFontFamilyFallbackBold),
      italic: BundledFontRegistry.addingNerdSymbolsFallback(
        to: italic, additionalFamilies: appearance.resolvedFontFamilyFallbackItalic),
      boldItalic: BundledFontRegistry.addingNerdSymbolsFallback(
        to: boldItalic, additionalFamilies: appearance.resolvedFontFamilyFallbackBoldItalic)
    )
  }

  var terminalForegroundColor: NSColor {
    NSColor(activeTheme.palette.foreground)
  }

  var terminalBackgroundColor: NSColor {
    NSColor(activeTheme.palette.renderedTerminalBackground)
  }

  /// 终端画布必须保留 Otty 的真实 RGBA 值。SwiftTerm 的 ANSI 内核颜色不保存 alpha，
  /// 但 AppKit 绘制默认背景时使用 `nativeBackgroundColor`，可以安全保留 `none` 的透明
  /// 语义；这里若预合成截图采样色，桌面内容或窗口材质一变就会产生错误的灰色接缝。
  var terminalCanvasBackgroundColor: NSColor {
    NSColor(activeTheme.palette.windowBackground)
  }

  var cursorColor: NSColor {
    let source = configuration.appearance.cursorColorOverride ?? activeTheme.palette.cursor
    return NSColor(source).withAlphaComponent(
      CGFloat(configuration.appearance.resolvedCursorOpacity)
    )
  }
  var cursorTextColor: NSColor {
    NSColor(
      configuration.appearance.cursorTextColorOverride
        ?? activeTheme.palette.cursorText
        ?? activeTheme.palette.windowBackground
    )
  }
  var selectionColor: NSColor { NSColor(activeTheme.palette.selection) }
  var selectionForegroundColor: NSColor {
    NSColor(activeTheme.palette.selectionForeground ?? activeTheme.palette.windowBackground)
  }
  var ansiColors: [HexColor] { activeTheme.palette.ansiColors }

  /// 参与名称解析的非内置主题：Aster 自有库优先，其次 Aster 磁盘主题目录，
  /// 最后才轮到内置表。resolve 按数组顺序取第一个命中项。
  private var overlayThemes: [TerminalTheme] {
    themeLibrary.customThemes + diskThemes
  }

  var lightTheme: TerminalTheme {
    resolved(
      TerminalThemeCatalog.resolve(
        named: configuration.appearance.themeName,
        customThemes: overlayThemes,
        mode: .light
      ))
  }

  var darkTheme: TerminalTheme {
    resolved(
      TerminalThemeCatalog.resolve(
        named: configuration.appearance.darkThemeName,
        customThemes: overlayThemes,
        mode: .dark
      ))
  }

  /// 主题的最终形态 = 基础主题 + 用户覆盖。所有读取路径都必须经过这里，
  /// 否则终端与界面会看到不同版本的同一套主题。
  func resolved(_ theme: TerminalTheme) -> TerminalTheme {
    theme.applyingOverrides(themeOverrides.overrides(for: theme.id))
  }

  var activeTheme: TerminalTheme {
    if let previewedTheme { return previewedTheme }
    if usesDarkAppearance {
      return configuration.appearance.useSeparateDarkTheme ? darkTheme : lightTheme
    }
    return lightTheme
  }

  func themes(for mode: TerminalThemeMode) -> [TerminalTheme] {
    // 遮蔽规则与 resolve 一致：自有库 > Aster 磁盘目录 > 内置表；同 id 或同名只保留
    // 优先级最高的一份，主题网格才不会出现两个「One Light」。
    var seenIDs: Set<String> = []
    var seenNames: Set<String> = []
    var merged: [TerminalTheme] = []
    for theme in themeLibrary.customThemes + diskThemes + TerminalThemeCatalog.builtIns {
      guard !seenIDs.contains(theme.id), !seenNames.contains(theme.name) else { continue }
      seenIDs.insert(theme.id)
      seenNames.insert(theme.name)
      merged.append(theme)
    }
    return merged.filter { $0.mode == mode }.map(resolved)
  }

  func selectTheme(_ theme: TerminalTheme) {
    if theme.mode == .dark {
      configuration.appearance.darkThemeName = theme.name
      // 主题卡和“显示 → 主题”都是“立即应用”入口。只保存暗色备用主题会让浅色
      // 外观下的点击看起来毫无反应，因此同时切换当前外观并开启独立暗色主题。
      configuration.appearance.useSeparateDarkTheme = true
      appearance = .dark
    } else {
      configuration.appearance.themeName = theme.name
      appearance = .light
    }
  }

  /// 临时应用一套主题，不修改持久化选择。调用方可以连续传入方向键或悬停命中的
  /// 主题；`objectWillChange` 会让所有工作区在下一轮 run loop 合并刷新。
  func previewTheme(_ theme: TerminalTheme) {
    guard previewedTheme != theme else { return }
    objectWillChange.send()
    previewedTheme = theme
    synchronizeThemeRuntime()
  }

  /// 保存当前预览。先把主题写入对应明暗模式的正式字段，再清掉临时值，避免工作区
  /// 在两个通知之间短暂闪回原主题。
  func commitThemePreview() {
    guard let previewedTheme else { return }
    selectTheme(previewedTheme)
    self.previewedTheme = nil
    synchronizeThemeRuntime()
    objectWillChange.send()
  }

  /// 放弃当前预览并恢复持久化主题。没有预览时保持幂等，面板重复关闭不会多刷新。
  func cancelThemePreview() {
    guard previewedTheme != nil else { return }
    objectWillChange.send()
    previewedTheme = nil
    synchronizeThemeRuntime()
  }

  /// 改一个 token 的颜色：写进覆盖表，原主题（含内置真值表）保持不动。
  ///
  /// 覆盖同时落到主题目录里那份主题文件：文件末尾追加带 `# aster-added:`
  /// 注释的段落，用户能直接看到、也能手工删掉某一行来撤销覆盖。
  func setThemeColor(_ color: HexColor, slotID: String, themeID: String) {
    var library = themeOverrides
    library.setColor(color, slotID: slotID, themeID: themeID)
    themeOverrides = library
  }

  /// 修改 ANSI 色位时只记录该 index 的覆盖，主题身份和其它 15 个色位保持不变。
  func setThemeANSIColor(_ color: HexColor, index: Int, themeID: String) {
    guard (0..<16).contains(index) else { return }
    var library = themeOverrides
    library.setANSIColor(color, index: index, themeID: themeID)
    themeOverrides = library
  }

  /// 主题字体使用同一覆盖层。空数组是显式取消该主题参数，缺少覆盖才表示继承原主题。
  func setThemeFontFamilies(
    _ families: [String], role: ThemeFontRole, themeID: String
  ) {
    var library = themeOverrides
    library.setFontFamilies(families, role: role, themeID: themeID)
    themeOverrides = library
  }

  /// 撤销某个 token 的覆盖，回到原主题的值（或它的派生值）。
  func clearThemeColor(slotID: String, themeID: String) {
    var library = themeOverrides
    library.clearColor(slotID: slotID, themeID: themeID)
    themeOverrides = library
  }

  /// 撤销整套主题的全部覆盖。
  func clearThemeOverrides(themeID: String) {
    var library = themeOverrides
    library.clearAll(themeID: themeID)
    themeOverrides = library
  }

  func themeOverrides(for themeID: String) -> ThemeColorOverrides {
    themeOverrides.overrides(for: themeID)
  }

  @discardableResult
  func duplicateTheme(_ source: TerminalTheme) -> TerminalTheme {
    var library = themeLibrary
    let duplicate = library.add(source.duplicated())
    themeLibrary = library
    selectTheme(duplicate)
    return duplicate
  }

  @discardableResult
  func updateTheme(_ theme: TerminalTheme) -> Bool {
    guard !theme.isBuiltIn,
      let previous = themeLibrary.customThemes.first(where: { $0.id == theme.id })
    else { return false }
    let wasSelectedAsLight = configuration.appearance.themeName == previous.name
    let wasSelectedAsDark = configuration.appearance.darkThemeName == previous.name
    var library = themeLibrary
    guard library.update(theme) else { return false }
    themeLibrary = library
    if previous.mode == theme.mode {
      if wasSelectedAsLight { configuration.appearance.themeName = theme.name }
      if wasSelectedAsDark { configuration.appearance.darkThemeName = theme.name }
    } else {
      if wasSelectedAsLight { configuration.appearance.themeName = "Ayu Light" }
      if wasSelectedAsDark { configuration.appearance.darkThemeName = "Ayu Dark" }
      selectTheme(theme)
    }
    return true
  }

  @discardableResult
  func importTheme(from url: URL) throws -> TerminalTheme {
    let imported = try TerminalThemeStore.load(from: url)
    var library = themeLibrary
    let stored = library.add(imported)
    themeLibrary = library
    selectTheme(stored)
    return stored
  }

  /// 把一套主题写进主题目录。刻意用与内置主题物化相同的 TOML 文本格式，
  /// 目录里因此只有一种可读、可手改的文件，用户导入后能直接编辑。
  func saveThemeToLibraryFolder(_ theme: TerminalTheme) throws -> URL {
    let directory = try themesDirectory()
    let safeName = theme.name.replacingOccurrences(
      of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    let url = directory.appendingPathComponent(safeName)
      .appendingPathExtension(Self.themeFileExtension)
    try TerminalThemeStore.save(theme, to: url)
    return url
  }

  /// 把某套主题的用户覆盖写成追加段落，落到主题目录里的同名主题文件。
  ///
  /// 追加而不是重写：文件里原主题的内容一字不动，用户覆盖以 `# aster-added:` 注释
  /// 标出；清空覆盖时删除整段。找不到源文件会明确失败，避免创建只有覆盖键、无法被
  /// Aster 自己也无法独立解析的残缺主题。
  @discardableResult
  func writeThemeOverridesToLibraryFolder(themeID: String) throws -> URL? {
    let overrides = themeOverrides.overrides(for: themeID)
    guard let theme = (TerminalThemeCatalog.builtIns + themeLibrary.customThemes)
        .first(where: { $0.id == themeID })
    else { return nil }
    let section = theme.themeOverrideSection(overrides)
    let directory = try themesDirectory()
    let url = try themeFileURL(for: theme, in: directory)
    let existing = try String(contentsOf: url, encoding: .utf8)
    // 每次写出都先剥掉上一轮追加的段落，否则同一个键会在文件里越堆越多。
    let base = ThemeOverrideFileWriter.strippingPreviousOverrides(from: existing)
    let normalizedBase = base.trimmingCharacters(in: .newlines)
    // 清空覆盖时也必须重写文件，移除上一轮 managed 段；提前返回会让设置页显示已
    // 恢复，而 Aster 下次启动仍继续读到旧的个性化参数。
    let content = if section.isEmpty {
      normalizedBase.isEmpty ? "" : normalizedBase + "\n"
    } else {
      (normalizedBase.isEmpty ? "" : normalizedBase + "\n\n")
        + ThemeOverrideFileWriter.marker + "\n" + section + "\n"
    }
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// 主题的唯一磁盘真值目录：`~/.config/aster/themes`。内置主题物化、用户参数
  /// 个性化、导入的主题都落在这里，用户用任意编辑器改文件即可生效。Aster 是独立
  /// 应用，不再读写 Otty 的目录，也不再把主题散落到 App Support。
  func themesDirectory() throws -> URL {
    let directory = themesDirectoryURL
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/aster/themes", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// 内置主题 ID 与文件 stem 一致（如 `ayu-light`）。自定义/导入主题先尝试
  /// 自身 ID，再按 `[meta].name` 扫描目录，避免把显示名大小写硬编码成错误的新文件。
  private func themeFileURL(for theme: TerminalTheme, in directory: URL) throws -> URL {
    let direct = directory.appendingPathComponent(theme.id)
      .appendingPathExtension(Self.themeFileExtension)
    if FileManager.default.fileExists(atPath: direct.path) { return direct }

    let candidates = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension.lowercased() == Self.themeFileExtension }
    if let matched = candidates.first(where: { url in
      guard let candidate = try? TerminalThemeStore.load(from: url) else { return false }
      return candidate.name == theme.name
    }) {
      return matched
    }

    throw CocoaError(
      .fileNoSuchFile,
      userInfo: [NSFilePathErrorKey: direct.path]
    )
  }

  func reset() {
    configuration = .default
    appearance = .system
  }

  /// 保存一个经过网页桥类型校验的兼容字段。空字符串仍是有效配置值，不在此层折叠。
  func setCompatibilityValue(_ value: SettingsCompatibilityValue, forKey key: String) {
    settingsCompatibility[key] = value
  }

  func resetCompatibilityValues() {
    settingsCompatibility = [:]
  }

  /// 配置文件导入只接受桥层已完成类型解码的兼容字段；本机授权不存放在该字典中。
  func importCompatibilityValues(_ values: [String: SettingsCompatibilityValue]) {
    settingsCompatibility = values
  }

  func compatibilityNumber(forKey key: String, default fallback: Double) -> Double {
    guard case .number(let value) = settingsCompatibility[key] else { return fallback }
    return value
  }

  func compatibilityString(forKey key: String, default fallback: String) -> String {
    guard case .string(let value) = settingsCompatibility[key] else { return fallback }
    return value
  }

  func importConfiguration(_ candidate: AsterConfiguration) {
    var imported = candidate.normalized()
    // 本机安全授权不能随 JSON 导入；否则第三方配置可预置 scheme 例外，或把 OSC 52
    // 读取改成无提示允许。显式 Deny 属于更严格策略，可以安全保留。
    imported.controls.allowedNonStandardLinkSchemes = []
    imported.controls.allowedExternalLinkHosts = []
    imported.controls.allowedExecutableFileSignatures = []
    if imported.controls.resolvedClipboardReadAccess == .allow {
      imported.controls.clipboardReadAccess = .ask
    }
    configuration = imported
  }

  private var usesDarkAppearance: Bool {
    switch appearance {
    case .light: false
    case .dark: true
    case .system:
      // `NSApp` 在 NSApplication 创建前是 nil(串行测试首个用例即如此);
      // `NSApplication.shared` 按需初始化,任何调用时序下都安全。
      NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
  }

  private func persistConfiguration() {
    guard let data = try? JSONEncoder().encode(configuration) else { return }
    defaults.set(data, forKey: Keys.configuration)
  }

  private func persistThemeOverrides() {
    guard let data = try? JSONEncoder().encode(themeOverrides) else { return }
    defaults.set(data, forKey: Keys.themeOverrides)
  }

  private func persistThemeLibrary() {
    guard let data = try? JSONEncoder().encode(themeLibrary) else { return }
    defaults.set(data, forKey: Keys.themeLibrary)
  }

  private func persistSettingsCompatibility() {
    guard let data = try? JSONEncoder().encode(settingsCompatibility) else { return }
    defaults.set(data, forKey: Keys.settingsCompatibility)
  }

  private func migrateMissingThemeSelections() {
    // Otty 1.3.1 使用完整名称。保留旧选择的意图，避免升级后静默回退到 Ayu Dark。
    if configuration.appearance.darkThemeName == "Catppuccin" {
      configuration.appearance.darkThemeName = "Catppuccin Mocha"
    }
    let names = Set((TerminalThemeCatalog.builtIns + themeLibrary.customThemes).map(\.name))
    if !names.contains(configuration.appearance.themeName) {
      configuration.appearance.themeName = "Ayu Light"
    }
    if !names.contains(configuration.appearance.darkThemeName) {
      configuration.appearance.darkThemeName = "Ayu Dark"
    }
  }

  /// 0.4.0 的 AppKit 初版默认 250pt，使 Otty 的窄侧栏在常用窗口尺寸下显得过宽。
  /// 只迁移仍等于旧默认值的配置；用户主动调整过的其他宽度保持不变。
  private func migrateLegacySidebarWidth() {
    guard !defaults.bool(forKey: Keys.compactSidebarMigration) else { return }
    defaults.set(true, forKey: Keys.compactSidebarMigration)
    if abs(configuration.appearance.sidebarWidth - 250) < 0.5 {
      configuration.appearance.sidebarWidth = 220
    }
  }

  private func synchronizeThemeRuntime() {
    // 关闭独立深色主题时必须复用完整浅色主题，而不只是调色板。ThemeRuntime 还需要
    // titlebar/sidebar/container 等 style token；只替换 palette 会在系统切到深色外观时
    // 又悄悄套回另一套主题的级联规则。
    let persistedLightTheme = lightTheme
    let persistedDarkTheme =
      configuration.appearance.useSeparateDarkTheme ? darkTheme : persistedLightTheme
    let effectiveLightTheme =
      previewedTheme?.mode == .light ? previewedTheme ?? persistedLightTheme : persistedLightTheme
    let effectiveDarkTheme =
      previewedTheme?.mode == .dark ? previewedTheme ?? persistedDarkTheme : persistedDarkTheme
    ThemeRuntime.shared.update(light: effectiveLightTheme, dark: effectiveDarkTheme)
  }

  private enum Keys {
    static let appearance = "appearance"
    static let configuration = "aster.configuration.v2"
    static let themeLibrary = "aster.theme-library.v1"
    static let themeOverrides = "aster.theme-overrides.v1"
    static let settingsCompatibility = "aster.settings-compatibility.v1"
    static let compactSidebarMigration = "aster.migration.compact-sidebar.v1"
    static let sidebarTabGrouping = "aster.sidebar.tab-grouping.v1"
    static let sidebarTabOrder = "aster.sidebar.tab-order.v1"
    static let sidebarCollapsedGroups = "aster.sidebar.collapsed-groups.v1"
    static let inspectorPresented = "aster.inspector.presented.v1"
    static let inspectorSection = "aster.inspector.section.v1"
    static let inspectorGitEditor = "aster.inspector.git-editor.v1"
    static let memoryRecordingMode = "aster.memory.recording-mode.v1"
    static let memoryExcludedPaths = "aster.memory.excluded-paths.v1"
    static let memoryExcludedCommands = "aster.memory.excluded-commands.v1"
    static let memoryExtractionEnabled = "aster.memory.extraction-enabled.v1"
    static let memoryExtractionProvider = "aster.memory.extraction-provider.v1"
    static let memoryExtractionAcknowledged = "aster.memory.extraction-acknowledged.v1"
    static let updateChannel = "aster.update.channel.v1"
  }
}
