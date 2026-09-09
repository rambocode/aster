import AsterCore
import Foundation

/// 机器与命名会话的控制协议方法（P4.8）。
///
/// 为什么单独一组方法而不是扩展 `AsterControlMethod`：这些动作的作用域是**客户端配置**
/// 与**某台机器上的会话注册表**，与既有 `pane.* / agent.*`（作用域是当前工作区的 Pane）
/// 不同。跨机器写入必须显式给出 `machine`，不能靠「当前选中项」补全（R17）。
enum MachineControlMethod: String, CaseIterable, Sendable {
  case machineList = "machine.list"
  case machineAdd = "machine.add"
  case machineRename = "machine.rename"
  case machineEnable = "machine.enable"
  case machineDisable = "machine.disable"
  case machineRemove = "machine.remove"
  case sessionList = "session.list"
  case sessionCreate = "session.create"
  case sessionStop = "session.stop"
  case sessionDelete = "session.delete"

  /// 写方法需要 IPC 写门禁。列表查询保持只读，任意终端都能调用。
  var isWrite: Bool {
    switch self {
    case .machineList, .sessionList: false
    case .machineAdd, .machineRename, .machineEnable, .machineDisable, .machineRemove,
      .sessionCreate, .sessionStop, .sessionDelete:
      true
    }
  }
}

/// `machine.*` 的结构化输出行。
struct MachineControlRow: Codable, Equatable, Sendable {
  var id: String
  var label: String
  var sessionName: String
  var sshTarget: String?
  var isLocal: Bool
  var enabled: Bool
  var state: String
  var lastUpdatedAtUnixMs: UInt64?
  var lastError: String?
}

struct MachineListResult: Codable, Equatable, Sendable {
  var machines: [MachineControlRow]
  /// 配置目录损坏时的可恢复错误；此时 `machines` 是最后一份**有效**配置。
  var configurationError: String?
}

/// `session.*` 的结构化输出行。
struct SessionControlRow: Codable, Equatable, Sendable {
  var sessionID: String
  var name: String
  var state: String
  var serverID: String?
  var serverEpoch: String?
}

struct SessionListResult: Codable, Equatable, Sendable {
  /// 被查询的机器；始终回显，便于自动化确认自己写到了哪台机器上。
  var machine: String
  var sessions: [SessionControlRow]
}

struct SessionActionResult: Codable, Equatable, Sendable {
  var machine: String
  var name: String
  var disposition: String
  var session: SessionControlRow?
}

/// `machine.add` 参数。
struct MachineAddParams: Codable, Equatable, Sendable {
  var label: String
  var sshTarget: String
  var sessionName: String
}

/// 只按 ID 或标签定位一台机器的参数。
struct MachineTargetParams: Codable, Equatable, Sendable {
  var machine: String
}

/// `machine.rename` 参数。
struct MachineRenameParams: Codable, Equatable, Sendable {
  var machine: String
  var label: String
}

/// `session.*` 参数。跨机器动作必须显式带 `machine`。
struct SessionTargetParams: Codable, Equatable, Sendable {
  var machine: String
  var name: String
}

extension AsterControlDispatcher {
  /// 处理机器/会话方法。返回 nil 表示不是本组方法，交回原有分发。
  ///
  /// 在 `resolvedMethod()` 之前调用：`AsterControlMethod` 是 AsterCore 的封闭枚举，
  /// 未知方法名会被它直接判成 `method_not_found`。
  func handleMachineMethod(
    _ request: AsterControlRequest,
    fleet: MachineFleetModel
  ) async -> AsterControlResponse? {
    guard let method = MachineControlMethod(rawValue: request.method) else { return nil }
    do {
      if method.isWrite {
        // 复用既有 IPC 写门禁的全局开关。这些动作不向某个 PTY 写字节，
        // 因此不走 Pane 级的敏感会话/可写性判断。
        guard policyProvider().allowSendKeys else {
          throw AsterControlError(code: .writeNotAllowed, message: "IPC Allow Send Keys 未开启。")
        }
      }
      let result = try await dispatchMachine(method, request: request, fleet: fleet)
      return AsterControlResponse(id: request.id, result: result)
    } catch let error as AsterControlError {
      return AsterControlResponse(id: request.id, error: error)
    } catch {
      return AsterControlResponse(
        id: request.id,
        error: AsterControlError(code: .internalError, message: "\(error)"))
    }
  }

