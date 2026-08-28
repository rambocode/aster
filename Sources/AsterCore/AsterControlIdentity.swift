import Foundation

// 控制协议的短 ID（herdr 风格）：`w1` / `w1:t2` / `w1:p5`。
// 内部对象仍用 UUID；短 ID 由进程级注册表分配，进程重启后从头编号，不持久化。

/// 窗口短 ID：`w<n>`。
public struct ControlWindowID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let number: Int

  public init(number: Int) { self.number = number }

  public init?(parsing text: String) {
    guard let selector = ControlTargetSelector(parsing: text), case .window(let id) = selector
    else { return nil }
    self = id
  }

  public var description: String { "w\(number)" }

  public init(from decoder: Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let parsed = ControlWindowID(parsing: text) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "非法窗口 ID: \(text)"))
    }
    self = parsed
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

/// 标签短 ID：`w<n>:t<m>`；编号在窗口内单调递增。
public struct ControlTabID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let window: ControlWindowID
  public let number: Int

  public init(window: ControlWindowID, number: Int) {
    self.window = window
    self.number = number
  }

  public init?(parsing text: String) {
    guard let selector = ControlTargetSelector(parsing: text), case .tab(let id) = selector
    else { return nil }
    self = id
  }

  public var description: String { "\(window):t\(number)" }

  public init(from decoder: Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let parsed = ControlTabID(parsing: text) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "非法标签 ID: \(text)"))
    }
    self = parsed
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

/// Pane 短 ID：`w<n>:p<m>`；编号在窗口内单调递增。
public struct ControlPaneID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let window: ControlWindowID
  public let number: Int

  public init(window: ControlWindowID, number: Int) {
    self.window = window
    self.number = number
  }

  public init?(parsing text: String) {
    guard let selector = ControlTargetSelector(parsing: text), case .pane(let id) = selector
    else { return nil }
    self = id
  }

  public var description: String { "\(window):p\(number)" }

  public init(from decoder: Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let parsed = ControlPaneID(parsing: text) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "非法 pane ID: \(text)"))
    }
    self = parsed
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

/// 客户端传入的 target/pane 字符串的解析结果。
/// 优先级：短 ID → `p_<UUID>` / 裸 UUID（旧 sh 脚本 selector）→ `current` → agent name。
public enum ControlTargetSelector: Equatable, Sendable {
  case window(ControlWindowID)
  case tab(ControlTabID)
  case pane(ControlPaneID)
  /// 旧 `ASTER_SESSION_ID` 形态：`p_<UUID>` 或裸 UUID，都指向 pane。
  case legacyPaneUUID(UUID)
  /// 调用方自己所在的 pane（服务端按连接携带的 `ASTER_PANE_ID` 或焦点 pane 解析）。
  case current
  case agentName(String)

  /// 短 ID 的正则：`^w(\d+)(?::([tp])(\d+))?$`。
  private static let shortIDPattern = try! NSRegularExpression(pattern: #"^w(\d+)(?::([tp])(\d+))?$"#)
  /// agent name 规则：小写字母开头，字母数字 `_` `-`，最长 32。
  private static let agentNamePattern = try! NSRegularExpression(pattern: #"^[a-z][a-z0-9_-]{0,31}$"#)

  public init?(parsing rawText: String) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    // 形如短 ID 的输入只能走短 ID 路径：编号溢出等非法情况直接判非法，不许退化成 agent name。
    if Self.looksLikeShortID(text) {
      guard let shortID = Self.parseShortID(text) else { return nil }
      self = shortID
      return
    }
    if text.hasPrefix("p_"), let uuid = UUID(uuidString: String(text.dropFirst(2))) {
      self = .legacyPaneUUID(uuid)
      return
    }
    if let uuid = UUID(uuidString: text) {
      self = .legacyPaneUUID(uuid)
      return
    }
    if text == "current" {
      self = .current
      return
    }
    guard Self.isValidAgentName(text) else { return nil }
    self = .agentName(text)
  }

  public static func isValidAgentName(_ name: String) -> Bool {
    let range = NSRange(name.startIndex..., in: name)
    return agentNamePattern.firstMatch(in: name, range: range) != nil
  }

  private static func looksLikeShortID(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return shortIDPattern.firstMatch(in: text, range: range) != nil
  }

  private static func parseShortID(_ text: String) -> ControlTargetSelector? {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = shortIDPattern.firstMatch(in: text, range: range) else { return nil }
    func group(_ index: Int) -> String? {
      let groupRange = match.range(at: index)
      guard groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: text)
      else { return nil }
      return String(text[swiftRange])
    }
    // 编号超出 Int 的输入直接视为非法，而不是崩溃。
    guard let windowText = group(1), let windowNumber = Int(windowText) else { return nil }
    let window = ControlWindowID(number: windowNumber)
    guard let kind = group(2), let childText = group(3), let childNumber = Int(childText) else {
      return .window(window)
    }
    switch kind {
    case "t": return .tab(ControlTabID(window: window, number: childNumber))
    case "p": return .pane(ControlPaneID(window: window, number: childNumber))
    default: return nil
    }
  }
}

