# Aster AppKit 界面架构

## 业务背景

Aster 0.4.1 的主窗口、设置窗口和所有交互控件均使用 AppKit。目标是获得稳定的 macOS 窗口材质、分屏拖动、菜单、键盘焦点和终端视图生命周期，同时继续精确应用 Otty 主题中的窗口、侧栏、标签、容器、阴影和材质令牌。

## 领域概念

- **AsterAppDelegate**：应用生命周期与菜单入口，创建主窗口和设置窗口。
- **WorkspaceViewController**：工作区组合根节点，负责标签布局、Pane 树、详情面板和命令面板。
- **SettingsViewController**：九类设置的原生侧栏和内容区，控件直接写入 `AppPreferences`。
- **WorkspacePaneRuntime**：持有 SwiftTerm 或文档缓冲，独立于 AppKit 视图的重排与刷新。
- **ThemeVisualEffectView**：将主题材质与色彩令牌映射为 `NSVisualEffectView`。
- **SidebarOptionsButton**：`TABS` 右侧的原生菜单入口，管理标签分组、时间排序和手动分隔线。
- **ActionButton / ActionMenuItem**：将局部闭包安全桥接到 AppKit target/action。

## 核心规则

1. `Sources/Aster` 不得导入 SwiftUI，也不得创建 `NSHostingView` 或 `NSHostingController`。
2. 终端运行态由 `WorkspacePaneRuntime` 持有，AppKit 布局重建不得重启 PTY。
3. 递归 Pane 树使用 `NSSplitView` 渲染；仅在用户拖动分隔线时持久化比例。
4. 菜单、搜索、分段控件、颜色选择器和文件列表使用原生 AppKit 控件及标准键盘焦点。
5. 主题令牌通过动态 `NSColor` 和 `ThemeVisualEffectView` 进入所有窗口层级，不在视图中散落固定主题色。
6. 文件与标签的右键菜单在打开时根据当前选择生成，不能保留已经失效的文件 URL 或标签引用。
7. 用户可见交互变化必须同步更新开发文档和用户帮助。
8. 垂直侧栏与设置导航必须显式使用整宽约束；不能依赖 `NSStackView` 的固有宽度推断。
9. 滚动设置内容必须使用翻转坐标系并从 `NSClipView` 顶部开始，短页面也不得垂直下沉。
10. Pane 树所在的容器链在**两个方向**都必须有必需尺寸约束，不能只约束宽度。
11. 切换聚焦 Pane 只做局部更新（焦点指示线 + first responder），不触发工作区整树重建。
12. 每个工作区窗口拥有独立 `AppModel` 和持久化 suite；设置和主题全局共享。附加窗口 suite 只接受 UUID 命名且最多恢复 16 个。
13. 跨窗口标签移动必须转移同一个 `TerminalTabItem`，不得从 snapshot 重建并丢失 PTY、滚动历史或 Agent 状态。
14. 外部拖放先按普通文件、符号链接、URL 和数量上限校验，再进入预览、文件浏览器或粘贴安全链路。

## 业务流程

```mermaid
flowchart LR
  A[NSApplication 启动] --> B[AsterAppDelegate]
  B --> C[WorkspaceViewController]
  B --> D[SettingsViewController]
  C --> E[Tab Bar]
  C --> F[Recursive NSSplitView]
  F --> G[SwiftTerm NSView]
  F --> H[File Browser / Editor / Preview]
  D --> I[Native AppKit Controls]
  I --> J[AppPreferences]
  J --> K[ThemeRuntime]
  K --> C
  K --> D
  J --> G
```

## 关键实现

`AsterApp.swift` 使用自定义 `@main` 调用 `NSApplication`，由 `AsterAppDelegate` 管理窗口、菜单和退出事务。「显示」菜单集中全部分屏命令：四个方向的拆分、缩放拆分、「调整拆分大小」与「聚焦面板」两个子菜单、关闭当前面板；只在多面板下有意义的项由 `NSMenuItemValidation` 按 `AppModel.selectedTabHasSplits` 置灰。`⌘W` 走 `closeSelectedPaneOrTab()`：还有分屏时只关闭聚焦面板，最后一个面板才关闭标签页（`⇧⌘W` 始终关标签页）。

