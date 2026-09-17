import Foundation
import Testing

@testable import Aster

@Test("Shell 集成安装幂等且禁用后保留用户 rc 内容")
func shellIntegrationInstallerIsIdempotentAndReversible() throws {
  let home = try temporaryDirectory(named: "aster-shell-home")
  defer { try? FileManager.default.removeItem(at: home) }
  let bashRC = home.appendingPathComponent(".bashrc")
  let zshRC = home.appendingPathComponent(".zshrc")
  try "export USER_VALUE=1\n".write(to: bashRC, atomically: true, encoding: .utf8)
  try "source ~/.zsh/plugins.zsh\n".write(to: zshRC, atomically: true, encoding: .utf8)
  let installer = ShellIntegrationInstaller(
    resourceDirectory: repositoryRoot.appendingPathComponent("Resources/shell-integration"),
    homeDirectory: home,
    tmuxAvailable: true
  )

  try installer.reconcile(enabled: true)
  try installer.reconcile(enabled: true)

  let bashText = try String(contentsOf: bashRC, encoding: .utf8)
  let profileText = try String(
    contentsOf: home.appendingPathComponent(".bash_profile"), encoding: .utf8)
  let zshText = try String(contentsOf: zshRC, encoding: .utf8)
  let fishText = try String(
    contentsOf: home.appendingPathComponent(
      ".config/fish/conf.d/aster-shell-integration.fish"),
    encoding: .utf8
  )
  #expect(bashText.components(separatedBy: ShellIntegrationInstaller.startMarker).count == 2)
  #expect(profileText.components(separatedBy: ShellIntegrationInstaller.startMarker).count == 2)
  #expect(zshText.components(separatedBy: ShellIntegrationInstaller.startMarker).count == 2)
  #expect(fishText.components(separatedBy: ShellIntegrationInstaller.startMarker).count == 2)
  #expect(bashText.contains("export USER_VALUE=1"))
  #expect(zshText.contains("source ~/.zsh/plugins.zsh"))

  try installer.reconcile(enabled: false)

  #expect(try String(contentsOf: bashRC, encoding: .utf8) == "export USER_VALUE=1\n")
  #expect(try String(contentsOf: zshRC, encoding: .utf8) == "source ~/.zsh/plugins.zsh\n")
  #expect(
    try String(contentsOf: home.appendingPathComponent(".bash_profile"), encoding: .utf8).isEmpty
  )
  #expect(
    try String(
      contentsOf: home.appendingPathComponent(
        ".config/fish/conf.d/aster-shell-integration.fish"), encoding: .utf8
    ).isEmpty
  )
}

@Test("受管 rc 是符号链接时编辑真实文件而不替换链接")
func shellIntegrationInstallerPreservesRCSymlink() throws {
  let home = try temporaryDirectory(named: "aster-shell-symlink")
  defer { try? FileManager.default.removeItem(at: home) }
  let configurationDirectory = home.appendingPathComponent("dotfiles")
  try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
  let target = configurationDirectory.appendingPathComponent("bashrc")
  try "alias ll='ls -l'\n".write(to: target, atomically: true, encoding: .utf8)
  let link = home.appendingPathComponent(".bashrc")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  let installer = ShellIntegrationInstaller(
    resourceDirectory: repositoryRoot.appendingPathComponent("Resources/shell-integration"),
    homeDirectory: home,
    tmuxAvailable: false
  )

  try installer.reconcile(enabled: true)

  let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
  #expect(values.isSymbolicLink == true)
  #expect(try String(contentsOf: target, encoding: .utf8).contains("alias ll='ls -l'"))
  #expect(try String(contentsOf: target, encoding: .utf8).contains("aster-integration.bash"))
}

