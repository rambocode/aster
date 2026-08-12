# Aster libghostty 单 Pane PoC

这是与 Aster 主 executable 隔离的实验程序，用于验证 Ghostty 的 PTY、VT state、
Metal renderer 和 AppKit 输入链路。它不持久化 Pane，也不修改现有 `TerminalSession`。

```bash
./scripts/setup-ghostty-poc.sh
swift run --package-path Prototypes/GhosttyPane AsterGhosttyPane
```

自动化生命周期烟测可运行：

```bash
swift run --package-path Prototypes/GhosttyPane AsterGhosttyPane --command /usr/bin/true
```

setup 固定使用 Ghostty revision `4dcb09ada0c0909717d92547623b26eafa50ca8a`
和 Zig 0.15.2，并把 XCFramework、terminfo、themes 与 shell integration 生成为
gitignored 本地工件。PoC 使用 Ghostty 的 internal `include/ghostty.h`；这个 ABI 没有
稳定性承诺，升级时必须同时更新 revision、重新构建并完成手工验收。

若需要忽略本地 revision stamp 并验证完整的源码构建链：

```bash
ASTER_GHOSTTY_FORCE_REBUILD=1 ./scripts/setup-ghostty-poc.sh
```

当前 vertical slice 覆盖：单个 login shell、Retina resize、焦点、键盘与 IME、鼠标
选择/滚动、系统剪贴板、title/CWD callback、进程退出和按需 Metal render。Aster 的
Read-only、Agent OSC 6974、Autocomplete、Vi/Hint、链接授权和 Pane 生命周期尚未迁移；
这些能力必须通过 adapter 映射后，才可考虑替换主应用中的 SwiftTerm。

Bridge provenance 与 MIT notices 会随 SwiftPM resource bundle 一起复制，见
`Sources/GhosttyPane/Resources/THIRD_PARTY_NOTICES.txt`。
