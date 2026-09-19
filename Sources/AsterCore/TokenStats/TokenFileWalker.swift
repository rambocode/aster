// 递归列举数据源目录下的文件，并给出缓存要比对的身份（路径、大小、修改时间）。
// 移植自 jettoai/tally（MIT）的 TokenStatsSources。
import Foundation

/// 数据源共用的目录遍历工具。
public enum TokenFileWalker {
  /// 递归遍历若干根目录，返回符合 `include` 的普通文件。
  ///
  /// 多账号配置经常把同一份 `projects/` 软链进每个 config home，所以根目录按**解析后**的路径去重；
  /// 不去重的话同样几 GB 的历史会被扫一遍算一遍。
  public static func files(
    in roots: [URL], include: (URL) -> Bool
  ) -> [TokenSourceFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    let manager = FileManager.default
    var out: [TokenSourceFile] = []
    var seenFiles = Set<String>()
    for root in resolvedRoots(roots) {
      guard
        let walker = manager.enumerator(
          at: root, includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }
      for case let url as URL in walker {
        guard include(url) else { continue }
        let resolved = url.resolvingSymlinksInPath()
        guard seenFiles.insert(resolved.path).inserted,
          let values = try? resolved.resourceValues(forKeys: Set(keys)),
          values.isRegularFile == true,
          let size = values.fileSize, let modified = values.contentModificationDate
        else { continue }
        out.append(
          TokenSourceFile(
            path: resolved.path, size: Int64(size),
            modified: modified.timeIntervalSince1970))
      }
    }
    return out
  }

  /// 存在的目录，软链已解析，每个只保留一次。
  private static func resolvedRoots(_ candidates: [URL]) -> [URL] {
    let manager = FileManager.default
    var seen = Set<String>()
    return candidates.compactMap { url in
      let resolved = url.resolvingSymlinksInPath()
      var isDirectory: ObjCBool = false
      guard manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
        isDirectory.boolValue, seen.insert(resolved.path).inserted
      else { return nil }
      return resolved
    }
  }
}