`AsterAppDelegate` 同时管理主窗口和附加工作区窗口。菜单、命令面板与 CLI `--new-window` 统一经模型回调创建窗口；Pin 只接受工作区窗口，PiP 可固定当前 Pane 或跟随活动 Pane。正常退出保存仍打开的附加 suite，用户主动关闭则删除；关闭确认发生在可取消的 `windowShouldClose`，应用退出由 `WorkspaceTerminationTransaction` 先确认全部模型再统一提交，避免后续窗口取消时前序 PTY 已被终止。crash loop 规则仍由各模型独立执行。Dock 聚合器订阅全部窗口，错误跳转和 Agent 防睡不会漏掉后台窗口。

PiP 与主工作区共享同一个长期 `TerminalSession` 容器。`PanePictureInPictureOwnership` 按对象身份登记唯一展示所有者；所有权存在时工作区渲染占位，刷新不得调用 `removeFromSuperview()` 抢回终端。跟随模式切换 Pane 时先释放旧所有权再接管新会话，关闭 PiP 后通知原工作区恢复同一容器。

`WorkspaceViewController` 使用 `NSStackView` 组合三种标签栏布局，用递归 `PersistedSplitView` 渲染 `PaneLayout`；`ActivePaneHostView` 不再画当前 Pane 的 2 pt 强调色顶边（在聚焦窗口里比终端内容还抢眼），改为给**非**聚焦 Pane 铺整块褪色遮罩（`AsterTheme.paper` 30%，`ClickThroughStripView` 点击穿透，点非活动 Pane 的第一下要能同时激活它并落到终端）。遮罩先于拖动把手安装，把手才浮在其上；切换聚焦只翻转 `isActivePane`（`didSet` 改遮罩可见性），不重建视图树。

**窗口活动状态**：窗口失去 key 状态时叠加 `InactiveWindowOverlayView`（主题 `paper` 色 45% 透明、`hitTest` 返回 nil，失焦窗口的第一次点击照常落到终端）。AppKit 只会自动灰化系统控件，终端网格与自绘视图不受影响，没有这层遮罩时非活动窗口看起来仍然「亮着」。通知按 `notification.object === view.window` 过滤，多窗口互不影响；`refresh()` 会清空子视图，因此刷新末尾要重新安放遮罩。分隔条的强调色在窗口非 key 时也一律退回灰线。窗口活动状态还会下发到所有会话：`AsterTerminalView` 在失焦时把生效样式换成 `preferredCursorStyle.nonBlinking`，终端光标停止闪烁但形状不变——SwiftTerm 的 `caretView.focused` 只切换实心/空心，闪烁完全由 `CursorStyle` 的 blink 变体决定，而窗口失焦并不会触发 `resignFirstResponder`。`preferredCursorStyle` 仍是用户配置的唯一真值，DECSCUSR 拦截按「生效样式」比较。

SwiftTerm 的 overlay `NSScroller` 在 `AsterTerminalView.didAddSubview` 里被隐藏：它是一条 5.5 pt 灰条，随滚动闪现又消失、并盖住右侧文字。SwiftTerm 的 `reservedScrollerWidth` 在 scroller 隐藏时归零，终端网格会自动收回这几个点，不会留白。

**分屏容器的尺寸约束**：`NSSplitView` 的子视图走 autoresizing，它无法反推内容尺寸，于是给每个子视图加 `PreferredSize/FallbackSize`（`height == 0 @250`）回退约束，自身在分隔方向的垂直方向上只剩分隔条厚度的固有尺寸。因此容器链两个方向都必须给必需约束：内容区绑定到外层 stack 的宽/高，`wrapper` 钉到 stack 底边，无 Composer 时 Pane 区直接钉到 `inner` 底边，有 Composer 时由 Composer 占据底边。只约束宽度时，上下分屏会把整个内容区塌成一条分隔条，两个终端高度都是 0（表现为窗口大面积空白、标题区被挤到垂直中央）。`PersistedSplitView.layout()` 还要等容器给出有效尺寸（>1pt）后才定位分隔条，否则首轮布局会把比例锁死在无效值上。