@Test("损坏的受管标记会停止安装且不改写文件")
func shellIntegrationInstallerRejectsMalformedManagedBlock() throws {
  let home = try temporaryDirectory(named: "aster-shell-malformed")
  defer { try? FileManager.default.removeItem(at: home) }
  let bashRC = home.appendingPathComponent(".bashrc")
  let original = "before\n\(ShellIntegrationInstaller.startMarker)\nmissing end\n"
  try original.write(to: bashRC, atomically: true, encoding: .utf8)
  let installer = ShellIntegrationInstaller(
    resourceDirectory: repositoryRoot.appendingPathComponent("Resources/shell-integration"),
    homeDirectory: home,
    tmuxAvailable: false
  )

  #expect(throws: ShellIntegrationInstallerError.malformedManagedBlock(bashRC.path)) {
    try installer.reconcile(enabled: true)
  }
  #expect(try String(contentsOf: bashRC, encoding: .utf8) == original)
}

@Test("任一启动文件预检失败时不改写其他启动文件")
func shellIntegrationInstallerPreflightsAllFilesBeforeWriting() throws {
  let home = try temporaryDirectory(named: "aster-shell-preflight")
  defer { try? FileManager.default.removeItem(at: home) }
  let bashRC = home.appendingPathComponent(".bashrc")
  let bashProfile = home.appendingPathComponent(".bash_profile")
  let originalRC = "export USER_VALUE=1\n"
  let malformedProfile = "before\n\(ShellIntegrationInstaller.startMarker)\nmissing end\n"
  try originalRC.write(to: bashRC, atomically: true, encoding: .utf8)
  try malformedProfile.write(to: bashProfile, atomically: true, encoding: .utf8)
  let installer = ShellIntegrationInstaller(
    resourceDirectory: repositoryRoot.appendingPathComponent("Resources/shell-integration"),
    homeDirectory: home,
    tmuxAvailable: true
  )

  #expect(throws: ShellIntegrationInstallerError.malformedManagedBlock(bashProfile.path)) {
    try installer.reconcile(enabled: true)
  }
  #expect(try String(contentsOf: bashRC, encoding: .utf8) == originalRC)
  #expect(try String(contentsOf: bashProfile, encoding: .utf8) == malformedProfile)
  #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))
}

@Test("后续启动文件写入失败时回滚已经更新的文件")
func shellIntegrationInstallerRollsBackEarlierWrites() throws {
  let home = try temporaryDirectory(named: "aster-shell-rollback")
  defer { try? FileManager.default.removeItem(at: home) }
  let bashRC = home.appendingPathComponent(".bashrc")
  let originalRC = "export USER_VALUE=1\n"
  try originalRC.write(to: bashRC, atomically: true, encoding: .utf8)

  let restrictedDirectory = home.appendingPathComponent("restricted", isDirectory: true)
  try FileManager.default.createDirectory(at: restrictedDirectory, withIntermediateDirectories: true)
  let profileTarget = restrictedDirectory.appendingPathComponent("bash_profile")
  try "export PROFILE_VALUE=1\n".write(
    to: profileTarget, atomically: true, encoding: .utf8)
  try FileManager.default.createSymbolicLink(
    at: home.appendingPathComponent(".bash_profile"), withDestinationURL: profileTarget)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: restrictedDirectory.path)
  defer {
    try? FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: restrictedDirectory.path)
  }
  let installer = ShellIntegrationInstaller(
    resourceDirectory: repositoryRoot.appendingPathComponent("Resources/shell-integration"),
    homeDirectory: home,
    tmuxAvailable: false
  )

  do {
    try installer.reconcile(enabled: true)
    Issue.record("不可写的后续启动文件应使安装失败")
  } catch {
    // 具体 Cocoa 错误码依赖文件系统；这里只验证失败后的跨文件恢复语义。
  }

  #expect(try String(contentsOf: bashRC, encoding: .utf8) == originalRC)
  #expect(try String(contentsOf: profileTarget, encoding: .utf8) == "export PROFILE_VALUE=1\n")
}

