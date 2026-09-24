// `host.*` 控制协议方法：只读列出已保存的 SSH 主机，供 `aster-cli host list` 使用。
import AsterCore
import Foundation

/// 主机目录的控制协议方法。
///
/// 与 `MachineControlMethod` 一样单独成组：作用域是客户端的主机配置，不是当前工作区的 Pane。
enum HostControlMethod: String, CaseIterable, Sendable {
  case hostList = "host.list"
}

/// `host.list` 的结构化输出行。
///
/// 刻意只放「能认出是哪台主机」的字段：认证方式、私钥路径、代理命令与「是否保存了口令」
/// 都不输出。口令本身在钥匙串里，CLI 输出会进终端回滚与日志，连「有没有」也不该泄露。
struct HostControlRow: Codable, Equatable, Sendable {
  var id: String
  var name: String
  var group: String?
  /// 合并默认项后的 `user@host:port`；用户名继承不到时省略 `user@`。
  var target: String
  var jumpHostID: String?
  /// 跳板主机的名称；跳板引用已失效时为 nil，`jumpHostID` 仍原样回显。
  var jumpHostName: String?
}

struct HostListResult: Codable, Equatable, Sendable {
  var hosts: [HostControlRow]
  /// hosts.json 最近一次加载失败的原因；此时 `hosts` 是最后一份有效配置。
  var configurationError: String?
}

/// `host.list` 读取的数据快照；测试注入替身，生产取 `SSHHostDirectory.shared`。
struct HostControlSnapshot: Sendable {
  /// 含默认项的全部主机；默认项只用于合并字段，不出现在输出里。
  var hosts: [SSHHostProfile]
  var loadError: String?

  /// 从主机目录取当前快照。
  @MainActor
  static func live(_ directory: SSHHostDirectory = .shared) -> HostControlSnapshot {
    HostControlSnapshot(hosts: directory.hosts, loadError: directory.loadError)
  }
}

extension AsterControlDispatcher {
  /// 处理主机方法。返回 nil 表示不是本组方法，交回原有分发。
  ///
  /// 只有只读方法，因此不走 IPC 写门禁。
  func handleHostMethod(_ request: AsterControlRequest) -> AsterControlResponse? {
    guard let method = HostControlMethod(rawValue: request.method) else { return nil }
    let snapshot = hostSnapshotProvider?() ?? HostControlSnapshot.live()
    do {
      switch method {
      case .hostList:
        let result = HostListResult(
          hosts: Self.hostRows(snapshot.hosts), configurationError: snapshot.loadError)
        return AsterControlResponse(id: request.id, result: try JSONValue(encoding: result))
      }
    } catch {
      return AsterControlResponse(
        id: request.id, error: AsterControlError(code: .internalError, message: "\(error)"))
    }
  }

  /// 把主机配置投影成输出行：跳过默认项，用户名与端口按默认项合并。
  ///
  /// 不走 `SSHHostResolver`：它会展开私钥路径、校验跳板链，主机名为空或跳板成环时直接抛错；
  /// 列表只需要显示字段，解析不通过的主机也必须列出来，用户才知道要去修哪一条。
  static func hostRows(_ hosts: [SSHHostProfile]) -> [HostControlRow] {
    let defaults = hosts.first(where: \.isDefaults) ?? .emptyDefaults()
    let names = Dictionary(hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    return hosts.filter { !$0.isDefaults }.map { profile in
      let user = [profile.user, defaults.user]
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
      let port = profile.port ?? defaults.port ?? 22
      // 与解析器一致：跳板主机不能经过默认项里的跳板回到自己。
      let jumpID = (profile.jumpHostID ?? defaults.jumpHostID).flatMap { $0 == profile.id ? nil : $0 }
      return HostControlRow(
        id: profile.id.uuidString,
        name: profile.name,
        group: profile.group,
        target: hostTarget(host: profile.host, user: user, port: port),
        jumpHostID: jumpID?.uuidString,
        jumpHostName: jumpID.flatMap { names[$0] })
    }
  }

  /// `user@host:port`；IPv6 地址加方括号，避免和端口分隔符混淆。
  private static func hostTarget(host: String, user: String?, port: Int) -> String {
    let trimmed = host.trimmingCharacters(in: .whitespaces)
    let hostText = trimmed.contains(":") ? "[\(trimmed)]" : trimmed
    let prefix = user.map { "\($0)@" } ?? ""
    return "\(prefix)\(hostText):\(port)"
  }
}
