import AppKit
import AsterCore
import Foundation

/// 安全提示的用户选择。`.always` 只适用于非标准 scheme；可执行文件和应用 bundle
/// 每次打开都重新确认，防止同一路径内容被替换后复用旧授权。
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
  typealias URLOpener = @MainActor (URL) -> Bool
  typealias ConfirmationHandler = @MainActor (TargetSecurityReason) -> TargetOpenConfirmation
  typealias ErrorReporter = @MainActor (String) -> Void

  private let preferences: AppPreferences
  private let resolver: TargetResolver
  private let inspectFile: FileInspector
  private let openURL: URLOpener
  private let confirm: ConfirmationHandler
  private let reportError: ErrorReporter

  init(
    preferences: AppPreferences,
    resolver: TargetResolver = TargetResolver(),
    inspectFile: @escaping FileInspector = TargetFileInspector.kind,
    openURL: @escaping URLOpener = { NSWorkspace.shared.open($0) },
    confirm: @escaping ConfirmationHandler = TerminalTargetOpenCoordinator.presentConfirmation,
    reportError: @escaping ErrorReporter = TerminalTargetOpenCoordinator.presentError
  ) {
    self.preferences = preferences
    self.resolver = resolver
    self.inspectFile = inspectFile
    self.openURL = openURL
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
    let decision = preferences.configuration.controls.resolvedTargetSecurityPolicy.decision(
      for: target,
      fileKind: fileKind
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
        if case .nonStandardScheme = reason { permissionToRemember = reason }
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
    guard openURL(url) else {
      reportError("系统无法打开该目标。请检查文件是否存在，或是否安装了对应应用。")
      return false
    }
    if let permissionToRemember { remember(permissionToRemember) }
    return true
  }

  private func remember(_ reason: TargetSecurityReason) {
    switch reason {
    case .nonStandardScheme(let scheme):
      var schemes = preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes
      schemes.insert(scheme.lowercased())
      preferences.configuration.controls.allowedNonStandardLinkSchemes = schemes
    case .executableFile:
      break
    case .unsupportedFileType:
      // 拒绝类型不会提供“始终允许”按钮；保留穷尽分支以防未来新增调用路径。
      break
    }
  }

  private static func denialMessage(for reason: TargetSecurityReason) -> String {
    switch reason {
    case .unsupportedFileType:
      return "为避免阻塞或访问系统设备，不能打开管道、socket 或设备文件。"
    case .nonStandardScheme, .executableFile:
      return "该目标未通过安全检查。"
    }
  }

  private static func presentConfirmation(_ reason: TargetSecurityReason) -> TargetOpenConfirmation {
    let alert = NSAlert()
    alert.alertStyle = .warning
    switch reason {
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
    if case .nonStandardScheme = reason {
      alert.addButton(withTitle: "始终允许此 Scheme")
      alert.addButton(withTitle: "取消")
      switch alert.runModal() {
      case .alertFirstButtonReturn: return .once
      case .alertSecondButtonReturn: return .always
      default: return .cancel
      }
    }
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn ? .once : .cancel
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