@Test("Shell 集成资源存在并通过对应 Shell 语法检查")
func shellIntegrationResourcesAreReadableAndSyntacticallyValid() throws {
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  let required = [
    "aster-integration.zsh",
    "aster-integration.bash",
    "aster-integration.fish",
    "aster-ssh.zsh",
    "aster-ssh.bash",
    "aster-ssh.fish",
    "zsh/.zshenv",
    "fish/vendor_conf.d/aster-shell-integration.fish",
  ]
  for relativePath in required {
    let url = root.appendingPathComponent(relativePath)
    #expect(FileManager.default.isReadableFile(atPath: url.path), "缺少资源：\(relativePath)")
    let contents = try String(contentsOf: url, encoding: .utf8)
    #expect(!contents.contains("OTTY"))
    #expect(!contents.contains("otty"))
  }
  let fishPayload = try String(
    contentsOf: root.appendingPathComponent("aster-integration.fish"), encoding: .utf8)
  #expect(fishPayload.contains("string match -q '*_aster_user_fish_prompt*'"))
  #expect(!fishPayload.contains("functions --details"))

  try runSyntaxCheck(executable: "/bin/zsh", arguments: ["-n", root.appendingPathComponent("aster-integration.zsh").path])
  try runSyntaxCheck(executable: "/bin/zsh", arguments: ["-n", root.appendingPathComponent("aster-ssh.zsh").path])
  try runSyntaxCheck(executable: "/bin/zsh", arguments: ["-n", root.appendingPathComponent("zsh/.zshenv").path])
  try runSyntaxCheck(executable: "/bin/bash", arguments: ["-n", root.appendingPathComponent("aster-integration.bash").path])
  try runSyntaxCheck(executable: "/bin/bash", arguments: ["-n", root.appendingPathComponent("aster-ssh.bash").path])

  let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first {
    FileManager.default.isExecutableFile(atPath: $0)
  }
  if let fish {
    try runSyntaxCheck(executable: fish, arguments: ["-n", root.appendingPathComponent("aster-integration.fish").path])
    try runSyntaxCheck(executable: fish, arguments: ["-n", root.appendingPathComponent("aster-ssh.fish").path])
    try runSyntaxCheck(
      executable: fish,
      arguments: ["-n", root.appendingPathComponent("fish/vendor_conf.d/aster-shell-integration.fish").path]
    )
  }
}

@Test("真实 zsh 会话按 A B C D 顺序发送 FTCS 和合法 OSC 7")
func zshIntegrationEmitsCommandLifecycle() throws {
  let home = try temporaryDirectory(named: "aster-zsh-runtime")
  defer { try? FileManager.default.removeItem(at: home) }
  try "alias aster_test_alias='echo safe'\n".write(
    to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  let output = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: [
      "HOME": home.path,
      "PATH": "/usr/bin:/bin",
      "PWD": home.path,
      "TERM": "xterm-256color",
      "TERM_PROGRAM": "aster",
      "ASTER_INTEGRATION": "1",
      "ASTER_SHELL_INTEGRATION_DIR": root.path,
      "ASTER_REAL_ZDOTDIR": home.path,
      "ASTER_REAL_ZDOTDIR_SET": "0",
      "ZDOTDIR": root.appendingPathComponent("zsh").path,
    ],
    input: "printf 'ASTER_ZSH_BODY\\n'\nexit\n"
  )

  try expectOrderedMarkers(
    output,
    markers: ["\u{1B}]133;A\u{7}", "\u{1B}]133;B\u{7}", "\u{1B}]133;C\u{7}",
      "ASTER_ZSH_BODY", "\u{1B}]133;D;0\u{7}"]
  )
  #expect(output.contains("\u{1B}]7;file://"))
  #expect(output.contains("\u{1B}]6973;Aliases=aster_test_alias"))
  #expect(!output.contains("%23/"))
}

