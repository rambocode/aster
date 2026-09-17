import AsterCore
import Foundation

/// 工作区恢复后在终端里打印的时间横幅（对齐 Otty 的 `Quitted at` / `Restored at`）：
/// 用户重启 Aster 时能一眼分清上一次会话在什么时候结束、这次是什么时候恢复的。
///
/// 产物是一段交给 Shell `-c` 执行的片段。Ghostty 没有「直接往屏幕写字」的接口，而 Aster
/// 的启动命令本来就由 Ghostty 交给 `/bin/sh -c` 执行，所以「先 printf 再 exec Shell」是让
/// 横幅像普通输出一样落进滚动缓冲的最简路径；外层壳必须是 Shell 本身，见 `launchCommand`。
enum SessionRestoreBanner {
  /// 横幅里的时间格式，固定 `MM/dd HH:mm`，不随系统区域变化，避免不同机器上宽度不一。
  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MM/dd HH:mm"
    return formatter
  }()

  /// 两端各一段横线，中间是提示符图形加文案；时间戳来自快照，旧快照没有时只打印恢复行。
  static func lines(quitAt: Date?, restoredAt: Date) -> [String] {
    var lines: [String] = []
    if let quitAt {
      lines.append(decorate(L("退出于 \(timeFormatter.string(from: quitAt))")))
    }
    lines.append(decorate(L("恢复于 \(timeFormatter.string(from: restoredAt))")))
    return lines
  }

  /// 拼成 `printf` 片段：格式串只含 SGR 转义（暗淡绿）与换行，文本走 `%s` 参数并经单引号
  /// 转义，因此文案里的 `%`、`\`、引号都不会被 sh 或 printf 二次解释。两行之间用一个空
  /// 参数打出空行，与参考效果一致。
  static func shellPrefix(quitAt: Date?, restoredAt: Date) -> String {
    let lines = self.lines(quitAt: quitAt, restoredAt: restoredAt)
    let arguments = lines.map(ShellQuoting.singleQuoted).joined(separator: " '' ")
    return "printf '\\033[2;32m%s\\033[0m\\n' \(arguments)"
  }

  /// 把横幅片段与 Shell 启动命令串成 `"<shell>" "-c" "printf …; exec <启动命令>"`。
  ///
  /// 第一个参数必须仍是 Shell 本身：Ghostty 只看启动命令 arg0 的 basename 决定要不要注入
  /// shell 集成，`printf …; exec zsh` 的 arg0 是 printf，集成整体丢失——恢复的 Pane 没有
  /// OSC 133/7，光标也退回配置默认的方块（正常 Pane 由集成在提示符处切成竖线）。
  /// `exec` 让最终 Shell 顶替外层进程成为 PTY 的直接子进程，退出码、前台进程检测不变。
  ///
  /// zsh 的注入靠 ZDOTDIR，而 Ghostty 的 `.zshenv` 在外层 `zsh -c` 里就把 ZDOTDIR 还原了，
  /// 因此 `reinjectGhosttyZshIntegration` 为 true 时在 exec 前按 Ghostty 同样的规则再注入一次；
  /// fish 走 XDG_DATA_DIRS 天然继承；bash 的 `-c` 路径 Ghostty 本就不注入，与 /bin/bash 一致。
  static func launchCommand(
    prefixing shellLaunchCommand: String,
    shell: String,
    reinjectGhosttyZshIntegration: Bool,
    quitAt: Date?,
    restoredAt: Date
  ) -> String {
    var script = shellPrefix(quitAt: quitAt, restoredAt: restoredAt)
    if reinjectGhosttyZshIntegration { script += "; " + zshIntegrationReinjection }
    script += "; exec " + shellLaunchCommand
    return GhosttyConfiguration.launchCommand(shell: shell, arguments: ["-c", script])
  }

  /// 对齐 Ghostty `setupZsh`：保留用户原有 ZDOTDIR 到 GHOSTTY_ZSH_ZDOTDIR，再把 ZDOTDIR 指到
  /// 资源目录里的 zsh 集成；资源目录缺失时什么都不做，退化为无集成的普通 Shell。
  static let zshIntegrationReinjection =
    "if [ -n \"${GHOSTTY_RESOURCES_DIR-}\" ] && [ -r \"$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/.zshenv\" ]; then"
    + " if [ -n \"${ZDOTDIR+x}\" ]; then export GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\"; fi;"
    + " export ZDOTDIR=\"$GHOSTTY_RESOURCES_DIR/shell-integration/zsh\"; fi"

  private static func decorate(_ text: String) -> String {
    "───── >_ \(text) ─────"
  }
}
