import AppKit
import AsterCore
import Foundation

/// 远端图片上传工具：剪贴板图片提取与格式转换。
///
/// 上传逻辑在 `ManagedTerminalCoordinator.uploadImageAsync` 和
/// `ManagedSessionClient.uploadImage` 中实现；本类只负责 AppKit 剪贴板操作。
@MainActor
final class RemoteImageUploader {
  /// 单张图片大小上限：20 MiB。
  static let maxImageSize = 20 * 1024 * 1024

  /// 上传结果。
  enum Result {
    case success(remotePath: String)
    case cancelled
    case failed(String)
  }

  /// 从 NSPasteboard 提取 PNG 图片数据。优先取 PNG，TIFF 转 PNG。
  static func extractImageData(from pasteboard: NSPasteboard) -> Data? {
    // 优先 PNG
    if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
      return pngData
    }
    // TIFF 转 PNG：截图等操作产出的是 TIFF
    if let tiffData = pasteboard.data(forType: .tiff),
      let rep = NSBitmapImageRep(data: tiffData),
      let pngData = rep.representation(using: .png, properties: [:]),
      !pngData.isEmpty
    {
      return pngData
    }
    return nil
  }

  /// 剪贴板是否包含图片数据（不含纯文本形式的粘贴）。
  static func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
  }
}
