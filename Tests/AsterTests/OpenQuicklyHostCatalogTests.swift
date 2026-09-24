import AsterCore
import Foundation
import Testing

@testable import Aster

// Open Quickly SSH 小节的目录计算：去重、frecency 排序与快连行位置。纯函数，不碰真实配置。

private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

private func host(_ name: String, _ address: String, user: String = "deploy", port: Int? = nil)
  -> SSHHostProfile
{
  SSHHostProfile(name: name, host: address, port: port, user: user)
}

@Test("绑定到机器的主机只显示机器；alias 已对应主机或机器时不再列出")
func hostCatalogDeduplicatesAgainstMachinesAndHosts() {
  let bound = host("prod", "10.0.0.5")
  let legacy = host("legacy", "10.0.0.6", port: 2222)
  let free = host("staging", "10.0.0.7")
  let machines = [
    OpenQuicklyHostCatalog.Machine(id: UUID(), label: "prod-box", target: "deploy@10.0.0.5", hostID: bound.id),
    // 旧机器没有 hostID，但 target 文本与主机的规范 target 相同。
    OpenQuicklyHostCatalog.Machine(id: UUID(), label: "old", target: "ssh://deploy@10.0.0.6:2222", hostID: nil),
  ]
  let aliases = [
    OpenQuicklyHostCatalog.Alias(alias: "staging", hostName: "10.0.0.7", user: "deploy"),  // 与主机同名
    OpenQuicklyHostCatalog.Alias(alias: "s2", hostName: "10.0.0.7", user: "deploy"),  // 地址同主机
    OpenQuicklyHostCatalog.Alias(alias: "old", hostName: "elsewhere"),  // 与机器标签同名
    OpenQuicklyHostCatalog.Alias(alias: "orb", hostName: "orb", user: "root@ubuntu"),
    OpenQuicklyHostCatalog.Alias(alias: "orb", hostName: "dup"),  // 重复 alias 只取第一条
  ]
  let rows = OpenQuicklyHostCatalog.rows(
    machines: machines, hosts: [.emptyDefaults(), bound, legacy, free], aliases: aliases,
    ledger: HostUsageLedger(), now: now)
  #expect(rows.map(\.title) == ["old", "prod-box", "staging", "orb"])
  #expect(rows.map(\.itemKind) == [.machine, .machine, .host, .ssh])
  #expect(rows[2].detail == "deploy@10.0.0.7")
  #expect(rows[3].detail == "root@ubuntu@orb")
  #expect(rows[3].id == "ssh:orb")
}

@Test("每组按使用频率降序，同分按名称")
func hostCatalogSortsByFrecency() {
  let a = host("alpha", "a.example")
  let b = host("beta", "b.example")
  let c = host("gamma", "c.example")
  var ledger = HostUsageLedger()
  ledger.record(.id(c.id), at: now)
  ledger.record(.id(c.id), at: now)
  ledger.record(.id(b.id), at: now)
  ledger.record(.target("zeta"), at: now)
  let rows = OpenQuicklyHostCatalog.rows(
    machines: [], hosts: [a, b, c],
    aliases: [.init(alias: "eta"), .init(alias: "zeta")], ledger: ledger, now: now)
  #expect(rows.map(\.title) == ["gamma", "beta", "alpha", "zeta", "eta"])
  #expect(rows[0].score > rows[1].score)
}

@Test("快连只在带地址特征、能解析、且是「全部」或「SSH」过滤器时出现")
func hostCatalogQuickConnectTarget() {
  #expect(OpenQuicklyHostCatalog.quickConnectTarget(query: "deploy@10.0.0.5:2222", filter: .ssh)?.port == 2222)
  #expect(OpenQuicklyHostCatalog.quickConnectTarget(query: "[::1]:22", filter: .all)?.host == "::1")
  #expect(OpenQuicklyHostCatalog.quickConnectTarget(query: "java", filter: .ssh) == nil)
  #expect(OpenQuicklyHostCatalog.quickConnectTarget(query: "java:99999", filter: .ssh) == nil)
  #expect(OpenQuicklyHostCatalog.quickConnectTarget(query: "deploy@box", filter: .opened) == nil)
}

@Test("快连行插到 SSH 小节最前面；没有 alias 时紧跟主机")
func hostCatalogInsertsQuickConnectAtSSHSection() {
  let quick = OpenQuicklyHostCatalog.QuickConnectAction.allCases.map {
    OpenQuicklyItem(id: $0.id, kind: .ssh, title: $0.id)
  }
  let base = [
    OpenQuicklyItem(id: "tab", kind: .opened, title: "tab"),
    OpenQuicklyItem(id: "machine", kind: .machine, title: "m"),
    OpenQuicklyItem(id: "host", kind: .host, title: "h"),
    OpenQuicklyItem(id: "ssh:orb", kind: .ssh, title: "orb"),
    OpenQuicklyItem(id: "file", kind: .file, title: "f"),
  ]
  #expect(
    OpenQuicklyHostCatalog.inserting(quick, into: base).map(\.id)
      == ["tab", "machine", "host"] + quick.map(\.id) + ["ssh:orb", "file"])
  let withoutAlias = base.filter { $0.kind != .ssh }
  #expect(
    OpenQuicklyHostCatalog.inserting(quick, into: withoutAlias).map(\.id)
      == ["tab", "machine", "host"] + quick.map(\.id) + ["file"])
  #expect(OpenQuicklyHostCatalog.inserting(quick, into: []).map(\.id) == quick.map(\.id))
  // 搜索结果里已经有快连行（旧 ID）时不重复。
  #expect(OpenQuicklyHostCatalog.inserting(quick, into: base + quick).count == base.count + quick.count)
  #expect(OpenQuicklyHostCatalog.inserting([], into: base) == base)
}
