# Aster 0.4.0 AppKit 与 Otty 主题设计验收

## 验收范围

- 参考源：用户提供的 Otty 外观设置截图，以及 `/Users/mike/.config/otty/themes` 中 Otty 1.3.1 的 24 套主题文件。
- 实现对象：Aster 0.4.0 的纯 AppKit 主窗口、设置页、主题网格、详情、编辑器、工作区主题渲染和 SwiftTerm 色表。
- 验收目标：无 SwiftUI Hosting；主题名称、明暗分类、终端前景/背景、ANSI 16 色、光标/选区及界面/标签/容器样式令牌与参考一致。

## 对照环境

- AppKit 设置窗口：`940 × 760 pt`，Retina 截图 `1880 × 1520 px` 以上。
- 实装版本：Aster `0.4.0 (5)`，浅色外观，Ayu Light 选中态。
- 主题总数：24；浅色 9，深色 15。
- 参考截图与实现截图先裁成相同宽高，再横向放进同一张对照图判断，不分开凭印象验收。

## 同屏对照记录

| 对照面 | 参考图 | 实现截图 | 合并对照 |
| --- | --- | --- | --- |
| 布局与标签栏 | `codex-clipboard-c3af878e-5c85-4ddf-8db9-aa79f438d7b8.png` | `../Aster-appkit-settings-appearance-0.4.0.png` | `../Aster-AppKit-Otty-layout-comparison-0.4.0.png` |
| Ayu Light 主题网格 | `codex-clipboard-356dc6f9-70d6-4e0a-be4c-4c5cde751c29.png` | `../Aster-appkit-theme-grid-ayu-light-0.4.0.png` | `../Aster-AppKit-Otty-theme-comparison-0.4.0.png` |
| 递归终端分屏 | Otty 分屏与容器令牌 | `../Aster-appkit-split-fixed-0.4.0.png` | 实机检查 |

## 数据与框架一致性

- `Sources/Aster` 完全由 AppKit 构成，不导入 SwiftUI，不创建 `NSHostingView` / `NSHostingController`。
- 24 套主题逐套保存 Otty 原始终端前景、背景和有序 ANSI 16 色；测试使用每套 18 个颜色值的 SHA-256 签名发现漏主题、改名、错色或顺序颠倒。
- Otty 的 window、sidebar、titlebar、tab、horizontal-tab、container、panel、surface、border、radius、margin、padding、shadow 和 material 分别保存并进入 AppKit 渲染。
- Floating Card、Nord、Pink、Glass 等显式光标文字色和选区前景/背景独立保存并同步到 SwiftTerm。
- Glass 的透明背景保留 RGBA 真值，终端栅格使用主题 surface 预合成，窗口与侧栏使用 `NSVisualEffectView` 原生材质。

## 强制检查项

- 字体与层级：分区标题、布局卡片、主题名称、详情标签和终端预览层级清楚；预览使用等宽字体。
- 间距与布局：四列主题网格稳定排列；9 个浅色主题与 15 个深色主题无重叠或横向溢出。
- 颜色与状态：Ayu Light 蓝色选中框清晰；浅色、深色、透明和纸张类表面可辨认；ANSI 色序正确。
- 图标：全部使用 SF Symbols 或应用自有图标，无占位图标、emoji 或破损资源。
- 交互：标签与文件右键菜单、主题选择、独立深色主题、复制、完整编辑、导入、详情分段控件和递归分屏均为真实 AppKit 交互。
- 终端：前景、背景、光标前景/文字、选区前景/背景、ANSI 16 色和窗口网格尺寸均写入 SwiftTerm。
- 可访问性：主题卡是原生 `NSButton`，可访问描述为主题名，选中态不只依赖颜色细微变化。
- 兼容性：旧 `.astertheme` 缺少新增可选字段时仍可解码；旧 `Catppuccin` 选择迁移为 `Catppuccin Mocha`。

## 发现与处理

- P0：无。
- P1：迁移初版的无固有宽度 Pane 容器被 `NSStackView` 压缩，分屏后终端宽度为 0；改为显式横向尺寸约束和 fill 分布，实机复测两个 SwiftTerm 网格均正常显示。
- P1：SwiftTerm 视图在工作区刷新时被直接反复改换父视图；增加 Session 生命周期内稳定的 AppKit 终端容器，刷新只重新安放外层容器。
- P1：原设置页主题编辑只覆盖 6 个角色色；已补齐明暗模式、界面窗口、容器、面板、主/次文字、强调色、光标、选区和 ANSI 16 色。
- P2：原布局设置与参考信息架构不同；已补齐新标签位置、自动隐藏标签面板和窗口尺寸入口，并保留窗口主题、侧栏宽度与状态栏设置。
- P2：文件浏览器与标签页右键动作在迁移中缺失；已恢复打开、预览、Finder 定位、分屏和关闭动作。
- P2：详情分段控件原本仅为视觉控件；已接通信息、大纲和 Git 三个真实状态。
- P3：Aster 保留独立品牌和九类设置侧栏，因此窗口整体不是 Otty 品牌复制；主题数据、缩略卡结构、选中状态和界面样式令牌按目标对齐。

