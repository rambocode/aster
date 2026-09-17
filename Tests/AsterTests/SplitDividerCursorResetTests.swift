import AppKit
import Testing

@testable import Aster

/// 拖完分隔条后指针离开，拖动光标必须复位成箭头：分隔条的 cursor rect 在指针压着的位置
/// 重建时 AppKit 会漏掉「离开」，只能由 mouseExited 自己复位。
@Test("离开 Pane 分隔条时拖动光标复位为箭头")
@MainActor
func paneSplitDividerExitResetsCursor() throws {
  _ = NSApplication.shared
  let split = PersistedSplitView(axis: .horizontal, ratio: 0.5, onRatioChanged: { _ in })
  split.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
  NSCursor.resizeLeftRight.set()
  // `.mouseExited` 是 enter/exit 类事件，用 mouseEvent(with:) 构造会抛 ObjC 异常。
  let event = try #require(NSEvent.enterExitEvent(
    with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
  split.mouseExited(with: event)
  #expect(NSCursor.current == NSCursor.arrow)
}

@Test("离开侧栏分隔条时拖动光标复位为箭头")
@MainActor
func panelSplitDividerExitResetsCursor() throws {
  _ = NSApplication.shared
  let suite = "AsterTests.dividercursor.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let store = WorkspacePanelLayoutStore(defaults: defaults, legacySidebarWidth: 230)
  let split = WorkspacePanelSplitView(panels: [], layoutStore: store, dividerColor: .clear)
  NSCursor.resizeLeftRight.set()
  // `.mouseExited` 是 enter/exit 类事件，用 mouseEvent(with:) 构造会抛 ObjC 异常。
  let event = try #require(NSEvent.enterExitEvent(
    with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
  split.mouseExited(with: event)
  #expect(NSCursor.current == NSCursor.arrow)
}
