# 命名工作区

工作区可以起名字、绑定一台机器，也能在切换器里按最近使用切换。这套设计借鉴 tty7 的 workspace、switcher 和 New Workspace 表单，但沿用了 Aster 现有的结构：「每个窗口一个 `AppModel`」加上「远端结构以服务端为准」。

## 两种工作区

| 类型 | 实体 | 真值 | 客户端只保存 |
| --- | --- | --- | --- |
| 本地命名工作区 | 一个窗口 | 该窗口的 UserDefaults suite（主窗口用 `.standard`）里的 `aster.workspace.snapshot.v1` | 注册表条目：名称、存储位置、是否固定保留、是否打开、最近使用时间 |
| 远端命名工作区 | 服务端 `RemoteSessionSnapshot.workspaces` 里的一项 | 远端 `aster-session` | 每台机器当前选中哪个工作区，以及最近使用时间 |

「绑定机器」是天然成立的：本地工作区属于 Local；远端工作区本来就挂在某台机器的服务上，不另存 machineID。

## 本地注册表

- 模型是 `NamedWorkspaceRegistry`（AsterCore，纯值类型）。App 侧由 `NamedWorkspaceDirectory` 负责读写和维护「窗口 ↔ 工作区」的对应关系。
- 注册表存在 UserDefaults.standard 的 `aster.workspace.registry.v1`。
- **迁移**：注册表不存在时，主窗口变成固定保留的「主工作区」；旧键 `aster.workspace.additional-window-suites.v1` 里的附加窗口，变成不保留、已打开的代号工作区，名字像 `quiet-otter`。
- 之后注册表是唯一权威，但每次保存都会把打开着的 suite 写回旧键，所以降级后还能恢复。注册表已存在时，启动会和旧键对账（`reconcile`），用来处理「降级后又升级」的情况；正常运行时对账不改任何东西。
- **上限**：同时最多打开 17 个（主窗口 + 16 个附加窗口，和改造前的恢复上限相同）；关闭后最多保留 48 个，超出时按最近使用淘汰，连同快照一起删。启动时先清理再恢复，避免两个条目指向同一 suite 时开出两个窗口。

## 关闭语义

| 窗口来源 | 关窗 | 能否从切换器重新打开 |
| --- | --- | --- |
| ⌘N 新窗口、拖出标签新开的窗口 | 删除条目和 suite，和改造前一样 | 否 |
| ⌘⇧N 新建的工作区、重命名过的工作区 | 保留快照，条目标记为关闭 | 是：恢复布局和目录，Shell 是新进程 |
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

- **文件 ▸ 新建工作区…（⌘⇧N）**：名称预填代号，主机下拉依次是本机、已添加的机器、已保存的主机、`~/.ssh/config` 别名、「添加主机…」。选本机时新开一个固定保留的窗口；选远端时在当前窗口（或勾选后在新窗口）创建远端工作区。选中还没添加的主机或别名时，先走添加机器流程。
- **文件 ▸ 切换工作区…（⌥⌘O）**：打开 Open Quickly 的「工作区」过滤器（chip ⌘K）。
  - 条目包括本地注册表的全部条目，以及各台机器缓存里的远端工作区，按最近使用排序；远端条目带连接状态点。
  - 按工作区名、标签标题、机器名都能搜到。
  - 右键菜单：重命名、在新窗口打开、删除/关闭、连接/断开。
  - 离线或从没访问过的机器只显示一行「连接到 X…」。
- **文件 ▸ 重命名工作区…**：改当前窗口对应的工作区，改完自动固定保留。
- **侧栏**：机器胶囊显示「机器 · 工作区名」。
- **CLI**：`aster-cli workspace list [--json]`、`workspace open <名称|id|机器/工作区>`、`workspace new --name <名称> [--machine <机器>]`。写操作要经过 `allowSendKeys` 门禁。

## 验证

`./scripts/test.sh --no-parallel --filter 'namedWorkspace|NamedWorkspace|workspaceCodename|RemoteNamedWorkspace|openQuicklyWorkspace|newWorkspaceSheet'`