## 0.4.x 设置页 Otty 风格重构验收（2026-08）

- 参考源：用户提供的 Otty 设置页截图（通用 / Shell / 编辑器 / 控制 四页）。
- 结构：设置窗口启用 `fullSizeContentView` + 透明标题栏实现全高侧栏，默认尺寸对齐截图的 700×460（内容滚动，宽度下限 700 保证主题网格不裁切）；侧栏导航行整宽方角高亮贴到窗口边缘，图标/文字左侧留 22pt 间隙，搜索框独立留边；内容区改为「分组小标题（小号灰色加字距）+ 大圆角卡片」，卡片行间取消 hairline 分隔线，靠行内边距留白；主题网格按窄内容区改为 3 列 130pt 卡片；间距/字号/圆角集中到 `SettingsMetrics`。
- 接线：通用、Shell、控制、编辑器、智能体、Recipes 页的开关与下拉接通 `AsterConfiguration` 既有字段（关闭确认、Shell/SSH 集成、会话恢复、通知、徽章、复制粘贴、编辑器选项、智能体启用、命令重放、行高、显示标签栏等）；枚举下拉由 `allCases` 单一来源生成，说明文案只描述配置意图。
- 交互：全量重建 `refresh()` 增加按分类的滚动位置保存/恢复，控件改动不再跳回顶部。
- 修复：内容区分组标题曾被内容栈按固有宽度靠右放置（跑到卡片右上角），压低水平 hugging 后恢复整行左对齐；`NSColor.controlAccentColor` 两处替换为 `AsterTheme.accent`，遵守主题色只经由 `ThemeRuntime` 的规则。
- 测试：布局测试改在内容滚动区内定位分组标题（侧栏按钮内部文本会干扰），卡片圆角断言引用 `SettingsMetrics`；新增「分类页由真实控件构成」与「新接线字段持久化 + normalized 钳制」两个测试。`swift test --no-parallel` 60 项全部通过。
- 追记（2026-08-07）：分组卡片底色从 `AsterTheme.panel`（surface）改为新增的 `settingsCard` 角色 —— Ayu 等多数主题的 surface 与窗口背景几乎相同（#FFFFFF / #FCFCFC），卡片「看不见」。`settingsCard` 以窗口背景为底向界面主文字色轻混 4%，浅色主题得到浅灰卡片、深色主题卡片略微提亮，内容画布保持窗口底色（用户确认目标效果是白底 + 灰卡片，初版灰画布 + 白卡片做反了已反转）。主题真值表未动，`swift test --no-parallel` 61 项全部通过，实机截图验收符合参考图。
- 追记二（2026-08-07）：修复「通用」页系统集成卡片丢失左侧 inset、贴到内容区左边缘的问题。根因 = 行内长说明文字不换行时的单行固有宽度（约 650pt）超过内容区可用宽度（448pt），NSStackView 的 `.width` 对齐 + `edgeInsets` 对这类 arranged subview 的分配不可靠（实测被放到 x=0、宽 474；压缩阻力从 750 逐级降到 250 均无效）。修复：`card()` 打 `settings.card` 标记，`makeContentScroll` 对标题与卡片施加显式 required 的 leading/trailing 约束（= 栈边 ±26pt），行内 labels 栈显式压低水平压缩阻力让说明文字换行吸收超宽压力。同一机制还修复了「外观」页光标卡片窄缩（357.5pt）的隐性偏差。新增回归测试「设置页所有分类的卡片保持左右边距且占满内容宽度」逐页断言。

## 0.4.x 侧栏标签运行态与系统集成（2026-08）

