import AppKit
@preconcurrency import GhosttyKit
import os

/// 将 libghostty 的任意线程 C callback 路由到对应 AppKit surface。
/// C 字符串只在 callback 内有效，所有跨线程值必须先复制为 Swift 值。
final class GhosttyCallbacks: @unchecked Sendable {
  private let tickScheduled = OSAllocatedUnfairLock(initialState: false)

  func wakeup() {
    let alreadyScheduled = tickScheduled.withLock { scheduled -> Bool in
      if scheduled { return true }
      scheduled = true
      return false
    }
    guard !alreadyScheduled else { return }
    DispatchQueue.main.async { [self] in
      tickScheduled.withLock { $0 = false }
      GhosttyApp.shared.tick()
    }
  }

  func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
    guard let view = surfaceView(from: target) else { return false }
    switch action.tag {
    case GHOSTTY_ACTION_RENDER:
      DispatchQueue.main.async { view.renderNow() }
    case GHOSTTY_ACTION_SET_TITLE:
      let value = action.action.set_title.title.map { String(cString: $0) } ?? ""
      DispatchQueue.main.async { view.applyTitle(value) }
    case GHOSTTY_ACTION_PWD:
      let value = action.action.pwd.pwd.map { String(cString: $0) } ?? ""
      DispatchQueue.main.async { view.applyWorkingDirectory(value) }
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      let code = Int32(action.action.child_exited.exit_code)
      DispatchQueue.main.async { view.handleProcessExit(code: code) }
    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let raw = action.action.command_finished.exit_code
      let code = raw < 0 ? nil : Int(raw)
      DispatchQueue.main.async { view.handleCommandFinished(exitCode: code) }
    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let report = action.action.progress_report
      let percent = report.progress < 0 ? nil : Int(report.progress)
      let value: GhosttyProgress
      switch report.state {
      case GHOSTTY_PROGRESS_STATE_REMOVE: value = .clear
      case GHOSTTY_PROGRESS_STATE_SET: value = .determinate(percent ?? 0)
      case GHOSTTY_PROGRESS_STATE_INDETERMINATE: value = .indeterminate
      case GHOSTTY_PROGRESS_STATE_PAUSE: value = .paused(percent)
      case GHOSTTY_PROGRESS_STATE_ERROR: value = .error(percent)
      default: value = .clear
      }
      DispatchQueue.main.async { view.handleProgress(value) }
    case GHOSTTY_ACTION_START_SEARCH:
      let needle = action.action.start_search.needle.map { String(cString: $0) }
      DispatchQueue.main.async { view.handleSearchStart(needle: needle) }
    case GHOSTTY_ACTION_END_SEARCH:
      DispatchQueue.main.async { view.handleSearchEnd() }
    case GHOSTTY_ACTION_SEARCH_TOTAL:
      let raw = action.action.search_total.total
      DispatchQueue.main.async { view.handleSearchTotal(raw < 0 ? nil : Int(raw)) }
    case GHOSTTY_ACTION_SEARCH_SELECTED:
      let raw = action.action.search_selected.selected
      DispatchQueue.main.async { view.handleSearchSelected(raw < 0 ? nil : Int(raw)) }
    case GHOSTTY_ACTION_READONLY:
      let enabled = action.action.readonly == GHOSTTY_READONLY_ON
      DispatchQueue.main.async { view.handleReadOnly(enabled) }
    case GHOSTTY_ACTION_OPEN_URL:
      let payload = action.action.open_url
      guard let pointer = payload.url else { return true }
      let value = String(
        decoding: UnsafeRawBufferPointer(start: pointer, count: Int(payload.len)), as: UTF8.self)
      DispatchQueue.main.async { view.handleOpenURL(value) }
    case GHOSTTY_ACTION_SECURE_INPUT:
      let mode = action.action.secure_input
      DispatchQueue.main.async { view.handleSecureInput(mode) }
    case GHOSTTY_ACTION_RING_BELL:
      DispatchQueue.main.async { view.handleBell() }
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let payload = action.action.desktop_notification
      let title = payload.title.map { String(cString: $0) } ?? ""
      let body = payload.body.map { String(cString: $0) } ?? ""
      DispatchQueue.main.async { view.handleNotification(title: title, body: body) }
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      // 空 URL 表示指针离开链接，用于清除预览徽章；字节必须在 callback 内复制。
      let payload = action.action.mouse_over_link
      let value: String
      if let pointer = payload.url, payload.len > 0 {
        value = String(
          decoding: UnsafeRawBufferPointer(start: pointer, count: Int(payload.len)), as: UTF8.self)
      } else {
        value = ""
      }
      DispatchQueue.main.async { view.handleMouseOverLink(value) }
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      let shape = action.action.mouse_shape
      DispatchQueue.main.async { view.applyMouseShape(shape) }
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
      DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(hidden) }
    default:
      return false
    }
    return true
  }

  func readClipboard(
    userdata: UnsafeMutableRawPointer?,
    location _: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?
  ) -> Bool {
    guard let view = surfaceView(from: userdata) else { return false }
    let text = onMain { view.readSystemClipboard() } ?? ""
    text.withCString {
      ghostty_surface_complete_clipboard_request(view.surface, $0, state, false)
    }
    return true
  }

  func confirmReadClipboard(
    userdata: UnsafeMutableRawPointer?,
    content: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
  ) {
    guard let view = surfaceView(from: userdata) else { return }
    let copiedContent = content.map { String(cString: $0) } ?? ""
    let allowed = onMain {
      switch request {
      case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
        return view.authorizeClipboard(.read)
      case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
        return view.authorizeClipboard(.write)
      default:
        return true
      }
    }
    let result = allowed ? copiedContent : ""
    result.withCString {
      ghostty_surface_complete_clipboard_request(view.surface, $0, state, true)
    }
  }

  func writeClipboard(
    userdata: UnsafeMutableRawPointer?,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: UInt,
    confirm: Bool
  ) {
    guard let view = surfaceView(from: userdata), let content, count > 0 else { return }
    var text: String?
    for item in UnsafeBufferPointer(start: content, count: Int(count)) {
      guard
        let mime = item.mime,
        String(cString: mime).hasPrefix("text/plain"),
        let data = item.data
      else { continue }
      text = String(cString: data)
      break
    }
    guard let text else { return }
    onMain {
      guard !confirm || view.authorizeClipboard(.write) else { return }
      view.writeSystemClipboard(text)
    }
  }

  func closeSurface(userdata: UnsafeMutableRawPointer?) {
    guard let view = surfaceView(from: userdata) else { return }
    DispatchQueue.main.async { view.handleProcessExit(code: nil) }
  }

  /// callback payload 属于 Ghostty IO 栈帧；返回前必须复制，之后才允许跨线程投递。
  func ptyRead(
    userdata: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int
  ) {
    guard let view = surfaceView(from: userdata), let bytes, count > 0 else { return }
    view.enqueuePTYRead(Array(UnsafeBufferPointer(start: bytes, count: Int(count))))
  }

  func ptyWrite(
    userdata: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    count: Int
  ) {
    guard let view = surfaceView(from: userdata), let bytes, count > 0 else { return }
    view.enqueuePTYWrite(Array(UnsafeBufferPointer(start: bytes, count: Int(count))))
  }

  func osc(
    userdata: UnsafeMutableRawPointer?,
    code: UInt32,
    payload: UnsafePointer<UInt8>?,
    count: Int,
    point: UnsafePointer<ghostty_aster_buffer_point_s>?
  ) {
    guard let view = surfaceView(from: userdata), let point else { return }
    let copied = payload.map {
      Array(UnsafeBufferPointer(start: $0, count: Int(count)))
    } ?? []
    view.enqueueOSC(code: code, payload: copied, point: point.pointee)
  }

  private func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
    guard
      target.tag == GHOSTTY_TARGET_SURFACE,
      let surface = target.target.surface,
      let userdata = ghostty_surface_userdata(surface)
    else { return nil }
    return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  }

  private func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
  }

  /// 剪贴板与授权 UI 必须在主线程同步完成，因为 C callback 返回后 request state 失效。
  private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
  }
}
