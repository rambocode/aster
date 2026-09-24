import Foundation
import Testing

@testable import AsterCore

// 机器绑定已保存主机（MachineProfile.hostID）的持久化与差异规则。

@Test("机器 hostID：有值才写出，读回一致；未绑定的配置不出现该键")
func machineHostBindingRoundTrip() throws {
  let hostID = UUID()
  let bound = MachineProfile(
    label: "orb", sshTarget: "root@127.0.0.1", sessionName: "work", hostID: hostID)
  let plain = MachineProfile(label: "lab", sshTarget: "lab", sessionName: "default")
  let data = try MachineProfileStore.encode([bound, plain])
  let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  #expect(objects[0]["hostID"] as? String == hostID.uuidString)
  // 未绑定时不写键：旧版本见到未知键会整份拒绝，未用新功能的配置必须保持可降级。
  #expect(objects[1]["hostID"] == nil)
  #expect(try MachineProfileStore.decode(data) == [bound, plain])

  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("aster-host-binding-\(UUID().uuidString)/machines.json")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = MachineProfileStore(fileURL: url)
  try store.save([bound, plain])
  #expect(try MachineProfileStore(fileURL: url).load() == .loaded([bound, plain]))
}

@Test("机器 hostID：非法取值整份拒绝")
func machineHostBindingRejectsInvalidHostID() {
  let json = """
    [{"id":"\(UUID().uuidString)","label":"orb","sessionName":"work","enabled":true,"hostID":"not-a-uuid"}]
    """
  #expect(throws: MachineProfileStoreError.invalidProfiles(reasons: ["[0] invalid hostID"])) {
    try MachineProfileStore.decode(Data(json.utf8))
  }
}

@Test("机器 hostID：绑定或解绑主机算连接变更，只改标签不算")
func machineHostBindingDiffTreatsHostAsConnectionField() {
  let id = UUID()
  let base = MachineProfile(id: id, label: "orb", sshTarget: "orb", sessionName: "work")
  var bound = base
  bound.hostID = UUID()
  var rebound = bound
  rebound.hostID = UUID()
  var renamed = bound
  renamed.label = "orb-2"

  #expect(MachineProfileStore.diff(old: [base], new: [bound]) == [.connectionChanged(id)])
  #expect(MachineProfileStore.diff(old: [bound], new: [rebound]) == [.connectionChanged(id)])
  #expect(MachineProfileStore.diff(old: [bound], new: [base]) == [.connectionChanged(id)])
  #expect(MachineProfileStore.diff(old: [bound], new: [renamed]).isEmpty)
}
