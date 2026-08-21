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
      "内置字体注册失败：\(message)"
    }
  }
}

/// 进程级注册终端正文与 Symbols-only 字体。正文使用随应用分发的 JetBrains Mono，
/// 确保默认配置不依赖系统安装状态；Symbols 字体只覆盖图标码位，并放入显式 fallback。
@MainActor
enum BundledFontRegistry {
  static let jetBrainsMonoFamilyName = "JetBrains Mono"
  static let nerdSymbolsPostScriptName = "AsterNerdSymbols"

  /// 与 Otty 1.3.1 应用资源保持一致的完整字体集合。文件名是打包及启动注册契约，
  /// 增删时必须同步字体资源、第三方声明和注册回归测试。
  static let bundledFontFileNames = [
    "JetBrainsMono.ttf",
    "JetBrainsMono-Italic.ttf",
    "OfficeCodePro-Regular.ttf",
    "OfficeCodePro-Bold.ttf",
    "OfficeCodePro-Italic.ttf",
    "OfficeCodePro-BoldItalic.ttf",
    "SymbolsNerdFontMono-Regular.ttf",
  ]

  private static var registeredFontURLs: Set<URL> = []

  static func registerBundledFonts(resourcesDirectory: URL) throws {
    let fontsDirectory = resourcesDirectory.appendingPathComponent("fonts", isDirectory: true)
    // Aster 重命名的 Symbols fallback 先注册，确保某个可选正文字体损坏时图标链
    // 仍可用；其余文件逐一尝试，最后统一报告失败，不能因单个文件中断整个集合。
    let fileNames = ["AsterNerdSymbols-Regular.ttf"] + bundledFontFileNames
    var failures: [String] = []
    for fileName in fileNames {
      do {
        try registerFont(
          at: fontsDirectory.appendingPathComponent(fileName, isDirectory: false)
        )
      } catch {
        failures.append("\(fileName)：\(error.localizedDescription)")
      }
    }
    guard failures.isEmpty else {
      throw BundledFontRegistryError.registrationFailed(failures.joined(separator: "；"))
    }
  }

  static func registerNerdSymbols(at url: URL) throws {
    try registerFont(at: url)
  }

  /// CoreText 的进程作用域不会修改用户字体目录，应用退出后注册自然失效。相同文件
  /// 可能由多个测试或启动路径重复请求；本地缓存和 CoreText 的 already-registered
  /// 错误均按幂等成功处理，其他损坏、权限或格式错误仍完整上抛。
  private static func registerFont(at url: URL) throws {
    let standardized = url.standardizedFileURL
    if registeredFontURLs.contains(standardized) { return }
    let values = try standardized.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw BundledFontRegistryError.unsafeFontFile(standardized.path)
    }
    var unmanagedError: Unmanaged<CFError>?
    guard
      CTFontManagerRegisterFontsForURL(
        standardized as CFURL,
        .process,
        &unmanagedError
      )
    else {
      let error = unmanagedError?.takeRetainedValue() as Error?
      let nsError = error as NSError?
      if nsError?.domain == kCTFontManagerErrorDomain as String,
        nsError?.code == CTFontManagerError.alreadyRegistered.rawValue
      {
        registeredFontURLs.insert(standardized)
        return
      }
      throw BundledFontRegistryError.registrationFailed(
        nsError?.localizedDescription ?? "未知错误"
      )
    }
    registeredFontURLs.insert(standardized)
  }

  static func addingNerdSymbolsFallback(
    to baseFont: NSFont,
    additionalFamilies: [String] = []
  ) -> NSFont {
    guard let fallback = NSFont(
      name: nerdSymbolsPostScriptName,
      size: baseFont.pointSize
    ) else { return baseFont }
    let cascadeAttribute = NSFontDescriptor.AttributeName(
      rawValue: kCTFontCascadeListAttribute as String
    )
    var attributes = baseFont.fontDescriptor.fontAttributes
    let existing = attributes[cascadeAttribute] as? [NSFontDescriptor] ?? []
    let configured = additionalFamilies.compactMap { family in
      font(named: family, size: baseFont.pointSize)?.fontDescriptor
    }
    let reservedNames = Set(
      [fallback.fontDescriptor.postscriptName] + configured.map(\.postscriptName)
    )
    let filtered = existing.filter { descriptor in
      !reservedNames.contains(descriptor.postscriptName)
    }
    attributes[cascadeAttribute] = [fallback.fontDescriptor] + configured + filtered
    let descriptor = NSFontDescriptor(fontAttributes: attributes)
    return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
  }

  /// `NSFont(name:)` 优先接受 PostScript 名；设置页允许输入更易懂的 family 名，
  /// 因此在直接解析失败时从该 family 的成员中选择 Regular（否则取第一项）。
  static func font(named name: String, size: CGFloat) -> NSFont? {
    if let direct = NSFont(name: name, size: size) { return direct }
    guard let members = NSFontManager.shared.availableMembers(ofFontFamily: name),
      let member = members.first(where: { ($0[safe: 3] as? UInt) == 0 }) ?? members.first,
      let postScriptName = member.first as? String
    else { return nil }
    return NSFont(name: postScriptName, size: size)
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