**分隔条与 Pane 拖放**：`PersistedSplitView` 的 `dividerThickness` 是 6pt 的命中区，`drawDivider(in:)` 只画中间 1pt（悬停 2pt）——默认 `AsterTheme.hairline`，仅在「窗口是 key 且指针压在命中区上」时换成 `AsterTheme.accent`；命中区 `NSTrackingArea` 由两个子视图的间隙算出，并在 `splitViewDidResizeSubviews` 里重建（自身 frame 不变时 AppKit 不会重建它）。移除感应区不会补发 `mouseExited`，指针恰好停在旧感应区里时高亮会卡住，因此每次重建后用 `mouseLocationOutsideOfEventStream` 对齐一次悬停状态。比例一律针对「扣掉分隔条的可用长度」，否则第一块会固定多出一个分隔条厚度。双击分隔条恢复等分。

Pane 顶边的 `PaneDragHandleView` 对应参考应用的 drag handle：`ActivePaneHostView` 用顶部 14pt 的 `NSTrackingArea`（不是覆盖视图——任何实体覆盖层都会吃掉终端在那一条上的点击与拖选）控制淡入，把手自身的 tracking area 负责悬停时加宽到 56pt、换成强调色并 `cursorUpdate` 到 `NSCursor.openHand`；完全透明时 `hitTest` 返回 nil，避免 Pane 顶部中央出现点不到终端的死区。按下把手后由 `NSWindow.trackEvents` 接管事件循环（落点都在本窗口内，不需要 `NSDraggingSession` 的粘贴板协议），`PaneDropOverlayView` 绘制落点：边缘用强调色（插到该侧，`PaneLayout.movingPane`）、中心用绿色（交换，`PaneLayout.swappingPanes`）。落点几何抽成 `PaneDropGeometry.zone(in:at:)` 纯函数单测，方向语义按 AppKit 非翻转坐标（y 小 = 底边）。两种操作都只重排描述符，面板 ID 不变，PTY 与滚动历史不重启。

标签行同样使用阈值拖动。松手点位于另一个工作区窗口时，源/目标 `AppModel` 直接转移已有 `TerminalTabItem`；位于窗口外时创建附加窗口。源窗口被取走最后一个标签会补空 Shell；新窗口创建失败则把原 Tab 放回。Finder/浏览器拖入由 `ActivePaneHostView` 的标准 `NSDraggingDestination` 处理，文本复用 paste protection，目录按内外落区创建终端或文件浏览器，文件创建预览。

**聚焦跟踪**：终端与文本视图自己消费 `mouseDown` 且不向 responder 链上抛，容器视图收不到点击，因此用窗口级 `NSEvent.addLocalMonitorForEvents` 沿 hitTest 结果的 superview 链定位 `ActivePaneHostView`。焦点变化经 `TerminalTabItem.activePaneChanged`（`PassthroughSubject`，不是 `@Published`）发布；`activePaneID.didSet` 统一覆盖显式聚焦、拆分、恢复、拖移和关闭后的焦点转换，避免消费者继续观察旧 Pane。控制器只更新指示线与 first responder——若走 `objectWillChange` 会重建整棵视图树，打断终端拖选与 TUI 重绘。视图树重建后只对活动 Pane 调用 `session.focus()`；过去对每个终端都调用，最后渲染的那个会抢走输入焦点，导致「关闭当前面板」关错对象。

