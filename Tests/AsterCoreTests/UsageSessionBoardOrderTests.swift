import Foundation
import Testing

@testable import AsterCore

@Suite("UsageSessionBoardOrder 排序与占用文案")
struct UsageSessionBoardOrderTests {
  /// 造一个排序输入。id 由固定前缀 + 序号生成，断言里好认。
  private func input(_ index: Int, _ status: AgentControlStatus, _ title: String)
    -> UsageSessionOrderInput
  {
    let suffix = String(format: "%012d", index)
    let uuid = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    return UsageSessionOrderInput(id: uuid, status: status, title: title)
  }

  @Test("按状态优先级排序：等待输入最前，未知垫底")
  func 状态优先级() {
    let inputs = [
      input(1, .unknown, "a"),
      input(2, .idle, "a"),
      input(3, .done, "a"),
      input(4, .working, "a"),
      input(5, .blocked, "a"),
    ]
    let order = UsageSessionBoardOrder.sorted(inputs)
    #expect(order == [inputs[4].id, inputs[3].id, inputs[2].id, inputs[1].id, inputs[0].id])
  }

  @Test("同级按标题稳定排序")
  func 同级按标题() {
    let inputs = [input(1, .working, "zeta"), input(2, .working, "alpha")]
    #expect(UsageSessionBoardOrder.sorted(inputs) == [inputs[1].id, inputs[0].id])
    // 输入顺序颠倒不改变结果。
    #expect(UsageSessionBoardOrder.sorted(inputs.reversed()) == [inputs[1].id, inputs[0].id])
  }

  @Test("同级同标题按 id 稳定排序")
  func 同级同标题() {
    let first = input(1, .idle, "same")
    let second = input(2, .idle, "same")
    #expect(UsageSessionBoardOrder.sorted([second, first]) == [first.id, second.id])
  }

  @Test("座位冻结：状态变化不换位")
  func 座位冻结() {
    let a = input(1, .idle, "a")
    let b = input(2, .idle, "b")
    let seats = UsageSessionBoardOrder.seats(previous: [], current: [a, b], reseat: true)
    #expect(seats == [a.id, b.id])
    // b 变成「等待输入」后优先级最高，但座位保持原样。
    let blockedB = input(2, .blocked, "b")
    let frozen = UsageSessionBoardOrder.seats(
      previous: seats, current: [a, blockedB], reseat: false)
    #expect(frozen == [a.id, b.id])
  }

  @Test("座位冻结：新会话追加到末尾")
  func 新会话追加() {
    let a = input(1, .idle, "a")
    let b = input(2, .idle, "b")
    let newcomer = input(3, .blocked, "c")
    let seats = UsageSessionBoardOrder.seats(
      previous: [a.id, b.id], current: [a, b, newcomer], reseat: false)
    #expect(seats == [a.id, b.id, newcomer.id])
  }

  @Test("座位冻结：多个新会话之间仍按优先级排")
  func 新会话之间排序() {
    let a = input(1, .idle, "a")
    let idleNew = input(2, .idle, "b")
    let blockedNew = input(3, .blocked, "c")
    let seats = UsageSessionBoardOrder.seats(
      previous: [a.id], current: [a, idleNew, blockedNew], reseat: false)
    #expect(seats == [a.id, blockedNew.id, idleNew.id])
  }

  @Test("座位冻结：消失的会话移除，其余保持顺序")
  func 消失移除() {
    let a = input(1, .idle, "a")
    let b = input(2, .idle, "b")
    let c = input(3, .idle, "c")
    let seats = UsageSessionBoardOrder.seats(
      previous: [a.id, b.id, c.id], current: [a, c], reseat: false)
    #expect(seats == [a.id, c.id])
  }

  @Test("reseat 时按优先级整体重排")
  func 重新落座() {
    let a = input(1, .idle, "a")
    let b = input(2, .blocked, "b")
    let seats = UsageSessionBoardOrder.seats(
      previous: [a.id, b.id], current: [a, b], reseat: true)
    #expect(seats == [b.id, a.id])
  }

  @Test("CPU 文案：取整、允许超过 100、缺数据为破折号")
  func CPU文案() {
    #expect(UsageSessionBoardOrder.cpuText(12.4) == "12%")
    #expect(UsageSessionBoardOrder.cpuText(12.6) == "13%")
    #expect(UsageSessionBoardOrder.cpuText(135.2) == "135%")
    #expect(UsageSessionBoardOrder.cpuText(0) == "0%")
    // 负值只可能来自计数器倒退，按 0 显示。
    #expect(UsageSessionBoardOrder.cpuText(-3) == "0%")
    #expect(UsageSessionBoardOrder.cpuText(nil) == "—")
    #expect(UsageSessionBoardOrder.cpuText(Double.nan) == "—")
  }

  @Test("内存文案：KB / MB / GB 分档与进位")
  func 内存文案() {
    #expect(UsageSessionBoardOrder.memoryText(nil) == "—")
    #expect(UsageSessionBoardOrder.memoryText(0) == "0 KB")
    #expect(UsageSessionBoardOrder.memoryText(700 * 1024) == "700 KB")
    #expect(UsageSessionBoardOrder.memoryText(512 * 1024 * 1024) == "512 MB")
    #expect(UsageSessionBoardOrder.memoryText(UInt64(1.4 * 1024 * 1024 * 1024)) == "1.4 GB")
    // 进位边界：四舍五入到 1024 MB 要改写成 1.0 GB。
    let almost = UInt64(1023.8 * 1024 * 1024)
    #expect(UsageSessionBoardOrder.memoryText(almost) == "1.0 GB")
  }
}
