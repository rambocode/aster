import AppKit
@preconcurrency import GhosttyKit

extension GhosttySurfaceView {
  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    if navigationMode != .normal {
      handleGhosttyPaneModeKeyDown(event)
      return
    }
    if onAutocompleteKeyDown?(event) == true { return }
    guard let surface, !readOnly else {
      if readOnly { NSSound.beep() } else { super.keyDown(with: event) }
      return
    }
    onUserInput?()
    let action: ghostty_input_action_e =
      event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
      !hasMarkedText()
    {
      var key = buildKeyEvent(from: event, action: action)
      let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
      if text.isEmpty {
        key.text = nil
        _ = ghostty_surface_key(surface, key)
      } else {
        text.withCString {
          key.text = $0
          _ = ghostty_surface_key(surface, key)
        }
      }
      return
    }

    if flags.contains(.command) {
      var key = buildKeyEvent(from: event, action: action)
      key.text = nil
      if ghostty_surface_key(surface, key) { return }
      super.keyDown(with: event)
      return
    }

    let hadMarkedText = hasMarkedText()
    currentKeyEvent = event
    keyTextAccumulator = []
    let translated = translatedEvent(for: event)
    interpretKeyEvents([translated])
    currentKeyEvent = nil

    var key = buildKeyEvent(from: event, action: action)
    key.consumed_mods = consumedModifiers(translated.modifierFlags)
    key.composing = hasMarkedText() || hadMarkedText

