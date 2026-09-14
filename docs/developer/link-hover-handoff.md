# Command 悬停链接问题交接

记录时间：2026-09-14。状态：**已解决（2026-09-14 下午）**。

## 结论（后续接手者先读）

- 根因：`GhosttySurfaceView.cursorUpdate(with:)`（f9b2c4f 引入）把事件交给 `handleLinkHoverMouseMoved`，而 AppKit 在 `NSCursor.set()` / 子视图变化后会经 `-[_NSTrackingAreaAKManager setCursorForMouseLocation:]` 合成 `cursorUpdate` 事件，其 `modifierFlags` 不含 `.command`。按下 Command 约 30ms 后 `linkCommandHeld` 被清零、`deactivateLinkUnderlines()` 被调用、Ghostty 随后的 mouse_shape TEXT 把指针改回 I-beam；预览徽章走 `updateCommandHoverPreview`（不由 cursorUpdate 触发）所以仍显示。用真实 HID 级 Command（CGEvent flagsChanged keyCode 55）+ lldb 断点在用户运行中的包上抓到完整调用链。
- 修复：`cursorUpdate` 只调用 `updateLinkHoverCursor()` 重施指针，不再读取事件修饰键。`GhosttyLinkHoverE2ETests` 的 cursorUpdate 用例改为空 flags（真机条件），修复前必然失败、修复后通过。
- 实机验证：修复后的打包版按住 Command 时下划线、手形（`[NSCursor currentCursor]` = pointing-hand）与徽章同时出现，松开后全部恢复。
- 同批调整：预览徽章改为 28pt 高、12pt 字，地址完整显示，只有超过 Pane 宽度才中间截断。

以下为原始交接记录，仅作历史参考。

## 问题与停止边界

用户在终端输出中的 `http://127.0.0.1:8899` 上悬停并按下键盘原生 Command，仍看不到下划线和手形。此前截图能看到底部链接预览。用户已测试多次打包结果，并确认以前有版本可以正常工作，但尚未确定正常版本号或提交。

本轮获准直接测试用户已打开的最新版 App，仍未验证实际问题恢复。用户要求本次不能修复就停止，交由其他 agent 接手。本轮最后阶段只做临时运行时诊断，没有继续修改业务源码；LLDB 已 detach 并退出，用户的 Aster 和其中运行的开发服务保留。不要将本记录视为继续修复、关闭用户终端或发布版本的授权。

## 工作区与正在运行的构建

- 工作区：`/Users/mike/source/project/aster`，分支 `master`，基准提交 `9d521bb`。
- 当前任务累计修改留在此工作区，未提交、未回滚；包含独立的 Tab 性能修复、链接设置交互和多轮悬停修复尝试。接手时先检查 `git status`，不要整体重置。
- 最后确认的运行进程：PID `43132`，路径 `/Users/mike/source/project/aster/.build/hover-render-fix/Aster.app/Contents/MacOS/Aster`。
- Mach-O UUID：`87EF5F2E-B6C4-3120-88BA-24F52B479B0D`。磁盘二进制与运行进程采样中的 UUID 一致，已排除当时运行旧包的解释。进程信息可能随重启变化。
- 最近打包结果位于 `.build/hover-render-fix/Aster.app`，没有替换 `/Applications` 中的应用，没有发布或增加版本号。

## 已确认的事实与验证限制

1. 之前对用户实际原生 Command 的观测记录了 keyCode `55` 的按下和释放事件；因此仅取消物理键码过滤不能解释或解决用户此后的反馈。该记录属于之前的包和窗口布局。
2. 本轮在最新包暂停于 Command 释放处理之前时，读到 `linkCommandHeld = true`、`linkUnderlinesActive = true`，以及三个非空下划线矩形和存在的 overlay/shape layer。它只能证明存在状态和几何数据，不能证明最终屏幕绘制正确。
3. 同次自动化观测的指针位置不在链接矩形上。因此当时 `linkHoverCursorActive = false` 不能用于证明用户实际悬停时的手形失败原因。
4. CUA 的 `pressKey("super+c")` 自动化事件使用 keyCode `0`，且会立即释放修饰键；工具没有已记录的持续按住 Command 并移动鼠标接口。单独 `pressKey("super")` 不受支持。不能将此序列等同于用户真实鼠标加原生 Command 操作。
5. App 被调试器暂停时，CUA 截图超时；未取得该暂停状态下的实际绘制截图。
6. 已有针对性测试通过，但使用了构造的 NSEvent 和测试指针位置注入。独立 AppKit/Metal 测试宿主中曾看到下划线，也不代表用户的打包 App 已修复。

## 尚未证实的线索

