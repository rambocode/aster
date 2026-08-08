import AppKit
import CoreText
import Foundation

enum BundledFontRegistryError: Error, LocalizedError {
  case unsafeFontFile(String)
  case registrationFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsafeFontFile(let path):
      "内置字体不是可安全读取的普通文件：\(path)"
    case .registrationFailed(let message):
      "内置 Nerd Symbols 注册失败：\(message)"
    }
  }
}

/// 进程级注册内置 Symbols-only 字体，并把它放入用户基础等宽字体的显式 fallback。
/// 字体只覆盖图标码位，不改变 ASCII/CJK/Emoji 的首选字体和终端网格度量。
@MainActor
enum BundledFontRegistry {
  static let nerdSymbolsPostScriptName = "AsterNerdSymbols"

  private static var registeredFontURLs: Set<URL> = []

  static func registerBundledFonts(resourcesDirectory: URL) throws {
    try registerNerdSymbols(
      at: resourcesDirectory.appendingPathComponent(
        "fonts/AsterNerdSymbols-Regular.ttf",
        isDirectory: false
      )
    )
  }

  static func registerNerdSymbols(at url: URL) throws {
    let standardized = url.standardizedFileURL
    if registeredFontURLs.contains(standardized) { return }
    let values = try standardized.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw BundledFontRegistryError.unsafeFontFile(standardized.path)
    }
    var unmanagedError: Unmanaged<CFError>?
    guard CTFontManagerRegisterFontsForURL(
      standardized as CFURL,
      .process,
      &unmanagedError
    ) else {
      let message = unmanagedError?.takeRetainedValue().localizedDescription ?? "未知错误"
      throw BundledFontRegistryError.registrationFailed(message)
    }
    registeredFontURLs.insert(standardized)
  }

  static func addingNerdSymbolsFallback(to baseFont: NSFont) -> NSFont {
    guard let fallback = NSFont(
      name: nerdSymbolsPostScriptName,
      size: baseFont.pointSize
    ) else { return baseFont }
    let cascadeAttribute = NSFontDescriptor.AttributeName(
      rawValue: kCTFontCascadeListAttribute as String
    )
    var attributes = baseFont.fontDescriptor.fontAttributes
    let existing = attributes[cascadeAttribute] as? [NSFontDescriptor] ?? []
    let filtered = existing.filter { descriptor in
      descriptor.postscriptName != nerdSymbolsPostScriptName
    }
    attributes[cascadeAttribute] = [fallback.fontDescriptor] + filtered
    let descriptor = NSFontDescriptor(fontAttributes: attributes)
    return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
  }
}