@Test("zsh 集成保留用户 .zshenv 对 ZDOTDIR 的重定向")
func zshIntegrationPreservesUserZDOTDIRRedirect() throws {
  let home = try temporaryDirectory(named: "aster-zsh-zdotdir")
  defer { try? FileManager.default.removeItem(at: home) }
  let redirected = home.appendingPathComponent("redirected")
  try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
  try "export ZDOTDIR=\"$HOME/redirected\"\n".write(
    to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
  try "print -r -- ASTER_REDIRECTED_ZSHRC\n".write(
    to: redirected.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")

  let output = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: [
      "HOME": home.path,
      "PATH": "/usr/bin:/bin",
      "PWD": home.path,
      "TERM": "xterm-256color",
      "TERM_PROGRAM": "aster",
      "ASTER_INTEGRATION": "1",
      "ASTER_SHELL_INTEGRATION_DIR": root.path,
      "ASTER_REAL_ZDOTDIR": home.path,
      "ASTER_REAL_ZDOTDIR_SET": "0",
      "ZDOTDIR": root.appendingPathComponent("zsh").path,
    ],
    input: "exit\n"
  )

  #expect(output.contains("ASTER_REDIRECTED_ZSHRC"))
  #expect(output.contains("\u{1B}]133;A\u{7}"))
}

@Test("Shell Integration 对 OSC 7 路径中的控制字节做 URL 转义")
func shellIntegrationEscapesControlBytesInOSC7Path() throws {
  let home = try temporaryDirectory(named: "aster-shell-osc7")
  defer { try? FileManager.default.removeItem(at: home) }
  let unsafeDirectory = home.appendingPathComponent(
    "unsafe-终端-\u{7}-\u{1B}]2;ASTER_INJECTED\u{7}", isDirectory: true)
  try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true)
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")

  let zshOutput = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: [
      "HOME": home.path,
      "PATH": "/usr/bin:/bin",
      "PWD": unsafeDirectory.path,
      "TERM": "xterm-256color",
      "TERM_PROGRAM": "aster",
      "ASTER_INTEGRATION": "1",
      "ASTER_SHELL_INTEGRATION_DIR": root.path,
      "ASTER_REAL_ZDOTDIR": home.path,
      "ASTER_REAL_ZDOTDIR_SET": "0",
      "ZDOTDIR": root.appendingPathComponent("zsh").path,
    ],
    input: "exit\n"
  )

  let bashHome = home.appendingPathComponent("bash-home", isDirectory: true)
  try FileManager.default.createDirectory(at: bashHome, withIntermediateDirectories: true)
  try ShellIntegrationInstaller(
    resourceDirectory: root,
    homeDirectory: bashHome,
    tmuxAvailable: false
  ).reconcile(enabled: true)
  let bashOutput = try runInteractiveShell(
    executable: "/bin/bash",
    arguments: ["--login", "-i"],
    environment: [
      "HOME": bashHome.path,
      "PATH": "/usr/bin:/bin",
      "PWD": unsafeDirectory.path,
      "TERM": "xterm-256color",
      "TERM_PROGRAM": "aster",
      "ASTER_INTEGRATION": "1",
      "ASTER_SHELL_INTEGRATION_DIR": root.path,
    ],
    input: "exit\n"
  )

  for output in [zshOutput, bashOutput] {
    let payload = try firstOSC7Payload(in: output)
    #expect(payload.contains("%E7%BB%88%E7%AB%AF"))
    #expect(payload.contains("%07"))
    #expect(payload.contains("%1B"))
    #expect(!payload.contains("\u{1B}"))
  }
  let fishPayload = try String(
    contentsOf: root.appendingPathComponent("aster-integration.fish"), encoding: .utf8)
  #expect(fishPayload.contains("string escape --style=url"))
}

@Test("zsh 集成在用户 precmd hook 之后仍保留真实退出码")
func zshIntegrationPreservesStatusAcrossExistingPrecmdHooks() throws {
  let home = try temporaryDirectory(named: "aster-zsh-precmd")
  defer { try? FileManager.default.removeItem(at: home) }
  try """
  autoload -Uz add-zsh-hook
  _user_precmd_hook() { return 0 }
  add-zsh-hook precmd _user_precmd_hook
  """.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")

  let output = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: [
      "HOME": home.path,
      "PATH": "/usr/bin:/bin",
      "PWD": home.path,
      "TERM": "xterm-256color",
      "TERM_PROGRAM": "aster",
      "ASTER_INTEGRATION": "1",
      "ASTER_SHELL_INTEGRATION_DIR": root.path,
      "ASTER_REAL_ZDOTDIR": home.path,
      "ASTER_REAL_ZDOTDIR_SET": "0",
      "ZDOTDIR": root.appendingPathComponent("zsh").path,
    ],
    input: "false\ntrue\nexit\n"
  )

  #expect(output.contains("\u{1B}]133;D;1\u{7}"))
}

