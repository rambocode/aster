# 文件、链接与 File Pane 领域

## 业务背景

终端输出同时包含本地路径、普通 URL 和程序通过 OSC 8 标注的显式链接。它们均属于不可信输入：Aster 必须先解析、规范化和授权，再交给系统应用，不能沿用终端组件直接调用 `NSWorkspace.open` 的默认路径。

## 领域概念

- **DetectedTarget**：已规范化的文件或 URL，不包含打开动作。
- **TargetResolver**：解析绝对、`~/`、相对、`path:line[:column]`、`file:` 和其它 URL。
- **LinkSchemePolicy**：普通文字采用“全部”或“标准 + 自定义”检测；OSC 8 始终可识别。
- **TargetSecurityPolicy**：普通文件放行；外部网站、非标准 scheme 和可执行文件首次确认；特殊文件拒绝。
- **Security Exception**：分别记住用户在本机确认的网站 host、非标准 scheme 和可执行文件身份签名。
- **WorkspaceResourcePlacement**：资源进入 Current Pane / New Tab / New Window / 四向 Split 的统一落点。
- **WorkspaceResourceOpenMode**：Files 使用 `automatic` 按展示能力选择 editor/preview；CLI 保持显式 view/edit。
- **FileDocumentSession**：由 `WorkspacePaneRuntime` 持有的 UTF-8 文档缓冲、dirty/read-only/error 状态。
- **FilePresentationKind**：Markdown、reStructuredText、HTML、SVG、图片、PDF、富文档、diff、Agent transcript、源码和二进制。
- **WorkspaceFileActionService**：Files 菜单创建、重命名和移入废纸篓的唯一写入边界。

## 核心规则

1. 原始目标最多 4096 UTF-8 字节且不能含控制字符。
2. 相对路径只以活动 Pane 最近一次可靠 OSC 7 CWD 为基准。
3. `file:` URL 转为文件目标，不能绕过文件类型检查。
4. OSC 8 不受自动检测白名单限制，但仍需打开授权。
5. FIFO、socket、设备和未知文件类型不得打开或预读。
6. 网站与 scheme 例外小写去重；可执行授权绑定文件身份，文件变化后重新确认；配置导入会剥离全部本机授权。
7. Files 打开使用 `automatic`：Markdown、reStructuredText、HTML、SVG 和普通源码恢复为 `.editor` 且默认可编辑；图片、PDF、富文档、diff、Agent transcript 与二进制恢复为 `.preview`。CLI 的 `view` / `edit` 与新建文件的显式 `edit` 不受影响。
8. 文件名拒绝空值、`.`、`..`、路径分隔符、控制字符和超过 255 UTF-8 字节的值；创建不覆盖同名项。
9. Rename 只在同一父目录内移动，并同步所有已打开文件及目录后代 Pane；删除只调用系统 Trash。
10. Source/Preview、锁定、语言、Soft Wrap 与缩放属于运行态，不改变既有 `.editor` / `.preview` 快照格式。

## 业务流程

```mermaid
flowchart LR
  A[Command-click] --> B{OSC 8?}
  B --> C[TargetResolver]
  C --> D{文件或 URL}
  D -->|文件| E[stat 文件类型]
  D -->|URL| F[scheme 策略]
  E --> G[TargetSecurityPolicy]
  F --> G
  G -->|允许| H[NSWorkspace.open]
  G -->|首次风险| I[打开一次 / 始终允许 / 取消]
  G -->|特殊文件| J[拒绝]
```

### Files 到 File Pane

```mermaid
flowchart LR
  A[Files row] --> B{Context action}
  B -->|Open| C[Launch Services]
  B -->|Open in Aster| D[AppModel.openResource]
  D --> E{Placement}
  E --> F[Current Pane]
  E --> G[New Tab / Window]
  E --> H[Split]
  F --> I[PaneDescriptor]
  G --> I
  H --> I
  I --> J[WorkspacePaneRuntime]
  J --> K[FilePaneViewController]
```

Files 的右键菜单保持固定结构：`Open`、`Open in Aster` 子菜单、创建/重命名/废纸篓、路径复制和 Finder。树展开仍由 chevron 或双击负责，不混入资源动作。`Copy Relative Path` 以当前 Files 根目录按 path components 计算，不用字符串前缀，也不添加 `./`。

File Pane 的顶部工具栏负责模式、Send to Chat、Share、保存状态、保存和关闭。Markdown、reStructuredText、HTML 与 SVG 显示 code/eye 胶囊，默认 Source，可切换 Preview；普通源码显示 code/lock 胶囊，默认可编辑，可就地锁定。预览专用类型不显示无效模式开关。Markdown 由固定版本 `swift-markdown` 解析 GFM 后在禁用 JavaScript、禁用网络的 `WKWebView` 中展示；HTML/SVG 使用同一沙箱。源码由 HighlighterSwift/highlight.js 着色，同时保持原生 `NSTextView` 输入语义。图片使用可缩放 `NSScrollView`，PDF 使用 PDFKit，Office/媒体/字体交给 Quick Look，二进制使用 `NSTableView` 按可见行生成有界 hex。可信 Agent transcript 只复用已发现历史的解析结果，并提供 Resume/Fork；任意 JSONL 不会自行升级为会话。