/// 进程级短 ID 注册表（值类型，由持有者串行访问）。
///
/// 规则：
/// - 编号只增不复用：pane 关闭后 `w1:p3` 永远不再指向别的 pane，避免 agent 拿着旧 ID 误操作。
/// - 跨窗口转移：pane/tab 被拖到另一窗口时会分配该窗口下的新 ID，但旧 ID 保留为「退役别名」，
///   仍能解析回同一 UUID；这样正在等待的 CLI 调用不会因为用户拖动而突然 not_found。
/// - `retire` 才真正删除映射（含所有别名），之后旧 ID 解析为 nil。
public struct ControlIdentityRegistry: Equatable, Sendable {
  private var windowNumbers: [UUID: Int] = [:]
  private var nextWindowNumber = 1
  /// 每个窗口的 tab / pane 下一个编号。
  private var nextTabNumber: [ControlWindowID: Int] = [:]
  private var nextPaneNumber: [ControlWindowID: Int] = [:]
  /// 当前有效 ID（正向）。
  private var currentTabIDs: [UUID: ControlTabID] = [:]
  private var currentPaneIDs: [UUID: ControlPaneID] = [:]
  /// 反向解析表：包含当前 ID 与退役别名。
  private var tabUUIDs: [ControlTabID: UUID] = [:]
  private var paneUUIDs: [ControlPaneID: UUID] = [:]

  public init() {}

  /// 取窗口编号；首次见到即分配。
  public mutating func windowNumber(for window: UUID) -> Int {
    if let existing = windowNumbers[window] { return existing }
    let number = nextWindowNumber
    nextWindowNumber += 1
    windowNumbers[window] = number
    return number
  }

  public mutating func windowID(for window: UUID) -> ControlWindowID {
    ControlWindowID(number: windowNumber(for: window))
  }

  /// 只读查询：窗口是否已注册。
  public func windowID(registeredFor window: UUID) -> ControlWindowID? {
    windowNumbers[window].map(ControlWindowID.init(number:))
  }

  /// 取 tab 短 ID；tab 已在其它窗口登记时分配新 ID 并保留旧 ID 为别名。
  public mutating func tabID(for tab: UUID, inWindow window: UUID) -> ControlTabID {
    let windowID = self.windowID(for: window)
    if let existing = currentTabIDs[tab], existing.window == windowID { return existing }
    let number = nextTabNumber[windowID, default: 1]
    nextTabNumber[windowID] = number + 1
    let id = ControlTabID(window: windowID, number: number)
    currentTabIDs[tab] = id
    tabUUIDs[id] = tab
    return id
  }

  /// 取 pane 短 ID；pane 已在其它窗口登记时分配新 ID 并保留旧 ID 为别名。
  public mutating func paneID(for pane: UUID, inWindow window: UUID) -> ControlPaneID {
    let windowID = self.windowID(for: window)
    if let existing = currentPaneIDs[pane], existing.window == windowID { return existing }
    let number = nextPaneNumber[windowID, default: 1]
    nextPaneNumber[windowID] = number + 1
    let id = ControlPaneID(window: windowID, number: number)
    currentPaneIDs[pane] = id
    paneUUIDs[id] = pane
    return id
  }

  /// 只读查询：pane 当前 ID（未登记为 nil）。
  public func currentPaneID(for pane: UUID) -> ControlPaneID? { currentPaneIDs[pane] }

  /// 只读查询：tab 当前 ID（未登记为 nil）。
  public func currentTabID(for tab: UUID) -> ControlTabID? { currentTabIDs[tab] }

  /// 短 ID → pane UUID；退役别名也能解析。
  public func paneUUID(for id: ControlPaneID) -> UUID? { paneUUIDs[id] }

  /// 短 ID → tab UUID；退役别名也能解析。
  public func tabUUID(for id: ControlTabID) -> UUID? { tabUUIDs[id] }

  /// 给定 ID 是否是别名（已不是该 pane 的当前 ID）。
  public func isAlias(_ id: ControlPaneID) -> Bool {
    guard let uuid = paneUUIDs[id] else { return false }
    return currentPaneIDs[uuid] != id
  }

  /// pane 关闭：删除当前 ID 与全部别名；编号不回收。
  public mutating func retire(pane: UUID) {
    currentPaneIDs[pane] = nil
    paneUUIDs = paneUUIDs.filter { $0.value != pane }
  }

  /// tab 关闭：删除当前 ID 与全部别名；编号不回收。
  public mutating func retire(tab: UUID) {
    currentTabIDs[tab] = nil
    tabUUIDs = tabUUIDs.filter { $0.value != tab }
  }
}