垂直侧栏整宽标签行的主文案始终显示 `tab.title`（目录稳定显示名，主目录为 `~`），选中与未选中之间切换不改变名字；行右侧在「有前台命令且近 3 秒内有输出」时显示小型 `NSProgressIndicator`（状态来源是 `TerminalSession.hasRunningCommand`：每秒用 `tcgetpgrp` 比较 PTY 前台进程组与 shell pgid，并以可见屏幕内容哈希作为输出活跃度探针（5 秒静默窗口）——Claude Code 等 TUI 思考时只在原位重绘状态行、光标与滚动位置不变，必须按内容而非光标位置探测；仅状态翻转时发布，等待交互输入的静止界面不会一直转圈），否则选中行显示 shell 名。两者都放在固定 28pt 右侧槽位；鼠标进入标签行时，槽位切换为无边框 `xmark` 按钮，不改变标题宽度。按钮调用 `AppModel.closeTab(id:)` 直接关闭目标：后台标签不先切换，当前标签仍按相邻顺序接续，未保存文档仍走原有确认。标签行在 `mouseDown` 立即派发选择而不等 `mouseUp` 的 target/action——整树重建可能在按下与抬起之间销毁按钮；`TerminalSession` 对 OSC 0/1/2 标题与 OSC 7 目录做去重发布，且 Tab 只定向转发 UI 消费的会话字段（isRunning / hasRunningCommand / exitCode / startupError），标题变化不再触发工作区重建。侧栏仍不允许没有业务状态来源的加载指示器。`TABS` 右侧使用 `SidebarOptionsButton` 弹出原生 `NSMenu`：GROUP 支持不分组、按项目和按日期，ORDER 支持按创建时间和更新时间，DIVIDER 在当前标签后插入分隔线或一次清除全部分隔线。分组与排序偏好写入独立 `UserDefaults` 键，分隔线跟随工作区快照恢复；标签快照使用可选时间戳兼容旧数据。默认宽度由旧版 250pt 迁移为 220pt，非旧默认值不改动。鼠标进入侧栏时，header 顶部右侧（与红绿灯同一水平线）淡入「+ 新建标签页 / 折叠标签栏」无边框按钮，离开淡出；折叠后（`appearance.showTabBar = false`）内容区顶部叠加点击穿透的悬停带（`ClickThroughStripView`，`hitTest` 返回 nil 以免拦截终端点击），鼠标进入窗口顶部即淡入「+ / 展开标签栏」按钮——按钮行是悬停带的兄弟视图而非子视图（否则点击穿透会吞掉按钮点击），且 leading 让开红绿灯遮挡区（实测约 103pt，比视觉圆点宽）；「显示」菜单的「显示/隐藏标签栏」与按钮共用同一配置开关。右侧标题区固定为 28pt，显示活动 Pane 的 OSC 2/0 窗口标题，并使用终端最终背景色与画布连续；OSC 1 的短名称只驱动标签文案。每个 Pane 独立保存程序标题，标题变化和 Pane 焦点切换通过专用事件局部更新 `NSWindow.title` 与标题文本，不重建终端视图树。标题区右端有详情面板的悬停切换按钮（`TitlebarHoverRevealView` 自持 tracking area，与侧栏悬停处理互不串扰）：指针进入时 0.15s 淡入、移出淡出；面板展开后保留同一入口实例但隐藏，收起入口在面板 header 右侧。除该按钮外，文件、分屏和命令面板仍通过菜单与快捷键使用，不在标题区重复放置按钮。面板显隐与选中页持久化在独立 `UserDefaults` 键（`aster.inspector.presented.v1` / `aster.inspector.section.v1`）；`AppModel.inspectorPresentationChanged` 只在当前内容区增删 divider/panel 并切换 workspace 尾部约束，绝不经过 `objectWillChange`，因此终端、Pane 树、侧栏与 first responder 全程保留。选中页同样由面板本地生效。底部自定义状态栏已移除，Pane 或 docked Composer 直接填充到容器底边；外观设置也不再显示无效的“显示状态栏”开关，配置字段仅保留用于旧文件解码兼容。

SwiftTerm 通过 OSC 7 上报目录时可能返回 `file://localhost/...`。`TerminalSession` 在更新标题和工作区快照前统一解析为本地绝对路径并进行百分号解码，防止 URL 字符串被误当成目录、污染下一次会话恢复。