每个 `WorkspaceViewController` 持有一个 `FileRenderPipeline` actor。语法高亮、Markdown 与 reStructuredText 转换在该串行后台边界完成，只把 RTF `Data` 或 HTML `String` 返回主线程；revision guard 会丢弃编辑后迟到的旧结果。`NSTextView` 与 `WKWebView` 在 Pane 生命周期内缓存复用，Source/Preview 和锁定切换只更新层级与编辑状态，不再重建整个工作区、WebKit 实例、选区或 undo 状态。

Pane 通过目标文件父目录的 vnode 事件检查 `contentModificationDate`，同时覆盖原位写入和 atomic replace；只有目录监听无法建立时才回退为带 tolerance 的一秒检测。没有本地改动时自动重载；存在 dirty 内容时显示 `Modified on Disk`，由用户从菜单明确 Reload 后才丢弃内存内容。保存继续使用 `DocumentBuffer` 原子替换，读取只接受普通、非符号链接文件，编辑缓冲上限仍为 10 MiB；超大或二进制预览只读取有界前缀。

## 关键实现与失败语义

`AsterTerminalView` 在点击发生时读取当前终端单元格的 OSC 8 payload，以精确区分显式链接和同值普通文字；`InlineURLDetector` 补充 SwiftTerm 固定 scheme 列表之外的 `scheme://`。自定义 URL 跨物理行时，会在可见区内按占满右边界的连续行重建，最多 8 行和 4096 字节；超出边界时拒绝截断打开。预览文字与实际打开共用 `TargetResolver` 和 Session 当前可信本地 CWD，因此相对路径、`~/`、`file:` 与行列后缀会显示成可核对的绝对路径；远端主机 OSC 7 不会被伪装成本机路径。底部预览使用独立圆角 badge：浅色外观固定为半透明黑底白字，深色外观反转为半透明白底黑字，只跟随系统明暗外观，不读取终端主题或 ANSI 颜色。Ghostty 主引擎下 `link-url` 固定关闭，普通文字 URL 与路径只有 Aster 一条通道：`TerminalInlineTargetScanner`（AsterCore）逐行切出 URL（`scheme://`、`mailto:`）与路径 token（绝对、`~/`、`./`、相对以及 `Makefile` 这类裸文件名，剥离 `@` 前缀、旗标、尾随句读，只接受 `:line[:column]` 形态的冒号）；`GhosttySurfaceView+Links` 把候选映射回终端列（含宽字符第二列），URL 按 `LinkSchemePolicy` 过滤，路径经 Session 提供的 `linkPathValidator`（`TerminalTargetOpenCoordinator.fileTargetExists`，按当前可信本地 CWD 解析后 stat）确认存在才采信，Command 按住期间结果有界缓存，CWD 变化即作废。Command 按下时扫描整个视口，用不参与命中测试的 `GhosttyLinkUnderlineOverlay`（zPosition 高于 CAMetalLayer）画实线下划线，输出、滚动、尺寸变化合并重扫，松开或指针离开即清除；Command 状态取自事件本身而非全局修饰键，便于合成事件测试。Command 悬停时手形指针由 Aster 设置，Ghostty 的 mouse_shape 只记录不应用，悬停结束后恢复。Command 点击在 mouseUp 放行 Ghostty 之后、以主队列异步方式打开命中目标，并用 `nativeOpenURLSequence` 确认同一次点击没有被 OSC 8 原生 `open_url` 抢先打开。预览仍是双来源：OSC 8 由 Ghostty `mouse_over_link` 原生上报并优先显示，普通文字目标由 Aster 侧识别；原生空清除信号只清原生预览并立刻按最近指针位置补一次 Aster 侧识别；badge layer 显式抬高 zPosition。`TerminalTargetOpenCoordinator` 负责终端目标；Files 的系统 Open 在再次 stat 后沿用同一特殊文件拒绝与可执行确认规则。控制页分别保存链接、文件与文件夹目的地：本地普通文件和目录选择 Aster 时由所属 `WorkspaceTab` 新建 Editor / File Browser Pane，HTTP(S) URL 新建 Web Pane，系统目的地继续交给 LaunchServices。Web Pane 的快照与 Recipe 只接受带 host 的 HTTP(S) URL，不开放脚本桥、本地文件或自定义协议；自定义应用只保存显示名和 bundle ID，每次使用时由 LaunchServices 重新定位，不固化可能失效的 `.app` 路径。SSH 远端文件仍不在本功能范围。

解析失败、用户取消或系统无对应应用均返回失败且不写例外。外部网站、非标准 scheme 与可执行目标的“始终允许”分别绑定 host、scheme 和文件路径/设备/inode/大小/修改时间签名；可执行文件发生替换或修改后旧授权不再匹配。特殊文件直接拒绝，配置导入统一剥离这些本机授权。测试位于 `FileDocumentTests.swift`、`WorkspaceFileActionServiceTests.swift`、`FilePaneViewControllerTests.swift`、`WorkspaceDetailsPanelTests.swift`、`DetectedTargetTests.swift`、`AppKitMigrationTests.swift` 和 `WorkspaceBehaviorTests.swift`。
