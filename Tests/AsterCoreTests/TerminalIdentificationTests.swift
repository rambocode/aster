import Foundation
import Testing

@testable import AsterCore

@Test("TERM auto 优先内置 xterm-ghostty")
func automaticTerminalIdentityPrefersBundledGhosttyEntry() {
  var checkedNames: [String] = []

  let resolution = TerminalIdentityPolicy.resolve(configuredName: "auto") { name in
    checkedNames.append(name)
    return name == "xterm-ghostty"
  }

  #expect(resolution.term == "xterm-ghostty")
  #expect(resolution.warning == nil)
  #expect(checkedNames == ["xterm-ghostty"])
}

@Test("TERM auto 缺内置条目时静默回退且空配置等价 auto")
func automaticTerminalIdentityFallsBackSilently() {
  let missing = TerminalIdentityPolicy.resolve(configuredName: "auto") { _ in false }
  let empty = TerminalIdentityPolicy.resolve(configuredName: "") { _ in false }

  #expect(missing.term == "xterm-256color")
  #expect(missing.warning == nil)
  #expect(empty.term == "xterm-256color")
  #expect(empty.warning == nil)
}

@Test("自定义 TERM 仅在语法安全且 terminfo 已安装时生效")
func customTerminalIdentityRequiresInstalledEntry() {
  let installed = TerminalIdentityPolicy.resolve(configuredName: "aster-direct") {
    $0 == "aster-direct"
  }
  let missing = TerminalIdentityPolicy.resolve(configuredName: "missing-term") { _ in false }
  let unsafe = TerminalIdentityPolicy.resolve(configuredName: "../../unsafe") { _ in true }
  let nonASCII = TerminalIdentityPolicy.resolve(configuredName: "终端") { _ in true }
  let optionLike = TerminalIdentityPolicy.resolve(configuredName: "-V") { _ in true }

  #expect(installed.term == "aster-direct")
  #expect(installed.warning == nil)
  #expect(missing.term == "xterm-256color")
  #expect(missing.warning?.contains("missing-term") == true)
  #expect(unsafe.term == "xterm-256color")
  #expect(unsafe.warning?.contains("非法") == true)
  #expect(nonASCII.term == "xterm-256color")
  #expect(optionLike.term == "xterm-256color")
}

@Test("产品版本同时生成原始标识和 DA2 整数")
func terminalVersionEncodesStableDeviceAttributeValue() {
  #expect(TerminalProductVersion("1.0.2").deviceAttributesValue == 10_002)
  #expect(TerminalProductVersion("12.34.56-beta.3").deviceAttributesValue == 123_456)
  #expect(TerminalProductVersion("0.4").deviceAttributesValue == 400)
  #expect(TerminalProductVersion("bad").deviceAttributesValue == 0)
  #expect(TerminalProductVersion("\(Int.max).1.1").deviceAttributesValue == 0)
}

@Test("终端环境包含品牌标识、稳定 Pane ID 和优先 terminfo 目录")
func terminalEnvironmentContainsIdentificationContract() {
  let environment = TerminalIdentityPolicy.environment(
    inherited: ["PATH": "/usr/bin", "TERMINFO_DIRS": "/custom/terminfo"],
    term: "aster-direct",
    version: "0.4.1",
    paneIdentifier: "pane-123",
    bundledTerminfoDirectories: [
      "/Applications/Aster.app/Contents/Resources/terminfo",
      "/Engine.bundle/terminfo",
    ]
  )

  #expect(environment["TERM"] == "aster-direct")
  #expect(environment["COLORTERM"] == "truecolor")
  #expect(environment["TERM_PROGRAM"] == "aster")
  #expect(environment["TERM_PROGRAM_VERSION"] == "0.4.1")
  #expect(environment["CW_TERM"] == "aster")
  #expect(environment["ASTER_PANE_ID"] == "pane-123")
  #expect(environment["ASTER_SESSION_ID"] == "pane-123")
  #expect(
    environment["TERMINFO_DIRS"]
      == "/Applications/Aster.app/Contents/Resources/terminfo:/Engine.bundle/terminfo:/custom/terminfo:/usr/share/terminfo"
  )
  #expect(environment["PATH"] == "/usr/bin")
}
