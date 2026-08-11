import AppKit
import Foundation
@preconcurrency import GhosttyKit
import os

private let ghosttyLogger = Logger(
  subsystem: "com.asterterminal.app", category: "GhosttyApp")

/// 持有进程级 libghostty application、配置和回调路由。
///
/// `libghostty` 当前没有稳定 SDK 所有权说明；配置更新频率仅等于用户设置变更，
/// 因此已交给 core 的旧 config 保留到进程结束，避免过早释放造成 use-after-free。
@MainActor
final class GhosttyApp {
  static let shared = GhosttyApp()

  private(set) var app: ghostty_app_t?
  private(set) var startupError: String?
  /// 最近一次配置诊断仅保存在内存，供启动失败界面和测试定位固定 revision 的配置漂移。
  private(set) var configurationDiagnostics: [String] = []
  let callbacks = GhosttyCallbacks()

  private var didInitializeLibrary = false
  private var retainedConfigs: [ghostty_config_t] = []
  private var currentConfigurationText = ""

  private init() {}

  var isReady: Bool { app != nil && startupError == nil }

  /// 在首个 surface 前初始化；后续偏好更新则广播给现有/未来 surface。
  /// 返回 false 时 `startupError` 给出不包含用户路径或环境的稳定失败原因。
  func prepare(configurationText: String) -> Bool {
    if let app {
      guard configurationText != currentConfigurationText else { return true }
      guard let config = makeConfig(configurationText: configurationText) else { return false }
      retainedConfigs.append(config)
      currentConfigurationText = configurationText
      ghostty_app_update_config(app, config)
      return true
    }

    guard resolveResources() else { return false }
    if !didInitializeLibrary {
      guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
        startupError = "libghostty 初始化失败。"
        ghosttyLogger.error("ghostty_init failed")
        return false
      }
      guard ghostty_aster_extension_abi_version() == GHOSTTY_ASTER_EXTENSION_ABI_VERSION else {
        startupError = "libghostty 的 Aster 扩展 ABI 版本不匹配。"
        ghosttyLogger.error("Aster Ghostty extension ABI mismatch")
        return false
      }
      didInitializeLibrary = true
    }
    guard let config = makeConfig(configurationText: configurationText) else { return false }

    var runtime = ghostty_runtime_config_s()
    runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
    // macOS 没有独立 X11 selection clipboard，但 libghostty 的 embedded surface 初始化
    // 仍要求宿主声明 clipboard callback 能处理 selection 请求；实现会安全回退标准剪贴板。
    runtime.supports_selection_clipboard = true
    runtime.wakeup_cb = { _ in GhosttyApp.shared.callbacks.wakeup() }
    runtime.action_cb = { _, target, action in
      GhosttyApp.shared.callbacks.action(target: target, action: action)
    }
    runtime.read_clipboard_cb = { userdata, location, state in
      GhosttyApp.shared.callbacks.readClipboard(
        userdata: userdata, location: location, state: state)
    }
    runtime.confirm_read_clipboard_cb = { userdata, content, state, request in
      GhosttyApp.shared.callbacks.confirmReadClipboard(
        userdata: userdata, content: content, state: state, request: request)
    }
    runtime.write_clipboard_cb = { userdata, _, content, count, confirm in
      GhosttyApp.shared.callbacks.writeClipboard(
        userdata: userdata, content: content, count: UInt(count), confirm: confirm)
    }
    runtime.close_surface_cb = { userdata, _ in
      GhosttyApp.shared.callbacks.closeSurface(userdata: userdata)
    }

    guard let created = ghostty_app_new(&runtime, config) else {
      startupError = "无法创建 libghostty application。"
      ghostty_config_free(config)
      ghosttyLogger.error("ghostty_app_new failed")
      return false
    }
    retainedConfigs.append(config)
    currentConfigurationText = configurationText
    app = created
    return true
  }

  /// 合并 libghostty 的异步 action。wakeup 由 `GhosttyCallbacks` 去重，输出风暴不会
  /// 在主队列形成无界 tick backlog。
  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  private func makeConfig(configurationText: String) -> ghostty_config_t? {
    configurationDiagnostics = []
    guard let config = ghostty_config_new() else {
      startupError = "无法分配 libghostty 配置。"
      return nil
    }
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-ghostty-\(UUID().uuidString).conf")
    do {
      try Data(configurationText.utf8).write(to: file, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: file.path)
      file.path.withCString { ghostty_config_load_file(config, $0) }
    } catch {
      ghostty_config_free(config)
      startupError = "无法准备 libghostty 配置。"
      ghosttyLogger.error("temporary config preparation failed")
      return nil
    }
    try? FileManager.default.removeItem(at: file)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)

    let diagnosticCount = ghostty_config_diagnostics_count(config)
    if diagnosticCount > 0 {
      for index in 0..<diagnosticCount {
        let diagnostic = ghostty_config_get_diagnostic(config, index)
        if let message = diagnostic.message {
          let value = String(cString: message)
          configurationDiagnostics.append(value)
          ghosttyLogger.warning("config: \(value, privacy: .public)")
        }
      }
      ghostty_config_free(config)
      startupError = "libghostty 配置校验失败。"
      return nil
    }
    startupError = nil
    return config
  }

  private func resolveResources() -> Bool {
    guard let root = Bundle.module.resourceURL else {
      unsetenv("GHOSTTY_RESOURCES_DIR")
      startupError = "未找到 libghostty 资源 Bundle。"
      return false
    }
    let ghostty = root.appendingPathComponent("ghostty", isDirectory: true)
    let terminfo = root.appendingPathComponent("terminfo", isDirectory: true)
    guard
      FileManager.default.fileExists(
        atPath: ghostty.appendingPathComponent("shell-integration").path),
      FileManager.default.fileExists(
        atPath: terminfo.appendingPathComponent("78/xterm-ghostty").path)
    else {
      unsetenv("GHOSTTY_RESOURCES_DIR")
      startupError = "libghostty 运行时资源不完整。"
      return false
    }
    setenv("GHOSTTY_RESOURCES_DIR", ghostty.path, 1)
    return true
  }
}