@Test("真实 Bash 登录会话通过受管区块发送 FTCS")
func bashIntegrationEmitsCommandLifecycle() throws {
  let home = try temporaryDirectory(named: "aster-bash-runtime")
  defer { try? FileManager.default.removeItem(at: home) }
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  let installer = ShellIntegrationInstaller(
    resourceDirectory: root,
    homeDirectory: home,
    tmuxAvailable: false
  )
  try installer.reconcile(enabled: true)
  let output = try runInteractiveShell(
    executable: "/bin/bash",
    arguments: ["--login", "-i"],
    environment: [
      "HOME": home.path,
      "PATH": "/usr/bin:/bin",
      "PWD": home.path,
      "TERM": "xterm-256color",
      "TERM_PROGRAM": "aster",
      "ASTER_INTEGRATION": "1",
      "ASTER_SHELL_INTEGRATION_DIR": root.path,
    ],
    input: "printf 'ASTER_BASH_BODY\\n'\nexit\n"
  )

  try expectOrderedMarkers(
    output,
    markers: ["\u{1B}]133;A\u{7}", "\u{1B}]133;B\u{7}", "\u{1B}]133;C\u{7}",
      "ASTER_BASH_BODY", "\u{1B}]133;D;0\u{7}"]
  )
}

@Test("没有 ASTER_SSH_CONTROL_DIR 时 zsh 集成不定义 ssh 包装函数")
func zshIntegrationSkipsSSHWrapperWithoutControlDirectory() throws {
  let home = try temporaryDirectory(named: "aster-zsh-ssh-off")
  defer { try? FileManager.default.removeItem(at: home) }
  try "".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")

  let output = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: sshWrapperEnvironment(home: home, root: root, controlDirectory: nil),
    input: "whence -w ssh\nexit\n"
  )

  #expect(!output.contains("ssh: function"))
}

@Test("有 ASTER_SSH_CONTROL_DIR 时 zsh 集成定义带 ControlMaster 的 ssh 包装函数")
func zshIntegrationDefinesSSHWrapperWithControlDirectory() throws {
  let home = try temporaryDirectory(named: "aster-zsh-ssh-on")
  defer { try? FileManager.default.removeItem(at: home) }
  try "".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
  let controlDirectory = home.appendingPathComponent("control", isDirectory: true)
  try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")

  let output = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: sshWrapperEnvironment(
      home: home, root: root, controlDirectory: controlDirectory.path),
    input: "whence -w ssh\nfunctions ssh\nexit\n"
  )

  #expect(output.contains("ssh: function"))
  #expect(output.contains("ControlMaster=auto"))
  // 函数体保留变量引用：ControlPath 在每次调用时展开，目录换了也不用重新定义函数。
  #expect(output.contains("ControlPath=${ASTER_SSH_CONTROL_DIR}/%C"))
}

@Test("用户已定义 ssh 时 zsh 集成保留用户定义")
func zshIntegrationKeepsUserDefinedSSH() throws {
  let home = try temporaryDirectory(named: "aster-zsh-ssh-user")
  defer { try? FileManager.default.removeItem(at: home) }
  try "ssh() { print -r -- ASTER_USER_SSH }\n".write(
    to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
  let controlDirectory = home.appendingPathComponent("control", isDirectory: true)
  try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")

  let output = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: sshWrapperEnvironment(
      home: home, root: root, controlDirectory: controlDirectory.path),
    input: "functions ssh\nexit\n"
  )

  #expect(output.contains("ASTER_USER_SSH"))
  #expect(!output.contains("ControlMaster=auto"))
}

