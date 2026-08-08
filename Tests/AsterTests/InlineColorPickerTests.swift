import AppKit
import AsterCore
import Testing

@testable import Aster

/// 模拟用户在 hex 框里敲字并结束编辑。直接赋 `stringValue` 不会触发
/// `controlTextDidChange`，取色器会把它当成程序回写而不是用户输入。
@MainActor
private func typeHex(_ value: String, into field: NSTextField) {
  field.stringValue = value
  NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
  NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: field)
}

extension NSView {
  /// 本文件用的视图树遍历（`descendants` 在别的测试文件里是 fileprivate）。
  fileprivate var allSubviews: [NSView] {
    subviews.flatMap { [$0] + $0.allSubviews }
  }
}

@Test("取色器加载后回显传入颜色的 hex")
@MainActor
func inlineColorPickerShowsIncomingColorAsHex() throws {
  var picked: [NSColor] = []
  let picker = InlineColorPickerViewController(
    title: "侧栏背景",
    color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
  ) { picked.append($0) }
  picker.loadViewIfNeeded()

  let hexField = try #require(
    picker.view.allSubviews.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "inline-color-picker-hex"
    })
  #expect(hexField.stringValue == "#ff0000")
  // 只是展示，不应在没有交互时就往回写。
  #expect(picked.isEmpty)
}

@Test("取色器不使用系统 NSColorPanel，自绘色域与两条滑条")
@MainActor
func inlineColorPickerIsSelfDrawn() {
  let picker = InlineColorPickerViewController(title: "光标", color: .black) { _ in }
  picker.loadViewIfNeeded()

  let typeNames = picker.view.allSubviews.map { String(describing: type(of: $0)) }
  #expect(typeNames.contains { $0.contains("SaturationBrightnessField") })
  // 色相条与透明度条各一。
  #expect(typeNames.filter { $0.contains("ColorComponentSlider") }.count == 2)
  #expect(typeNames.contains { $0.contains("NSColorWell") } == false)
  #expect(picker.view.allSubviews.contains { $0.identifier?.rawValue == "inline-color-picker-close" })
}

@Test("hex 输入写回颜色，非法输入被丢弃")
@MainActor
func inlineColorPickerAcceptsHexInputAndRejectsGarbage() throws {
  var picked: [NSColor] = []
  let picker = InlineColorPickerViewController(title: "强调色", color: .white) {
    picked.append($0)
  }
  picker.loadViewIfNeeded()
  let hexField = try #require(
    picker.view.allSubviews.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "inline-color-picker-hex"
    })

  // 不带 # 也接受：从主题文件里拷出来的色号两种写法都有。
  typeHex("3b82f6", into: hexField)
  let applied = try #require(picked.last)
  #expect(HexColor(nsColor: applied).displayString == "#3b82f6")

  let countBeforeGarbage = picked.count
  typeHex("not-a-color", into: hexField)
  // 非法输入不产生新颜色，并把输入框还原成当前值。
  #expect(picked.count == countBeforeGarbage)
  #expect(hexField.stringValue == "#3b82f6")
}

@Test("带透明度的颜色保留 alpha")
@MainActor
func inlineColorPickerKeepsAlpha() throws {
  var picked: [NSColor] = []
  let picker = InlineColorPickerViewController(
    title: "选区",
    color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
  ) { picked.append($0) }
  picker.loadViewIfNeeded()
  let hexField = try #require(
    picker.view.allSubviews.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "inline-color-picker-hex"
    })
  // 半透明色显示为 8 位短写。
  #expect(hexField.stringValue.count == 9)
  #expect(picker.currentColor.alphaComponent < 0.6)

  typeHex("#00ff0080", into: hexField)
  let applied = try #require(picked.last)
  #expect(HexColor(nsColor: applied).alpha == 0x80)
}

@Test("拖动色域后 hex 输入框跟着更新")
@MainActor
func inlineColorPickerHexFollowsFieldDrag() throws {
  var picked: [NSColor] = []
  let picker = InlineColorPickerViewController(
    title: "窗口底色",
    color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
  ) { picked.append($0) }
  picker.loadViewIfNeeded()
  let hexField = try #require(
    picker.view.allSubviews.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "inline-color-picker-hex"
    })
  #expect(hexField.stringValue == "#ffffff")

  // 模拟在色域里拖到一个新位置：回归锁——输入框拿到 popover 的初始焦点后，
  // 旧实现用 `currentEditor() == nil` 拦住了同步，色号会永远停在 #ffffff。
  let field = try #require(
    picker.view.allSubviews.first {
      String(describing: type(of: $0)).contains("SaturationBrightnessField")
    })
  field.setFrameSize(NSSize(width: 100, height: 100))
  field.layoutSubtreeIfNeeded()
  let drag = try #require(NSEvent.mouseEvent(
    with: .leftMouseDown,
    location: field.convert(NSPoint(x: 100, y: 0), to: nil),
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    eventNumber: 0,
    clickCount: 1,
    pressure: 1
  ))
  field.mouseDown(with: drag)

  #expect(picked.isEmpty == false)
  #expect(hexField.stringValue != "#ffffff")
  #expect(hexField.stringValue == HexColor(nsColor: picker.currentColor).displayString)
}

@Test("拖动色域不会用输入框里的旧色号把颜色改回去")
@MainActor
func inlineColorPickerDragDoesNotCommitStaleHex() throws {
  var picked: [NSColor] = []
  let picker = InlineColorPickerViewController(
    title: "窗口底色",
    color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
  ) { picked.append($0) }
  picker.loadViewIfNeeded()
  let hexField = try #require(
    picker.view.allSubviews.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "inline-color-picker-hex"
    })

  // 用户没敲过字，结束编辑不该提交——否则拖色时焦点一移走就会被旧色号打回去。
  NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: hexField)
  #expect(picked.isEmpty)
}