- P0：有前台命令运行时点击侧栏标签无响应。根因 = OSC 0/2 标题高频重发（无去重）→ 工作区整树以近每帧频率重建，`TabRowButton` 在 mouseDown/mouseUp 之间被销毁、action 永不触发。修复：`TerminalSession` 对标题/目录发布去重 + 标签行改为 `mouseDown` 立即派发选择。
- P1：运行中标签缺少状态指示。新增 `TerminalSession.hasRunningCommand`（每秒 `tcgetpgrp` 比较 PTY 前台进程组与 shell pgid，仅翻转时发布），侧栏行右侧显示小型 spinner；「无业务状态来源不放加载指示器」的原则保持成立。
- P1（回归）：命令有输出时 spinner 闪烁——OSC 标题变化经全量 objectWillChange 转发触发整树重建，spinner 每次重建都重启动画。修复：Tab 只定向转发 UI 消费的会话字段（isRunning / hasRunningCommand / exitCode / startupError）。同时按用户预期把 spinner 语义收紧为「前台命令 + 近 5 秒有输出」；活跃度探针从光标/滚动位置改为可见屏幕内容哈希——Claude Code 思考时在原位重绘状态行（光标不动），位置探针会误判为无输出导致 spinner 时有时无，内容哈希能稳定捕捉原位动画，静止等待输入的界面则在窗口过后停转。
- 安全：ssh:// 链接的 user/host 加保守字符集白名单（拒绝控制字符），防止 percent-encoded 换行把「预填不执行」变成注入自动执行。
- P1：右侧内容区被套上 panel 色（April 主题下 #F4F6F4 灰绿），与白色终端画布割裂。根因 = 容器背景解析回退顺序 `container ?? panel ?? background` 错借 panel；改为 `container ?? background`（与终端画布连续、透明保持透明），与主题缩略卡的绘制规则及 Otty 参考截图一致。主题真值签名（fg/bg/ANSI）不受影响，测试全绿。
- P1：切换标签时原标签名字变化（选中显示完整路径 / 未选中显示短名两个字段）。统一为始终显示 `tab.title`（目录稳定显示名，主目录 `~`），OSC 7 改名只在真正变化时写回。
- 通用页新增「系统集成」组：设为 ssh:// 默认终端、安装 `aster` CLI、Finder「在 Aster 中打开」服务（Info.plist NSServices + servicesProvider）、完全磁盘访问设置入口；ssh 链接与 Finder/CLI 目录统一走 `handleOpenURL`，ssh 命令只预填不自动执行。「为常用应用设为默认终端」（改写第三方应用配置）未实现。
- 追记（2026-08-07）：垂直侧栏新增悬停动作区 —— 鼠标进入侧栏时 header 顶部右侧（与红绿灯同一水平线）淡入「+ 新建标签页 / 折叠标签栏」无边框按钮，离开淡出；折叠写入既有 `appearance.showTabBar` 配置。折叠态在内容区顶部叠加点击穿透悬停带（`ClickThroughStripView.hitTest = nil`），鼠标进入窗口顶部淡入「+ / 展开标签栏」，按钮行是悬停带的兄弟视图（否则点击穿透吞掉按钮点击），leading 让开红绿灯遮挡区（实测约 103pt）。「显示」菜单新增「显示/隐藏标签栏」共用同一开关。旧的「垂直标签栏不含按钮」「标题区无 ActionButton」断言按新设计更新：标题区仍保持纯净，悬停按钮属侧栏/折叠态覆盖层。新增「折叠标签栏后顶部提供悬停恢复入口」回归测试。`swift test --no-parallel` 75 项全部通过；实机视觉验收（侧栏态 hover 截图与参考图一致）由用户完成。

final result: passed
## 终端进度、徽章与通知验收（2026-08-08）

- 本批次按用户要求不执行界面测试、通知横幅实机触发或 Dock 动画截图；视觉与系统权限手感由用户检查。
- 待用户检查：横向/垂直标签的五类状态、成功状态一秒过渡、等待输入手势、Dock 动画/错误标红/点击跳转、系统通知前台策略和设置页权限状态刷新。
- 代码侧已用非并行全量测试覆盖 OSC 9;4、OSC 9/777/99、Kitty 分片/base64/替换/查询、BEL、标题权限、自动进度、`aster watch`、直接徽章、等待提示判定、Dock 聚合、旧配置兼容和 parser 前通知限长。

## 终端复制与粘贴功能验收（2026-08-08）

- 本批次按用户要求不执行界面测试或截图验收；视觉与交互手感由用户自行检查。
- 待用户检查：终端右键“粘贴为”层级、危险粘贴预览在长文本下的可读性、设置页新增 OSC 52 下拉项，以及 Base64 文件选择错误提示。
- 代码侧验收覆盖复制文本转换、四类风险、bracketed 结束标记中和、精确传输字节、Shell 转义、普通文件/符号链接/大小边界、parser 前 OSC 跨分片限长、OSC 52 解析/响应/Allow-Ask-Deny/提示冷却副作用，以及旧配置和导入安全默认值。

