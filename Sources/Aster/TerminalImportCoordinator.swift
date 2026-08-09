import AppKit
import Darwin
import Foundation

/// 终端“插入”能力的临时文件边界。Continuity Camera 和交互式截屏都先落成普通文件，
/// 再把经过 Shell 转义的路径写入当前提示符；终端永远不直接解释图片字节。
enum TerminalImportError: Error, Equatable {
  case emptyData
  case fileTooLarge
  case unsupportedType
  case invalidCapturedFile
  case writeFailed
}

enum TerminalImportedFileStore {
  /// 手机照片与多页 PDF 可能明显大于普通剪贴板内容；32 MiB 足以覆盖日常捕获，同时
  /// 阻止 Continuity pasteboard 把无界数据写进临时目录。
  static let maximumBytes = 32 * 1024 * 1024
  static let importedDirectoryName = "aster-imports"
  static let screenshotDirectoryName = "aster-screenshots"

  static let supportedPasteboardTypes: [NSPasteboard.PasteboardType] = [
    .png,
    .tiff,
    .pdf,
    .init("public.jpeg"),
    .init("public.heic"),
  ]

  static func supports(_ type: NSPasteboard.PasteboardType) -> Bool {
    fileExtension(for: type) != nil
  }

  /// 保存来自 Continuity Camera 的图片或 PDF，并返回可插入终端的本地路径。
  ///
  /// - Parameters:
  ///   - data: AppKit 从 Continuity pasteboard 交付的完整数据。
  ///   - type: 数据对应的稳定 pasteboard UTI。
  ///   - baseDirectory: 测试可注入隔离目录；生产默认使用系统临时目录。
  /// - Returns: 权限收紧为 `0600` 的新普通文件 URL。
  /// - Throws: 数据为空、超限、类型不支持或文件系统写入失败时抛出确定错误。
  static func save(
    _ data: Data,
    type: NSPasteboard.PasteboardType,
    baseDirectory: URL = FileManager.default.temporaryDirectory,
  ) throws -> URL {
    guard !data.isEmpty else { throw TerminalImportError.emptyData }
    guard data.count <= maximumBytes else { throw TerminalImportError.fileTooLarge }
    guard let fileExtension = fileExtension(for: type) else {
      throw TerminalImportError.unsupportedType
    }

    let directory = baseDirectory.appendingPathComponent(importedDirectoryName, isDirectory: true)
    do {
      try preparePrivateDirectory(directory)
      let destination = directory.appendingPathComponent(
        "import-\(UUID().uuidString.lowercased()).\(fileExtension)",
        isDirectory: false,
      )
      // Foundation 不允许 `.atomic` 与 `.withoutOverwriting` 组合。UUID 目标在写完前不会
      // 暴露给终端，因此这里优先拒绝覆盖，避免路径碰撞时改写任何既有捕获文件。
      try data.write(to: destination, options: [.withoutOverwriting])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: destination.path,
      )
      return destination
    } catch let error as TerminalImportError {
      throw error
    } catch {
      throw TerminalImportError.writeFailed
    }
  }

  /// 为 `/usr/sbin/screencapture` 预留一个尚不存在的私有目标路径。真正写入由系统工具
  /// 完成，结束后仍须调用 `validateCapturedFile(at:)`，不能只相信退出码。
  static func makeScreenshotDestination(
    baseDirectory: URL = FileManager.default.temporaryDirectory,
  ) throws -> URL {
    let directory = baseDirectory.appendingPathComponent(screenshotDirectoryName, isDirectory: true)
    do {
      try preparePrivateDirectory(directory)
      return directory.appendingPathComponent(
        "screenshot-\(UUID().uuidString.lowercased()).png",
        isDirectory: false,
      )
    } catch {
      throw TerminalImportError.writeFailed
    }
  }

  /// 截屏进程成功退出后复验最终对象：只接受有内容、未超限、非符号链接的普通文件。
  static func validateCapturedFile(at url: URL) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_size > 0
    else {
      throw TerminalImportError.invalidCapturedFile
    }
    guard metadata.st_size <= maximumBytes else { throw TerminalImportError.fileTooLarge }
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path,
      )
    } catch {
      throw TerminalImportError.writeFailed
    }
  }

  private static func preparePrivateDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    // 目录可能由旧版本以更宽权限创建；每次使用前重新收紧，避免捕获内容被其它用户读。
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path,
    )
  }

  private static func fileExtension(for type: NSPasteboard.PasteboardType) -> String? {
    switch type {
    case .png: "png"
    case .tiff: "tiff"
    case .pdf: "pdf"
    case .init("public.jpeg"): "jpg"
    case .init("public.heic"): "heic"
    default: nil
    }
  }
}
