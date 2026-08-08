import Foundation

/// File Pane 内部的稳定文件分类。分类只描述展示能力，不会自行读取文件、
/// 启动外部应用或放宽安全策略。
public enum FilePresentationKind: String, Equatable, Sendable {
  case markdown
  case restructuredText
  case html
  case svg
  case image
  case pdf
  case richDocument
  case diff
  case agentTranscript
  case sourceText
  case binary

  public var supportsSourcePreviewToggle: Bool {
    switch self {
    case .markdown, .restructuredText, .html, .svg, .agentTranscript: true
    default: false
    }
  }

  /// 只有文本分类才进入 `DocumentBuffer`。图片、PDF、Quick Look 和二进制由各自
  /// renderer 直接、有界读取，不能先尝试 UTF-8 解码并制造伪错误状态。
  public var usesTextContent: Bool {
    switch self {
    case .markdown, .restructuredText, .html, .svg, .diff, .agentTranscript, .sourceText: true
    case .image, .pdf, .richDocument, .binary: false
    }
  }

  public var supportsEditing: Bool {
    switch self {
    case .markdown, .restructuredText, .html, .svg, .sourceText: true
    default: false
    }
  }
}

/// 经过路径扩展名和小段内容探测得到的展示计划。未知扩展名只在字节符合
/// 严格 UTF-8 且不含 NUL 时按普通文本处理，避免把二进制载荷交给编辑器。
public enum FileDocumentClassifier {
  private static let sourceExtensions: Set<String> = [
    "asm", "bash", "c", "cc", "clj", "cljs", "cmake", "conf", "cpp", "cs", "css",
    "csv", "dart", "dockerfile", "elm", "env", "erl", "ex", "exs", "fish", "fs",
    "go", "graphql", "groovy", "h", "hpp", "ini", "java", "js", "jsx", "kt", "kts",
    "less", "lua", "m", "makefile", "mm", "nix", "org", "pas", "php", "pl", "proto",
    "ps1", "py", "r", "rb", "rego", "rs", "scala", "scss", "sh", "sql", "swift",
    "tex", "toml", "ts", "tsx", "txt", "v", "vue", "wgsl", "xml", "yaml", "yml", "zig",
  ]
  private static let imageExtensions: Set<String> = [
    "apng", "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "png", "tif", "tiff", "webp",
  ]
  private static let richExtensions: Set<String> = [
    "avi", "doc", "docx", "font", "key", "mov", "mp3", "mp4", "numbers", "otf", "pages",
    "ppt", "pptx", "rtf", "ttc", "ttf", "wav", "xls", "xlsx",
  ]

  public static func classify(
    fileName: String,
    prefix: Data,
    trustedAgentProvider: AgentProvider? = nil
  ) -> FilePresentationKind {
    if trustedAgentProvider != nil { return .agentTranscript }
    let lower = fileName.lowercased()
    let ext = URL(fileURLWithPath: lower).pathExtension
    if ["md", "markdown", "mdown", "mkd"].contains(ext) { return .markdown }
    if ["rst", "rest"].contains(ext) { return .restructuredText }
    if ["html", "htm"].contains(ext) { return .html }
    if ext == "svg" { return .svg }
    if imageExtensions.contains(ext) { return .image }
    if ext == "pdf" { return .pdf }
    if ["diff", "patch"].contains(ext) { return .diff }
    if richExtensions.contains(ext) { return .richDocument }
    if sourceExtensions.contains(ext) || sourceExtensions.contains(lower) { return .sourceText }
    return looksLikeUTF8Text(prefix) ? .sourceText : .binary
  }

  private static func looksLikeUTF8Text(_ data: Data) -> Bool {
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return false }
    let controls = text.unicodeScalars.filter {
      $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t"
    }
    return controls.count <= max(1, text.unicodeScalars.count / 100)
  }
}

public enum FileItemNameError: Error, Equatable, Sendable {
  case empty
  case reserved
  case containsPathSeparator
  case containsControlCharacter
  case tooLong(maximumBytes: Int)
}

/// Files 菜单的创建和重命名共用同一个名称边界，避免两个入口对 `..`、
/// 分隔符或控制字符做出不同处理。
public enum FileItemNameValidator {
  public static let maximumBytes = 255

  public static func validate(_ proposed: String) throws -> String {
    let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw FileItemNameError.empty }
    guard name != ".", name != ".." else { throw FileItemNameError.reserved }
    guard !name.contains("/"), !name.contains(":") else {
      throw FileItemNameError.containsPathSeparator
    }
    guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw FileItemNameError.containsControlCharacter }
    guard name.utf8.count <= maximumBytes else {
      throw FileItemNameError.tooLong(maximumBytes: maximumBytes)
    }
    return name
  }
}

public enum WorkspaceRelativePath {
  /// 只返回 root 内部目标的相对路径；不用字符串前缀判断，因为 `/tmp/a`
  /// 不能成为 `/tmp/ab` 的根目录。
  public static func make(target: URL, relativeTo root: URL) -> String? {
    let rootComponents = root.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    guard targetComponents.count >= rootComponents.count,
      targetComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    else { return nil }
    let remainder = targetComponents.dropFirst(rootComponents.count)
    return remainder.isEmpty ? "." : remainder.joined(separator: "/")
  }
}

public enum HexLineFormatter {
  public static let bytesPerLine = 16

  public static func line(offset: Int, bytes: ArraySlice<UInt8>) -> String {
    let address = String(format: "%08X", max(0, offset))
    let hex = bytes.map { String(format: "%02X", $0) }
      .enumerated().map { $0.offset == 8 ? "  \($0.element)" : $0.element }
      .joined(separator: " ")
      .padding(toLength: 49, withPad: " ", startingAt: 0)
    let ascii = bytes.map { byte -> Character in
      (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
    }
    return "\(address)  \(hex)  |\(String(ascii))|"
  }
}
