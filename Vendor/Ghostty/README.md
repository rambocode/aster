# libghostty vendor contract

Aster 的主终端引擎使用 Ghostty 的 internal C interface。上游尚未把
`libghostty` 作为版本化 SDK 发布，因此仓库只锁定源码 revision，不提交生成的
XCFramework。

- 固定 revision：`4dcb09ada0c0909717d92547623b26eafa50ca8a`
- 生成命令：`./scripts/setup-ghostty.sh`
- 编译器：Zig 0.15.2 与 Xcode Metal Toolchain
- 产物：`Vendor/GhosttyKit.xcframework`
- 运行时资源：`Sources/Aster/Ghostty/Resources/{ghostty,terminfo}`

更新 revision 时必须重新构建、运行完整测试与 release App 验收，并核对
`include/ghostty.h` 中 Aster 使用的 action、surface、clipboard 和 text ABI。
