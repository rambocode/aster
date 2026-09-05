import AppKit
import Carbon

/// Carbon 热键不监听普通键盘输入，也不需要辅助功能授权。注册失败保留菜单入口。
@MainActor
final class QuickTerminalHotKey {
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var registeredShortcut: String?
  var onToggle: (() -> Void)?

  isolated deinit { stop() }

  func configure(shortcut: String) -> OSStatus {
    guard ["none", "controlGrave", "controlOptionSpace"].contains(shortcut) else {
      stop()
      return OSStatus(paramErr)
    }
    if registeredShortcut == shortcut { return noErr }
    stop()
    guard shortcut != "none" else {
      registeredShortcut = shortcut
      return noErr
    }
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        var identifier = EventHotKeyID()
        guard let event,
          GetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
            &identifier) == noErr,
          identifier.signature == 0x4153_5451, identifier.id == 1
        else { return OSStatus(eventNotHandledErr) }
        guard let context else { return OSStatus(eventNotHandledErr) }
        MainActor.assumeIsolated {
          Unmanaged<QuickTerminalHotKey>.fromOpaque(context).takeUnretainedValue().onToggle?()
        }
        return noErr
      }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard status == noErr else { return status }
    let modifiers = shortcut == "controlOptionSpace" ? controlKey | optionKey : controlKey
    let key = shortcut == "controlOptionSpace" ? kVK_Space : kVK_ANSI_Grave
    let result = RegisterEventHotKey(
      UInt32(key), UInt32(modifiers),
      EventHotKeyID(signature: 0x4153_5451, id: 1), GetApplicationEventTarget(), 0, &reference)
    if result == noErr { registeredShortcut = shortcut } else { stop() }
    return result
  }

  /// 应用结束或配置变化时显式释放系统注册，重复调用无副作用。
  func stop() {
    if let reference { UnregisterEventHotKey(reference) }
    if let handler { RemoveEventHandler(handler) }
    reference = nil
    handler = nil
    registeredShortcut = nil
  }
}
