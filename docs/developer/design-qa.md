# Design QA

## 验收边界

功能实现以代码测试、静态检查和构建为本轮自动验收范围。按项目要求，不运行鼠标、键盘或真实窗口自动化；以下视觉与交互检查由用户在打包应用中完成，结果回填到本文。

## Selection / Scroll 检查清单

- [ ] 拖动、双击和三击分别选择字符范围、单词和整行。
- [ ] `Option` 拖动显示矩形高亮，复制文本按物理行保留列边界。
- [ ] 鼠标报告开启时，`Option` 选择不会触发 TUI 鼠标动作；`Shift` 遵循程序协商的捕获模式。
- [ ] `Shift+Arrow` 线性扩展可跨锚点收缩并反向扩展；加 `Option` 后显示矩形高亮。
- [ ] 设置中的输入清理、复制清理和 Shift 方向键开关立即作用于已有 Pane。
- [ ] 触控板滚动连续且无字符行撕裂，手势结束后对齐完整行。
- [ ] `Shift+Page Up/Down` 与 `Shift+Home/End` 作用于当前 Pane。
- [ ] 首尾四种停靠模式符合设置文案；进入 vim、less 等 alternate screen 后不出现越界空白。
- [ ] 新输出和键盘输入会回到最新内容，设置窗口切换滚动选项时布局不抖动。

## Shell Integration / Identification 检查清单

- [ ] 新建 zsh、Bash、fish Pane 后，目录变化可同步，提示符不出现可见 OSC 字符。
- [ ] `Command+Page Up / Page Down` 连续跳过多条命令，首尾没有反向跳动。
- [ ] 命令运行时标签显示 spinner；结束后按设置显示 `✓` 或非零退出码。
- [ ] 提示符内选择 ASCII 文本后按 Backspace 或 Cut，只删除选区；跨行或 Unicode 选区保持无损降级。
- [ ] 关闭 Shell Integration 会显示确认并移除受管区块；重新开启不会重复追加 marker。
- [ ] `TERM=auto` 下 `echo "$TERM_PROGRAM $TERM"` 显示 `aster xterm-256color`；DA/XTVERSION 探测工具识别为 Aster。

## Autocomplete / Inline Suggest 检查清单

- [ ] zsh、Bash 和 fish 的提示符停顿后显示 ghost；Backspace 和 Escape 立即清除旧候选。
- [ ] 默认第一次 Escape 关闭 ghost，第二次打开面板；上下键、Return、Tab 和点击均只接受候选、不自动执行命令。
- [ ] 候选面板跟随光标并在上下空间不足时翻转，最多显示 8 项，长描述不撑破 Pane。
- [ ] Tab、Tab 或 Right、Control-Space、关闭四种接受策略立即作用于已打开 Pane。
- [ ] 文件、目录、alias、历史、README、纠错与 `aster learn` 候选分别显示正确类型。
- [ ] 关闭本机学习后不再出现历史/README/纠错，也不启动 help 探测；文件与内置命令仍可补全。
- [ ] 设置页“立即更新”只在点击后联网；“清除”移除学习和固定命令但保留本地 help 规格。

## 记录

- 2026-08-08：新增 Selection / Scroll 验收项；尚未执行界面测试。
- 2026-08-08：新增 Shell Integration / Identification 验收项；按用户要求仍未执行界面测试。
- 2026-08-08：新增 Autocomplete / Inline Suggest 验收项；按用户要求仍未执行界面测试。
