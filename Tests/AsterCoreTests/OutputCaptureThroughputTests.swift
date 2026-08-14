import Foundation
import Testing

@testable import AsterCore

/// Session Recording 输出管线的计算主体吞吐基准：
/// ShellCommandOutputCapture 状态机 + ANSICleaner + Redactor。
/// 该路径运行在 utility 队列上，不占主线程；基准保证洪峰输出（10MB/命令上限截断前）
/// 不会造成后台积压。
@Suite struct OutputCaptureThroughputTests {
  @Test("10MB PTY 输出经捕获、清理与脱敏在 2 秒内完成")
  func tenMegabyteThroughput() {
    var capture = ShellCommandOutputCapture()
    // OSC 133 C 开始捕获。
    _ = capture.consume(ArraySlice("\u{1B}]133;C\u{07}".utf8))
    let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 64 * 1_024)
    let start = Date()
    for _ in 0..<160 {  // 160 × 64KiB = 10MB
      _ = capture.consume(chunk[...])
    }
    let completed = capture.consume(ArraySlice("\u{1B}]133;D;0\u{07}".utf8))
    #expect(completed.count == 1)
    // 环形缓冲上限 128KiB：洪峰输出只保留尾部，不随总量增长。
    #expect(completed[0].text.utf8.count <= 128 * 1_024)
    let visible = ANSICleaner.visibleText(from: completed[0].text)
    let redacted = AgentContextRedactor.redact(visible).value
    _ = redacted
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 2.0)
  }
}
