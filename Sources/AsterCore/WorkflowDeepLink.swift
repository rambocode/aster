import Foundation

public enum WorkflowWindowSelector: Equatable, Sendable {
  case identifier(String)
  case current
  case last
  case index(Int)
  case title(String)
}

public enum WorkflowTabSelector: Equatable, Sendable {
  case identifier(String)
  case index(Int)
}

public enum WorkflowPaneSelector: Equatable, Sendable {
  case identifier(String)
  case sessionIdentifier(String)
}

/// `otty://` URL 唯一允许描述的动作集合。没有运行命令、打开文件或修改状态的 case。
public enum WorkflowDeepLinkAction: Equatable, Sendable, CustomStringConvertible {
  case focusWindow(WorkflowWindowSelector)
  case focusTab(WorkflowTabSelector)
  case focusPane(WorkflowPaneSelector)

  public var description: String {
    switch self {
    case .focusWindow(let selector): "聚焦 Window：\(String(describing: selector))"
    case .focusTab(let selector): "聚焦 Tab：\(String(describing: selector))"
    case .focusPane(let selector): "聚焦 Pane：\(String(describing: selector))"
    }
  }

  public var onlyMovesFocus: Bool { true }
}

public enum WorkflowDeepLinkError: Error, Equatable {
  case invalidURL
  case invalidScheme
  case unsupportedTarget
  case missingSelector
  case invalidSelector
  case unexpectedURLComponent
}

/// Otty 深链解析器。未知或过期 selector 是否命中由运行层决定；本层只确保 URL 形状
/// 对应一个有界的聚焦动作，查询参数不能偷偷携带命令或文件操作。
public enum WorkflowDeepLink {
  public static func parse(_ rawURL: String) throws -> WorkflowDeepLinkAction {
    guard rawURL.utf8.count <= 1_024, let url = URL(string: rawURL) else {
      throw WorkflowDeepLinkError.invalidURL
    }
    guard url.scheme?.lowercased() == "otty" else { throw WorkflowDeepLinkError.invalidScheme }
    guard url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil
    else { throw WorkflowDeepLinkError.unexpectedURLComponent }
    guard let kind = url.host?.lowercased(), !kind.isEmpty else {
      throw WorkflowDeepLinkError.unsupportedTarget
    }

    // 从 percent-encoded path 分割后再逐段解码，确保 `%2F` 不能伪装成 selector 内容。
    let encodedComponents = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard !encodedComponents.isEmpty else { throw WorkflowDeepLinkError.missingSelector }
    guard encodedComponents.count == 1,
      let selector = String(encodedComponents[0]).removingPercentEncoding,
      !selector.contains("/")
    else { throw WorkflowDeepLinkError.unexpectedURLComponent }
    try validateSelectorText(selector)

    switch kind {
    case "window":
      return .focusWindow(try parseWindowSelector(selector))
    case "tab":
      return .focusTab(try parseTabSelector(selector))
    case "pane":
      return .focusPane(try parsePaneSelector(selector))
    default:
      throw WorkflowDeepLinkError.unsupportedTarget
    }
  }

  private static func parseWindowSelector(_ selector: String) throws -> WorkflowWindowSelector {
    if selector == "current" { return .current }
    if selector == "last" { return .last }
    if selector.hasPrefix("w_"), isOpaqueIdentifier(selector) { return .identifier(selector) }
    if let index = positiveIndex(selector) { return .index(index) }
    if selector.hasPrefix("title:") {
      let title = String(selector.dropFirst("title:".count))
      guard !title.isEmpty else { throw WorkflowDeepLinkError.invalidSelector }
      return .title(title)
    }
    throw WorkflowDeepLinkError.invalidSelector
  }

  private static func parseTabSelector(_ selector: String) throws -> WorkflowTabSelector {
    if selector.hasPrefix("t_"), isOpaqueIdentifier(selector) { return .identifier(selector) }
    if let index = positiveIndex(selector) { return .index(index) }
    throw WorkflowDeepLinkError.invalidSelector
  }

  private static func parsePaneSelector(_ selector: String) throws -> WorkflowPaneSelector {
    guard isOpaqueIdentifier(selector) else { throw WorkflowDeepLinkError.invalidSelector }
    return selector.hasPrefix("p_")
      ? .identifier(selector)
      : .sessionIdentifier(selector)
  }

  private static func positiveIndex(_ value: String) -> Int? {
    guard let index = Int(value), index > 0 else { return nil }
    return index
  }

  private static func validateSelectorText(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 256,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw WorkflowDeepLinkError.invalidSelector }
  }

  private static func isOpaqueIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy { scalar in
        CharacterSet.alphanumerics.contains(scalar) || "-_.:".unicodeScalars.contains(scalar)
      }
  }
}
