import Testing

@testable import AsterCore

@Test("原生文本编辑动作编码为稳定的 readline 字节")
func naturalTextEditingUsesReadlineSequences() {
  let expected: [(NaturalTextEditingAction, [UInt8])] = [
    (.moveToBeginningOfLine, [0x01]),
    (.moveToEndOfLine, [0x05]),
    (.moveWordLeft, [0x1B, 0x62]),
    (.moveWordRight, [0x1B, 0x66]),
    (.deleteToBeginningOfLine, [0x15]),
    (.deleteToEndOfLine, [0x0B]),
    (.deleteWordLeft, [0x17]),
    (.deleteWordRight, [0x1B, 0x64]),
    (.undo, [0x1F]),
  ]

  for (action, bytes) in expected {
    #expect(TerminalInputEncoder.encode(action) == bytes)
  }
  #expect(NaturalTextEditingAction.allCases.count == expected.count)
}

@Test("原生文本编辑只在普通 Shell 屏幕且未协商增强键盘协议时接管")
func naturalTextEditingPolicyPreservesFullScreenPrograms() {
  #expect(
    TerminalInputPolicy.usesNaturalTextEditing(
      isAlternateScreen: false,
      hasEnhancedKeyboardProtocol: false
    ))
  #expect(
    !TerminalInputPolicy.usesNaturalTextEditing(
      isAlternateScreen: true,
      hasEnhancedKeyboardProtocol: false
    ))
  #expect(
    !TerminalInputPolicy.usesNaturalTextEditing(
      isAlternateScreen: false,
      hasEnhancedKeyboardProtocol: true
    ))
}

@Test("自动安全输入只保护聚焦的 canonical 隐藏输入")
func automaticSecureInputRequiresFocusedHiddenInput() {
  #expect(
    TerminalSecureInputPolicy.requiresAutomaticProtection(
      enabled: true,
      terminalFocused: true,
      terminalEchoEnabled: false,
      terminalCanonicalMode: true
    ))
  #expect(
    !TerminalSecureInputPolicy.requiresAutomaticProtection(
      enabled: false,
      terminalFocused: true,
      terminalEchoEnabled: false,
      terminalCanonicalMode: true
    ))
  #expect(
    !TerminalSecureInputPolicy.requiresAutomaticProtection(
      enabled: true,
      terminalFocused: false,
      terminalEchoEnabled: false,
      terminalCanonicalMode: true
    ))
  #expect(
    !TerminalSecureInputPolicy.requiresAutomaticProtection(
      enabled: true,
      terminalFocused: true,
      terminalEchoEnabled: true,
      terminalCanonicalMode: true
    ))
  #expect(
    !TerminalSecureInputPolicy.requiresAutomaticProtection(
      enabled: true,
      terminalFocused: true,
      terminalEchoEnabled: false,
      terminalCanonicalMode: false
    ))
}
