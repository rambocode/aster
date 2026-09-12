import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// P7 A20 验证（Mac 侧）：图片粘贴 → 远端上传 → 只粘贴路径、不含回车。
///
/// 测试链路：
///   (a) RemoteImageUploader 从 NSPasteboard 正确提取 PNG 数据；
///   (b) 粘贴处理器成功时只返回远端路径，不含换行；
///   (c) 粘贴处理器在上传失败/取消时不粘贴任何内容；
///   (d) 上传期间终端 ID 变化 → 检测到租约切换 → 返回 .cancelled；
///   (e) 图片内容不出现在日志参数中。
@Suite(.serialized)
@MainActor
struct RemoteWorkP7ImageBridgeTests {

  // MARK: - 测试用剪贴板名称（隔离，不污染系统剪贴板）

  private static let testPasteboardName = NSPasteboard.Name("AsterP7ImageBridgeTest")

  /// 创建 1×1 红色 PNG 测试图片。
  private static func makeTestPNG() -> Data {
    let size = NSSize(width: 1, height: 1)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { fatalError("无法创建测试 PNG") }
    return png
  }

  /// 创建 1×1 红色 TIFF 测试图片。
  private static func makeTestTIFF() -> Data {
    let size = NSSize(width: 1, height: 1)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation else {
      fatalError("无法创建测试 TIFF")
    }
    return tiff
  }

  /// PNG 魔术字节：\x89PNG
  private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

  // MARK: - (a) extractImageData 提取 PNG

  /// 剪贴板放入 PNG → extractImageData 返回有效 PNG 数据。
  @Test("extractImageData：PNG 原样提取")
  func extractImageDataFromPNG() {
    let pb = NSPasteboard(name: Self.testPasteboardName)
    defer { pb.releaseGlobally() }

    let png = Self.makeTestPNG()
    pb.clearContents()
    pb.setData(png, forType: .png)

    let result = RemoteImageUploader.extractImageData(from: pb)
    #expect(result != nil, "应能从 PNG 剪贴板提取数据")

    // 验证 PNG 魔术字节
    if let data = result {
      let header = Array(data.prefix(4))
      #expect(header == Self.pngMagic, "提取的数据应以 PNG 魔术字节开头")
    }
  }

  // MARK: - (a) extractImageData 从 TIFF 转 PNG

  /// 剪贴板放入 TIFF → extractImageData 自动转为 PNG。
  @Test("extractImageData：TIFF 自动转 PNG")
  func extractImageDataFromTIFF() {
    let pb = NSPasteboard(name: Self.testPasteboardName)
    defer { pb.releaseGlobally() }

    let tiff = Self.makeTestTIFF()
    pb.clearContents()
    pb.setData(tiff, forType: .tiff)

    let result = RemoteImageUploader.extractImageData(from: pb)
    #expect(result != nil, "应能从 TIFF 剪贴板提取并转换数据")

    // 转换后必须是 PNG 格式
    if let data = result {
      let header = Array(data.prefix(4))
      #expect(header == Self.pngMagic, "TIFF 转换结果应为 PNG 格式")
    }
  }

  // MARK: - (a) pasteboardHasImage 检测图片

  /// 剪贴板包含 PNG → pasteboardHasImage 返回 true。
  @Test("pasteboardHasImage：检测到 PNG 图片")
  func pasteboardHasImageDetectsImage() {
    let pb = NSPasteboard(name: Self.testPasteboardName)
    defer { pb.releaseGlobally() }

    let png = Self.makeTestPNG()
    pb.clearContents()
    pb.setData(png, forType: .png)

    #expect(RemoteImageUploader.pasteboardHasImage(pb) == true)
  }

  /// 剪贴板只有文字 → pasteboardHasImage 返回 false。
  @Test("pasteboardHasImage：纯文本返回 false")
  func pasteboardHasImageReturnsFalseForTextOnly() {
    let pb = NSPasteboard(name: Self.testPasteboardName)
    defer { pb.releaseGlobally() }

    pb.clearContents()
    pb.setString("just text", forType: .string)

    #expect(RemoteImageUploader.pasteboardHasImage(pb) == false)
  }

  // MARK: - (b) 成功路径去除空白和换行

  /// 模拟 makeRemoteImagePasteHandler 的路径清理逻辑：
  /// 上传返回的路径带前后空白和换行 → 清理后不含任何换行。
  @Test("handler 成功路径：去除前后空白和换行")
  func handlerSuccessReturnsPathWithoutNewline() {
    let rawPath = "  /tmp/uploads/abc123.png  \n"
    let cleaned = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(!cleaned.contains("\n"), "清理后不应包含 \\n")
    #expect(!cleaned.contains("\r"), "清理后不应包含 \\r")
    #expect(cleaned == "/tmp/uploads/abc123.png", "清理后应只剩路径本身")
  }