    if !keyTextAccumulator.isEmpty {
      var committed = key
      committed.composing = false
      for text in keyTextAccumulator {
        text.withCString {
          committed.text = $0
          _ = ghostty_surface_key(surface, committed)
        }
      }
    } else if !hasMarkedText() {
      let text = printableText(event.characters ?? "")
      if !text.isEmpty, !key.composing {
        text.withCString {
          key.text = $0
          _ = ghostty_surface_key(surface, key)
        }
      } else {
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.text = nil
        _ = ghostty_surface_key(surface, key)
      }
    }
  }

  override func doCommand(by selector: Selector) {}

  override func keyUp(with event: NSEvent) {
    guard navigationMode == .normal, let surface else { return }
    var key = buildKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
    key.text = nil
    _ = ghostty_surface_key(surface, key)
  }

  override func flagsChanged(with event: NSEvent) {
    // 按下/松开 Command 本身也要刷新下划线与路径预览,即使鼠标没有移动。
    if event.keyCode == 54 || event.keyCode == 55 {
      handleCommandModifierChange(pressed: event.modifierFlags.contains(.command))
    }
    updateCommandHoverPreview(with: event)
    guard navigationMode == .normal, let surface else { return }
    let action: ghostty_input_action_e =
      modifierWasPressed(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    var key = buildKeyEvent(from: event, action: action)
    key.text = nil
    _ = ghostty_surface_key(surface, key)
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
    guard let surface else { return }
    window?.makeFirstResponder(self)
    guard navigationMode == .normal else { return }
    beginCommandClickTracking(with: event)
    reportMousePosition(event)
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modifiers(event))
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    if focusFollowsMouse { onRequestFocus?() }
  }

  override func mouseUp(with event: NSEvent) {
    guard navigationMode == .normal, let surface else { return }
    reportMousePosition(event)
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modifiers(event))
    // 先让 Ghostty 处理 OSC 8 原生打开，再由 Aster 侧识别普通文字目标。
    finishCommandClick(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let surface else { return }
    window?.makeFirstResponder(self)
    guard navigationMode == .normal else { return }
    if event.modifierFlags.contains(.control) {
      if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
      return
    }
    reportMousePosition(event)
    let consumed = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modifiers(event))
    // `context-menu` 会由 Ghostty 先校正选区并返回 false，宿主随后展示原生菜单。
    if !consumed, let menu = menu(for: event) {
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
  }

  override func rightMouseUp(with event: NSEvent) {
    guard navigationMode == .normal, let surface,
      !event.modifierFlags.contains(.control) else { return }
    reportMousePosition(event)
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modifiers(event))
  }

  override func otherMouseDown(with event: NSEvent) {
    guard navigationMode == .normal else { return }
    guard event.buttonNumber == 2, let surface else {
      super.otherMouseDown(with: event)
      return
    }
    reportMousePosition(event)
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, modifiers(event))
  }

  override func otherMouseUp(with event: NSEvent) {
    guard navigationMode == .normal else { return }
    guard event.buttonNumber == 2, let surface else {
      super.otherMouseUp(with: event)
      return
    }
    reportMousePosition(event)
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, modifiers(event))
  }

  override func mouseMoved(with event: NSEvent) {
    if navigationMode == .normal { reportMousePosition(event) }
    handleLinkHoverMouseMoved(with: event)
    updateCommandHoverPreview(with: event)
  }

  override func cursorUpdate(with event: NSEvent) {
    handleLinkHoverMouseMoved(with: event)
    if !linkHoverCursorActive { applyMouseShape(lastGhosttyMouseShape) }
  }
  override func mouseDragged(with event: NSEvent) {
    if navigationMode == .normal { reportMousePosition(event) }
  }
  override func rightMouseDragged(with event: NSEvent) {
    if navigationMode == .normal { reportMousePosition(event) }
  }
  override func otherMouseDragged(with event: NSEvent) {
    if navigationMode == .normal { reportMousePosition(event) }
  }

  override func mouseExited(with event: NSEvent) {
    // 指针离开 surface 时,两个来源的预览与下划线都必须清除(原生的清除信号只覆盖 OSC 8)。
    removeLinkPreview()
    handleLinkHoverMouseExited()
    guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
    ghostty_surface_mouse_pos(surface, -1, -1, modifiers(event))
  }

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    if navigationMode != .normal {
      handleGhosttyViewportChange()
      if event.scrollingDeltaY > 0 {
        _ = performBindingAction("scroll_page_up")
      } else if event.scrollingDeltaY < 0 {
        _ = performBindingAction("scroll_page_down")
      }
      return
    }
    reportMousePosition(event)
    var scrollModifiers: ghostty_input_scroll_mods_t = 0
    if event.hasPreciseScrollingDeltas { scrollModifiers |= 1 }
    ghostty_surface_mouse_scroll(
      surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollModifiers)
    // 滚动改变视口行，Command 下划线要跟着重扫。
    scheduleLinkUnderlineRefresh()
  }

  private func reportMousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let local = convert(event.locationInWindow, from: nil)
    let point = NSPoint(x: local.x, y: bounds.height - local.y)
    ghostty_surface_mouse_pos(surface, point.x, point.y, modifiers(event))
  }

  // MARK: - Key translation

  private func buildKeyEvent(
    from event: NSEvent,
    action: ghostty_input_action_e
  ) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(event.keyCode)
    key.mods = modifiers(event)
    key.consumed_mods = GHOSTTY_MODS_NONE
    key.composing = false
    key.text = nil
    key.unshifted_codepoint = unshiftedCodepoint(event)
    return key
  }

  private func consumedModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
  }

  private func modifiers(_ event: NSEvent) -> ghostty_input_mods_e {
    var raw = GHOSTTY_MODS_NONE.rawValue
    let flags = event.modifierFlags
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }

    let deviceFlags = flags.rawValue
    if deviceFlags & 0x04 != 0, deviceFlags & 0x02 == 0 {
      raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue
    }
    if deviceFlags & 0x2000 != 0, deviceFlags & 0x01 == 0 {
      raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue
    }
    if deviceFlags & 0x40 != 0, deviceFlags & 0x20 == 0 {
      raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue
    }
    if deviceFlags & 0x10 != 0, deviceFlags & 0x08 == 0 {
      raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue
    }
    return ghostty_input_mods_e(rawValue: raw)
  }

  private func modifierWasPressed(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 56, 60: return event.modifierFlags.contains(.shift)
    case 58, 61: return event.modifierFlags.contains(.option)
    case 59, 62: return event.modifierFlags.contains(.control)
    case 55, 54: return event.modifierFlags.contains(.command)
    case 57: return event.modifierFlags.contains(.capsLock)
    default: return false
    }
  }

  private func printableText(_ text: String) -> String {
    guard let scalar = text.unicodeScalars.first else { return "" }
    if scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) { return "" }
    return text
  }

  private func translatedEvent(for event: NSEvent) -> NSEvent {
    guard let surface else { return event }
    let translationRaw = ghostty_surface_key_translation_mods(surface, modifiers(event)).rawValue
    var flags = event.modifierFlags
    let mapping: [(UInt32, NSEvent.ModifierFlags)] = [
      (GHOSTTY_MODS_SHIFT.rawValue, .shift),
      (GHOSTTY_MODS_CTRL.rawValue, .control),
      (GHOSTTY_MODS_ALT.rawValue, .option),
      (GHOSTTY_MODS_SUPER.rawValue, .command),
    ]
    for (bit, flag) in mapping {
      if translationRaw & bit != 0 { flags.insert(flag) } else { flags.remove(flag) }
    }
    guard flags != event.modifierFlags else { return event }
    let characters = event.characters(byApplyingModifiers: flags) ?? ""
    return NSEvent.keyEvent(
      with: event.type,
      location: event.locationInWindow,
      modifierFlags: flags,
      timestamp: event.timestamp,
      windowNumber: event.windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      isARepeat: event.isARepeat,
      keyCode: event.keyCode
    ) ?? event
  }

  private func unshiftedCodepoint(_ event: NSEvent) -> UInt32 {
    guard
      event.type == .keyDown || event.type == .keyUp,
      let characters = event.characters(byApplyingModifiers: []),
      let scalar = characters.unicodeScalars.first
    else { return 0 }
    return scalar.value
  }
}
