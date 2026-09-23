# Aster 公开推广资料

目标：让更多真正会使用 macOS 终端工作区的人发现、试用并自愿收藏 Aster。GitHub star 是结果指标，不购买、不交换，也不请人代刷。

## 当前基线与核验

2026-09-23，GitHub API 显示 `rambocode/aster` 为 2 stars、0 forks；最新公开版本是 `v0.6.11`，其 DMG 当时显示 2 次下载。数字会变化，发布前及每周复核：

```bash
gh api repos/rambocode/aster --jq '{stars: .stargazers_count, forks: .forks_count}'
gh api repos/rambocode/aster/releases/latest --jq '{version: .tag_name, downloads: [.assets[] | {name, download_count}]}'
```

用 GitHub Insights → Traffic 查看访问与来源，用 Issue/Discussion 和实际反馈判断试用障碍。按周记录 star 净增、DMG 下载和有效反馈；下载次数不等于安装人数，star 也不等于活跃用户。

## 发布前资料

- 制作真实 Aster 窗口截图或短录屏，展示终端与文件预览并排使用；清除用户名、路径、令牌和终端历史。官网现有的动画窗口是演示图，不作为真实应用截图。
- 在干净的 macOS 14+ 环境试装最新版 DMG，确认首次打开、分屏、打开文件和更新入口，并记录可复现的结果。
- 检查 README、官网、DMG 版本、系统要求和下载链接一致。任何对外内容只使用已发布能力。
- 准备好持续回答安装、兼容性和隐私问题的维护者；发布后及时修正发现的障碍。

## 分发顺序

1. 先向已有 Mac 开发者和终端用户展示真实工作流，收集 5–10 条具体反馈，解决影响首次试用的问题。
2. 发布一篇面向开发者的技术说明，解释 AppKit 工作区与 Ghostty 引擎的分工，附可运行的下载链接和真实截图。把文章分享到与主题相符、允许项目分享的社区。
3. 在资料齐全且维护者能参与讨论时考虑 [Show HN](https://news.ycombinator.com/showhn.html)：链接直达可试用项目，说明为什么制作它；不请求投票。
4. 考虑 [Product Hunt](https://www.producthunt.com/launch) 发布：准备真实画面、明确的产品说明和维护者答疑；按平台规则邀请试用和评论，不请求赞票。
5. 后续每次有实质改进时发布独立的工作流演示，说明解决了什么问题、如何试用，并回看哪类内容带来真实反馈。

每次只在符合社区规则且内容与受众相关时发布，公开维护者身份。不要跨社区复制同一条泛泛广告。

## 可复用文案

英文短帖：

> Aster is an open-source, native AppKit terminal workspace for macOS 14+. It puts Ghostty-powered terminals beside files, editors, and previews in recursive splits, with tabs and workspace restore. The signed DMG is ready to try: https://github.com/rambocode/aster/releases/latest — source: https://github.com/rambocode/aster. I'd value feedback on the split and file workflows.

中文短帖：

> Aster 是面向 macOS 14+ 的开源原生终端工作区。它用递归分屏把基于 Ghostty 的终端、文件、编辑器和预览放在一个窗口里，并支持标签与工作区恢复。最新版 DMG 可直接试用：https://github.com/rambocode/aster/releases/latest；源码：https://github.com/rambocode/aster。欢迎反馈分屏与文件工作流中的实际问题。

Show HN 标题草稿：`Show HN: Aster – an AppKit terminal workspace with Ghostty-powered panes`

这些文案是待审核资料，需结合真实演示和发布当天版本更新；发布行为由维护者授权后执行。
