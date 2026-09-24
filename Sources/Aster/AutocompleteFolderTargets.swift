// 目录型参数（cd / pushd / rmdir 及规格标注为 folders 的参数）的本机存在性校验。
import AsterCore
import Foundation

/// 历史与固定命令里的目录参数可能早已被删除或改名，或者当时就敲错了（`cd` 失败
/// 退出码为 1，学习库只剔除 127，照样会记下来）。补全前用它剔除指向不存在目录的
/// 候选，避免 `cd` 推荐一个进不去的路径。
///
/// 只判断能静态确定的字面路径：选项、`cd -`、变量、命令替换、通配符和 `~user`
/// 一律视为「无法判断」而保留。当前目录在本机不存在（例如远端会话上报的路径）时
/// 整体跳过校验，不误删远端候选。
struct AutocompleteFolderTargets {
  let specDatabase: AutocompleteSpecDatabase
  let fileManager: FileManager
  let directory: String

  /// 整条命令的最后一个参数是目录槽位且该目录不存在时返回 true。
  func hasMissingTarget(command: String) -> Bool {
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard tokens.count >= 2, let target = tokens.last else { return false }
    return expectsFolder(after: Array(tokens.dropLast())) && isMissingFolder(target)
  }

  /// `leading` 是命令名加上目标参数之前已经完成的 token；该位置要目录时返回 true。
  func expectsFolder(after leading: [String]) -> Bool {
    guard let name = leading.first, let root = specDatabase.command(named: name) else { return false }
    return AutocompleteArgumentContext(root: root, completed: Array(leading.dropFirst()))
      .filesystemMode == .folders
  }

  /// 字面路径解析到本机后既不是目录、也不是指向目录的符号链接时返回 true。
  func isMissingFolder(_ target: String) -> Bool {
    guard !target.isEmpty, !target.hasPrefix("-"),
      !target.contains(where: { "$`*?[{".contains($0) }),
      localDirectoryExists(directory)
    else { return false }
    let path: String
    if target.hasPrefix("/") {
      path = target
    } else if target == "~" || target.hasPrefix("~/") {
      path = NSString(string: target).expandingTildeInPath
    } else if target.hasPrefix("~") {
      // `~user` 需要查询账户数据库，不值得在按键路径上做。
      return false
    } else {
      path = URL(fileURLWithPath: directory).appendingPathComponent(target).standardizedFileURL.path
    }
    return !localDirectoryExists(path)
  }

  /// `fileExists(atPath:isDirectory:)` 会跟随符号链接，链到目录的链接也算目录。
  private func localDirectoryExists(_ path: String) -> Bool {
    guard path.hasPrefix("/") else { return false }
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }
}