  private func dispatchMachine(
    _ method: MachineControlMethod,
    request: AsterControlRequest,
    fleet: MachineFleetModel
  ) async throws -> JSONValue {
    switch method {
    case .machineList:
      return try encodeMachine(
        MachineListResult(
          machines: fleet.rows.map(Self.row),
          configurationError: fleet.configurationError))

    case .machineAdd:
      let params = try request.decodeParams(MachineAddParams.self)
      // CLI 不能代替用户接受安装或服务替换：那两条路径必须走交互式设置流程。
      let outcome = await fleet.addMachine(
        label: params.label, sshTarget: params.sshTarget, sessionName: params.sessionName,
        confirm: { _ in false })
      switch outcome {
      case .added(let profile):
        guard let row = fleet.rows.first(where: { $0.id == profile.id }) else {
          throw AsterControlError(code: .internalError, message: "机器已保存但未出现在列表中。")
        }
        return try encodeMachine(Self.row(row))
      case .cancelled:
        throw AsterControlError(
          code: .invalidRequest,
          message: "该机器需要安装或替换远端服务；请在 App 的「文件 ▸ 添加机器…」里确认后再试。")
      case .failed(let message):
        throw AsterControlError(code: .invalidRequest, message: message)
      }

    case .machineRename:
      let params = try request.decodeParams(MachineRenameParams.self)
      let profile = try resolveMachine(params.machine, fleet: fleet)
      if let failure = fleet.rename(profile.id, to: params.label) {
        throw AsterControlError(code: .invalidRequest, message: failure)
      }
      return try encodeMachine(try machineRow(profile.id, fleet: fleet))

    case .machineEnable, .machineDisable:
      let params = try request.decodeParams(MachineTargetParams.self)
      let profile = try resolveMachine(params.machine, fleet: fleet)
      if let failure = fleet.setEnabled(profile.id, method == .machineEnable) {
        throw AsterControlError(code: .invalidRequest, message: failure)
      }
      return try encodeMachine(try machineRow(profile.id, fleet: fleet))

    case .machineRemove:
      let params = try request.decodeParams(MachineTargetParams.self)
      let profile = try resolveMachine(params.machine, fleet: fleet)
      let removed = try machineRow(profile.id, fleet: fleet)
      if let failure = fleet.remove(profile.id) {
        throw AsterControlError(code: .invalidRequest, message: failure)
      }
      return try encodeMachine(removed)

    case .sessionList:
      let params = try request.decodeParams(MachineTargetParams.self)
      let profile = try resolveMachine(params.machine, fleet: fleet)
      let sessions = try await withMachineErrors {
        try await fleet.sessions(onMachine: profile.id)
      }
      return try encodeMachine(
        SessionListResult(machine: profile.label, sessions: sessions.map(Self.row)))

    case .sessionCreate, .sessionStop, .sessionDelete:
      let params = try request.decodeParams(SessionTargetParams.self)
      let profile = try resolveMachine(params.machine, fleet: fleet)
      let registry = try fleet.registry(for: profile.id)
      switch method {
      case .sessionCreate:
        let session = try withMachineErrorsSync { try registry.client.createSession(registry.endpoint, name: params.name) }
        return try encodeMachine(
          SessionActionResult(
            machine: profile.label, name: params.name, disposition: "created",
            session: Self.row(session)))
      case .sessionStop:
        let session = try withMachineErrorsSync { try registry.client.stopSession(registry.endpoint, selector: .name(params.name)) }
        return try encodeMachine(
          SessionActionResult(
            machine: profile.label, name: params.name, disposition: "stopped",
            session: Self.row(session)))
      default:
        // 删除要求会话已停止；活动会话由服务端返回 session_running，原样上抛。
        _ = try withMachineErrorsSync { try registry.client.deleteSession(registry.endpoint, selector: .name(params.name)) }
        return try encodeMachine(
          SessionActionResult(
            machine: profile.label, name: params.name, disposition: "deleted", session: nil))
      }
    }
  }

  /// 按 ID 或标签定位机器。找不到或标签重复都拒绝，不猜「当前选中项」。
  private func resolveMachine(_ selector: String, fleet: MachineFleetModel) throws -> MachineProfile
  {
    guard !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AsterControlError.invalidParams("machine 不能为空；跨机器动作必须显式指定机器。")
    }
    guard let profile = fleet.resolve(idOrLabel: selector) else {
      throw AsterControlError(
        code: .notFound, message: "找不到机器（或标签不唯一）：\(selector)")
    }
    return profile
  }

  private func machineRow(_ id: UUID, fleet: MachineFleetModel) throws -> MachineControlRow {
    guard let row = fleet.rows.first(where: { $0.id == id }) else {
      throw AsterControlError(code: .notFound, message: "机器不存在：\(id.uuidString)")
    }
    return Self.row(row)
  }

  private func withMachineErrors<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let error as AsterControlError {
      throw error
    } catch {
      throw AsterControlError(
        code: .internalError, message: RemoteSetupDescription.text(for: error))
    }
  }

  private func withMachineErrorsSync<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let error as AsterControlError {
      throw error
    } catch {
      throw AsterControlError(
        code: .internalError, message: RemoteSetupDescription.text(for: error))
    }
  }

  private func encodeMachine<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONValue(encoding: value)
  }

  static func row(_ row: MachineFleetRow) -> MachineControlRow {
    MachineControlRow(
      id: row.isLocal ? "local" : row.id.uuidString,
      label: row.label,
      sessionName: row.sessionName,
      sshTarget: row.sshTarget,
      isLocal: row.isLocal,
      enabled: row.enabled,
      state: row.state.rawValue,
      lastUpdatedAtUnixMs: row.lastUpdatedAt.map { UInt64(max(0, $0.timeIntervalSince1970 * 1000)) },
      lastError: row.lastError)
  }

  static func row(_ session: NamedSessionDescriptor) -> SessionControlRow {
    SessionControlRow(
      sessionID: session.sessionID,
      name: session.name,
      state: session.state.rawValue,
      serverID: session.serverID,
      serverEpoch: session.serverEpoch)
  }
}
