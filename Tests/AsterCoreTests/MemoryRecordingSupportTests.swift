import Foundation
import Testing

@testable import AsterCore

// MARK: - 磁盘布局

@Test("transcript 路径固定为 transcripts/<session>/<seq>.txt 且是相对路径")
func transcriptLayoutIsRelative() {
  let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  let path = MemoryTranscriptLayout.relativePath(sessionID: session, sequence: 7)
  #expect(path == "transcripts/11111111-2222-3333-4444-555555555555/7.txt")
  #expect(!path.hasPrefix("/"))
  #expect(
    MemoryTranscriptLayout.sessionDirectory(sessionID: session)
      == "transcripts/11111111-2222-3333-4444-555555555555")
}

@Test("负序号被钳到 0，不会生成越出 session 目录的路径")
func transcriptLayoutClampsNegativeSequence() {
  let path = MemoryTranscriptLayout.relativePath(sessionID: UUID(), sequence: -5)
  #expect(path.hasSuffix("/0.txt"))
  #expect(!path.contains(".."))
}

// MARK: - git 快照 payload

@Test("git 快照 payload 往返编解码保持字段")
func gitSnapshotPayloadRoundTrips() {
  let payload = GitSnapshotPayload(branch: "main", commit: "abc123", dirtyFileCount: 4)
  let json = payload.jsonString()
  #expect(json != nil)
  #expect(GitSnapshotPayload.decode(json!) == payload)
}

@Test("git 快照的空状态被判为无意义，不产生噪音事件")
func gitSnapshotPayloadRejectsEmptyState() {
  #expect(GitSnapshotPayload(dirtyFileCount: 0).isMeaningful == false)
  #expect(GitSnapshotPayload(branch: "main").isMeaningful)
  #expect(GitSnapshotPayload(commit: "deadbeef").isMeaningful)
  #expect(GitSnapshotPayload(dirtyFileCount: 1).isMeaningful)
}

@Test("脏文件数不接受负值")
func gitSnapshotPayloadClampsDirtyCount() {
  #expect(GitSnapshotPayload(dirtyFileCount: -3).dirtyFileCount == 0)
}

@Test("非本类型的 payload 解码返回 nil")
func gitSnapshotPayloadRejectsForeignJSON() {
  #expect(GitSnapshotPayload.decode("not json") == nil)
}

// MARK: - 限频

@Test("限频闸门在最短间隔内只放行一次")
func throttleAllowsOncePerInterval() {
  var throttle = RecordingThrottle(minimumInterval: 5)
  let base = Date(timeIntervalSince1970: 1_000)
  // mutating 调用不能直接写在 #expect 里（宏展开会把接收者变成不可变副本）。
  let first = throttle.allow(at: base)
  let tooSoon = throttle.allow(at: base.addingTimeInterval(1))
  let stillTooSoon = throttle.allow(at: base.addingTimeInterval(4.9))
  let atBoundary = throttle.allow(at: base.addingTimeInterval(5))
  let afterBoundary = throttle.allow(at: base.addingTimeInterval(6))
  #expect(first)
  #expect(tooSoon == false)
  #expect(stillTooSoon == false)
  #expect(atBoundary)
  #expect(afterBoundary == false)
}

@Test("间隔为 0 的闸门每次都放行")
func throttleWithZeroIntervalAlwaysAllows() {
  var throttle = RecordingThrottle(minimumInterval: 0)
  let base = Date(timeIntervalSince1970: 0)
  let first = throttle.allow(at: base)
  let second = throttle.allow(at: base)
  #expect(first)
  #expect(second)
}

@Test("配额扫描按累计字节触发并在触发后清零")
func quotaTrackerSweepsByAccumulatedBytes() {
  var tracker = ArtifactQuotaTracker(bytesBetweenSweeps: 100)
  let first = tracker.shouldSweep(afterWriting: 40)
  let second = tracker.shouldSweep(afterWriting: 40)
  let third = tracker.shouldSweep(afterWriting: 40)
  // 触发后累计值归零，不会连续触发。
  let fourth = tracker.shouldSweep(afterWriting: 40)
  #expect(first == false)
  #expect(second == false)
  #expect(third)
  #expect(fourth == false)
}

@Test("配额上限为 512 MiB")
func quotaDefaultIs512MiB() {
  #expect(ArtifactQuotaTracker.defaultQuotaBytes == 512 * 1_024 * 1_024)
}

// MARK: - 摘录截取

@Test("短文本原样返回，首尾空白被裁掉")
func excerptKeepsShortText() {
  #expect(MemoryOutputExcerpt.tail(of: "  hello \n") == "hello")
}

@Test("空白文本不产生摘录")
func excerptRejectsBlankText() {
  #expect(MemoryOutputExcerpt.tail(of: "   \n\t ") == nil)
  #expect(MemoryOutputExcerpt.tail(of: "") == nil)
}

@Test("超长文本按 UTF-8 字节截尾且不超上限")
func excerptTruncatesByBytes() {
  let text = String(repeating: "a", count: 10_000)
  let excerpt = MemoryOutputExcerpt.tail(of: text, maximumBytes: 4_096)
  #expect(excerpt?.utf8.count == 4_096)
  // 截尾不截头：错误信息在末尾。
  #expect(excerpt?.hasSuffix("a") == true)
}

@Test("多字节文本截断后仍是合法 UTF-8，不出现替换字符")
func excerptKeepsValidUTF8() {
  // 每个「界」是 3 字节；上限取 10 会落在字符中间，必须向后对齐。
  let text = String(repeating: "界", count: 100)
  let excerpt = MemoryOutputExcerpt.tail(of: text, maximumBytes: 10)
  #expect(excerpt != nil)
  #expect(excerpt!.contains("\u{FFFD}") == false)
  #expect(excerpt!.utf8.count == 9)
  #expect(excerpt! == "界界界")
}

// MARK: - 策略叠加

@Test("隐身覆盖把任何模式都变成零落盘")
func incognitoOverrideStopsDiskWrites() {
  let on = RecordingPolicy(mode: .on, excludedPathPrefixes: ["/secret"])
  #expect(on.writesToDisk)
  let hidden = on.overriddenByIncognito(true)
  #expect(hidden.mode == .incognito)
  #expect(hidden.writesToDisk == false)
  // 排除列表不因隐身而丢失，退出隐身后依然生效。
  #expect(hidden.excludedPathPrefixes == ["/secret"])
}

@Test("隐身只能收紧不能放松：全局关闭时不因取消隐身而开启")
func incognitoOverrideOnlyTightens() {
  let off = RecordingPolicy(mode: .off)
  #expect(off.overriddenByIncognito(false).writesToDisk == false)
  #expect(off.overriddenByIncognito(true).mode == .incognito)
}

@Test("off 与 incognito 都不落盘，只有 on 落盘")
func onlyOnModeWritesToDisk() {
  #expect(RecordingPolicy(mode: .off).writesToDisk == false)
  #expect(RecordingPolicy(mode: .incognito).writesToDisk == false)
  #expect(RecordingPolicy(mode: .on).writesToDisk)
}
