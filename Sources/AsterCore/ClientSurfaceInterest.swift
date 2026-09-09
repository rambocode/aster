import Foundation

/// P4.6：客户端独立焦点与画面兴趣集合。
///
/// 依据 `docs/developer/remote-work.md` §3.3 与 §4.2：
/// - 焦点、活动机器、可见订阅属于**客户端**；客户端之间互不抢选中项。
/// - 可见终端传输画面；隐藏后取消画面订阅，但结构与 Agent 事件订阅保留。
/// - 重新可见时先发完整快照；快照确认到达之前不放行交互。
/// - 尺寸只由**持有写租约且可见**的控制器更新。
///
/// 本类型是纯状态机：不发网络请求，只产出「意图」，由传输层执行。

/// 画面订阅意图。传输层按它发 `surface.subscribe` / `surface.unsubscribe` / `surface.snapshot`。
public enum SurfaceInterestIntent: Equatable, Sendable {
  case subscribe(terminalID: String)
  case unsubscribe(terminalID: String)
  /// 重新可见时先请求完整快照，快照到达之前不放行交互。
  case requestSnapshot(terminalID: String)
}

/// 交互闸门。重新可见后必须先经过 `awaitingSnapshot` 才能到 `open`。
public enum InteractionGate: String, Equatable, Sendable {
  /// 不可见：不订阅画面，也不接受交互。
  case closed
  /// 已请求快照，等待确认。此时**不放行交互**。
  case awaitingSnapshot
  /// 快照已确认，可以交互。
  case open
}

/// 尺寸更新被拒绝的原因。
public enum SurfaceResizeRejection: String, Equatable, Sendable {
  /// 该终端当前不可见。
  case notVisible
  /// 调用方没有写租约（只读观察者、别的客户端）。
  case noWriteLease
  /// 快照尚未确认，交互闸门未开。
  case gateNotOpen
}

/// 尺寸更新判定结果。
public enum SurfaceResizeDecision: Equatable, Sendable {
  case allowed
  case rejected(SurfaceResizeRejection)
}

/// 一个客户端的焦点与画面兴趣集合。
///
/// 每个客户端各持一份实例；实例之间没有任何共享状态，所以两个客户端不会互相抢焦点。
public struct ClientSurfaceInterest: Equatable, Sendable {
  /// 本客户端的 clientID。租约归属按它判定。
  public let clientID: String
  /// 本客户端自己的焦点窗格。其他客户端改焦点不影响它。
  public private(set) var focusedPaneID: UUID?
  /// 当前可见的终端集合（terminalID）。
  public private(set) var visibleSurfaces: Set<String>
  /// 每个终端的交互闸门。
  public private(set) var gates: [String: InteractionGate]
  /// 本客户端持有写租约的终端集合。
  public private(set) var writeLeases: Set<String>

  public init(clientID: String) {
    self.clientID = clientID
    self.focusedPaneID = nil
    self.visibleSurfaces = []
    self.gates = [:]
    self.writeLeases = []
  }

  /// 设置本客户端焦点。纯本地动作，不产生任何服务端意图，因此不可能抢别人的焦点。
  public mutating func focus(paneID: UUID?) {
    focusedPaneID = paneID
  }

  /// 终端变为可见。
  ///
  /// 先请求完整快照并把闸门置为 `awaitingSnapshot`：在 `confirmSnapshot` 之前，
  /// `allowsInteraction` 为 false，`resizeDecision` 也会拒绝。
  public mutating func becameVisible(terminalID: String) -> [SurfaceInterestIntent] {
    let alreadyVisible = visibleSurfaces.contains(terminalID)
    visibleSurfaces.insert(terminalID)
    gates[terminalID] = .awaitingSnapshot
    // 已经可见时不重复订阅，但仍然重新取快照：调用方通常是在重连之后调用它。
    return alreadyVisible
      ? [.requestSnapshot(terminalID: terminalID)]
      : [.subscribe(terminalID: terminalID), .requestSnapshot(terminalID: terminalID)]
  }

  /// 快照确认到达，放行交互。
  public mutating func confirmSnapshot(terminalID: String) {
    guard visibleSurfaces.contains(terminalID) else { return }
    gates[terminalID] = .open
  }

  /// 终端被隐藏：取消画面订阅并关闭闸门。
  ///
  /// 只取消**画面**订阅；结构与 Agent 事件订阅是会话级的，不在这里处理，因此隐藏
  /// 之后后台元数据继续更新（§4.2）。
  public mutating func becameHidden(terminalID: String) -> [SurfaceInterestIntent] {
    guard visibleSurfaces.remove(terminalID) != nil else {
      gates[terminalID] = .closed
      return []
    }
    gates[terminalID] = .closed
    return [.unsubscribe(terminalID: terminalID)]
  }

  /// 连接断开或代次变化：所有闸门关闭，画面订阅全部作废。
  ///
  /// 不保留 `visibleSurfaces` 之外的任何状态；重新可见时会重新走
  /// 「先快照后交互」，不会把断线前的旧画面当成当前状态。
  public mutating func connectionLost() -> [SurfaceInterestIntent] {
    let intents = visibleSurfaces.sorted().map { SurfaceInterestIntent.unsubscribe(terminalID: $0) }
    for terminalID in visibleSurfaces { gates[terminalID] = .closed }
    writeLeases.removeAll()
    return intents
  }

  /// 记录本客户端取得写租约。
  public mutating func acquireWriteLease(terminalID: String) {
    writeLeases.insert(terminalID)
  }

  /// 释放写租约（分离、被接管、断线）。
  public mutating func releaseWriteLease(terminalID: String) {
    writeLeases.remove(terminalID)
  }

  public func gate(terminalID: String) -> InteractionGate {
    gates[terminalID] ?? .closed
  }

  /// 该终端当前是否放行交互。
  public func allowsInteraction(terminalID: String) -> Bool {
    gate(terminalID: terminalID) == .open
  }

  /// 判定一次尺寸更新是否允许。
  ///
  /// 三个条件缺一不可：可见、持有写租约、闸门已开。只读观察者与不可见控制器都被拒绝
  /// （§4.2：尺寸只由持有写租约的可见控制器更新）。
  public func resizeDecision(terminalID: String) -> SurfaceResizeDecision {
    guard visibleSurfaces.contains(terminalID) else { return .rejected(.notVisible) }
    guard writeLeases.contains(terminalID) else { return .rejected(.noWriteLease) }
    guard gate(terminalID: terminalID) == .open else { return .rejected(.gateNotOpen) }
    return .allowed
  }
}
