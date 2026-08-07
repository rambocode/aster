import AppKit
import AsterCore
import Testing

@testable import Aster

@Test("终端输出与用户输入都会触发安全输入即时采样")
@MainActor
func terminalIOTriggersSecureInputSampling() {
  let view = AsterTerminalView(frame: .zero)
  var samples = 0
  view.onTerminalIO = { samples += 1 }

  view.dataReceived(slice: Array("prompt".utf8)[...])
  #expect(samples == 1)

  view.send(source: view, data: Array("x".utf8)[...])
  #expect(samples == 2)
}

@Test("原生编辑菜单动作只在普通终端屏幕启用")
@MainActor
func naturalEditingMenuValidationPreservesAlternateScreen() {
  let view = AsterTerminalView(frame: .zero)
  let item = NSMenuItem(
    title: "移到行首",
    action: #selector(AsterTerminalView.movePromptToBeginningOfLine(_:)),
    keyEquivalent: ""
  )

  #expect(view.responds(to: item.action!))
  #expect(view.validateUserInterfaceItem(item))

  view.getTerminal().feed(byteArray: Array("\u{1B}[?1049h".utf8))
  #expect(view.getTerminal().isCurrentBufferAlternate)
  #expect(!view.validateUserInterfaceItem(item))
}
