# Aster 领域上下文

## 工作区布局通用语言

- **Window（工作区窗口）**：一个可独立保存、恢复并激活的工作区实例。每个 Window 拥有自己的标签、Pane 运行态和 Panel 宽度。
- **Panel（窗口区域）**：Window 第一层的横向区域，只承担窗口级信息架构。当前角色为左侧 `Sidebar`、中央 `Content` 和右侧 `Inspector`。
- **Sidebar Panel（左侧 Panel）**：承载垂直标签栏及其工作区操作；顶部或底部标签布局下可不出现。
- **Content Panel（中央 Panel）**：弹性主区域，承载标签栏、递归 Pane 树、Composer 和工作区浮层，始终存在。
- **Inspector Panel（右侧 Panel）**：承载 Info、Outline、Git、Files 等详情能力，可显式展开或收起。
- **Pane（内容面板）**：Content Panel 内递归分屏树的叶节点，可以是终端、文件浏览器、编辑器或预览。Pane 有稳定 UUID，并拥有独立运行态。
- **Divider（分隔条）**：相邻区域之间的拖动边界。Panel Divider 保存 point 宽度；Pane Divider 保存递归树中的比例。

## 不变量

1. Panel 与 Pane 是不同层级的概念，命名、状态和持久化不得混用。
2. Content Panel 始终存在且保持弹性；Sidebar 与 Inspector 是可选边缘 Panel。
3. 每个 Window 独立保存 Sidebar 与 Inspector 的首选宽度；设置窗口只编辑最近活动的工作区窗口。
4. Panel 显隐或调宽不得重建 Pane 运行态，也不得改变 Pane UUID。
5. 拖动 Divider 只调整尺寸，不承担 Panel 显隐；显隐必须通过明确入口完成。
