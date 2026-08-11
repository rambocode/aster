import Foundation
import Darwin

/// 终端文字中目标的来源。显式 OSC 8 链接由远端程序主动标注，不受本地自动检测
/// scheme 列表限制；它仍须经过与普通目标完全相同的打开安全决策。
public enum DetectedTargetSource: Equatable, Sendable {
  case plainText
  case osc8
}

/// 普通文字链接的 scheme 检测范围。
public enum LinkSchemePolicy: Equatable, Sendable {
  /// 识别所有语法合法的 `scheme://` 链接。
  case all
  /// 仅识别标准 scheme 和调用方明确添加的 scheme。标准集合不可被关闭。
  case custom(Set<String>)

  /// 判断普通文字中的 scheme 是否应参与点击命中。OSC 8 调用方不应使用此过滤。
  public func detects(_ scheme: String) -> Bool {
    let normalized = scheme.lowercased()
    if Self.standardSchemes.contains(normalized) { return true }
    switch self {
    case .all:
      return true
    case .custom(let schemes):
      return schemes.lazy.map { $0.lowercased() }.contains(normalized)
    }
  }

  /// `file` 在解析后转成文件目标，但仍属于始终启用的标准 scheme。
  public static let standardSchemes: Set<String> = ["http", "https", "file", "mailto"]

  /// 验证 RFC 3986 scheme 的 ASCII 子集，供配置导入层复用同一语法边界。
  public static func isSyntacticallyValid(_ value: String) -> Bool {
    guard value.utf8.count <= 64 else { return false }
    return TargetResolver.isValidScheme(value)
  }
}

/// 已规范化的本地文件定位。`line`、`column` 使用编辑器常见的一基编号。
public struct FileTarget: Equatable, Sendable {
  public let path: String
  public let line: Int?
  public let column: Int?

  public init(path: String, line: Int? = nil, column: Int? = nil) {
    self.path = path
    self.line = line
    self.column = column
  }
}

/// 已验证语法的非文件 URL。scheme 单独保存为小写，供安全策略稳定比较。
public struct URLTarget: Equatable, Sendable {
  public let url: URL
  public let scheme: String

  public init(url: URL, scheme: String) {
    self.url = url
    self.scheme = scheme.lowercased()
  }
}

/// 终端内可操作目标的领域表示。文件 URL 也统一表示为 `.file`，确保不能绕过
/// 可执行文件和特殊文件类型检查。
public enum DetectedTarget: Equatable, Sendable {
  case file(FileTarget)
  case url(URLTarget)
}

public enum TargetResolutionError: Error, Equatable, Sendable {
  case emptyInput
  case inputTooLong
  case controlCharacter
  case invalidURL
  case schemeNotDetected(String)
  case invalidCurrentDirectory
  case invalidLocation
}

/// 解析 SwiftTerm 单元格保存的 OSC 8 payload（`params;URI`）。来源判断必须读取用户
/// 实际点击的单元格，不能按历史 URL 猜测，否则同值普通文字和滚动历史会被误分类。
public enum OSC8Payload {
  public static func link(from payload: String) -> String? {
    guard let separator = payload.firstIndex(of: ";") else { return nil }
    let link = String(payload[payload.index(after: separator)...])
    return link.isEmpty ? nil : link
  }
}

/// 在一行终端文字中补充识别 SwiftTerm 内置列表之外的 `scheme://` URL。返回值仍需
/// 交给 `TargetResolver` 按用户 scheme 设置过滤，检测器本身不承担授权职责。
public enum InlineURLDetector {
  /// 在终端软换行形成的多条物理行中定位 URL。行之间不插入换行符；点击偏移仍以
  /// 目标物理行中的 Swift `Character` 计数。若最后一行可能继续，则拒绝截断目标。
  public static func url(
    inPhysicalLines lines: [String],
    clickedLine: Int,
    atCharacterOffset offset: Int,
    finalBoundaryMayContinue: Bool
  ) -> String? {
    guard lines.indices.contains(clickedLine), offset >= 0, offset < lines[clickedLine].count else {
      return nil
    }
    let text = lines.joined()
    guard text.utf8.count <= TargetResolver.maximumInputBytes else { return nil }
    let combinedOffset = lines[..<clickedLine].reduce(0) { $0 + $1.count } + offset
    return url(
      in: text,
      atCharacterOffset: combinedOffset,
      rightBoundaryMayContinue: finalBoundaryMayContinue
    )
  }

