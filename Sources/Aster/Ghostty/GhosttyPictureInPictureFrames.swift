import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

/// GPU 完成回调与主线程之间的单帧邮箱。只在 PiP 开启时复制，最多 15 fps / 1600 万像素，
/// 新帧替换尚未消费的旧帧，绝不向主队列排入无界任务。关闭会丢弃在途复制的结果。
final class GhosttyPictureInPictureFrames: @unchecked Sendable {
  static let maximumPixels = 16_777_216
  private let lock = NSLock()
  private var enabled = false
  private var generation: UInt64 = 0
  private var nextCaptureTime: TimeInterval = 0
  private var latest: CVPixelBuffer?
  private var failure: String?

  func start() {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    enabled = true
    nextCaptureTime = 0
    latest = nil
    failure = nil
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    enabled = false
    latest = nil
    failure = nil
  }

  /// Metal 编码结束前预留一帧；返回 false 时 renderer 不做额外的 GPU/CPU 同步。
  func reserveFrame(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard enabled, now >= nextCaptureTime else { return false }
    nextCaptureTime = now + 1.0 / 15
    return true
  }

  /// 在 renderer 释放 swap-chain 槽之前同步完成深复制；不能保留源 IOSurface 给 AVKit，
  /// 因为 Ghostty 会复用它。该入口不接触 AppKit，不等待主线程，也不执行 UI 操作。
  func receive(_ surface: IOSurfaceRef) {
    lock.lock()
    let ticket = generation
    let shouldCopy = enabled
    lock.unlock()
    guard shouldCopy else { return }
    let result = Self.copyFrame(surface)
    lock.lock()
    defer { lock.unlock() }
    guard enabled, generation == ticket else { return }
    switch result {
    case .success(let buffer): latest = buffer
    case .failure(let error): failure = error.localizedDescription
    }
  }

  func takeLatest() -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    defer { latest = nil }
    return latest
  }

  func takeFailure() -> String? {
    lock.lock()
    defer { lock.unlock() }
    defer { failure = nil }
    return failure
  }

  private enum CaptureError: LocalizedError {
    case unsupportedFrame, copyFailed
    var errorDescription: String? {
      switch self {
      case .unsupportedFrame: "终端帧尺寸或像素格式不受画中画支持"
      case .copyFailed: "无法复制终端画中画帧"
      }
    }
  }

  private static func copyFrame(_ surface: IOSurfaceRef) -> Result<CVPixelBuffer, CaptureError> {
    let width = IOSurfaceGetWidth(surface)
    let height = IOSurfaceGetHeight(surface)
    guard width > 0, height > 0, width <= maximumPixels / height,
      IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA,
      IOSurfaceGetPlaneCount(surface) == 0,
      IOSurfaceGetBytesPerRow(surface) >= width * 4
    else { return .failure(.unsupportedFrame) }
    var output: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      attributes as CFDictionary, &output) == kCVReturnSuccess,
      let output,
      CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess
    else { return .failure(.copyFailed) }
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    guard IOSurfaceLock(surface, .readOnly, nil) == 0 else { return .failure(.copyFailed) }
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let source = IOSurfaceGetBaseAddress(surface)
    guard let destination = CVPixelBufferGetBaseAddress(output)
    else { return .failure(.copyFailed) }
    for row in 0..<height {
      memcpy(destination.advanced(by: row * CVPixelBufferGetBytesPerRow(output)),
        source.advanced(by: row * IOSurfaceGetBytesPerRow(surface)), width * 4)
    }
    // Pinned Ghostty Target 使用 Display P3 / BGRA；把颜色空间传给 AVKit，避免浅色主题偏色。
    if let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) {
      CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
    }
    CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
      kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
    CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    return .success(output)
  }
}

extension GhosttySurfaceView {
  /// 可选的 pinned renderer 扩展：由 GPU 完成线程调用。两个方法都只访问线程安全邮箱。
  @objc nonisolated func asterWantsPictureInPictureFrame() -> Bool {
    pictureInPictureFrames.reserveFrame()
  }

  @objc nonisolated func asterDidRenderPictureInPictureFrame(_ pointer: UnsafeRawPointer) {
    let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
    pictureInPictureFrames.receive(surface)
  }
}
