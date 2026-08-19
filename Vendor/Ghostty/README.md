# libghostty vendor contract

Aster 的主终端引擎使用 Ghostty 的 internal C interface。上游尚未把
`libghostty` 作为版本化 SDK 发布，因此仓库同时锁定源码 revision 与一份可审计、
可重放的 Aster extension patch；不提交临时 clone。

- 固定 revision：`4dcb09ada0c0909717d92547623b26eafa50ca8a`
- 扩展 ABI：`GHOSTTY_ASTER_EXTENSION_ABI_VERSION == 1`
- 补丁：`patches/0001-aster-extension-abi.patch`
- 生成命令：`./scripts/setup-ghostty.sh`
- 编译器：Zig 0.15.2 与 Xcode Metal Toolchain
- 产物：`Vendor/GhosttyKit.xcframework`
- 运行时资源：`Sources/Aster/Ghostty/Resources/{ghostty,terminfo}`

ABI v1 在上游 internal interface 之外补充：原始 PTY read/write observer、任意数字
OSC 的非消费式 observer、稳定 page anchor 与绝对缓冲区坐标、固定宽度 cell row、
精确 selection、绝对 row 滚动，以及 literal/regex、大小写、前后方向的完整搜索。
无活动 macOS display link 时 surface 保持可用并仅关闭 vsync。observer payload 只在
同步 callback 期间有效，宿主跨线程保留前必须复制；page anchor 仅在对应 page 仍被
scrollback 保留时可解析。

Aster 的嵌入式 renderer 额外把 focused display link 改为按需运行：普通终端收到状态、
光标或尺寸变化时启动，完成最新帧并再确认一轮没有新请求后停止；持续输出会在相邻刷新间
重新置位请求，因此仍按屏幕节奏合并呈现。只有启用自定义 shader 动画时保持连续 vsync。
这不等于 `window-vsync=false`：每个真实帧仍由 display link 对齐，避免撕裂、外接显示器
性能问题和上游文档警告的 macOS 风险。

构建 stamp 同时包含 revision 与 patch SHA-256，因此改动补丁后不会误复用旧二进制。
更新 revision 时先在干净 clone 中执行 `git apply --check`，解决冲突后重新生成补丁，
再运行 Zig 定向测试、完整 Swift 测试与 release App 验收，并核对导出的 ABI 版本。