  public static func url(
    in line: String,
    atCharacterOffset offset: Int,
    rightBoundaryMayContinue: Bool = false
  ) -> String? {
    guard offset >= 0, offset < line.count,
      let expression = try? NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"'`，。；：！？（）【】]+"#
      )
    else { return nil }
    let clickedIndex = line.index(line.startIndex, offsetBy: offset)
    let searchRange = NSRange(line.startIndex..<line.endIndex, in: line)
    let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}")

    for match in expression.matches(in: line, range: searchRange) {
      guard var range = Range(match.range, in: line) else { continue }
      while range.lowerBound < range.upperBound,
        let scalar = line[range].unicodeScalars.last,
        trailingPunctuation.contains(scalar)
      {
        range = range.lowerBound..<line.index(before: range.upperBound)
      }
      guard range.contains(clickedIndex) else { continue }
      guard !(rightBoundaryMayContinue && range.upperBound == line.endIndex) else { return nil }
      return String(line[range])
    }
    return nil
  }
}

/// 把 SwiftTerm 或其它文字检测器给出的原始值规范化为 Aster 领域目标。
///
/// 解析器只处理语法和路径定位，不访问文件系统，也不决定是否打开。调用方应在打开
/// 前读取文件类型，并交给 `TargetSecurityPolicy` 做最终授权。
public struct TargetResolver: Sendable {
  public static let maximumInputBytes = 4_096

  private let homeDirectory: URL

