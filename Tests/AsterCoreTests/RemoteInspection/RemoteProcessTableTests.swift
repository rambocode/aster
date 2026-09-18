// 进程表合并与排序的规则测试。

import Foundation
import Testing

@testable import AsterCore

private func sample(
  pid: Int32, cpu: Double, rssKiB: UInt64, command: String = "proc"
) -> RemoteProcessSample {
  RemoteProcessSample(
    pid: pid, cpuPercent: cpu, memoryPercent: 0, residentKiB: rssKiB, user: "root",
    command: command, arguments: command)
}

@Test func processTableMergesBothListsWithoutDuplicates() {
  let byCPU = [sample(pid: 1, cpu: 90, rssKiB: 100), sample(pid: 2, cpu: 50, rssKiB: 200)]
  // 只在内存榜里的进程：CPU 为 0，用单份 CPU 列表排序时会整条丢失。
  let byMemory = [sample(pid: 3, cpu: 0, rssKiB: 9_000), sample(pid: 1, cpu: 90, rssKiB: 100)]
  let merged = RemoteProcessTable.merged(
    byCPU: byCPU, byMemory: byMemory,
    sort: RemoteProcessSort(column: .memory, order: .descending))
  #expect(merged.map(\.pid) == [3, 2, 1])
}

@Test func processTableSortsBySelectedColumnAndOrder() {
  let rows = [
    sample(pid: 1, cpu: 10, rssKiB: 300),
    sample(pid: 2, cpu: 30, rssKiB: 100),
    sample(pid: 3, cpu: 20, rssKiB: 200),
  ]
  let byCPUDesc = RemoteProcessTable.merged(
    byCPU: rows, byMemory: [], sort: RemoteProcessSort(column: .cpu, order: .descending))
  #expect(byCPUDesc.map(\.pid) == [2, 3, 1])

  let byCPUAsc = RemoteProcessTable.merged(
    byCPU: rows, byMemory: [], sort: RemoteProcessSort(column: .cpu, order: .ascending))
  #expect(byCPUAsc.map(\.pid) == [1, 3, 2])

  let byMemoryDesc = RemoteProcessTable.merged(
    byCPU: rows, byMemory: [], sort: RemoteProcessSort(column: .memory, order: .descending))
  #expect(byMemoryDesc.map(\.pid) == [1, 3, 2])
}

@Test func processTableKeepsStableOrderForEqualValues() {
  let rows = [
    sample(pid: 9, cpu: 0, rssKiB: 10), sample(pid: 2, cpu: 0, rssKiB: 10),
    sample(pid: 5, cpu: 0, rssKiB: 10),
  ]
  let sorted = RemoteProcessTable.merged(
    byCPU: rows, byMemory: [], sort: RemoteProcessSort())
  #expect(sorted.map(\.pid) == [2, 5, 9])
}

@Test func processSortTogglesOrderOnSameColumnAndResetsOnSwitch() {
  let initial = RemoteProcessSort()
  #expect(initial.column == .cpu && initial.order == .descending)

  let cpuAscending = initial.selecting(.cpu)
  #expect(cpuAscending.order == .ascending)

  // 换列回到降序：占用率表格里用户找的总是最高的那几行。
  let memory = cpuAscending.selecting(.memory)
  #expect(memory.column == .memory && memory.order == .descending)
}

@Test func processTableRespectsRowLimit() {
  let rows = (1...40).map { sample(pid: Int32($0), cpu: Double($0), rssKiB: 1) }
  let merged = RemoteProcessTable.merged(byCPU: rows, byMemory: [], sort: RemoteProcessSort())
  #expect(merged.count == RemoteProcessTable.maximumRows)
}
