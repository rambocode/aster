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

final result: passed
