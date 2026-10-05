// 控制协议里改变窗口结构的方法（pane.close / pane.split / tab.*）的参数与结果。
// 方法名登记在 `AsterControlMethod`；这里只放它们专用的类型，免得协议主文件继续变长。

import Foundation

/// pane.close：关闭一个 Pane。标签里只剩这一个 Pane 时连标签一起关，与 ⌘W 一致。
public struct PaneCloseParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var pane: String

  public init(pane: String) { self.pane = pane }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(pane, field: "pane")
  }
}

/// pane.split：在目标 Pane 的某一侧拆出一个新的终端 Pane，新 Pane 继承目标的工作目录。
public struct PaneSplitParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var pane: String
  public var direction: SplitDirection

  public init(pane: String, direction: SplitDirection = .right) {
    self.pane = pane
    self.direction = direction
  }

  /// `direction` 在线上可省略（默认向右）；合成的解码器不会用属性默认值，所以手写。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pane = try container.decode(String.self, forKey: .pane)
    direction = try container.decodeIfPresent(SplitDirection.self, forKey: .direction) ?? .right
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(pane, field: "pane")
  }
}

/// tab.new：在某个窗口里新建标签。
///
/// `window` 是该窗口里任意 Pane / 标签 / 窗口的 selector，nil 表示当前焦点窗口；
/// `cwd` 为 nil 时继承该窗口选中标签的工作目录。
public struct TabNewParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public static let maximumPathBytes = 4096

  public var window: String?
  public var cwd: String?

  public init(window: String? = nil, cwd: String? = nil) {
    self.window = window
    self.cwd = cwd
  }

  public func validate() throws {
    if let window { try ControlSelectorValidation.validateSelector(window, field: "window") }
    if let cwd {
      guard cwd.hasPrefix("/"), cwd.utf8.count <= Self.maximumPathBytes else {
        throw AsterControlError.invalidParams("cwd 需为绝对路径，且不超过 \(Self.maximumPathBytes) 字节")
      }
    }
  }
}

/// tab.close / tab.focus：只带目标标签的参数。
///
/// `tab` 可以是标签短 ID（`w1:t2`），也可以是标签里任意 Pane 的 selector。
public struct TabTargetParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var tab: String

  public init(tab: String) { self.tab = tab }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(tab, field: "tab")
  }
}

/// tab.rename：把标签固定成 `title`；`title` 为 nil 或空串时恢复自动标题。
public struct TabRenameParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public static let maximumTitleBytes = 256

  public var tab: String
  public var title: String?

  public init(tab: String, title: String?) {
    self.tab = tab
    self.title = title
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(tab, field: "tab")
    if let title, title.utf8.count > Self.maximumTitleBytes {
      throw AsterControlError.invalidParams("title 不能超过 \(Self.maximumTitleBytes) 字节")
    }
  }
}

/// 结构方法的统一结果：动作落在哪个窗口 / 标签 / Pane 上。
///
/// - 关闭类：被关掉的那个 Pane 或标签的 ID；`pane.close` 连标签一起关时 `closedTab` 为 true。
/// - 新建类：新标签 / 新 Pane 的 ID。远端机器的结构变更是一次服务端事务，请求返回时新
///   ID 还不存在，此时 `paneID`（`tab.new` 还有 `tabID`）为 nil，调用方改用
///   `events wait --kind pane.created` 或 `session snapshot` 取结果。
public struct LayoutActionResult: Codable, Equatable, Sendable {
  public var ok: Bool
  public var windowID: String
  public var tabID: String?
  public var paneID: String?
  public var closedTab: Bool?

  private enum CodingKeys: String, CodingKey {
    case ok
    case windowID = "window_id"
    case tabID = "tab_id"
    case paneID = "pane_id"
    case closedTab = "closed_tab"
  }

  public init(
    windowID: String, tabID: String? = nil, paneID: String? = nil, closedTab: Bool? = nil
  ) {
    self.ok = true
    self.windowID = windowID
    self.tabID = tabID
    self.paneID = paneID
    self.closedTab = closedTab
  }
}