@Test("bash 集成按 ASTER_SSH_CONTROL_DIR 决定是否定义 ssh 包装函数")
func bashIntegrationDefinesSSHWrapperOnlyWithControlDirectory() throws {
  let home = try temporaryDirectory(named: "aster-bash-ssh")
  defer { try? FileManager.default.removeItem(at: home) }
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  try ShellIntegrationInstaller(
    resourceDirectory: root, homeDirectory: home, tmuxAvailable: false
  ).reconcile(enabled: true)
  let controlDirectory = home.appendingPathComponent("control", isDirectory: true)
  try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)

  let without = try runInteractiveShell(
    executable: "/bin/bash",
    arguments: ["--login", "-i"],
    environment: sshWrapperEnvironment(home: home, root: root, controlDirectory: nil),
    input: "declare -F ssh || echo ASTER_NO_SSH_FUNCTION\nexit\n"
  )
  #expect(without.contains("ASTER_NO_SSH_FUNCTION"))

  let with = try runInteractiveShell(
    executable: "/bin/bash",
    arguments: ["--login", "-i"],
    environment: sshWrapperEnvironment(
      home: home, root: root, controlDirectory: controlDirectory.path),
    input: "declare -f ssh\nexit\n"
  )
  #expect(with.contains("ControlMaster=auto"))
  #expect(with.contains("ControlPath=${ASTER_SSH_CONTROL_DIR}/%C"))
}

@Test("受管 rc 区块用不依赖 TMUX 的独立条件加载 ssh payload")
func shellIntegrationInstallerWritesTMUXIndependentSSHBlock() throws {
  let home = try temporaryDirectory(named: "aster-ssh-block")
  defer { try? FileManager.default.removeItem(at: home) }
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  // tmux 不可用也必须写入 ssh 区块：Ghostty 原生 Pane 与 tmux 无关。
  try ShellIntegrationInstaller(
    resourceDirectory: root, homeDirectory: home, tmuxAvailable: false
  ).reconcile(enabled: true)

  let zshText = try String(
    contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
  let bashText = try String(
    contentsOf: home.appendingPathComponent(".bashrc"), encoding: .utf8)
  let fishText = try String(
    contentsOf: home.appendingPathComponent(
      ".config/fish/conf.d/aster-shell-integration.fish"),
    encoding: .utf8
  )

  for (text, suffix) in [(zshText, "zsh"), (bashText, "bash")] {
    let expected = """
      if [[ "${TERM_PROGRAM:-}" == "aster" ]] && [[ "${ASTER_DISABLE_INTEGRATION:-0}" != "1" ]] \
      && [[ -n "${ASTER_SSH_CONTROL_DIR:-}" ]]; then
        source '\(root.appendingPathComponent("aster-ssh.\(suffix)").path)'
      fi
      """
    #expect(text.contains(expected), "缺少 ssh 受管语句：\(suffix)\n\(text)")
  }
  #expect(
    fishText.contains(
      "if test \"$TERM_PROGRAM\" = \"aster\"; and test \"$ASTER_DISABLE_INTEGRATION\" != \"1\"; "
        + "and test -n \"$ASTER_SSH_CONTROL_DIR\""))
  #expect(fishText.contains("aster-ssh.fish"))
  // tmux 不可用时不写整体集成，只保留 ssh 语句。
  #expect(!zshText.contains("aster-integration.zsh"))
  #expect(!fishText.contains("aster-integration.fish"))
  #expect(!zshText.contains("TMUX"))
}