`GhosttySurfaceView.cursorUpdate(with:)` 调用 `handleLinkHoverMouseMoved(with:)`，后者可能依据事件的 `modifierFlags` 更新 Command 状态。可以进一步核查真实 AppKit cursorUpdate 是否会在 Command 持续按下时携带零 flags 并清除状态。

**这不是已确认根因。** 本轮可靠日志只捕获到 Command 未按下或释放之后的零 flags cursorUpdate，没有捕获到“Command 仍按住而 cursorUpdate flags 为零”的关键证据，也没有据此修改代码。焦点、实际指针坐标来源、视图覆盖和 viewport 布局也没有被确认为根因。旧诊断中窗口大小在采样间发生变化，不能凭不同时间的 frame 差异断定布局错误。

## 已保留的相关实现

- `GhosttySurfaceView+Input.swift`：flagsChanged 不再限制 keyCode 54/55；reportMousePosition 缓存指针位置。
- `GhosttySurfaceView+Links.swift`：Command 按下时重新读取实际窗口指针位置；引入测试位置提供器；cursor 状态结合 native hit 与扫描结果；下划线从 draw 改用 CAShapeLayer。
- `GhosttySurfaceView.swift`、`GhosttySurfaceView+Modes.swift`：native hit 与预览显示分离，补充关闭预览、退出、销毁时的状态处理。
- `GhosttyLinkHoverE2ETests.swift`、`GhosttyLinkPreviewTests.swift`：增加真实输出行、滚动历史、按键事件、指针缓存和 native hit 的覆盖。

上述改动不能标记为已经解决用户报告的缺陷。另有 Otty 链接协议设置对齐改动，集中在 `Resources/settings-ui/`、`SettingsView.swift`、`DetectedTarget.swift` 和相关测试及文档，接手时应区分问题范围。

独立的本地 Tab 性能问题曾确认与 `CoreLocalization` 在锁内直接存储可选闭包导致重复包装有关，已改为具名 State 保存 translator。已有实测改善记录在 `interface-localization.md`；不要将它与未解决的悬停问题混为一谈。

## 测试与证据位置

- `/tmp/aster-latest-live.sample`：当前包与进程 UUID 核对。
- `/tmp/aster-held-state.json`、`/tmp/aster-held-debug.log`：Command 释放前读取的状态及三个下划线矩形。
- `/tmp/aster-cursor-events.jsonl`、`/tmp/aster-cursor-events-debug.log`：最新事件探针记录；探针文件为 `/tmp/aster_cursor_events.py`。
- `/tmp/aster-current-offsets.log`：当时通过 Objective-C runtime 获取的 ivar 偏移。早期探针误用 NSEvent 偏移 8，相关 flags 值无效；后续确认 `_modifierFlags` 偏移为 24。不要跨进程或构建复用裸地址及偏移。
- `.design-loop/otty-link-protocols/ux/evidence/physical-command.json`：此前原生 Command 记录。该目录为本机证据，已通过 `.git/info/exclude` 排除。
- `/tmp/aster-hover-pointer-final.log`、`/tmp/aster-links-render-final.log`：此前针对性测试各 11 项通过；不构成真实用户场景的验收。
- `/tmp/aster-hover-bundled.log`：独立测试宿主显示下划线的测试记录。
- `/tmp/aster-hover-render-full.log`、`.build/test-runs/20260914-122015-15905/result.json`：全量测试选择 1687 项、跳过 27 项，仍有错误码数量、视图复用、迁移等失败，**不是全量通过**。
- 最新包的资源检查与签名校验曾通过，但没有解决实际交互验证缺口。

`/tmp` 和 `.build` 的文件可能被系统或后续构建清理。此前证据文档中关于测试宿主显示正常的表述不能替代本记录的“用户实际场景未解决”结论。

## 下一位接手者的调查入口

用户明确说曾有正常版本，优先确定可重复的正常/异常构建并比较事件和绘制路径，避免继续依据测试替身结果推测修复。相关文件最近的历史提交包括：

- `40056be`：remote-work P4。
- `f9b2c4f`：workspace / picture in picture / inspector。
- `e39fa08`：统一 inline target scanner。
- `a61100a`：恢复 Ghostty 引擎下 Command 悬停链接预览。
- `3ea8d88`：恢复 Ghostty 上的 Aster 功能。

这些仅是调查入口，不代表任何一个提交已被确认为好版本或回归来源。验收应覆盖用户实际打开的打包 App、原生 Command、鼠标静止后按键及按住后移动两种顺序，并确认下划线与手形都出现、释放后恢复。实际界面验证通过前，不应再次宣称此问题已修复。
