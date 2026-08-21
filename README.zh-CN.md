# Aster Terminal

[English](README.md) | 简体中文

Aster 是一个完全使用 AppKit 构建的原生 macOS 终端工作区，采用轻量标签导航、弱化标题栏、纸张色画布和克制的苔绿色状态反馈。它使用独立品牌、图标和从零编写的工作区实现，不包含 Otty 的品牌资源或私有代码。

## 能力

- 完整 VT100/xterm 终端、ANSI 真彩色、鼠标、超链接和全屏 TUI
- 多标签，垂直/顶部/底部三种标签布局
- 左右/上下递归分屏，可混合终端、文件浏览器、编辑器和预览
- Files 严格资源菜单与统一 File Pane，支持源码、Markdown/RST、图片、PDF、Quick Look、diff、hex 和 Agent transcript
- 终端缓冲区查找、命令面板、详情面板和快捷键
- `.asterrecipe` 工作区导入/导出及启动会话恢复
- OSC 1/2/0 独立标题、固定名称/动态前缀，以及 `⇧⌘T` 最近关闭标签恢复
- zsh/Bash/fish Shell Integration、命令锚点导航、退出状态与安全提示符选区删除
- 本机 Autocomplete / inline suggestion、715 命令清单、文件与别名候选、隐私学习和 `aster learn`
- `TERM=auto`/terminfo 安全回退、Aster 环境标识及 DA1/DA2/XTVERSION/DSR 回包
- 通用、Shell、控制、编辑器、智能体、外观、Recipes、快捷键和高级九类设置
- 与 Otty 1.3.1 对齐的 24 个内置主题、实时终端预览、自定义复制/编辑及安全 `.astertheme` 导入
- 主窗口、设置、菜单、分屏、主题预览和全部交互控件均为原生 AppKit，无 SwiftUI/Hosting 桥接层
- 独立应用图标、签名 `.app` 与 DMG 构建
- 基于 Sparkle 2 的应用内更新：后台检查、可选静默安装、预览通道

## 安装

从[发布页](https://github.com/rambocode/aster/releases)下载已签名并公证的 DMG，打开后把
`Aster.app` 拖进 `/Applications`。

此后 Aster 会自己更新：每天在后台检查一次新版本，也可以让它自动下载并安装。相关开关在
**设置 → 通用 → 更新**，**Aster → 检查更新…** 可随时手动触发。更新只从官方更新源获取，
且必须同时通过 EdDSA 签名校验与 macOS 公证校验才会安装，全程不发送任何使用数据。

> 从 0.4.1 或更早版本升级：那些版本不含更新组件，无法自动更新，需要手动下载一次 DMG。
> 此后即可自动更新。

## 构建

```bash
brew install zig@0.15
xcodebuild -downloadComponent MetalToolchain
./scripts/setup-ghostty.sh
./scripts/test.sh
./scripts/build-app.sh
./scripts/build-dmg.sh
open dist/Aster.app
```

需要 macOS 14 或更高版本、Swift 6.2、Zig 0.15.2 与 Xcode Metal Toolchain。
`setup-ghostty.sh` 从固定 revision 生成本机 `GhosttyKit.xcframework` 和运行时资源；
`build-app.sh` 会自动调用它。来源、ABI 风险与更新流程见 `Vendor/Ghostty/README.md`。
SwiftTerm 仍以本地 target 保留，仅用于迁移期旧适配器回归测试，不进入产品终端视图树。
默认构建使用本机 ad-hoc 签名，适合本机安装；正式分发时通过
`ASTER_SIGN_IDENTITY="Developer ID Application: ..."` 提供 Developer ID、通过
`ASTER_NOTARY_PROFILE` 提供公证 profile，然后用 `./scripts/release.sh` 发布。
测试请走 `./scripts/test.sh` 而不是裸 `swift test`：测试宿主不在 `.app` 布局里，
需要 `DYLD_FRAMEWORK_PATH` 才能加载 Sparkle。
ad-hoc 构建不启用自动更新，设置页的「更新」一组会整体置灰。
签名、appcast 与发版细节见 `docs/developer/software-update.md`。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建标签页 | `⌘T` |
| 打开文件 | `⌘O` |
| 关闭标签页 | `⌘W` |
| 向右分屏 | `⌘D` |
| 向下分屏 | `⇧⌘D` |
| 关闭 Pane | `⌥⌘W` |
| 查找 | `⌘F` |
| 命令面板 | `⌘K` |
| 设置 | `⌘,` |

## 文档

- [工作区领域与实现](docs/developer/terminal-domain.md)
- [Ghostty 终端引擎](docs/developer/ghostty-terminal-engine.md)
- [AppKit 界面架构](docs/developer/appkit-interface.md)
- [文件、链接与 File Pane 领域](docs/developer/files-and-links-domain.md)
- [外观主题领域与实现](docs/developer/theme-system.md)
- [用户帮助](docs/user/help.md)
- [第三方许可](THIRD-PARTY-NOTICES.md)

## 许可证

MIT，见 [LICENSE](LICENSE)。`Vendor/` 内的第三方组件保留各自的许可证，见
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