## 终端输入功能验收（2026-08-08）

- 本批次继续不执行界面测试；用户可检查“编辑 → 文本编辑 / 安全键盘输入”的菜单层级与快捷键显示。
- 代码测试覆盖 9 种可移植 readline 精确字节、普通屏/alternate screen 接管边界、输入/输出即时安全采样、canonical 隐藏输入策略，以及多 Pane、手动请求、应用失活和系统调用失败的保护状态机。

---

# Workspace Title Popover Design QA

- source visual truth: `/var/folders/7x/yt4bl33s2yq8vgt2cswylzwr0000gn/T/codex-clipboard-8415b98c-0031-4144-9834-9134a36495f6.png`
- implementation screenshot: `/Users/mike/source/project/AsterTerminal/.build/design-qa/workspace-title-popover-final.png`
- combined comparison: `/Users/mike/source/project/AsterTerminal/.build/design-qa/workspace-title-popover-comparison-final.png`
- viewport: 280 × 462 pt popover content, light appearance, Name segment selected
- density normalization: source popover region cropped to 560 × 924 px at approximately 2×; implementation captured at 560 × 950 px at 2×, including 13 pt of native popover chrome above and below the 462 pt content region
- state: hover title path entry clicked; workspace action popover open; no text field focus

## Full-view comparison evidence

The final combined image places the source on the left and the rendered AppKit implementation on the right. Both use the same information order, 280 pt width, compact vertical rhythm, segmented Name/Prefix header, filled name field, uppercase working-directory heading, folder/path row, action dividers, trailing notification icons, submenu chevrons, and keyboard shortcuts. The implementation uses native AppKit text rasterization and SF Symbols; the source uses the same macOS visual language. No actionable P0/P1/P2 differences remain.

## Focused region comparison evidence

The full comparison already renders the controls at 2× and keeps all labels and icons readable, so a second crop was unnecessary. The most fidelity-sensitive header region was checked at original pixels: the selected Name segment is a white capsule with a subtle shadow on a neutral track, and the text field uses a borderless gray fill matching the source. The working-directory and action regions preserve the source alignment and separator rhythm.

## Required fidelity surfaces

- Fonts and typography: native system font, matching regular/semibold hierarchy, uppercase directory heading, single-line truncation, and shortcut weights are consistent with the source.
- Spacing and layout rhythm: width, grouping, row order, dividers, corner radii, and compact action spacing match; the 26 px height difference is native popover chrome rather than content drift.
- Colors and visual tokens: neutral AppKit/Aster theme tokens reproduce the light surface, gray field, secondary labels, dividers, and hover affordance without adding a title-specific background color.
- Image quality and asset fidelity: the source contains no raster product imagery. Visible icons use native SF Symbols at backing scale; no placeholder, emoji, custom SVG, or bitmap substitute is present.
- Copy and content: labels, working-directory formatting, submenu affordances, and keyboard shortcuts match the requested reference. The path is dynamic and therefore uses the test workspace value.
- Interaction and accessibility: Name/Prefix, reset, copy path, Finder, editor menu, Git menu, notification settings, split menu, find, global find, Jump to, and Command Palette are native controls with target/action behavior and accessibility descriptions for icon-only controls.

## Comparison history

1. Initial capture: `.build/design-qa/workspace-title-popover-comparison.png`.
   - P2: popover was 300 pt wide and vertically too loose.
   - P2: Copy/Reveal used leading icons absent from the source; Notifications used one leading icon instead of two trailing status icons.
   - P2: name field used a white bordered bezel instead of a filled gray field.
   - Fixes: reduced the popover to 280 × 462 pt, tightened stack spacing, removed the extra action icons, added trailing SF Symbols for notification/sound, and changed the field to a borderless neutral fill.
2. Second capture: `.build/design-qa/workspace-title-popover-comparison-v2.png`.
   - P2: the system capsule drew the selected Name segment gray instead of white.
   - Fix: retained `NSSegmentedControl` semantics while rendering the reference white selected capsule, neutral track, native typography, and subtle shadow.
3. Post-fix capture: `.build/design-qa/workspace-title-popover-comparison-final.png`.
   - Result: earlier P2 findings are resolved; no actionable P0/P1/P2 difference remains.

## Residual P3 polish

- Native font rasterization and the system popover material may vary slightly by macOS appearance and display scale; this is expected platform behavior and does not change hierarchy or operation.

final result: passed
