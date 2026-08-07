import Foundation

/// Shell 提示符中的原生 macOS 编辑动作。这里只表达用户意图，不依赖 AppKit selector。
public enum NaturalTextEditingAction: CaseIterable, Equatable, Sendable {
  case moveToBeginningOfLine
  case moveToEndOfLine
  case moveWordLeft
  case moveWordRight
  case deleteToBeginningOfLine
  case deleteToEndOfLine
  case deleteWordLeft
  case deleteWordRight
  case undo
}

/// 把原生编辑动作编码成 readline/Emacs 风格字节，确保 zsh、bash 与 fish 的基础
/// 提示符编辑保持一致。增强键盘协议和全屏程序由终端组件继续编码，不走这里。
public enum TerminalInputEncoder {
  public static func encode(_ action: NaturalTextEditingAction) -> [UInt8] {
    switch action {
    case .moveToBeginningOfLine: [0x01]  // C-a
    case .moveToEndOfLine: [0x05]  // C-e
    case .moveWordLeft: [0x1B, 0x62]  // M-b
    case .moveWordRight: [0x1B, 0x66]  // M-f
    case .deleteToBeginningOfLine: [0x15]  // C-u
    case .deleteToEndOfLine: [0x0B]  // C-k
    case .deleteWordLeft: [0x17]  // C-w
    case .deleteWordRight: [0x1B, 0x64]  // M-d
    case .undo: [0x1F]  // C-_
    }
  }
}

/// 决定 Aster 是否接管 AppKit 的原生编辑 selector。全屏 TUI 和已协商 Kitty 键盘
/// 协议的程序必须收到原组件编码，不能被 Shell 专用 readline 字节覆盖。
public enum TerminalInputPolicy {
  public static func usesNaturalTextEditing(
    isAlternateScreen: Bool,
    hasEnhancedKeyboardProtocol: Bool
  ) -> Bool {
    !isAlternateScreen && !hasEnhancedKeyboardProtocol
  }
}

/// 自动安全输入的纯策略。密码读取通常保留 canonical 模式并关闭 ECHO；raw-mode
/// TUI 同时关闭 ICANON，必须排除。只保护当前聚焦终端，避免后台 Pane 长期占用。
public enum TerminalSecureInputPolicy {
  public static func requiresAutomaticProtection(
    enabled: Bool,
    terminalFocused: Bool,
    terminalEchoEnabled: Bool,
    terminalCanonicalMode: Bool
  ) -> Bool {
    enabled && terminalFocused && !terminalEchoEnabled && terminalCanonicalMode
  }
}
