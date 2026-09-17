import AsterCore
import Foundation

/// 本机 ssh 连接复用（OpenSSH ControlMaster）共用的 socket 目录。
///
/// 目录必须稳定且短：control socket 的完整路径受 `sockaddr_un` 104 字节限制，而 `%C`
/// 展开后就占 64 字符，所以不能用 macOS 的 `$TMPDIR`（本身就是很长的随机路径），
/// 固定成 `/tmp/aster-cm-<uid>`。带 uid 是为了在多用户机器上不与他人目录冲突。
enum SSHControlDirectory {
  /// 当前用户的默认目录路径。
  static var defaultPath: String { "/tmp/aster-cm-\(getuid())" }

  /// 为当前用户准备默认目录，返回可用路径；任何校验不通过都返回 nil。
  static func prepare(fileManager: FileManager = .default) -> String? {
    prepare(path: defaultPath, fileManager: fileManager)
  }

  /// 准备指定目录（测试注入路径用）。
  ///
  /// 校验只判断、不修复：如果 `/tmp` 下已有同名项却不满足条件（是符号链接、属主不是
  /// 当前用户、权限比 0700 宽），很可能是别人抢占或恶意布置的诱饵。此时删除或 chmod
  /// 都是危险动作，正确处理是放弃复用，让 ssh 走普通新连接。
  static func prepare(path: String, fileManager: FileManager = .default) -> String? {
    guard SSHControlDirectoryPolicy.validate(path: path) else { return nil }

    var status = stat()
    if lstat(path, &status) != 0 {
      do {
        try fileManager.createDirectory(
          atPath: path,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        return nil
      }
      return path
    }

    // lstat 不跟随符号链接：目录项是链接时 S_ISDIR 为假，指向别处的诱饵由此被拒绝。
    guard (status.st_mode & S_IFMT) == S_IFDIR else { return nil }
    guard status.st_uid == getuid() else { return nil }
    guard (status.st_mode & 0o777) == 0o700 else { return nil }
    return path
  }
}
