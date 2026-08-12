// Callback routing adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit
import GhosttyKit
import os

/// Thread-safe edge between libghostty callbacks and AppKit-owned surface state.
///
/// The C callbacks can arrive off-main and their pointers are valid only for the call.
/// This type therefore copies strings first and never dereferences a view after an async hop
/// unless the view itself is still retained by the window hierarchy.
final class GhosttyCallbacks: @unchecked Sendable {
  private let tickScheduled = OSAllocatedUnfairLock(initialState: false)

  func wakeup() {
    let wasScheduled = tickScheduled.withLock { scheduled -> Bool in
      if scheduled { return true }
      scheduled = true
      return false
    }
    guard !wasScheduled else { return }

    DispatchQueue.main.async { [self] in
      tickScheduled.withLock { $0 = false }
      GhosttyApp.shared.tick()
    }
  }

  func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_RENDER:
      guard let view = surfaceView(from: target) else { return true }
      DispatchQueue.main.async { view.renderNow() }
      return true
    case GHOSTTY_ACTION_SET_TITLE:
      guard let view = surfaceView(from: target) else { return true }
      let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
      DispatchQueue.main.async { view.applyTitle(title) }
      return true
    case GHOSTTY_ACTION_PWD:
      guard let view = surfaceView(from: target), let pointer = action.action.pwd.pwd else {
        return true
      }
      let path = String(cString: pointer)
      DispatchQueue.main.async { view.applyWorkingDirectory(path) }
      return true
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      guard let view = surfaceView(from: target) else { return false }
      DispatchQueue.main.async { view.handleProcessExit() }
      return true
    default:
      return false
    }
  }

  func readClipboard(
    userdata: UnsafeMutableRawPointer?,
    location _: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?
  ) -> Bool {
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    text.withCString {
      ghostty_surface_complete_clipboard_request(surface(from: userdata), $0, state, false)
    }
    return true
  }

  func confirmReadClipboard(
    userdata: UnsafeMutableRawPointer?,
    content: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
  ) {
    guard let content else { return }
    if request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ {
      // The PoC has no permission sheet. Deny terminal-initiated clipboard reads by
      // completing with an empty value; `confirmed = false` would leave the request
      // pending and make libghostty ask again. User-triggered paste remains allowed.
      "".withCString {
        ghostty_surface_complete_clipboard_request(surface(from: userdata), $0, state, true)
      }
    } else {
      ghostty_surface_complete_clipboard_request(surface(from: userdata), content, state, true)
    }
  }

  func writeClipboard(
    userdata _: UnsafeMutableRawPointer?,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: UInt,
    confirm: Bool
  ) {
    // A `confirm` write originates from OSC 52. Until Aster's existing authorization
    // coordinator is adapted, refuse it so a terminal process cannot silently replace
    // the system clipboard. Normal user Copy arrives without this confirmation gate.
    guard !confirm, let content, count > 0 else { return }
    for item in UnsafeBufferPointer(start: content, count: Int(count)) {
      guard
        let mime = item.mime,
        String(cString: mime).hasPrefix("text/plain"),
        let data = item.data
      else { continue }
      let value = String(cString: data)
      DispatchQueue.main.async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
      }
      return
    }
  }

  func closeSurface(userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async { view.handleProcessExit() }
  }

  private func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
    guard
      target.tag == GHOSTTY_TARGET_SURFACE,
      let surface = target.target.surface,
      let userdata = ghostty_surface_userdata(surface)
    else { return nil }
    return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  }

  private func surface(from userdata: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue().surface
  }
}
