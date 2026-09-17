// 远端巡检端到端验收：用真实 OpenSSH 连 OrbStack，走 live 客户端跑监控、目录、集成探测与传输。
//
// 与 RemoteWorkP3 系列一样按环境变量开关：`ASTER_REMOTE_INSPECTOR_ORB=1` 时才执行，
// 目标由 `ASTER_REMOTE_INSPECTOR_TARGET` 指定（默认 `root@ubuntu@orb`）。
// 本文件不经过 Inspector 视图，只验证「远端上下文 → 旁路通道 → 远端脚本 → 解析器」这条
// 真实链路；界面状态机由 RemoteInspectorPanelTests 用假客户端覆盖。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 验收开关与目标解析，避免每个用例重复读环境。
private enum RemoteInspectionAcceptance {
  static var enabled: Bool {
    ProcessInfo.processInfo.environment["ASTER_REMOTE_INSPECTOR_ORB"] == "1"
  }

  static var target: String {
    ProcessInfo.processInfo.environment["ASTER_REMOTE_INSPECTOR_TARGET"] ?? "root@ubuntu@orb"
  }

  /// 按场景 A 的真实入口构造上下文：解析用户敲的 `ssh` 命令，再用 `ssh -G` 得到端点。
  @MainActor
  static func makeContext() async throws -> RemoteInspectionContext {
    let invocation = try #require(SSHCommandInvocation.parse("ssh \(target)"))
    let endpoint = try #require(await SSHHostResolutionService.resolve(invocation))
    return .ssh(invocation: invocation, endpoint: endpoint)
  }
}

@Test(.enabled(if: RemoteInspectionAcceptance.enabled))
@MainActor
func remoteInspectionLiveMonitorReadsOrbStackHost() async throws {
  let context = try await RemoteInspectionAcceptance.makeContext()
  let first = try await RemoteInspectionClient.live.monitor(context, nil).get()
  #expect(first.host?.isEmpty == false)
  #expect(first.uname?.hasPrefix("Linux") == true)
  #expect(first.load != nil)
  #expect(first.memory != nil)
  #expect(!first.topByCPU.isEmpty)
  #expect(!first.disks.isEmpty)
  #expect(!first.unavailableSections.contains(RemoteHostMonitorSection.ports))
  // 第二个样本才能算 CPU 百分比；两次采样之间远端时钟必然前进。
  let second = try await RemoteInspectionClient.live.monitor(context, nil).get()
  let firstSample = try #require(first.cpuSample)
  let secondSample = try #require(second.cpuSample)
  #expect(RemoteCPUUsage.compute(previous: firstSample, current: secondSample) != nil)
}

@Test(.enabled(if: RemoteInspectionAcceptance.enabled))
@MainActor
func remoteInspectionLiveListsEtcDirectory() async throws {
  let context = try await RemoteInspectionAcceptance.makeContext()
  let listing = try await RemoteInspectionClient.live.listDirectory(context, "/etc").get()
  #expect(listing.directory == "/etc")
  #expect(listing.entries.contains { $0.name == "hosts" && $0.kind == .file })
  #expect(listing.entries.contains { $0.name == "ssh" && $0.kind == .directory })
  #expect(!listing.isTruncated)

  let missing = await RemoteInspectionClient.live.listDirectory(context, "/definitely/missing")
  guard case .failure(.directoryMissing) = missing else {
    Issue.record("缺失目录应归类为 directoryMissing，实际：\(missing)")
    return
  }
}

@Test(.enabled(if: RemoteInspectionAcceptance.enabled))
@MainActor
func remoteInspectionLiveDetectsInstalledBashIntegration() async throws {
  let context = try await RemoteInspectionAcceptance.makeContext()
  let status = try await RemoteInspectionClient.live.inspectIntegration(context).get()
  #expect(status.home == "/root")
  // 验收机已按安装器布局手工装好 bash 集成；zsh 未装。
  #expect(status.bash == .installed)
  #expect(status.zsh != .installed)
}

@Test(.enabled(if: RemoteInspectionAcceptance.enabled))
@MainActor
func remoteInspectionLiveUploadsThenDownloadsIdenticalBytes() async throws {
  let context = try await RemoteInspectionAcceptance.makeContext()
  let remoteDirectory = "/tmp/aster-inspector-accept-\(UUID().uuidString.prefix(8))"
  let channel = try #require(RemoteSideChannelResolver.resolve(context))
  _ = try channel.run(
    script: "mkdir -p -- \"$1\"", arguments: [remoteDirectory], timeout: 10,
    maximumOutputBytes: 1024)
  defer {
    _ = try? channel.run(
      script: "rm -rf -- \"$1\"", arguments: [remoteDirectory], timeout: 10,
      maximumOutputBytes: 1024)
  }

  let local = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-inspector-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: local) }
  // 文件名故意带空格与单引号，验证只经位置参数进入远端 Shell。
  let fileName = "up load'test.bin"
  let payload = Data((0..<70_000).map { UInt8($0 % 251) })
  let source = local.appendingPathComponent("source.bin")
  try payload.write(to: source)

  try await RemoteInspectionClient.live.upload(context, source, remoteDirectory, fileName).get()
  #expect(await RemoteInspectionClient.live.fileExists(context, "\(remoteDirectory)/\(fileName)"))
  let listing = try await RemoteInspectionClient.live.listDirectory(context, remoteDirectory).get()
  #expect(listing.entries.map(\.name) == [fileName])
  #expect(listing.entries.first?.size == Int64(payload.count))

  let downloaded = local.appendingPathComponent("downloaded.bin")
  try await RemoteInspectionClient.live.download(
    context, "\(remoteDirectory)/\(fileName)", downloaded
  ).get()
  #expect(try Data(contentsOf: downloaded) == payload)
}
