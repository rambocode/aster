import AppKit
import CoreVideo
import AsterCore
import Testing
@testable import Aster

/// UI 回归必须观察产品实际挂载的 Ghostty，不能新建未挂载的 SwiftTerm 兼容视图。
@MainActor
func liveGhosttyView(for session: TerminalSession, preferences: AppPreferences) throws -> GhosttySurfaceView {
  func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  return try #require(descendants(session.makeTerminalHost(preferences: preferences))
    .compactMap { $0 as? GhosttySurfaceView }.first)
}

/// 保留 Session 的真实输入观察回调，测试只旁听已编码的 PTY 字节。
@MainActor
func observeTestPTYWrites(_ view: GhosttySurfaceView, record: @escaping ([UInt8]) -> Void) {
  let previous = view.onPTYWrite
  view.onPTYWrite = { bytes in
    previous?(bytes)
    record(Array(bytes))
  }
}

/// 检查真实 Metal 帧的大块底色，避免仅验证已经更新但尚未用于渲染的配置对象。
@MainActor
func ghosttyRendersBackground(_ view: GhosttySurfaceView, color: HexColor) async throws -> Bool {
  view.pictureInPictureFrames.start()
  defer { view.pictureInPictureFrames.stop() }
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
    view.renderNow()
    if let frame = view.pictureInPictureFrames.takeLatest(), backgroundMatches(frame, color: color) {
      return true
    }
    try await Task.sleep(for: .milliseconds(25))
  }
  return false
}

private func backgroundMatches(_ frame: CVPixelBuffer, color: HexColor) -> Bool {
  guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
        CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return false }
  defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
  guard let base = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else {
    return false
  }
  let rowBytes = CVPixelBufferGetBytesPerRow(frame)
  let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
  guard width > 0, height > 0 else { return false }
  var matching = 0, sampled = 0
  for y in stride(from: 0, to: height, by: 8) {
    for x in stride(from: 0, to: width, by: 8) {
      let offset = y * rowBytes + x * 4
      if abs(Int(base[offset]) - Int(color.blue)) <= 3
        && abs(Int(base[offset + 1]) - Int(color.green)) <= 3
        && abs(Int(base[offset + 2]) - Int(color.red)) <= 3 { matching += 1 }
      sampled += 1
    }
  }
  return matching * 100 > sampled * 70
}

/// 记录实际终端视图的尺寸变化；不把位置变化或重复布局当成新的 resize。
@MainActor
final class TestTerminalGeometryRecorder: NSObject {
  private weak var view: NSView?
  private var lastSize: NSSize
  private(set) var sizes: [NSSize] = []

  init(view: NSView) {
    self.view = view
    lastSize = view.frame.size
    super.init()
    view.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(frameChanged),
                                          name: NSView.frameDidChangeNotification, object: view)
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  @objc private func frameChanged(_ notification: Notification) {
    guard let view, view.frame.size != lastSize else { return }
    lastSize = view.frame.size
    sizes.append(lastSize)
  }
}
