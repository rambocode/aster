# 界面文字可读性：字号档位与加深文字

## 业务背景

用户反馈设置页和侧栏的字太小、太淡，而终端本身的字号已经够用。原因有三条：界面字号在两百多处写死成 10–12pt；没有一处跟随系统的文字大小设置；次要与三级文字色的对比度偏低（设置页浅色模式的三级文字 `#aaa` 对白底只有约 2.3:1）。

本功能提供两个互相独立、也和终端字号独立的设置，都在「设置 → 外观 → 界面文字」：

- **界面字号**：五档，倍数 0.9 / 1 / 1.15 / 1.3 / 1.5。
- **加深界面文字**：把次要、三级文字色朝主文字色推，直到对比度不低于 4.5:1。系统开启「增强对比度」时视同开启。

## 领域概念

- `InterfaceTextScale`（`Sources/AsterCore/InterfaceTextLegibility.swift`）：档位枚举与倍数。未知档位解码为默认档，不让整份配置解码失败。
- `InterfaceTextContrast`（同文件）：加深取色规则与 WCAG 对比度计算，不依赖 AppKit。
- `InterfaceScale`（`Sources/Aster/InterfaceScale.swift`）：应用层入口，把档位变成字体与尺寸。
- 配置字段：`appearance.interfaceTextScale`、`appearance.interfaceHighContrastText`，都是可选字段，旧配置缺失时按「默认档 / 关闭」解析。

## 核心规则

1. **界面字号只从 `InterfaceScale` 取。** 新代码不直接写 `NSFont.systemFont(ofSize:)`，改用 `NSFont.interface(ofSize:weight:)`、`interfaceMonospaced`、`interfaceMonospacedDigit`；`makeLabel(_:size:)` 内部已经缩放，调用方传默认档字号，不要再乘倍数。
2. **装文字的固定尺寸跟着缩放。** 行高、文字控件的固定宽高、以文字为主的浮层尺寸用 `InterfaceScale.length(_:)`；被外部几何卡住的尺寸（标题栏、屏幕大小）用 `length(_:max:)` 设上限。
3. **不缩放的东西。** 间距、圆角、描边、分隔线、动画参数、窗口最小尺寸、Panel 宽度，以及一切终端内容（终端字体、文件预览正文、Dock 图标绘制）。它们放大后只会挤掉内容。
4. **默认档必须和改动前逐像素一致。** 倍数为 1 时所有 API 原样返回，现有布局测试与截图不受影响。
5. **原生界面的档位在启动时固定。** `AsterAppDelegate.init` 在创建任何窗口前调用 `InterfaceScale.install`；字体与行高在视图创建时确定，运行中改档位只写配置并询问是否重启（与界面语言同一做法）。因此 `static let` 里使用缩放 API 是安全的。
6. **设置页立即生效。** 设置页是 `WKWebView`，按配置里的最新档位设置 `pageZoom`，用户改档位能当场看到大小，再决定是否重启。
7. **加深文字只动次要与三级色。** 主文字、强调色、底色不变。`ThemeRuntime.color(for:)` 对 `.secondary` / `.tertiary` 角色生效；主题里直接取出的文字色（侧栏 `tab.foreground`）经 `ThemeRuntime.legibleText(_:in:)`。背景半透明（磨砂主题）时算不出真实对比度，只做固定幅度的加深。
8. **设置页的加深配色由原生侧判定。** 快照字段 `appearance.interfaceStrongTextActive` 包含系统「增强对比度」，网页据此给根元素切换 `strong-text` 类，不自行判断。

## 业务流程

1. 用户在设置页改「界面字号」→ 网页发 `set` → `applyWebSetting` 写入配置并立刻设置 `pageZoom` → `handleWebSet` 发现档位变化，弹出「立即重启 / 稍后」。
2. 重启后 `InterfaceScale.install` 读到新档位，侧栏、面板、浮层按新字号构建。
3. 用户开关「加深界面文字」，或系统「增强对比度」变化 → `AppPreferences.synchronizeThemeRuntime` 更新 `ThemeRuntime` → 工作区按主题变化的同一条路径刷新；设置页收到新快照后切换 `strong-text`。

## 关键实现

- 档位与取色规则：`Sources/AsterCore/InterfaceTextLegibility.swift`。
- 缩放入口与重启提示：`Sources/Aster/InterfaceScale.swift`。
- 文字色加深：`ThemeRuntime.setStrengthensText` / `legibleText`（`Sources/Aster/DesignSystem.swift`），由 `AppPreferences.strengthensInterfaceText` 驱动。
- 设置页：`Resources/settings-ui/settings.js` 的「界面文字」分组，`settings.css` 的 `:root.strong-text`。

## 失败语义

- 配置里的档位写错：按默认档解析，其余设置不受影响。
- 用户选了「稍后」：配置已保存，设置页已缩放，原生界面保持旧档位直到下次启动。再次打开设置不会重复弹窗，除非档位再次改变。
- 极窄的侧栏配最大档：标签名按原有规则截断，用户可以拖宽侧栏。

## 测试与验收

- `Tests/AsterCoreTests/InterfaceTextLegibilityTests.swift`：倍数、旧配置兼容、未知档位、对比度达标、半透明背景。
- `Tests/AsterTests/InterfaceScaleTests.swift`：默认档与系统字体一致、取整规则、`ThemeRuntime` 只改次要色、设置页往返与 `pageZoom`。
- 人工验收：五档逐档重启，检查侧栏行、详情面板、浮层、用量面板没有截字或重叠；浅色与深色各检查一次加深开关。
