import CoreVideo
import IOSurface
import Testing

@testable import Aster

private func makePictureInPictureSurface(format: OSType = kCVPixelFormatType_32BGRA) throws
  -> IOSurfaceRef
{
  try #require(IOSurfaceCreate([
    kIOSurfaceWidth: 4, kIOSurfaceHeight: 3, kIOSurfaceBytesPerElement: 4,
    kIOSurfacePixelFormat: format,
  ] as CFDictionary))
}

@Test("PiP 帧邮箱深复制像素，源 surface 复用后已交付帧保持不变")
func pictureInPictureFrameCopySurvivesSourceReuse() throws {
  let inbox = GhosttyPictureInPictureFrames()
  let source = try makePictureInPictureSurface()
  #expect(!inbox.reserveFrame(now: 0))
  inbox.start()
  #expect(inbox.reserveFrame(now: 0))
  #expect(!inbox.reserveFrame(now: 0.01))
  #expect(inbox.reserveFrame(now: 0.1))
  IOSurfaceLock(source, [], nil)
  memset(IOSurfaceGetBaseAddress(source), 0xA7, IOSurfaceGetAllocSize(source))
  IOSurfaceUnlock(source, [], nil)
  inbox.receive(source)
  let first = try #require(inbox.takeLatest())
  #expect(inbox.takeLatest() == nil)
  IOSurfaceLock(source, [], nil)
  memset(IOSurfaceGetBaseAddress(source), 0xB8, IOSurfaceGetAllocSize(source))
  IOSurfaceUnlock(source, [], nil)
  inbox.receive(source)
  let second = try #require(inbox.takeLatest())
  CVPixelBufferLockBaseAddress(first, .readOnly)
  CVPixelBufferLockBaseAddress(second, .readOnly)
  defer {
    CVPixelBufferUnlockBaseAddress(first, .readOnly)
    CVPixelBufferUnlockBaseAddress(second, .readOnly)
  }
  let firstBytes = try #require(CVPixelBufferGetBaseAddress(first))
  let secondBytes = try #require(CVPixelBufferGetBaseAddress(second))
  for row in 0..<3 {
    for columnByte in 0..<16 {
      #expect(firstBytes.load(fromByteOffset: row * CVPixelBufferGetBytesPerRow(first) + columnByte,
        as: UInt8.self) == 0xA7)
      #expect(secondBytes.load(fromByteOffset: row * CVPixelBufferGetBytesPerRow(second) + columnByte,
        as: UInt8.self) == 0xB8)
    }
  }
  inbox.stop()
  inbox.receive(source)
  #expect(inbox.takeLatest() == nil)
  #expect(!inbox.reserveFrame(now: 10))
}

@Test("PiP 拒绝不支持的像素格式，关闭后清除错误与待消费帧")
func pictureInPictureRejectsUnsupportedFrames() throws {
  let inbox = GhosttyPictureInPictureFrames()
  inbox.start()
  inbox.receive(try makePictureInPictureSurface(format: kCVPixelFormatType_32RGBA))
  #expect(inbox.takeLatest() == nil)
  #expect(inbox.takeFailure() != nil)
  #expect(inbox.takeFailure() == nil)
  inbox.receive(try makePictureInPictureSurface())
  inbox.stop()
  #expect(inbox.takeLatest() == nil)
  #expect(inbox.takeFailure() == nil)
}
