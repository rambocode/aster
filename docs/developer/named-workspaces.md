# 命名工作区

工作区就是一组标签。本机工作区是**同一窗口里的一组标签**：侧栏上方列出工作区，点一个只显示它的标签，切走的工作区里的终端照常运行（像 Arc 的 Space）。远端工作区挂在某台机器的服务上，切换器与新建表单沿用 tty7 的 workspace、switcher 和 New Workspace 设计。

## 三种概念

| 概念 | 实体 | 真值 | 说明 |
| --- | --- | --- | --- |
| 窗口内工作区（本机） | 窗口 `AppModel` 里的 `WorkspaceGroup` | 该窗口快照 `aster.workspace.snapshot.v1` 里的 `workspaceGroups` 与各标签的 `workspaceGroupID` | ⌘⇧N 选「本机」、侧栏「+」都建这种 |
| 远端命名工作区 | 服务端 `RemoteSessionSnapshot.workspaces` 里的一项 | 远端 `aster-session` | 客户端只存每台机器选中哪个、最近使用时间 |
| 窗口注册表条目（旧） | 一个窗口 | 窗口的 UserDefaults suite | 旧版「本机工作区 = 窗口」留下的条目；已关闭的固定窗口仍可从切换器重新打开 |

## 窗口内工作区

- 模型：`WorkspaceGroup`（AsterCore，`id`、`name`、`createdAt`）与纯规则 `WorkspaceGroupRules`（恢复整理、切换选中、删除去向、默认名称）。App 侧操作在 `AppModel+WorkspaceGroups.swift`，对话框在 `WorkspaceGroupActions`。
- **`tabs` 仍是全部标签的唯一真值。** 工作区只给本地标签打 `workspaceGroupID`；界面用 `visibleTabs` 只显示当前工作区。Agent 事件、通知、CLI、Dock 徽章和持久化继续面向全部标签，所以切走的工作区里的终端不会停，也不会丢通知。远端机器活动时 `visibleTabs` 等于全部标签，远端分组由远端工作区负责。
- **选中标签决定当前工作区。** `selectedTabID` 的 `didSet` 会把 `selectedWorkspaceGroupID` 切到该标签的工作区，所以 Open Quickly、通知点击、CLI 选中别的工作区的标签时，界面会跟过去。每个工作区上次选中的标签只记在内存里，重启后切回工作区时选第一个标签。
- **插入**：新标签（含跨窗口拖来的标签、Recipe、原生 SSH 标签）一律落进当前工作区；别的窗口的分组 id 在这里没有意义。
- **关闭**：只在同一工作区里选相邻标签，不跳到别的工作区。当前工作区被关空时补一个新 Shell，和「整个窗口关空补 Shell」的老规则一致；后台工作区被关空时先留空，切过去时再补。
- **移动**：标签右键「移到工作区」只改归属，界面留在当前工作区；移走的是当前标签时，当前工作区改选相邻标签。手动分隔线属于原工作区的排列，不跟过去。
- **删除**：至少保留一个工作区。先移除工作区并切到相邻工作区，再逐个关闭其中标签（进「最近关闭」，可以重新打开）。未保存文档由各标签自己询问；用户保留下来的标签移到切过去的工作区，不会变成看不见的孤儿。重新打开的标签回到原工作区，原工作区已删除时落进当前工作区。
- **兼容**：`workspaceGroups`、`selectedWorkspaceGroupID`、`workspaceGroupID` 都是可选字段。旧快照没有这些字段时，恢复层建一个「默认」工作区并把全部标签放进去；重复的分组 id 只留第一个，指向不存在分组的标签归到第一个分组。降级到旧版本时这些字段被忽略，所有标签回到同一个列表，不丢标签。

## 窗口注册表（旧的本地命名工作区）

旧版把「本机工作区」实现成一个窗口。下面的注册表规则仍然管理窗口的恢复与关闭，但 ⌘⇧N 选「本机」不再新开窗口。


- 模型是 `NamedWorkspaceRegistry`（AsterCore，纯值类型）。App 侧由 `NamedWorkspaceDirectory` 负责读写和维护「窗口 ↔ 工作区」的对应关系。
- 注册表存在 UserDefaults.standard 的 `aster.workspace.registry.v1`。
- **迁移**：注册表不存在时，主窗口变成固定保留的「主工作区」；旧键 `aster.workspace.additional-window-suites.v1` 里的附加窗口，变成不保留、已打开的代号工作区，名字像 `quiet-otter`。
- 之后注册表是唯一权威，但每次保存都会把打开着的 suite 写回旧键，所以降级后还能恢复。注册表已存在时，启动会和旧键对账（`reconcile`），用来处理「降级后又升级」的情况；正常运行时对账不改任何东西。
- **上限**：同时最多打开 17 个（主窗口 + 16 个附加窗口，和改造前的恢复上限相同）；关闭后最多保留 48 个，超出时按最近使用淘汰，连同快照一起删。启动时先清理再恢复，避免两个条目指向同一 suite 时开出两个窗口。

## 关闭语义

| 窗口来源 | 关窗 | 能否从切换器重新打开 |
| --- | --- | --- |
| ⌘N 新窗口、拖出标签新开的窗口 | 删除条目和 suite，和改造前一样 | 否 |
| 旧版 ⌘⇧N 建的固定窗口、旧版重命名过的窗口 | 保留快照，条目标记为关闭 | 是：恢复布局和目录，Shell 是新进程 |
| 主窗口 | 只标记为关闭 | 是 |
| 退出 App | 不改变任何打开状态 | 下次启动原样恢复 |