  public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory.standardizedFileURL
  }

  /// 解析路径、`path:line[:column]`、URL 或 OSC 8 目标。
  ///
  /// - Parameters:
  ///   - rawValue: 终端检测器返回的原始目标，不应包含换行或其它控制字符。
  ///   - currentDirectory: OSC 7 当前目录；仅相对文件路径会使用它。
  ///   - source: OSC 8 显式链接会跳过自动检测 scheme 白名单。
  ///   - schemePolicy: 普通文字 URL 的检测范围。
  /// - Returns: 绝对、标准化且带可选行列的文件目标，或语法合法的 URL 目标。
  /// - Throws: 输入超限、含控制字符、URL/行列非法或相对路径没有合法 CWD。
  public func resolve(
    _ rawValue: String,
    currentDirectory: String,
    source: DetectedTargetSource = .plainText,
    schemePolicy: LinkSchemePolicy = .all
  ) throws -> DetectedTarget {
    guard !rawValue.isEmpty else { throw TargetResolutionError.emptyInput }
    guard rawValue.utf8.count <= Self.maximumInputBytes else {
      throw TargetResolutionError.inputTooLong
    }
    guard rawValue.rangeOfCharacter(from: .controlCharacters) == nil else {
      throw TargetResolutionError.controlCharacter
    }

    if let scheme = Self.detectURLScheme(in: rawValue, allowsOpaqueURI: source == .osc8) {
      guard source == .osc8 || schemePolicy.detects(scheme) else {
        throw TargetResolutionError.schemeNotDetected(scheme)
      }
      guard let url = URL(string: rawValue), url.scheme?.lowercased() == scheme else {
        throw TargetResolutionError.invalidURL
      }
      guard let decodedValue = rawValue.removingPercentEncoding else {
        throw TargetResolutionError.invalidURL
      }
      guard decodedValue.rangeOfCharacter(from: .controlCharacters) == nil else {
        throw TargetResolutionError.controlCharacter
      }
      if url.isFileURL {
        guard url.path.hasPrefix("/") else { throw TargetResolutionError.invalidURL }
        return .file(FileTarget(path: url.standardizedFileURL.path))
      }
      return .url(URLTarget(url: url, scheme: scheme))
    }

    let location = try Self.splitLocationSuffix(from: rawValue)
    let expandedPath: String
    if location.path == "~" {
      expandedPath = homeDirectory.path
    } else if location.path.hasPrefix("~/") {
      expandedPath = homeDirectory.appendingPathComponent(String(location.path.dropFirst(2))).path
    } else if location.path.hasPrefix("/") {
      expandedPath = location.path
    } else {
      guard currentDirectory.hasPrefix("/"),
        currentDirectory.utf8.count <= Self.maximumInputBytes,
        currentDirectory.rangeOfCharacter(from: .controlCharacters) == nil
      else { throw TargetResolutionError.invalidCurrentDirectory }
      expandedPath = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        .appendingPathComponent(location.path).path
    }
    let normalizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    return .file(FileTarget(path: normalizedPath, line: location.line, column: location.column))
  }

  /// 普通文字自动识别任意 `scheme://` 和 SwiftTerm 已支持的常见 opaque URI；OSC 8
  /// 本身就是显式链接，因此允许其它合法 `scheme:value`。普通路径仍不会因行号后缀
  /// 被误判，例如 `README.md:12` 不在 opaque 集合中。
  private static func detectURLScheme(in value: String, allowsOpaqueURI: Bool) -> String? {
    guard let colon = value.firstIndex(of: ":") else { return nil }
    let candidate = String(value[..<colon])
    guard isValidScheme(candidate) else { return nil }
    let normalized = candidate.lowercased()
    let remainder = value[value.index(after: colon)...]
    // OSC 8 也允许把 `README.md:12[:3]` 标成显式文件链接。带文件名特征且后缀全为
    // 正整数时优先走文件定位，不能因显式来源允许 opaque URI 就误判为 scheme。
    if allowsOpaqueURI, candidate.contains("."),
      remainder.split(separator: ":").allSatisfy({ Int($0).map { $0 > 0 } == true })
    {
      return nil
    }
    guard remainder.hasPrefix("//") || allowsOpaqueURI
      || recognizedOpaqueSchemes.contains(normalized)
    else {
      return nil
    }
    return normalized
  }

  private static let recognizedOpaqueSchemes: Set<String> = [
    "file", "mailto", "magnet", "news", "sms", "ssh", "tel", "urn",
  ]

  fileprivate static func isValidScheme(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first, Self.isASCIIAlpha(first) else { return false }
    return value.unicodeScalars.dropFirst().allSatisfy { scalar in
      Self.isASCIIAlpha(scalar) || (0x30...0x39).contains(scalar.value) || scalar == "+"
        || scalar == "-" || scalar == "."
    }
  }

  private static func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
    (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
  }

  private static func splitLocationSuffix(
    from rawValue: String
  ) throws -> (path: String, line: Int?, column: Int?) {
    let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return (rawValue, nil, nil) }

    guard let trailing = Int(parts[parts.count - 1]) else {
      return (rawValue, nil, nil)
    }
    guard trailing > 0 else { throw TargetResolutionError.invalidLocation }

    if parts.count > 2, let line = Int(parts[parts.count - 2]) {
      guard line > 0 else { throw TargetResolutionError.invalidLocation }
      let path = parts.dropLast(2).joined(separator: ":")
      guard !path.isEmpty else { throw TargetResolutionError.invalidLocation }
      return (path, line, trailing)
    }

    let path = parts.dropLast().joined(separator: ":")
    guard !path.isEmpty else { throw TargetResolutionError.invalidLocation }
    return (path, trailing, nil)
  }
}

/// 调用方读取到的文件系统类型。特殊文件不能交给预览器或外部应用，以免读取 FIFO
/// 阻塞、连接 socket，或意外访问设备节点。
public enum TargetFileKind: Equatable, Sendable {
  case regular(executable: Bool)
  case directory
  /// Launch Services 会执行 `.app` 目录，安全语义等同于可执行文件而不是普通文件夹。
  case applicationBundle
  case missing
  case namedPipe
  case socket
  case device
  case other
}

