import CoreGraphics
import Testing

@testable import AsterCore

/// 侧栏左栏与红绿灯行两块感应区的真值表。
private let sidebar = CGRect(x: 0, y: 0, width: 240, height: 700)
private let titleBarRow = CGRect(x: 0, y: 670, width: 240, height: 30)

@Test("指针停在标签列表上只显示新建按钮")
func pointerInSidebarShowsOnlyNewTab() {
  let visibility = SidebarHoverActionVisibility.resolve(
    pointer: CGPoint(x: 120, y: 400), sidebar: sidebar, titleBarRow: titleBarRow)
  #expect(visibility.showsNewTab)
  #expect(visibility.showsCollapseToggle == false)
}

@Test("指针停在红绿灯行同时显示折叠按钮")
func pointerInTitleBarRowShowsCollapseToggle() {
  let visibility = SidebarHoverActionVisibility.resolve(
    pointer: CGPoint(x: 200, y: 685), sidebar: sidebar, titleBarRow: titleBarRow)
  // 红绿灯行嵌在左栏内部，「+」不能因为进入该行而闪断。
  #expect(visibility.showsNewTab)
  #expect(visibility.showsCollapseToggle)
}

@Test("指针离开左栏后两个按钮都隐藏")
func pointerOutsideSidebarHidesBothActions() {
  let visibility = SidebarHoverActionVisibility.resolve(
    pointer: CGPoint(x: 600, y: 400), sidebar: sidebar, titleBarRow: titleBarRow)
  #expect(visibility == .hidden)
}

@Test("窗口不是键盘焦点窗口时不露出动作按钮")
func inactiveWindowHidesBothActions() {
  let visibility = SidebarHoverActionVisibility.resolve(
    pointer: nil, sidebar: sidebar, titleBarRow: titleBarRow)
  #expect(visibility == .hidden)
}

@Test("标签栏折叠后顶部悬停带同时承担两个按钮")
func collapsedSidebarStripDrivesBothActions() {
  // 折叠态没有左栏，宿主层把同一条悬停带同时传给两个参数。
  let strip = CGRect(x: 0, y: 656, width: 340, height: 44)
  let inside = SidebarHoverActionVisibility.resolve(
    pointer: CGPoint(x: 120, y: 680), sidebar: strip, titleBarRow: strip)
  #expect(inside.showsNewTab)
  #expect(inside.showsCollapseToggle)

  let below = SidebarHoverActionVisibility.resolve(
    pointer: CGPoint(x: 120, y: 400), sidebar: strip, titleBarRow: strip)
  #expect(below == .hidden)
}