@Test("旧受管区块在再次安装时整体更新为新文本且保持幂等")
func shellIntegrationInstallerUpdatesLegacyManagedBlock() throws {
  let home = try temporaryDirectory(named: "aster-ssh-upgrade")
  defer { try? FileManager.default.removeItem(at: home) }
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  // 旧版本只写 tmux 限定的整体集成，没有 ssh 语句；升级必须原地改写而不是叠加。
  let legacy = """
    export USER_VALUE=1
    \(ShellIntegrationInstaller.startMarker)
    if [[ "${TERM_PROGRAM:-}" == "aster" ]] && [[ "${ASTER_DISABLE_INTEGRATION:-0}" != "1" ]] && [[ -n "${TMUX:-}" ]]; then
      source '/old/path/aster-integration.zsh'
    fi
    \(ShellIntegrationInstaller.endMarker)

    """
  let zshRC = home.appendingPathComponent(".zshrc")
  try legacy.write(to: zshRC, atomically: true, encoding: .utf8)
  let installer = ShellIntegrationInstaller(
    resourceDirectory: root, homeDirectory: home, tmuxAvailable: true)

  try installer.reconcile(enabled: true)
  let firstPass = try String(contentsOf: zshRC, encoding: .utf8)
  try installer.reconcile(enabled: true)
  let secondPass = try String(contentsOf: zshRC, encoding: .utf8)

  #expect(firstPass == secondPass)
  #expect(firstPass.components(separatedBy: ShellIntegrationInstaller.startMarker).count == 2)
  #expect(!firstPass.contains("/old/path/aster-integration.zsh"))
  #expect(firstPass.contains(root.appendingPathComponent("aster-ssh.zsh").path))
  #expect(firstPass.contains(root.appendingPathComponent("aster-integration.zsh").path))
  #expect(firstPass.hasPrefix("export USER_VALUE=1\n"))

  try installer.reconcile(enabled: false)
  #expect(try String(contentsOf: zshRC, encoding: .utf8) == "export USER_VALUE=1\n")
}

@Test("Ghostty 原生 zsh Pane 只靠受管 rc 区块就能拿到 ssh 包装函数")
func zshNativePaneDefinesSSHWrapperFromManagedBlock() throws {
  let home = try temporaryDirectory(named: "aster-zsh-native-ssh")
  defer { try? FileManager.default.removeItem(at: home) }
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  try "".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
  try ShellIntegrationInstaller(
    resourceDirectory: root, homeDirectory: home, tmuxAvailable: true
  ).reconcile(enabled: true)
  let controlDirectory = home.appendingPathComponent("control", isDirectory: true)
  try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)

  let without = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: nativePaneEnvironment(home: home, controlDirectory: nil),
    input: "whence -w ssh\nexit\n"
  )
  #expect(!without.contains("ssh: function"))

  let with = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: nativePaneEnvironment(home: home, controlDirectory: controlDirectory.path),
    input: "whence -w ssh\nfunctions ssh\nexit\n"
  )
  #expect(with.contains("ssh: function"))
  #expect(with.contains("ControlMaster=auto"))
  #expect(with.contains("ControlPath=${ASTER_SSH_CONTROL_DIR}/%C"))
}

@Test("Ghostty 原生 zsh Pane 保留用户自定义的 ssh")
func zshNativePaneKeepsUserDefinedSSH() throws {
  let home = try temporaryDirectory(named: "aster-zsh-native-user-ssh")
  defer { try? FileManager.default.removeItem(at: home) }
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  try "ssh() { print -r -- ASTER_USER_SSH }\n".write(
    to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
  try ShellIntegrationInstaller(
    resourceDirectory: root, homeDirectory: home, tmuxAvailable: true
  ).reconcile(enabled: true)
  let controlDirectory = home.appendingPathComponent("control", isDirectory: true)
  try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)

  let output = try runInteractiveShell(
    executable: "/bin/zsh",
    arguments: ["-d", "-l", "-i"],
    environment: nativePaneEnvironment(home: home, controlDirectory: controlDirectory.path),
    input: "functions ssh\nexit\n"
  )

  #expect(output.contains("ASTER_USER_SSH"))
  #expect(!output.contains("ControlMaster=auto"))
}

