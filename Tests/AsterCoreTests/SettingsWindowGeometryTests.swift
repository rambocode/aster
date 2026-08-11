import Testing

@testable import AsterCore

// 设置窗口尺寸记忆的钳制规则：恢复出来的窗口不能小于设计下限，也不能超过当前屏幕。

@Test("记忆宽度低于下限时回到最小宽度")
func settingsWindowWidthClampsToMinimum() {
  #expect(
    SettingsWindowGeometry.clampWidth(320, availableWidth: 1_600)
      == SettingsWindowGeometry.minimumWidth)
}

@Test("记忆宽度超过可视屏幕时被收回屏幕宽度")
func settingsWindowWidthClampsToScreen() {
  #expect(SettingsWindowGeometry.clampWidth(1_800, availableWidth: 1_200) == 1_200)
}

@Test("合法记忆宽度原样保留")
func settingsWindowWidthKeepsValidValue() {
  #expect(SettingsWindowGeometry.clampWidth(940, availableWidth: 1_600) == 940)
}

@Test("非法记忆宽度退回默认宽度")
func settingsWindowWidthRejectsInvalidValue() {
  #expect(
    SettingsWindowGeometry.clampWidth(.nan, availableWidth: 1_600)
      == SettingsWindowGeometry.width)
  #expect(
    SettingsWindowGeometry.clampWidth(0, availableWidth: 1_600)
      == SettingsWindowGeometry.width)
}

@Test("记忆高度低于下限时回到最小高度")
func settingsWindowHeightClampsToMinimum() {
  #expect(
    SettingsWindowGeometry.clampHeight(120, availableHeight: 1_000)
      == SettingsWindowGeometry.minimumHeight)
}

@Test("记忆高度超过可视屏幕时被收回屏幕高度")
func settingsWindowHeightClampsToScreen() {
  // 换到更小的屏幕后恢复：窗口不能高过屏幕，否则标题栏被推到菜单栏之上没法拖动。
  #expect(SettingsWindowGeometry.clampHeight(1_600, availableHeight: 900) == 900)
}

@Test("合法记忆高度原样保留")
func settingsWindowHeightKeepsValidValue() {
  #expect(SettingsWindowGeometry.clampHeight(820, availableHeight: 1_000) == 820)
}

@Test("屏幕比最小高度还小时以最小高度为准")
func settingsWindowHeightPrefersMinimumOverTinyScreen() {
  #expect(
    SettingsWindowGeometry.clampHeight(700, availableHeight: 200)
      == SettingsWindowGeometry.minimumHeight)
}

@Test("非法记忆值退回默认高度")
func settingsWindowHeightRejectsInvalidValue() {
  #expect(
    SettingsWindowGeometry.clampHeight(.nan, availableHeight: 1_000)
      == SettingsWindowGeometry.defaultHeight)
  #expect(
    SettingsWindowGeometry.clampHeight(0, availableHeight: 1_000)
      == SettingsWindowGeometry.defaultHeight)
  #expect(
    SettingsWindowGeometry.clampHeight(-40, availableHeight: 1_000)
      == SettingsWindowGeometry.defaultHeight)
}