SwiftTerm 的 `LocalProcessTerminalView` 直接作为 AppKit 子视图嵌入。文件浏览器使用 `NSTableView`，支持双击、预览、路径复制、终端目录动作、Finder/默认应用和 Send to Chat；详情面板（`WorkspaceDetailsPanel.swift` 的 `DetailsPanelViewController`）以四个 icon chip（Info / Outline / Git / Files）切换页签，未选中项只显示图标、选中项灰底展开文字，header 右侧有收起按钮。chip 宽度由显式约束驱动：收起态固定 26pt 正方形，四个页签在默认状态下保持统一间距（header stack `spacing = 6`），不随各自标题长度变化；选中态宽度取「收起宽度 + 标题实际测量宽度」，因为按钮内容居中，图标在两种状态下停在同一水平位置，只有文字从右侧长出来（改用固有尺寸展开会把 bezel 内边距算进来，图标会在动画里横向漂移）。点击切换时先把 constant 写成最终值，再在 `NSAnimationContext`（0.18s ease-out、`allowsImplicitAnimation`）里对 superview `layoutSubtreeIfNeeded()` 演出这一轮布局变化——用 `animator()` 代理改 constant 会让模型值滞后于动画，收起/展开状态无法被同步读取或测试。展开先写文字再放宽度以形成揭示效果（`lineBreakMode = .byClipping`，中间态按宽度裁剪而非省略号），收起则把清空文字延后到宽度收完，避免文字先消失、宽度后回缩的两段跳变。未选中 chip 悬停时叠加 0.05 alpha 底色，与选中态 0.08 拉开层次，背景切换走 0.12s `CABasicAnimation`。选中/悬停变化和系统 Reduce Motion 开启时全部降级为直接赋值。四页根视图首次展示后固定挂载到 `contentHost`，切换、活动 Pane 变化与 CWD 更新都只改页内数据或 `isHidden`；同标签收起/重开继续复用控制器、滚动容器、搜索框、表格行池和约束。Info 页显示工作目录、动作链接、子进程和监听端口。Outline、Git、Files 的大列表均使用 `NSTableView` 虚拟化，目录规模或 1,000 条大纲不再转换为等量常驻按钮；Files 目录默认收起，只用 `expandedPaths` 记录用户明确展开的路径，新目录首次展示仅投影顶层行，搜索、排序和折叠只重算轻量行模型，搜索框与滚动位置不因输入而重建。终端 OSC 133 大纲即时刷新，编辑器大纲使用 120ms trailing debounce、后台解析和 revision 校验；外层取消会传递到解析任务，行式解析每 64 行协作检查一次取消，旧文本既不继续消耗整份解析 CPU，也不能覆盖新版本。Git 继续显示分支、diff 统计和 staged/unstaged 分组。写操作全部收敛到 `injectGitCommand(_:)` 这一个出口，仍只经 `TerminalSession.typeText` 预填命令，不执行仓库写操作：Commit 是 `SplitActionButton`（AppKit 无分离式按钮控件，用主按钮 + 箭头按钮拼出，主动作一键可达而不是像 `NSPopUpButton` 那样点标题也弹菜单），下拉含 Push / Pull / Fetch / Merge… / Rebase…，后两者先用 `NSAlert` 收一个分支名。命令文本由 `AsterCore` 的 `GitCommand` 生成并单引号转义，分支名与路径先过 `sanitizedBranch`/`sanitizedPath`（拒空、拒控制字符、拒 `-` 开头）；非法输入不生成命令，绝不注入半条 git 命令。右侧第二个 `SplitActionButton` 用 `WorkspaceEditorLocator` 探测到的编辑器打开当前目录，箭头菜单切换默认项并写入 `aster.inspector.git-editor.v1`；探测结果可注入，因此测试不依赖本机真实安装。详情面板的三种列表行共用 `HoverHighlightRowView`：悬停时整行铺 `AsterTheme.ink` 6% 的圆角底色（独立子视图而非染 cell 的 layer，行才保留左右 8pt 留白），分组标题这类不可点的行用 `isHoverHighlightEnabled = false` 关掉——复用 cell 时两个方向都要显式设置，否则会继承上一行的状态。可点的无边框图标一律用 `IconHoverButton`（悬停底色 + 图标加深 + 手型指针，隐藏时自行清除悬停态，因为隐藏视图收不到 `mouseExited`），可点的无边框文本用 `PointingHandButton`；Git 与 Files 的文件项再打开 `activatesOnDoubleClickOnly`，在 `sendAction` 里按 `clickCount` 拦掉单击（单击打开会在滚动、选中或想点行尾图标时误开 Pane）。Outline 条目不受此限：它是跳转到行/终端位置，不打开新 Pane。变更行悬停时才在行尾露出暂存/取消暂存、在编辑器中打开、预览三个图标（`fileButton` 的 trailing 在两条约束之间切换——图标常驻会让所有行的路径提前截断），复用 cell 时分组行必须显式清掉这些动作。预览走 `GitDiffPreviewOverlay`：面板只有 278pt 宽放不下 diff，浮层挂在窗口 `contentView` 上并自带 scrim，`GitDiffParser` 把只读 `git diff` 分类成增/删/hunk/文件头后按主题色渲染到只读 `NSTextView`（4,000 行上限，超出追加提示行）。气泡本体是 `CalloutPanelView`：右缘贴详情面板左缘（用 `convert` 得到的实际边界，不硬编码 278），箭头对准触发行的垂直中心，行视图通过 `GitChangeRowActions.preview` 的参数上传。圆角矩形与箭头是同一条 `CAShapeLayer` 路径（分开画会在接缝处叠出两层阴影暗边，箭头基线因此嵌入矩形 1pt）。定位用 frame 而非约束——宽高要同时受可用空间、上限与最小可读尺寸约束，纵向还要在贴近窗口边缘时把本体夹回窗口内并让箭头留在原位，这组规则用互相冲突的约束表达并不更清晰；`layout()` 按同一组锚点重算，窗口缩放不会让气泡脱离面板。文件名压在 `DiffPreviewHeaderView` 标题条上：底色按设计稿固定为 `#EFF4FF`、只保留顶部两个圆角（非翻转坐标下是 `layerMinXMaxYCorner`/`layerMaxXMaxYCorner`），底边直接接 diff 文本。这是主题令牌规则的一处明确例外——底色既然不跟随明暗外观，条上的标题与关闭图标也必须一起固定为深色，否则深色主题的浅色前景落在浅蓝底上不可读。标题条、关闭按钮与滚动区的 trailing 都让开箭头宽度，否则它们会压在箭头根部。浮层用 local event monitor 处理 Esc 与浮层外点击（它是普通子视图，终端仍持有 first responder，不能依赖 `cancelOperation(_:)`），关闭时必须注销 monitor；切走 Git 页或收起面板一并关闭。未跟踪文件没有可比对象，`inspectDiff` 回落到 `git diff --no-index -- /dev/null <path>`，仍是只读命令。`WorkspaceInspectionClient` 把 Info、Git、Files 拆成独立懒加载请求：Info 只运行 `ps/lsof`，Git 只运行只读 `git status/diff`，Files 只枚举目录；切页、切 Pane、连续 `cd` 或收起面板会取消失效任务。阻塞命令以 25ms 周期观察 Swift Task cancellation，取消或超时后先 terminate，250ms 后仍未退出再 `SIGKILL`，同时保留固定绝对路径、输出上限和无登录 Shell 安全边界。Open Quickly 浮层（`OpenQuicklyOverlayViewController`）是顶部 chip 标签条 + 可滚动双行结果列表 + 底部快捷键栏：结果行带 SF Symbol 图标、相对时间（共享 `RelativeTime`）与类型徽章，多类型视图按 `OpenQuicklyIndex.sections` 分组显示小节标题；`OverlaySearchField` 额外截获 `⌘1`–`⌘9` 快速选中与 `⌘K` 操作菜单。「当前」过滤器除 Pane 外还含 `.prompt` 条目：运行中的前台命令名来自 `TerminalSession.foregroundCommandName`（Agent provider 优先，否则已提交命令首 token），提示词取同 provider、`updatedAt` 最新会话的最近 user prompt（pane ↔ session 无可靠映射，属刻意启发式），点击经 `AppModel.insertPromptIntoPane` 以 bracketed paste 写回终端输入行而不自动回车。Open Quickly 和全局查找使用独立 overlay，不改变终端 first responder 之外的运行态。