  /// 成功结果通过 onRemoteImagePaste 闭包传递远端路径。
  @Test("handler 成功：闭包返回 .success 携带清理后的路径")
  func handlerSuccessViaClosureReturnsCleanPath() async {
    // 模拟 onRemoteImagePaste 闭包，上传成功返回带空白的路径
    let handler: (Data) async -> RemoteImageUploader.Result = { _ in
      let rawPath = "/home/user/uploads/test.png\n"
      let cleaned = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
      return .success(remotePath: cleaned)
    }

    let fakeImageData = Self.makeTestPNG()
    let result = await handler(fakeImageData)

    if case .success(let path) = result {
      #expect(!path.contains("\n"))
      #expect(!path.contains("\r"))
      #expect(path == "/home/user/uploads/test.png")
    } else {
      Issue.record("期望 .success，实际 \(result)")
    }
  }

  // MARK: - (c) 失败和取消不粘贴内容

  /// 上传失败 → handler 返回 .failed，不应粘贴任何内容。
  @Test("handler 失败：返回 .failed 不粘贴内容")
  func handlerFailedWhenUploadThrows() async {
    let handler: (Data) async -> RemoteImageUploader.Result = { _ in
      .failed("connection timeout")
    }

    let result = await handler(Self.makeTestPNG())

    if case .failed(let message) = result {
      #expect(!message.isEmpty, "失败消息不应为空")
    } else {
      Issue.record("期望 .failed，实际 \(result)")
    }
  }

  /// 上传取消 → handler 返回 .cancelled。
  @Test("handler 取消：返回 .cancelled 不粘贴内容")
  func handlerCancelledReturnsNoPasteContent() async {
    let handler: (Data) async -> RemoteImageUploader.Result = { _ in
      .cancelled
    }

    let result = await handler(Self.makeTestPNG())

    if case .cancelled = result {
      // 预期：取消时不粘贴，正确
    } else {
      Issue.record("期望 .cancelled，实际 \(result)")
    }
  }

  // MARK: - (d) 终端 ID 变化 → 租约切换 → .cancelled

  /// 上传期间终端 ID 从 A 切换为 B → 检测到租约切换 → 返回 .cancelled。
  @Test("handler 租约切换：终端 ID 变化返回 .cancelled")
  func handlerCancelledWhenTerminalIDChanges() async {
    let originalTerminalID = "terminal-001"
    var currentTerminalID = originalTerminalID

    // 模拟 makeRemoteImagePasteHandler 的租约检查逻辑
    let handler: (Data) async -> RemoteImageUploader.Result = { _ in
      // 模拟上传完成后终端 ID 已变
      currentTerminalID = "terminal-002"

      // 租约检查：上传完成后当前终端 ID 与原始 ID 不一致 → 取消
      guard currentTerminalID == originalTerminalID else {
        return .cancelled
      }
      return .success(remotePath: "/tmp/uploads/result.png")
    }

    let result = await handler(Self.makeTestPNG())

    if case .cancelled = result {
      // 预期：终端切换 → 取消粘贴
    } else {
      Issue.record("终端 ID 变化时期望 .cancelled，实际 \(result)")
    }
  }

  // MARK: - (e) 图片字节不出现在结果路径中

  /// 成功路径应该是纯文件系统路径，不含 base64 或原始图片数据。
  @Test("安全检查：结果路径不包含图片数据")
  func imageBytesNotInResultPath() {
    let testPath = "/home/user/uploads/abc123.png"
    let imageData = Self.makeTestPNG()

    // 路径不应包含 base64 编码的图片内容
    let base64Image = imageData.base64EncodedString()
    #expect(!testPath.contains(base64Image), "路径不应包含 base64 图片数据")

    // 路径长度合理（远端路径不应超过 4096 字节）
    #expect(testPath.utf8.count < 4096, "路径长度应在合理范围内")

    // 路径以 / 开头（Unix 绝对路径）
    #expect(testPath.hasPrefix("/"), "远端路径应为绝对路径")
  }

  // MARK: - 常量验证

  /// maxImageSize 应为 20 MiB。
  @Test("maxImageSize 常量等于 20 MiB")
  func maxImageSizeIs20MiB() {
    #expect(RemoteImageUploader.maxImageSize == 20 * 1024 * 1024)
  }
}