关窗仍然会结束本地 PTY。只有开启了「本机后台保活」的受管 Pane 能活下来，所以界面文案不能说「进程已保留」。

## 远端多工作区

- `RemoteWorkspaceCoordinator` 为每台机器记住选中的工作区，存在 UserDefaults 的 `aster.remote.selectedWorkspace.<机器UUID>` 里。选中项属于客户端，不写服务端。
- `apply(projection:)` 只把选中工作区的标签交给标签栏。其它工作区的标签实例仍然保留，它们的终端走「分离」路径：取消画面订阅，远端进程照常运行，切回来时复用同一个实例重新附加。这就是 remote-work.md §4.2 表中的「临时不显示某远端工作区」。
- 选中的工作区被其它客户端关闭后，自动退回第一个工作区，并发出 `selectedWorkspaceDidChange` 通知。
- 新建标签、Agent 标签和回退 cwd 都跟随选中的工作区。新建的远端工作区会自动选中，第一个 Shell 落在远端 `$HOME`。
- 关闭远端工作区会结束其中全部远端进程（服务端 `workspace.close`）。调用前必须先用 `confirmClose` 确认，确认框列出终端数和标签数，默认按钮是「取消」。
- 事务都带 revision。遇到冲突时，用服务端返回的 revision 或新快照重试一次。

## 入口

- **侧栏**（`WorkspaceGroupSidebarSection.swift`）：TABS 上方是「工作区」区块，标题右侧「+」新建；每行显示图标、名称和标签数，当前工作区高亮。单击在 mouseDown 时切换（原因同 `TabRowButton`：切换会重建侧栏，等 mouseUp 视图可能已被替换）；双击重命名；右键有重命名、删除、新建。标签区块标题改为「<工作区名> · 标签」，写明归属。标签右键「移到工作区」列出其它工作区。远端机器活动时，同一区块列出这台机器的远端工作区（只读缓存的摘要，快照回来之前只有标题行）。左下胶囊在本机时显示当前窗口内工作区名。
- **顶部 / 底部标签布局**：横向标签条开头有工作区按钮，菜单里能切换、新建、重命名。开了「自动隐藏标签栏」时，本机有多个工作区就不因当前工作区只剩一个标签而隐藏，否则没有地方切换。
- **文件 ▸ 新建工作区…（⌘⇧N）**：主机下拉依次是本机、已添加的机器、已保存的主机、`~/.ssh/config` 别名、「添加主机…」。选本机时在当前 key 工作区窗口里建窗口内工作区（key window 不是工作区窗口时用最前面的工作区窗口，一个都没有才开新窗口；窗口正显示远端时先切回本机），名称预填「工作区 N」。选远端时名称预填代号，在当前窗口（或勾选后在新窗口）创建远端工作区。选中还没添加的主机或别名时，先走添加机器流程。窗口外的这些操作都经 `WorkspaceGroupNavigator`。
- **文件 ▸ 重命名工作区… / 删除工作区… / 下一个工作区（⌃⌘]）/ 上一个工作区（⌃⌘[）**：只作用于 key 工作区窗口。本机时改当前窗口内工作区；远端时重命名改当前选中的远端工作区。只剩一个工作区时删除置灰；远端活动或只有一个工作区时切换置灰。
- **文件 ▸ 切换工作区…（⌥⌘O）**：打开 Open Quickly 的「工作区」过滤器（chip ⌘K）。
  - 每个打开窗口的每个窗口内工作区各一条，副标题是「本机 · 窗口名 · N 个标签 · 标签标题」（窗口名只在多窗口时出现）。当前窗口的当前工作区排第一，其余按列表顺序，排在远端条目和旧窗口条目之前。右键可重命名、删除。
  - 远端条目按最近使用排序，带连接状态点；离线或从没访问过的机器只显示一行「连接到 X…」。
  - 注册表里**已关闭**的旧固定窗口仍列出，点了照旧重新打开窗口；已打开的窗口不再单独列一条。
  - 按工作区名、标签标题、机器名都能搜到。
- **CLI**：`aster-cli workspace list [--json]`、`workspace open <名称|id|机器/工作区>`、`workspace new --name <名称> [--machine <机器>]`。
  - `workspace.list` 新增顶层 `groups` 数组，每行 `kind:"group"`、`id`、`name`、`windowID`、`windowLabel?`、`isKeyWindow`、`isSelected`、`tabCount?`；原有本地行加 `kind:"window"`，远端行加 `kind:"remote"`。只加字段，不删字段。
  - `workspace new` 不带 `--machine` 时在最前面的可见工作区窗口里建窗口内工作区；名称非法时直接报错，不开窗。
  - `workspace open` 能匹配窗口内工作区；与旧窗口条目同名时返回 `ambiguous_target`。
  - 写操作要经过 `allowSendKeys` 门禁。

## 验证

`./scripts/test.sh --no-parallel --filter 'workspaceGroup|WorkspaceGroup|workspaceSnapshotDecodesLegacyJSONWithoutGroups|namedWorkspace|NamedWorkspace|workspaceCodename|RemoteNamedWorkspace|openQuicklyWorkspace|newWorkspaceForm|workspaceSwitcher|workspaceControl'`
