# 发行说明

每个发布版本一个文件，文件名是 `CFBundleShortVersionString`，例如 `0.5.0.md`、
`0.5.0-preview.1.md`。

`scripts/release.sh` 在阶段 0 校验对应文件存在，之后同时把它用于两处：

- `gh release create --notes-file`，作为 GitHub Release 的正文；
- 复制成与 DMG 同名的 `.md` 供 `generate_appcast --embed-release-notes` 以 CDATA 嵌进
  appcast 的 `<description>`，也就是用户在 Sparkle 更新窗口里看到的内容。

因此内容要能同时充当这两种读者的说明：写用户看得懂的变化，不要写实现细节或提交号。
Markdown 会被 Sparkle 渲染，标题从 `##` 起，避免与它自己的版本标题重复。