Files 目录枚举以可取消的 user-initiated 任务运行；快速切换目录会取消旧遍历，防止无效扫描积压并延迟当前结果。详情面板收起时同样取消尚未完成的当前页任务，但保留已经完成的快照与 Files 查询/折叠状态。

Open Quickly 使用独立 `openQuicklyPresentationChanged` 事件局部挂载，显隐不会触发 `WorkspaceViewController.refresh()`，关闭后保留控制器供下次复用。搜索框、过滤器、结果和底栏统一约束到 700pt 浮层的内容宽度；结果行池只更新图标、文本、徽章和动作，不在每次过滤或输入时重建视图与内部约束。面板使用 CALayer 阴影和独立轻量 scrim 建立浮层深度，搜索框关闭系统 bezel/focus ring 但保留插入光标、IME 与原生文本编辑。`OpenQuicklySearchFieldCell` 为 borderless 状态分别计算图标和文本矩形，`OpenQuicklyPanelView` 只在 36pt 搜索区保留 I-beam，面板其余区域显式注册 arrow cursor rect。浮层展示期间的 local event monitor 在按住 `⌘` 时展开 chip 和前九条结果的键帽提示，并拦截 `⌘0/W/R/Z/S/G/J/E` 切换对应过滤器。同一 monitor 处理 `Esc` 和窗口中浮层外部的左/右/其他鼠标点击，`NSApplication.didResignActiveNotification` 处理切换到其他应用时的隐藏；关闭时必须注销 monitor，不影响终端快捷键。Agent 历史扫描通过独立事件局部刷新消费者，不再重建终端工作区。复用行在移出 `resultsStack` 前停用宽度约束，重新加入共同层级后才激活，避免 AppKit `no common ancestor` 异常。

