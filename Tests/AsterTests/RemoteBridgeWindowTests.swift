import AppKit
import CoreImage
import CoreVideo
import Darwin
import Foundation
import Testing
@testable import Aster

/// Explicit P0 integration run; routine tests do not implicitly build/install Zig.
/// Enable with ASTER_SESSION_PROBE_BINARY pointing at the freshly built runtime.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASTER_SESSION_PROBE_BINARY"] != nil))
@MainActor
func remoteBridgeRendersAndReattachesInGhosttyWindow() async throws {
  _ = NSApplication.shared
  let binary = try #require(ProcessInfo.processInfo.environment["ASTER_SESSION_PROBE_BINARY"])
  let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("aster-window-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: folder) }
  let socket = folder.appendingPathComponent("session.sock")
  let pidFile = folder.appendingPathComponent("child.pid")
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let png = try Data(contentsOf: root.appendingPathComponent("SessionRuntime/src/testdata/rgba.png")).base64EncodedString()
  let server = Process()
  server.executableURL = URL(fileURLWithPath: binary)
  let imageCommand = "printf '\\033_Ga=T,f=100,i=17,p=3,c=10,r=4,C=1,q=2;%s\\033\\\\' " + shellWord(png)
  server.arguments = ["probe-serve", socket.path, folder.path, "/bin/sh", "-c",
    "echo $$ > child.pid.tmp; mv child.pid.tmp child.pid; printf READY; while IFS= read -r line; do if [ \"$line\" = image ]; then " + imageCommand + "; printf 'IMAGE_DONE\\n'; else printf 'ANSWER:%s\\n' \"$line\"; fi; done"]
  server.standardOutput = FileHandle.nullDevice
  server.standardError = FileHandle.nullDevice
  try server.run()
  defer {
    // The owned server has default SIGTERM behavior. Closing its PTY master
    // hangs up its shell; avoid signalling a possibly reaped/reused child PID.
    if server.isRunning { server.terminate() }
    server.waitUntilExit()
  }
  try await bridgeWait { FileManager.default.fileExists(atPath: pidFile.path) }
  let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

  let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 420),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  window.title = "Aster remote bridge — P0 integration"
  window.isReleasedWhenClosed = false
  defer { window.orderOut(nil); window.close() }

  func mount() -> GhosttySurfaceView {
    let view = GhosttySurfaceView(workingDirectory: folder.path,
                                 environment: ["PATH": "/usr/bin:/bin"], configurationText: "font-size = 13\nbackground = 262b33\nforeground = eeeeee")
    view.pictureInPictureFrames.start()
    view.command = shellWord(binary) + " probe-bridge " + shellWord(socket.path)
    view.frame = window.contentView?.bounds ?? .zero
    view.autoresizingMask = [.width, .height]
    window.contentView?.addSubview(view)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    window.layoutIfNeeded()
    view.createSurface()
    return view
  }

  let first = mount()
  defer { first.pictureInPictureFrames.stop(); first.destroySurface() }
  try await bridgeWait { first.readText(includeScrollback: false)?.contains("READY") == true }
  #expect(first.typeText("窗口桥接\n"))
  try await bridgeWait { first.readText(includeScrollback: false)?.contains("ANSWER:窗口桥接") == true }
  #expect(first.typeText("image\n"))
  try await bridgeWait { first.readText(includeScrollback: false)?.contains("IMAGE_DONE") == true }
  var captured: CVPixelBuffer?
  try await bridgeWait {
    first.renderNow()
    guard let frame = first.pictureInPictureFrames.takeLatest(), bridgeRedPixels(frame) > 400 else { return false }
    captured = frame
    return true
  }
  let frame = try #require(captured)
  let context = CIContext()
  let image = CIImage(cvPixelBuffer: frame)
  let cgImage = try #require(context.createCGImage(image, from: image.extent))
  let encoded = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
  try encoded.write(to: root.appendingPathComponent(".build/remote-bridge-image.png"), options: .atomic)
  first.pictureInPictureFrames.stop()
  first.destroySurface()
  first.removeFromSuperview()
  #expect(kill(pid, 0) == 0)
  try await Task.sleep(for: .milliseconds(100))
  let second = mount()
  defer { second.pictureInPictureFrames.stop(); second.destroySurface() }
  try await bridgeWait { second.readText(includeScrollback: false)?.contains("ANSWER:窗口桥接") == true }
  #expect(kill(pid, 0) == 0)
  try await bridgeWait {
    second.renderNow()
    guard let frame = second.pictureInPictureFrames.takeLatest() else { return false }
    return bridgeRedPixels(frame) > 400
  }
  #expect(second.typeText("重新连接\n"))
  try await bridgeWait { second.readText(includeScrollback: false)?.contains("ANSWER:重新连接") == true }
}

@MainActor
private func bridgeWait(_ condition: () -> Bool) async throws {
  for _ in 0..<250 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(condition(), "Timed out waiting for the real bridge/VT state")
}

private func shellWord(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}


private func bridgeRedPixels(_ frame: CVPixelBuffer) -> Int {
  guard CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return 0 }
  defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
  guard let base = CVPixelBufferGetBaseAddress(frame)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
  let stride = CVPixelBufferGetBytesPerRow(frame)
  var count = 0
  for y in 0..<CVPixelBufferGetHeight(frame) {
    for x in 0..<CVPixelBufferGetWidth(frame) {
      let offset = y * stride + x * 4
      if base[offset + 2] > 180 && base[offset + 1] < 90 && base[offset] < 90 { count += 1 }
    }
  }
  return count
}
