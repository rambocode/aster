import AsterCore
import Testing

@testable import Aster

@Test("Pane 启动环境解析 TERM 并应用 zsh 集成计划")
func terminalLaunchEnvironmentResolvesTermAndShellIntegration() {
  var checked: [(String, String?)] = []
  let result = TerminalLaunchEnvironmentBuilder.make(
    inherited: ["HOME": "/Users/test", "PATH": "/usr/bin"],
    configuredTerm: "aster-direct",
    shellPath: "/bin/zsh",
    shellIntegrationEnabled: true,
    paneIdentifier: "pane-1",
    version: "0.4.1",
    resourcesDirectory: "/Applications/Aster.app/Contents/Resources"
  ) { name, environment in
    checked.append((name, environment["TERMINFO_DIRS"]))
    return name == "aster-direct"
  }

  #expect(result.resolution.term == "aster-direct")
  #expect(result.resolution.warning == nil)
  #expect(result.environment["TERM"] == "aster-direct")
  #expect(result.environment["TERM_PROGRAM"] == "aster")
  #expect(result.environment["ASTER_PANE_ID"] == "pane-1")
  #expect(result.environment["ASTER_INTEGRATION"] == "1")
  #expect(
    result.environment["ZDOTDIR"]
      == "/Applications/Aster.app/Contents/Resources/shell-integration/zsh"
  )
  #expect(checked.count == 1)
  #expect(checked.first?.0 == "aster-direct")
  #expect(
    checked.first?.1
      == "/Applications/Aster.app/Contents/Resources/terminfo:/usr/share/terminfo"
  )
  #expect(result.programIdentity.name == "aster")
  #expect(result.programIdentity.version == "0.4.1")
  #expect(result.programIdentity.deviceAttributesVersion == 401)
}

@Test("缺失 terminfo 安全回退且关闭 Shell 集成时不注入标记变量")
func terminalLaunchEnvironmentFallsBackWithoutShellInjection() {
  let result = TerminalLaunchEnvironmentBuilder.make(
    inherited: ["HOME": "/Users/test"],
    configuredTerm: "missing-term",
    shellPath: "/bin/bash",
    shellIntegrationEnabled: false,
    paneIdentifier: "pane-2",
    version: "2.0.0",
    resourcesDirectory: "/Applications/Aster.app/Contents/Resources"
  ) { _, _ in false }

  #expect(result.resolution.term == "xterm-256color")
  #expect(result.resolution.warning?.contains("missing-term") == true)
  #expect(result.environment["TERM"] == "xterm-256color")
  #expect(result.environment["ASTER_INTEGRATION"] == nil)
  #expect(result.environment["ASTER_SHELL_INTEGRATION_DIR"] == nil)
  #expect(result.programIdentity.deviceAttributesVersion == 20_000)
}