@Test("Ghostty 原生 bash Pane 只靠受管 rc 区块就能拿到 ssh 包装函数")
func bashNativePaneDefinesSSHWrapperFromManagedBlock() throws {
  let home = try temporaryDirectory(named: "aster-bash-native-ssh")
  defer { try? FileManager.default.removeItem(at: home) }
  let root = repositoryRoot.appendingPathComponent("Resources/shell-integration")
  try ShellIntegrationInstaller(
    resourceDirectory: root, homeDirectory: home, tmuxAvailable: true
  ).reconcile(enabled: true)
  let controlDirectory = home.appendingPathComponent("control", isDirectory: true)
  try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)

  let without = try runInteractiveShell(
    executable: "/bin/bash",
    arguments: ["--login", "-i"],
    environment: nativePaneEnvironment(home: home, controlDirectory: nil),
    input: "declare -F ssh || echo ASTER_NO_SSH_FUNCTION\nexit\n"
  )
  #expect(without.contains("ASTER_NO_SSH_FUNCTION"))

  let with = try runInteractiveShell(
    executable: "/bin/bash",
    arguments: ["--login", "-i"],
    environment: nativePaneEnvironment(home: home, controlDirectory: controlDirectory.path),
    input: "declare -f ssh\nexit\n"
  )
  #expect(with.contains("ControlMaster=auto"))
  #expect(with.contains("ControlPath=${ASTER_SSH_CONTROL_DIR}/%C"))
}

/// 模拟 Ghostty 原生 Pane：不注入 ASTER_INTEGRATION、不改 ZDOTDIR，也不在 tmux 里，
/// 唯一的加载入口就是安装器写进用户 rc 的受管区块。
private func nativePaneEnvironment(home: URL, controlDirectory: String?) -> [String: String] {
  var environment = [
    "HOME": home.path,
    "PATH": "/usr/bin:/bin",
    "PWD": home.path,
    "TERM": "xterm-256color",
    "TERM_PROGRAM": "aster",
  ]
  if let controlDirectory { environment["ASTER_SSH_CONTROL_DIR"] = controlDirectory }
  return environment
}

/// ssh 包装函数用例共用的环境：只有 controlDirectory 非 nil 时才注入开关变量。
private func sshWrapperEnvironment(
  home: URL,
  root: URL,
  controlDirectory: String?
) -> [String: String] {
  var environment = [
    "HOME": home.path,
    "PATH": "/usr/bin:/bin",
    "PWD": home.path,
    "TERM": "xterm-256color",
    "TERM_PROGRAM": "aster",
    "ASTER_INTEGRATION": "1",
    "ASTER_SHELL_INTEGRATION_DIR": root.path,
    "ASTER_REAL_ZDOTDIR": home.path,
    "ASTER_REAL_ZDOTDIR_SET": "0",
    "ZDOTDIR": root.appendingPathComponent("zsh").path,
  ]
  if let controlDirectory { environment["ASTER_SSH_CONTROL_DIR"] = controlDirectory }
  return environment
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private func temporaryDirectory(named prefix: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func runSyntaxCheck(executable: String, arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let errorPipe = Pipe()
  process.standardError = errorPipe
  try process.run()
  process.waitUntilExit()
  let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  #expect(process.terminationStatus == 0, "语法检查失败：\(error)")
}

private func runInteractiveShell(
  executable: String,
  arguments: [String],
  environment: [String: String],
  input: String
) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.environment = environment
  process.currentDirectoryURL = URL(fileURLWithPath: environment["PWD"] ?? environment["HOME"]!)
  let inputPipe = Pipe()
  let outputPipe = Pipe()
  process.standardInput = inputPipe
  process.standardOutput = outputPipe
  process.standardError = outputPipe
  try process.run()
  inputPipe.fileHandleForWriting.write(Data(input.utf8))
  try inputPipe.fileHandleForWriting.close()
  let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  return String(decoding: data, as: UTF8.self)
}

private func expectOrderedMarkers(_ text: String, markers: [String]) throws {
  var lowerBound = text.startIndex
  for marker in markers {
    let range = try #require(text.range(of: marker, range: lowerBound..<text.endIndex))
    lowerBound = range.upperBound
  }
}

private func firstOSC7Payload(in text: String) throws -> String {
  let prefix = "\u{1B}]7;file://"
  let start = try #require(text.range(of: prefix)?.upperBound)
  let end = try #require(text[start...].firstIndex(of: "\u{7}"))
  return String(text[start..<end])
}
