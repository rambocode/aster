import Foundation

/// P4.2a：混合布局的受管终端子树映射与本地资源关联。
///
/// 规则（`docs/developer/remote-work.md` §4.2）：
/// - 共享结构中的节点**只**承载受管终端。
/// - 本地文件、编辑器、预览、Web Pane 仍由来源客户端管理；迁移混合布局时保存本地视图
///   关联，只向服务端提交受管终端子树，**不上传本地文件内容或资源路径**。
/// - 其他客户端只显示共享终端布局，不打开来源客户端的本地资源。
///
/// 本文件全部是纯函数，因此「提交载荷里不含任何本地 resourcePath / 本地文件 pane」
/// 可以被直接单测证明。

/// 一个留在来源客户端的本地视图关联。
///
/// 它按 `paneID` 保存，只存在于来源客户端的本地布局里，绝不进入任何提交载荷。
public struct LocalPaneAssociation: Equatable, Sendable {
  public var paneID: UUID
  public var kind: PaneKind
  public var workingDirectory: String
  /// 本地文件路径或规范化 Web URL。这是必须留在本地的字段。
  public var resourcePath: String?

  public init(paneID: UUID, kind: PaneKind, workingDirectory: String, resourcePath: String?) {
    self.paneID = paneID
    self.kind = kind
    self.workingDirectory = workingDirectory
    self.resourcePath = resourcePath
  }
}

/// 向服务端提交的受管终端子树。
///
/// `layout` 为 nil 表示该标签内没有任何受管终端，此时**不应提交**：提交一棵空树会在
/// 服务端建出一个没有终端的标签，与来源客户端的本地视图对不上。
public struct ManagedSubtreeSubmission: Equatable, Sendable {
  public var layout: RemoteLayoutNode?
  /// 被排除在共享结构之外、仍由来源客户端持有的本地 Pane 身份。
  public var retainedLocalPaneIDs: [UUID]

  public init(layout: RemoteLayoutNode?, retainedLocalPaneIDs: [UUID]) {
    self.layout = layout
    self.retainedLocalPaneIDs = retainedLocalPaneIDs
  }
}

public enum ManagedSubtreeMapping {
  /// 从本地布局里提取可提交的受管终端子树。
  ///
  /// 只保留同时满足两个条件的叶：`kind == .terminal` 且 `managedTerminal != nil`。
  /// 非受管叶被整体剪掉，其兄弟自动提升，因此不会留下只有一个子节点的空分隔容器
  /// （与 `PaneLayout.removing(paneID:)` 的语义一致）。
  ///
  /// - Note: 输出类型是 `RemoteLayoutNode`，它**没有** resourcePath 字段，所以本地资源
  ///   路径在类型层面就无法进入提交载荷。
  public static func submission(for layout: PaneLayout) -> ManagedSubtreeSubmission {
    ManagedSubtreeSubmission(
      layout: extractManagedSubtree(from: layout),
      retainedLocalPaneIDs: localPaneIDs(in: layout)
    )
  }

  /// 提取受管终端子树；没有任何受管终端时返回 nil。
  public static func extractManagedSubtree(from layout: PaneLayout) -> RemoteLayoutNode? {
    switch layout {
    case .leaf(let pane):
      guard pane.kind == .terminal, let managed = pane.managedTerminal else { return nil }
      return .leaf(
        RemotePane(
          paneID: pane.id.uuidString.lowercased(),
          terminalID: managed.terminalID,
          title: nil
        ))

    case .split(let axis, let first, let second, let ratio):
      let left = extractManagedSubtree(from: first)
      let right = extractManagedSubtree(from: second)
      // 一侧被整体剪掉时提升另一侧，保持树是「只含受管终端」的最简形态。
      switch (left, right) {
      case (nil, nil): return nil
      case (let node?, nil): return node
      case (nil, let node?): return node
      case (let a?, let b?):
        return .split(axis: axis, ratio: ratio, first: a, second: b)
      }
    }
  }

  /// 被排除在共享结构之外的本地 Pane 身份（文件、编辑器、预览、Web，以及尚未托管的终端）。
  public static func localPaneIDs(in layout: PaneLayout) -> [UUID] {
    layout.allPanes
      .filter { $0.kind != .terminal || $0.managedTerminal == nil }
      .map(\.id)
  }

  /// 捕获来源客户端要保留的本地视图关联。
  ///
  /// 覆盖两类 Pane：非终端 Pane（本地资源本体），以及虽是受管终端但仍带本地
  /// `resourcePath` 的 Pane。两类都必须留在本地。
  public static func captureLocalAssociations(in layout: PaneLayout) -> [UUID: LocalPaneAssociation]
  {
    var result: [UUID: LocalPaneAssociation] = [:]
    for pane in layout.allPanes {
      let isManagedTerminal = pane.kind == .terminal && pane.managedTerminal != nil
      guard !isManagedTerminal || pane.resourcePath != nil else { continue }
      result[pane.id] = LocalPaneAssociation(
        paneID: pane.id,
        kind: pane.kind,
        workingDirectory: pane.workingDirectory,
        resourcePath: pane.resourcePath
      )
    }
    return result
  }

  /// 把服务端共享结构合并回本地布局。
  ///
  /// - 来源客户端传入自己 `captureLocalAssociations` 的结果，按 paneID 恢复本地资源关联。
  /// - 其他客户端传入空字典，于是只得到终端共享结构，`resourcePath` 保持为 nil ——
  ///   它们既拿不到也打不开来源客户端的本地资源。
  ///
  /// - Parameters:
  ///   - shared: `RemoteWorkspaceProjection` 投影出的共享布局。
  ///   - associations: 本客户端自己的本地关联；其他客户端传 `[:]`。
  public static func merge(
    shared: PaneLayout,
    localAssociations associations: [UUID: LocalPaneAssociation]
  ) -> PaneLayout {
    shared.mappingPanes { pane in
      guard let association = associations[pane.id] else { return pane }
      var restored = pane
      restored.resourcePath = association.resourcePath
      restored.workingDirectory = association.workingDirectory
      return restored
    }
  }
}

extension PaneLayout {
  /// 对每个叶节点做纯变换，保持树形、方向与比例不变。
  ///
  /// 与 `updatingPane(paneID:transform:)` 的区别是它一次遍历全部叶，用于合并整棵
  /// 共享结构时避免按 paneID 反复重建整棵树。
  public func mappingPanes(_ transform: (PaneDescriptor) -> PaneDescriptor) -> PaneLayout {
    switch self {
    case .leaf(let pane):
      return .leaf(transform(pane))
    case .split(let axis, let first, let second, let ratio):
      return .split(
        axis: axis,
        first: first.mappingPanes(transform),
        second: second.mappingPanes(transform),
        ratio: ratio
      )
    }
  }
}
