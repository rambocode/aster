import Foundation

/// 纯逻辑的文件枚举器，递归扫描给定目录下的普通文件，供 Open Quickly 的「文件」过滤器
/// 提供候选数据源。不依赖 AppKit，可在单元测试中直接验证。
public enum WorkspaceFileScanner {
  /// 扫描上限。深度以 root 的直接子项为 1 计。
  public struct Limits: Sendable {
    public var maximumDepth: Int
    public var maximumFiles: Int

    public init(maximumDepth: Int = 8, maximumFiles: Int = 5_000) {
      self.maximumDepth = maximumDepth
      self.maximumFiles = maximumFiles
    }
  }

  /// 扫描到的单个普通文件。
  public struct File: Equatable, Sendable {
    public let path: String
    public let name: String
    public let relativeParent: String
    public let depth: Int
  }

  /// 枚举时整棵跳过的目录名：构建产物、依赖缓存等目录体量大且对「查找文件」没有价值，
  /// 命中即整棵跳过，避免遍历成本浪费在这些目录上。
  public static let skippedDirectoryNames: Set<String> = [
    "node_modules", ".build", "build", "dist", "target", "DerivedData", "Pods", "vendor", "__pycache__",
  ]

  /// 递归枚举 root 下的普通文件，返回按深度、再按文件名排序的结果。
  public static func scan(root: String, limits: Limits = Limits()) -> [File] {
    guard !root.isEmpty else { return [] }
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
      return []
    }

    // 用原始路径判断存在性之后，再用 resolvingSymlinksInPath 计算规范路径：
    // macOS 上 /tmp、/var 等常见路径本身是符号链接（指向 /private/...），若不先
    // 规范化，后面用 pathComponents 差集推导 relativeParent 时会因前缀对不上而算错。
    let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
    let rootComponents = rootURL.pathComponents
    let rootName = rootURL.lastPathComponent
    let depthLimit = max(0, limits.maximumDepth)
    let fileLimit = max(0, limits.maximumFiles)
    guard fileLimit > 0 else { return [] }

    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: { _, _ in true }
    ) else { return [] }

    var result: [File] = []
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }

      // 符号链接（无论指向文件还是目录）一律跳过，不收录也不递归：既避免把
      // 链接目标误报为工作区内文件，也防止循环链接导致遍历失控。
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }

      if values.isDirectory == true {
        let level = enumerator.level
        // 命中黑名单目录名，或层级已超过 maximumDepth：整棵跳过，enumerator 不再
        // 下探其内容。深度判断放在这里只是提前剪枝；单个文件是否计入还要看下面
        // 对 depth 的显式过滤，两者配合才能精确匹配 maximumDepth 语义。
        if skippedDirectoryNames.contains(url.lastPathComponent) || level > depthLimit {
          enumerator.skipDescendants()
        }
        continue
      }

      guard values.isRegularFile == true else { continue }
      let depth = enumerator.level
      guard depth <= depthLimit else { continue }

      // relativeParent 用 pathComponents 做前缀差集，而不是字符串 hasPrefix，
      // 避免 /a/proj 与 /a/proj-2 这类相邻同名前缀被误切成子路径。
      let parentComponents = url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
      let suffixComponents = Array(parentComponents.dropFirst(rootComponents.count))
      let relativeParent = ([rootName] + suffixComponents).joined(separator: "/")

      result.append(File(path: url.path, name: url.lastPathComponent, relativeParent: relativeParent, depth: depth))
      if result.count >= fileLimit { break }
    }

    return result.sorted { lhs, rhs in
      if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }
}
