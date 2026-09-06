import AppKit
import AsterCore
import Foundation

/// 安全提示的用户选择。外部 host、非标准 scheme 和带文件身份签名的可执行目标均可
/// 选择 `.always`；签名变化后可执行目标会重新确认。
enum TargetOpenConfirmation: Equatable {
  case once
  case always
  case cancel
}

/// 终端目标打开的唯一 AppKit 边界。解析和安全判断位于 AsterCore；本类型只负责读取
/// 当前设置、执行确认、持久化最小例外，并最终调用 `NSWorkspace`。
@MainActor
final class TerminalTargetOpenCoordinator {
  typealias FileInspector = @MainActor (String) -> TargetFileKind
  typealias TextProbe = @MainActor (String) -> Bool
  typealias URLOpener = @MainActor (URL) -> Bool
  typealias AsterOpener = @MainActor (URL, Bool) -> Bool
  typealias ExecutableSignatureProvider = @MainActor (String) -> String?
  typealias ConfirmationHandler = @MainActor (TargetSecurityReason) -> TargetOpenConfirmation
  typealias ErrorReporter = @MainActor (String) -> Void

  private let preferences: AppPreferences
  private let resolver: TargetResolver
  private let inspectFile: FileInspector
  private let isTextFile: TextProbe
  private let openURL: URLOpener
  private let openInAster: AsterOpener
  private let executableSignature: ExecutableSignatureProvider
  private let confirm: ConfirmationHandler
  private let reportError: ErrorReporter

  init(
    preferences: AppPreferences,
    resolver: TargetResolver = TargetResolver(),
    inspectFile: @escaping FileInspector = TargetFileInspector.kind,
    isTextFile: @escaping TextProbe = TargetFileInspector.isProbablyText,
    openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
    openInAster: @escaping AsterOpener = { _, _ in false },
    executableSignature: @escaping ExecutableSignatureProvider = TerminalTargetOpenCoordinator.executableSignature,
    confirm: @escaping ConfirmationHandler = TerminalTargetOpenCoordinator.presentConfirmation,
    reportError: @escaping ErrorReporter = TerminalTargetOpenCoordinator.presentError
  ) {
    self.preferences = preferences
    self.resolver = resolver
    self.inspectFile = inspectFile
    self.isTextFile = isTextFile
    self.openURL = openURL
    self.openInAster = openInAster
    self.executableSignature = executableSignature
    self.confirm = confirm
    self.reportError = reportError
  }

  /// 解析并打开一个终端目标。
  ///
  /// - Returns: 只有系统打开调用成功时才返回 `true`；取消、拒绝、解析失败和系统打开
  ///   失败均返回 `false`，且不会把失败选择写入安全例外。
  @discardableResult
  func open(
    _ rawValue: String,
    source: DetectedTargetSource,
    currentDirectory: String
  ) -> Bool {
    guard preferences.configuration.controls.resolvedLinkDetectionEnabled else { return false }

    let target: DetectedTarget
    do {
      target = try resolver.resolve(
        rawValue,
        currentDirectory: currentDirectory,
        source: source,
        schemePolicy: preferences.configuration.controls.resolvedLinkSchemePolicy
      )
    } catch {
      reportError("无法识别该链接或文件路径。")
      return false
    }

    let fileKind: TargetFileKind?
    if case .file(let file) = target {
      fileKind = inspectFile(file.path)
    } else {
      fileKind = nil
    }
    let signature: String? = if case .file(let file) = target,
      fileKind == .regular(executable: true) || fileKind == .applicationBundle
    {
      executableSignature(file.path)
    } else {
      nil
    }
    let decision = preferences.configuration.controls.resolvedTargetSecurityPolicy.decision(
      for: target,
      fileKind: fileKind,
      executableSignature: signature
    )

    var permissionToRemember: TargetSecurityReason?
    switch decision {
    case .allow:
      break
    case .confirm(let reason):
      switch confirm(reason) {
      case .once:
        break
      case .always:
        permissionToRemember = reason
      case .cancel:
        return false
      }
    case .deny(let reason):
      reportError(Self.denialMessage(for: reason))
      return false
    }

    let url: URL
    switch target {
    case .file(let file):
      url = URL(fileURLWithPath: file.path)
    case .url(let target):
      url = target.url
    }
    let controls = preferences.configuration.controls
    let opened: Bool
    switch target {
    case .file(let file):
      // 按文件类型分流：`.app`、可执行文件、二进制和缺失文件不能进右侧 Pane，
      // 否则编辑器会因 DocumentBufferError 失败；这些一律交给系统 open。
      let route = TargetInternalOpenRoute.route(
        fileKind: fileKind,
        folderOpensInAster: controls.resolvedFolderOpenWith == .aster,
        fileOpensInAster: controls.resolvedFileOpenWith == .aster,
        isText: { isTextFile(file.path) }
      )
      switch route {
      case .fileBrowser: opened = openInAster(url, true) || openURL(url)
      case .editor: opened = openInAster(url, false) || openURL(url)
      case .system: opened = openURL(url)
      }
    case .url:
      // 内部打开器只接受 HTTP(S) Web Pane；mailto 或自定义协议返回 false 后仍交给
      // LaunchServices，且前面已经完成对应的 scheme 安全决策。
      opened = controls.resolvedLinkOpenWith == .aster && openInAster(url, false)
        ? true : openURL(url)
    }
    guard opened else {
      reportError("系统无法打开该目标。请检查文件是否存在，或是否安装了对应应用。")
      return false
    }
    if let permissionToRemember {
      remember(permissionToRemember, executableSignature: signature)
    }
    return true
  }