`SettingsViewController` 使用 `NSSearchField`、`NSPopUpButton`、`NSSwitch`、`NSSlider`、`NSColorWell` 和 `NSGridView`。设置窗口默认 `700 × 460 pt`（宽度下限 700，内容滚动），启用 `fullSizeContentView` 与透明标题栏，侧栏延伸到窗口顶部并以顶部内边距为红绿灯让位；200pt 导航列中，导航行的整宽方角高亮贴到窗口边缘、行内容左侧留 22pt 间隙，搜索框独立留边。右侧内容区以「分组小标题 + 大圆角卡片」组织：滚动文档使用 `FlippedDocumentView`（左上原点）从顶部排列，内容画布保持窗口底色（`AsterTheme.paper`），卡片是 `cornerRadius = SettingsMetrics.cardCornerRadius` 的 `NSStackView`，填充 `AsterTheme.settingsCard`。全量重建 `refresh()` 会按分类保存/恢复滚动偏移。智能体页从 `AgentSetupService` 读取七类 provider 的真实状态，安装/卸载按钮只进入受管配置事务；启动命令按 argv 保存。通用页安装的 `aster` CLI 不是 `open -a` 简单包装，而是带 `0600` token 的私有文件 request/response 客户端；写 Pane 的能力还受 IPC 设置控制。Finder 服务和 `ssh://` 继续只预填安全动作。

主窗口使用配置中的初始尺寸与 AppKit frame autosave。`windowDidEndLiveResize` 只在拖动结束后保存新的内容尺寸，避免 live resize 期间触发工作区重建；设置页可恢复 `1180 × 760 pt` 默认尺寸。

## 失败语义

- 终端或文档视图创建失败：只影响对应 Pane，其它 Pane 与标签保持可用。
- 文件浏览器目录刷新失败：显示空列表，不保留旧目录项引用。
- 主题或配置写入失败：保留当前内存状态并显示错误，不写入部分文件。
- 关闭未保存文档被取消：中止 Pane、标签、窗口或应用关闭事务。
- AppKit 菜单目标已释放：弱引用动作直接返回，不访问悬空运行态。

## 测试与验收

`AppKitMigrationTests` 静态确认主工作区和设置页不包含 SwiftUI Hosting，并检查 `NSSplitView`、九类设置、Glass 原生材质、整宽侧栏行、标签整理菜单、分组/排序/分隔线行为、28pt 标题区与设置页顶部锚定。完整测试还覆盖 24 套主题真值、终端、Recipe、文件安全与进程生命周期。发布前运行：

```bash
swift test --no-parallel
swift build -c release
./scripts/build-app.sh
codesign --verify --deep --strict dist/Aster.app
```

最后启动已打包应用，实测主题切换、左右/上下分屏、文件右键菜单、详情面板和设置窗口，并确认可执行文件没有 SwiftUI 动态链接依赖。