/// 使用 `lstat(2)` 读取目标元数据而不打开文件内容。符号链接先由 Foundation 解析，
/// 再检查最终目标，因此指向 FIFO、socket 或设备的链接不能绕过安全策略。
public enum TargetFileInspector {
  public static func kind(atPath path: String) -> TargetFileKind {
    kind(atPath: path, followsSymbolicLink: true)
  }

  private static func kind(atPath path: String, followsSymbolicLink: Bool) -> TargetFileKind {
    var metadata = stat()
    guard Darwin.lstat(path, &metadata) == 0 else {
      return errno == ENOENT || errno == ENOTDIR ? .missing : .other
    }

    switch metadata.st_mode & S_IFMT {
    case S_IFREG:
      let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
      return .regular(executable: metadata.st_mode & executableBits != 0)
    case S_IFDIR:
      return URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
        ? .applicationBundle : .directory
    case S_IFIFO:
      return .namedPipe
    case S_IFSOCK:
      return .socket
    case S_IFCHR, S_IFBLK:
      return .device
    case S_IFLNK where followsSymbolicLink:
      let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
      guard resolved != path else { return .other }
      return kind(atPath: resolved, followsSymbolicLink: false)
    default:
      return .other
    }
  }
}

public enum TargetSecurityReason: Equatable, Sendable {
  case externalLink(String)
  case nonStandardScheme(String)
  case executableFile(String)
  case unsupportedFileType(TargetFileKind)
}

public enum TargetSecurityDecision: Equatable, Sendable {
  case allow
  case confirm(TargetSecurityReason)
  case deny(TargetSecurityReason)
}

/// 纯值安全策略。普通文件直接放行；首次外部 host、非标准 scheme 与可执行文件要求
/// 用户确认；设备、管道和 socket 无条件拒绝。可执行授权绑定调用方提供的文件签名，
/// 文件被替换后不会沿用旧的“始终允许”。
public struct TargetSecurityPolicy: Equatable, Sendable {
  public let allowedNonStandardSchemes: Set<String>
  public let allowedExternalHosts: Set<String>
  public let allowedExecutableSignatures: Set<String>

  public init(
    allowedNonStandardSchemes: Set<String> = [],
    allowedExternalHosts: Set<String> = [],
    allowedExecutableSignatures: Set<String> = []
  ) {
    self.allowedNonStandardSchemes = Set(allowedNonStandardSchemes.map { $0.lowercased() })
    self.allowedExternalHosts = Set(allowedExternalHosts.map { $0.lowercased() })
    self.allowedExecutableSignatures = allowedExecutableSignatures
  }

  /// 返回打开决策。文件类型未知或不存在时允许调用方继续，让实际打开动作提供明确的
  /// “文件不存在/无权限”错误；只有已确认的特殊文件类型在策略层拒绝。
  public func decision(
    for target: DetectedTarget,
    fileKind: TargetFileKind? = nil,
    executableSignature: String? = nil
  ) -> TargetSecurityDecision {
    switch target {
    case .url(let target):
      if ["http", "https"].contains(target.scheme) {
        let host = target.url.host?.lowercased() ?? ""
        return allowedExternalHosts.contains(host)
          ? .allow : .confirm(.externalLink(host))
      }
      if LinkSchemePolicy.standardSchemes.contains(target.scheme) { return .allow }
      if allowedNonStandardSchemes.contains(target.scheme) { return .allow }
      return .confirm(.nonStandardScheme(target.scheme))
    case .file(let target):
      switch fileKind {
      case .regular(executable: true), .applicationBundle:
        if let executableSignature, allowedExecutableSignatures.contains(executableSignature) {
          return .allow
        }
        return .confirm(.executableFile(target.path))
      case .namedPipe:
        return .deny(.unsupportedFileType(.namedPipe))
      case .socket:
        return .deny(.unsupportedFileType(.socket))
      case .device:
        return .deny(.unsupportedFileType(.device))
      case .other:
        return .deny(.unsupportedFileType(.other))
      case .none, .regular, .directory, .missing:
        return .allow
      }
    }
  }
}
