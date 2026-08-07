import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("OSC 52 写入按当前允许策略替换剪贴板")
@MainActor
func osc52WriteUsesCurrentPermission() {
  var writes: [String] = []
  let coordinator = OSC52ClipboardCoordinator(
    access: { _ in .allow },
    confirm: { _ in
      Issue.record("允许策略不应请求确认")
      return false
    },
    readClipboard: { nil },
    writeClipboard: { text in
      writes.append(text)
      return true
    }
  )
  let payload = "c;\(Data("copied by app".utf8).base64EncodedString())"

  let response = coordinator.handle(ArraySlice(payload.utf8))

  #expect(response == nil)
  #expect(writes == ["copied by app"])
}

@Test("OSC 52 读取在询问获准后返回剪贴板，拒绝策略不读取")
@MainActor
func osc52ReadAsksAndDenyAvoidsClipboardAccess() {
  var confirmations: [OSC52ClipboardOperation] = []
  var reads = 0
  let askingCoordinator = OSC52ClipboardCoordinator(
    access: { _ in .ask },
    confirm: { operation in
      confirmations.append(operation)
      return true
    },
    readClipboard: {
      reads += 1
      return "secret"
    },
    writeClipboard: { _ in false }
  )
  let denyingCoordinator = OSC52ClipboardCoordinator(
    access: { _ in .deny },
    confirm: { _ in
      Issue.record("拒绝策略不应请求确认")
      return true
    },
    readClipboard: {
      reads += 1
      return "secret"
    },
    writeClipboard: { _ in false }
  )

  let allowed = askingCoordinator.handle(ArraySlice("c;?".utf8))
  let denied = denyingCoordinator.handle(ArraySlice("c;?".utf8))

  #expect(String(decoding: allowed ?? [], as: UTF8.self) == "\u{1B}]52;c;c2VjcmV0\u{1B}\\")
  #expect(denied == nil)
  #expect(confirmations == [.read])
  #expect(reads == 1)
}

@Test("OSC 52 每次询问被取消或请求畸形时没有副作用")
@MainActor
func osc52CancelledAndMalformedRequestsAreIgnored() {
  var confirmations = 0
  var reads = 0
  var writes = 0
  let coordinator = OSC52ClipboardCoordinator(
    access: { _ in .ask },
    confirm: { _ in
      confirmations += 1
      return false
    },
    readClipboard: {
      reads += 1
      return "secret"
    },
    writeClipboard: { _ in
      writes += 1
      return true
    }
  )

  #expect(coordinator.handle(ArraySlice("c;?".utf8)) == nil)
  #expect(coordinator.handle(ArraySlice("not-an-osc52-payload".utf8)) == nil)
  #expect(confirmations == 1)
  #expect(reads == 0)
  #expect(writes == 0)
}

@Test("OSC 52 询问在拒绝后冷却，避免连续请求制造模态提示风暴")
@MainActor
func osc52AskPolicyRateLimitsPrompts() {
  var currentTime = Date(timeIntervalSince1970: 100)
  var confirmations = 0
  let coordinator = OSC52ClipboardCoordinator(
    access: { _ in .ask },
    confirm: { _ in
      confirmations += 1
      return false
    },
    readClipboard: { "secret" },
    writeClipboard: { _ in true },
    now: { currentTime },
    promptCooldown: 5
  )

  #expect(coordinator.handle(ArraySlice("c;?".utf8)) == nil)
  #expect(coordinator.handle(ArraySlice("c;?".utf8)) == nil)
  #expect(confirmations == 1)
  currentTime.addTimeInterval(5)
  #expect(coordinator.handle(ArraySlice("c;?".utf8)) == nil)
  #expect(confirmations == 2)
}

@Test("Paste As 主菜单启用文件动作并在 Composer 未接入时禁用")
@MainActor
func pasteAsMenuValidationUsesTerminalCapabilities() {
  let view = AsterTerminalView(frame: .zero)
  let file = NSMenuItem(
    title: "粘贴 Base64 编码文件",
    action: #selector(AsterTerminalView.pasteFileBase64Encoded(_:)),
    keyEquivalent: ""
  )
  let composer = NSMenuItem(
    title: "Composer",
    action: #selector(AsterTerminalView.pasteAndContinueInComposer(_:)),
    keyEquivalent: ""
  )
  #expect(view.responds(to: file.action!))
  #expect(view.responds(to: composer.action!))
  #expect(view.validateUserInterfaceItem(file))
  #expect(!view.validateUserInterfaceItem(composer))
  view.onPasteIntoComposer = { _ in }
  #expect(view.validateUserInterfaceItem(composer))
}
