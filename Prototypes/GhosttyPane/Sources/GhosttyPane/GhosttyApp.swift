// Bridge lifecycle adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit
import Foundation
import GhosttyKit
import os

private let ghosttyLogger = Logger(
  subsystem: "com.asterterminal.ghostty-poc", category: "GhosttyApp")

/// Owns the process-wide libghostty application and its immutable startup config.
///
/// libghostty invokes runtime callbacks from its own threads. `GhosttyCallbacks` copies
/// ephemeral C values synchronously and then schedules AppKit work on the main queue.
@MainActor
final class GhosttyApp {
  static let shared = GhosttyApp()

  private(set) var app: ghostty_app_t?
  private(set) var config: ghostty_config_t?
  let callbacks = GhosttyCallbacks()

  var isReady: Bool { app != nil && config != nil }

  private init() {
    guard resolveResources() else { return }
    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      ghosttyLogger.error("ghostty_init failed")
      return
    }
    guard let config = makeConfig() else {
      ghosttyLogger.error("ghostty_config_new failed")
      return
    }

    var runtime = ghostty_runtime_config_s()
    runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
    runtime.supports_selection_clipboard = true
    runtime.wakeup_cb = { _ in GhosttyApp.shared.callbacks.wakeup() }
    runtime.action_cb = { _, target, action in
      GhosttyApp.shared.callbacks.action(target: target, action: action)
    }
    runtime.read_clipboard_cb = { userdata, location, state in
      GhosttyApp.shared.callbacks.readClipboard(
        userdata: userdata,
        location: location,
        state: state
      )
    }
    runtime.confirm_read_clipboard_cb = { userdata, content, state, request in
      GhosttyApp.shared.callbacks.confirmReadClipboard(
        userdata: userdata,
        content: content,
        state: state,
        request: request
      )
    }
    runtime.write_clipboard_cb = { userdata, _, content, count, confirm in
      GhosttyApp.shared.callbacks.writeClipboard(
        userdata: userdata,
        content: content,
        count: UInt(count),
        confirm: confirm
      )
    }
    runtime.close_surface_cb = { userdata, _ in
      GhosttyApp.shared.callbacks.closeSurface(userdata: userdata)
    }

    guard let app = ghostty_app_new(&runtime, config) else {
      ghosttyLogger.error("ghostty_app_new failed")
      ghostty_config_free(config)
      return
    }
    self.app = app
    self.config = config
  }

  /// Drains all pending libghostty application actions. Wakeups are coalesced by
  /// `GhosttyCallbacks`, so sustained output cannot enqueue an unbounded main queue.
  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  private func makeConfig() -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }

    // The PoC intentionally loads the user's regular Ghostty config when present so
    // font and key behavior are realistic. An invalid option is reported but does not
    // terminate the prototype; libghostty falls back according to its own config rules.
    let userConfig = (NSHomeDirectory() as NSString).appendingPathComponent(
      ".config/ghostty/config")
    if FileManager.default.fileExists(atPath: userConfig) {
      userConfig.withCString { ghostty_config_load_file(config, $0) }
    }
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)

    for index in 0..<ghostty_config_diagnostics_count(config) {
      let diagnostic = ghostty_config_get_diagnostic(config, index)
      if let message = diagnostic.message {
        ghosttyLogger.warning("config: \(String(cString: message), privacy: .public)")
      }
    }
    return config
  }

  private func resolveResources() -> Bool {
    // `GHOSTTY_RESOURCES_DIR` must point at `ghostty/`; libghostty derives the
    // sibling `terminfo/` path itself when spawning the shell. Do not fall back to
    // an installed Ghostty.app: that would let a locally working PoC ship without
    // its own matching resources and hide an XCFramework/resource provenance bug.
    guard let resourceRoot = Bundle.module.resourceURL else {
      unsetenv("GHOSTTY_RESOURCES_DIR")
      ghosttyLogger.error("SwiftPM resource bundle was not found")
      return false
    }
    let path = resourceRoot.appendingPathComponent("ghostty").path(percentEncoded: false)
    let terminfo = resourceRoot.appendingPathComponent("terminfo").path(percentEncoded: false)
    guard
      FileManager.default.fileExists(atPath: path + "/shell-integration"),
      FileManager.default.fileExists(atPath: terminfo + "/78/xterm-ghostty")
    else {
      unsetenv("GHOSTTY_RESOURCES_DIR")
      ghosttyLogger.error("Bundled Ghostty resources are incomplete")
      return false
    }
    setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    return true
  }
}
