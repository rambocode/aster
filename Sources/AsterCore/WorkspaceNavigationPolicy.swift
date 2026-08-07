import Foundation

/// 用户对程序动态标题的覆盖方式。固定名称完全替换程序标题；前缀保留后续 OSC 更新。
public enum TerminalTitleOverride: Codable, Equatable, Sendable {
  case automatic
  case name(String)
  case prefix(String)

  /// 空名称/前缀等价于恢复自动模式；非空值在持久化前完成控制字符清理和长度限制。
  public func normalized() -> TerminalTitleOverride {
    switch self {
    case .automatic:
      return .automatic
    case .name(let value):
      let value = TerminalTitleState.sanitize(value)
      return value.isEmpty ? .automatic : .name(value)
    case .prefix(let value):
      let value = TerminalTitleState.sanitize(value)
      return value.isEmpty ? .automatic : .prefix(value)
    }
  }

  fileprivate func resolve(dynamicTitle: String, fallback: String) -> String {
    switch self {
    case .automatic:
      return dynamicTitle.isEmpty ? fallback : dynamicTitle
    case .name(let value):
      let name = TerminalTitleState.sanitize(value)
      return name.isEmpty ? (dynamicTitle.isEmpty ? fallback : dynamicTitle) : name
    case .prefix(let value):
      let prefix = TerminalTitleState.sanitize(value)
      let base = dynamicTitle.isEmpty ? fallback : dynamicTitle
      return TerminalTitleState.sanitize(prefix + base)
    }
  }
}

/// 分离保存 xterm 的窗口标题（OSC 2）与图标名称（OSC 1）。OSC 0 同时更新两者。
///
/// 标题来自终端程序，属于不可信输入。状态在进入持久化和 AppKit 标签前移除控制字符，
/// 并按 UTF-8 字节限制长度，避免控制序列污染菜单或异常大标题撑高快照。
public struct TerminalTitleState: Codable, Equatable, Sendable {
  public static let maximumTitleBytes = 512

  public var programWindowTitle: String
  public var programIconName: String
  public var tabOverride: TerminalTitleOverride
  public var windowOverride: TerminalTitleOverride
  public var fallback: String

  public init(
    programWindowTitle: String = "",
    programIconName: String = "",
    tabOverride: TerminalTitleOverride = .automatic,
    windowOverride: TerminalTitleOverride = .automatic,
    fallback: String = "Shell"
  ) {
    self.programWindowTitle = Self.sanitize(programWindowTitle)
    self.programIconName = Self.sanitize(programIconName)
    self.tabOverride = tabOverride.normalized()
    self.windowOverride = windowOverride.normalized()
    self.fallback = Self.sanitize(fallback)
  }

  /// 标签优先使用 OSC 1；程序只发送 OSC 2 时回退到窗口标题。
  public var tabTitle: String {
    let dynamic = programIconName.isEmpty ? programWindowTitle : programIconName
    return tabOverride.resolve(dynamicTitle: dynamic, fallback: resolvedFallback)
  }

  /// 标题栏只由 OSC 2 / OSC 0 驱动，不借用 OSC 1 的短标签名。
  public var windowTitle: String {
    windowOverride.resolve(dynamicTitle: programWindowTitle, fallback: resolvedFallback)
  }

  /// 应用终端标题通道。未知 OSC 编号保持状态不变，避免误解释其它协议。
  public mutating func applyOSC(code: Int, text: String) {
    let value = Self.sanitize(text)
    switch code {
    case 0:
      programWindowTitle = value
      programIconName = value
    case 1:
      programIconName = value
    case 2:
      programWindowTitle = value
    default:
      break
    }
  }

  public mutating func updateFallback(_ value: String) {
    fallback = Self.sanitize(value)
  }

  /// 重新经过公共初始化器清理反序列化数据。`Codable` 合成实现会直接写入存储属性，
  /// 因此旧快照或手工配置中的空覆盖、控制字符仍需在进入运行态时统一归一化。
  public func normalized() -> TerminalTitleState {
    TerminalTitleState(
      programWindowTitle: programWindowTitle,
      programIconName: programIconName,
      tabOverride: tabOverride,
      windowOverride: windowOverride,
      fallback: fallback
    )
  }

  private var resolvedFallback: String {
    let value = Self.sanitize(fallback)
    return value.isEmpty ? "Shell" : value
  }

  fileprivate static func sanitize(_ value: String) -> String {
    let visibleScalars = value.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
    }
    let visible = String(String.UnicodeScalarView(visibleScalars))
    var result = ""
    var byteCount = 0
    for character in visible {
      let bytes = String(character).utf8.count
      guard byteCount + bytes <= maximumTitleBytes else { break }
      result.append(character)
      byteCount += bytes
    }
    return result
  }
}

/// 新标签相对现有标签的插入策略，对应 Otty 的 `new-tab-position`。
public enum NewTabPosition: String, CaseIterable, Codable, Equatable, Sendable {
  case automatic = "auto"
  case end
  case afterCurrent = "after-current"

  /// 计算数组插入下标。空标签在自动模式下进入当前分组末尾；带文件、目录或历史内容的
  /// 标签紧跟当前标签。所有外部下标都会被约束到 `0...tabCount`。
  public func insertionIndex(
    selectedIndex: Int?,
    tabCount: Int,
    hasContent: Bool,
    sectionEndIndex: Int?
  ) -> Int {
    let count = max(tabCount, 0)
    guard let selectedIndex else { return count }
    let afterSelected = min(max(selectedIndex + 1, 0), count)
    switch self {
    case .end:
      return count
    case .afterCurrent:
      return afterSelected
    case .automatic:
      guard !hasContent else { return afterSelected }
      return min(max(sectionEndIndex ?? count, afterSelected), count)
    }
  }
}

/// 可持久化的最近关闭标签栈。仅保存可重建快照，不保存 PTY、PID 或文件描述符。
public struct RecentlyClosedTabs: Codable, Equatable, Sendable {
  public private(set) var entries: [WorkspaceTabSnapshot]
  public let limit: Int

  public init(limit: Int = 20, entries: [WorkspaceTabSnapshot] = []) {
    self.limit = min(max(limit, 1), 100)
    self.entries = Array(entries.suffix(self.limit))
  }

  private enum CodingKeys: String, CodingKey {
    case entries
    case limit
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entries = try container.decodeIfPresent([WorkspaceTabSnapshot].self, forKey: .entries) ?? []
    let limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 20
    self.init(limit: limit, entries: entries)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entries, forKey: .entries)
    try container.encode(limit, forKey: .limit)
  }

  public mutating func record(_ snapshot: WorkspaceTabSnapshot) {
    entries.removeAll { $0.id == snapshot.id }
    entries.append(snapshot)
    if entries.count > limit {
      entries.removeFirst(entries.count - limit)
    }
  }

  public mutating func reopenLast() -> WorkspaceTabSnapshot? {
    entries.popLast()
  }

  public mutating func removeEntries(withIDs identifiers: Set<UUID>) {
    guard !identifiers.isEmpty else { return }
    entries.removeAll { identifiers.contains($0.id) }
  }
}