  /// 判断一个路径候选在当前目录下是否真实存在，供 Command 下划线与点击命中过滤裸相对
  /// 路径（`site`、`Makefile`）。只做解析加 stat，不授权也不打开；URL 一律返回 false。
  func fileTargetExists(_ rawValue: String, currentDirectory: String) -> Bool {
    guard preferences.configuration.controls.resolvedLinkDetectionEnabled,
      let target = try? resolver.resolve(
        rawValue, currentDirectory: currentDirectory, source: .plainText, schemePolicy: .all),
      case .file(let file) = target
    else { return false }
    return FileManager.default.fileExists(atPath: file.path)
  }

  /// 生成与实际打开解析一致的预览文字。相对、`~/`、`file:` 和行列后缀会显示为
  /// 可核对的绝对本地路径；解析失败时保留原文，避免远端 OSC 7 被误装成本机路径。
  /// 该方法只做纯解析，不检查文件、不请求授权，也不会执行打开动作。
  func previewText(_ rawValue: String, currentDirectory: String) -> String {
    guard let target = try? resolver.resolve(
      rawValue,
      currentDirectory: currentDirectory,
      // 目标已经由终端点击命中；预览不应再次按普通文字 scheme 白名单隐藏它。
      source: .osc8,
      schemePolicy: preferences.configuration.controls.resolvedLinkSchemePolicy
    ) else { return rawValue }
    switch target {
    case .url(let target):
      return target.url.absoluteString
    case .file(let file):
      var value = file.path
      if let line = file.line {
        value += ":\(line)"
        if let column = file.column { value += ":\(column)" }
      }
      return value
    }
  }

  private func remember(_ reason: TargetSecurityReason, executableSignature: String?) {
    switch reason {
    case .externalLink(let host):
      guard !host.isEmpty else { return }
      var hosts = preferences.configuration.controls.resolvedAllowedExternalLinkHosts
      hosts.insert(host.lowercased())
      preferences.configuration.controls.allowedExternalLinkHosts = hosts
    case .nonStandardScheme(let scheme):
      var schemes = preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes
      schemes.insert(scheme.lowercased())
      preferences.configuration.controls.allowedNonStandardLinkSchemes = schemes
    case .executableFile:
      guard let executableSignature else { return }
      var signatures = preferences.configuration.controls.resolvedAllowedExecutableFileSignatures
      signatures.insert(executableSignature)
      preferences.configuration.controls.allowedExecutableFileSignatures = signatures
    case .unsupportedFileType:
      // 拒绝类型不会提供“始终允许”按钮；保留穷尽分支以防未来新增调用路径。
      break
    }
  }

  private static func denialMessage(for reason: TargetSecurityReason) -> String {
    switch reason {
    case .unsupportedFileType:
      return "为避免阻塞或访问系统设备，不能打开管道、socket 或设备文件。"
    case .externalLink, .nonStandardScheme, .executableFile:
      return "该目标未通过安全检查。"
    }
  }

  private static func presentConfirmation(_ reason: TargetSecurityReason) -> TargetOpenConfirmation {
    let alert = NSAlert()
    alert.alertStyle = .warning
    switch reason {
    case .externalLink(let host):
      alert.messageText = "允许打开 \(host)？"
      alert.informativeText = "外部链接可能离开当前工作区。仅在信任该网站时打开。"
    case .nonStandardScheme(let scheme):
      alert.messageText = "允许打开 \(scheme):// 链接？"
      alert.informativeText = "非标准链接会交给本机已注册的应用处理。仅在信任来源时打开。"
    case .executableFile(let path):
      alert.messageText = "允许打开可执行文件？"
      alert.informativeText = "目标 \(path) 可能运行代码。仅在确认文件可信时打开。"
    case .unsupportedFileType:
      return .cancel
    }
    alert.addButton(withTitle: "打开一次")
    let alwaysTitle: String = switch reason {
    case .externalLink: "始终允许此网站"
    case .nonStandardScheme: "始终允许此 Scheme"
    case .executableFile: "始终允许此文件"
    case .unsupportedFileType: "始终允许"
    }
    alert.addButton(withTitle: alwaysTitle)
    alert.addButton(withTitle: "取消")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .once
    case .alertSecondButtonReturn: return .always
    default: return .cancel
    }
  }

  /// 授权令牌绑定标准化路径、设备、inode、大小和纳秒级修改时间。路径被替换或内容
  /// 更新后任一身份字段变化都会重新提示；无法读取元数据时不提供可持久化授权。
  private static func executableSignature(at path: String) -> String? {
    let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: normalizedPath),
      let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
      let size = (attributes[.size] as? NSNumber)?.uint64Value,
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    let modifiedNanoseconds = Int64(modified.timeIntervalSince1970 * 1_000_000_000)
    return "\(normalizedPath)|\(device)|\(inode)|\(size)|\(modifiedNanoseconds)"
  }

  private static func presentError(_ message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "无法打开目标"
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
  }
}
