(() => {
  "use strict";

  const icons = {
    general: "<circle cx='8' cy='8' r='5.5'/><path d='M8 7.5v4M8 4.5h.01'/>",
    shell: "<rect x='2.2' y='3' width='11.6' height='10' rx='2'/><path d='m4.8 6 2 2-2 2M8.5 10h2.8'/>",
    controls: "<path d='m4 2.5 8 6-4.1.8L6.5 13z'/>",
    editor: "<path d='M4 2.5h5l3 3v8H4z'/><path d='M9 2.5v3h3M6 8h4M6 10.5h4'/>",
    // 插头线条图标（lucide plug 风格，对齐 Otty 的「智能体」侧栏图标）。
    agents: "<path d='M6 1.8v3M10 1.8v3M4.6 4.8h6.8v3.4a3.4 3.4 0 0 1-3.4 3.4 3.4 3.4 0 0 1-3.4-3.4zM8 11.6v2.6'/>",
    appearance: "<path d='M8 2.2a5.8 5.8 0 1 0 0 11.6c1 0 1.6-.5 1.6-1.2 0-.5-.3-.8-.3-1.2 0-.7.6-1.2 1.3-1.2h1.1c1.3 0 2.1-1 2.1-2.2A5.8 5.8 0 0 0 8 2.2z'/><circle cx='5.2' cy='6' r='.5'/><circle cx='8' cy='4.7' r='.5'/><circle cx='10.8' cy='6.1' r='.5'/>",
    recipes: "<rect x='2.5' y='2.5' width='4.5' height='4.5' rx='1'/><rect x='9' y='2.5' width='4.5' height='4.5' rx='1'/><rect x='2.5' y='9' width='4.5' height='4.5' rx='1'/><rect x='9' y='9' width='4.5' height='4.5' rx='1'/>",
    shortcuts: "<path d='m9.3 2.3-5 6h3.6l-1.2 5.4 5-6H8.1z'/>",
    advanced: "<path d='M5.6 4.4a3.2 3.2 0 0 0 4 4l3.6 3.6-1.2 1.2-3.6-3.6a3.2 3.2 0 0 1-4-4L6.2 7 7 6.2z'/>",
  };

  const options = {
    language: [["system", "跟随系统"], ["zh-Hans", "中文"], ["en", "English"]],
    launch: [["newWindow", "新窗口"], ["restoreLastSession", "恢复上次会话"]],
    confirm: [["always", "总是提示"], ["runningProcess", "有进程运行时"], ["multipleTabs", "有多个标签页时"], ["never", "从不提示"]],
    workingDirectory: [["home", "主目录"], ["currentSession", "与当前标签页相同"], ["custom", "自定义…"]],
    optionMeta: [["false", "关闭（输入重音）"], ["true", "左右 Option"], ["left", "仅左 Option"], ["right", "仅右 Option"]],
    rightClick: [["context-menu", "上下文菜单"], ["copy", "复制"], ["paste", "粘贴"], ["copy-or-paste", "已选则复制，否则粘贴"], ["ignore", "忽略"]],
    bypassMouse: [["none", "无"], ["shift", "Shift"], ["ctrl", "Control"], ["alt", "Option"], ["ctrl+shift", "Control + Shift"], ["super", "Command"]],
    openLink: [["browser", "系统浏览器"], ["aster", "在 Aster 中打开"]],
    openFile: [["default-app", "系统默认应用"], ["aster", "在 Aster 中打开"]],
    openFolder: [["default-app", "访达"], ["aster", "在 Aster 中打开"]],
    foreground: [["off", "关闭（系统默认）"], ["banner", "仅当来源标签未聚焦时"], ["always", "始终显示"]],
    restoreProcesses: [["none", "不重启"], ["whitelist", "仅白名单内"], ["all", "所有运行中的进程"]],
    term: [["auto", "Auto (xterm-ghostty)"], ["xterm-ghostty", "xterm-ghostty (内置)"], ["aster", "aster (内置)"], ["xterm-256color", "xterm-256color"], ["tmux-256color", "tmux-256color"], ["custom", "自定义…"]],
    replay: [["automatic", "自动"], ["confirmOnce", "确认一次"], ["manual", "逐条"], ["skip", "跳过"]],
    scrollLast: [["disabled", "关闭"], ["lastContentAtTop", "最后有内容行置顶"], ["lastLineInMiddle", "内容行停在中间"], ["cursorLineAtTop", "光标行置顶"]],
    scrollFirst: [["disabled", "关闭"], ["sameAsLast", "与末尾设置一致"], ["firstLineWithContent", "历史首行置底"], ["firstLineInMiddle", "首行停在中间"]],
    autocompleteShortcut: [["tab", "Tab"], ["tab+right-arrow", "Tab + 右方向键"], ["ctrl+space", "Control + Space"], ["disable", "关闭"]],
    candidatePanel: [["disable", "关闭"], ["auto", "自动"], ["escape", "Esc 打开"], ["option-escape", "Option + Esc 打开"]],
    descriptionLanguage: [["system", "跟随系统"], ["chinese", "中文"], ["english", "English"]],
    cursorStyle: [["block", "块状"], ["bar", "竖线"], ["underline", "下划线"], ["blockHollow", "空心块状"]],
    cursorBlink: [["defaultOff", "默认关闭"], ["defaultOn", "默认开启"], ["alwaysOff", "始终关闭"], ["alwaysOn", "始终开启"]],
    cursorAnimation: [["off", "关闭"], ["smooth", "平滑"]],
    ligatures: [["off", "关闭"], ["standard", "标准 (calt)"], ["extended", "扩展 (dlig)"]],
    textStyle: [["off", "关闭"], ["automatic", "自动"], ["primaryOnly", "仅主字体"], ["synthetic", "合成"]],
    layout: [["horizontalTop", "顶部标签栏"], ["horizontalBottom", "底部标签栏"], ["vertical", "垂直标签栏"]],
    tabVisibility: [["always", "始终显示"], ["automatic", "自动隐藏"], ["default", "默认"]],
    windowSize: [["remember", "记住上次尺寸"], ["grid", "按列数和行数"], ["frame", "按像素宽高"]],
    fontBlending: [["srgbOver", "sRGB Over"], ["macOSLike", "macOS 原生"], ["linear", "线性"], ["perceptual", "感知"]],
    windowsText: [["natural", "自然"], ["naturalSymmetric", "自然对称"], ["gdi", "GDI 经典"], ["clearType", "ClearType"], ["aliased", "无抗锯齿"]],
    recordingMode: [["off", "关闭"], ["on", "记录中"], ["incognito", "隐身"]],
    updateChannel: [["stable", "稳定版"], ["preview", "预览版"]],
    memoryExtractionProvider: [["claudeCode", "Claude Code"], ["codex", "Codex"], ["openCode", "OpenCode"], ["cursorCLI", "Cursor Agent"], ["kimiCode", "Kimi Code"], ["pi", "Pi"], ["omp", "OMP"]],
  };

  const row = (key, label, detail, type = "toggle", extra = {}) => ({ key, label, detail, type, ...extra });
  const action = (name, label, detail, button, extra = {}) => ({ action: name, label, detail, type: "action", button, ...extra });

  const sections = [
    {
      id: "general", title: "通用", description: "启动、窗口行为和 macOS 系统集成。", groups: [
        { title: "通用", rows: [
          row("general.language", "语言", "Aster 界面显示语言", "select", { options: options.language }),
          row("general.shell", "Shell", "新终端使用的登录 Shell", "text"),
          row("launchBehavior", "启动时", "打开 Aster 时的初始窗口行为", "select", { options: options.launch }),
          row("general.quitAfterLastWindowClosed", "关闭所有窗口时退出", "关闭最后一个工作区窗口时退出应用"),
          row("general.newWindowWhenAllClosed", "关闭所有窗口后新建窗口", "点击 Dock 图标时自动创建工作区"),
          row("general.hideDirtyIndicator", "隐藏关闭按钮圆点", "红绿灯不显示运行中或未保存状态"),
        ]},
        { title: "关闭确认", rows: [
          row("general.closeTabConfirmation", "关闭标签页", "何时在关闭标签页前询问", "select", { options: options.confirm }),
          row("general.closeWindowConfirmation", "关闭窗口", "何时在关闭窗口前询问", "select", { options: options.confirm }),
          row("general.closePaneConfirmation", "关闭分屏", "何时在关闭 Pane 前询问", "select", { options: options.confirm }),
        ]},
        { title: "标签页", rows: [
          row("appearance.newTabPosition", "新标签页位置", "自动、末尾或当前标签之后", "select", { options: [["automatic", "自动"], ["end", "末尾"], ["afterCurrent", "当前标签之后"]] }),
        ]},
        { title: "系统集成", rows: [
          action("setDefaultTerminal", "默认终端", "注册 Aster 处理 ssh:// 链接", "设为默认终端"),
          action("configureExternalApps", "为常用应用设为默认终端", "配置 VS Code、Cursor、Windsurf、VSCodium、Trae 和 Sublime Text", "配置…"),
          action("openFinderSettings", "Finder 集成", "配置 Finder 服务快捷键", "打开系统设置"),
          action("openFullDiskAccess", "完全磁盘访问权限", "仅在命令需要受保护目录时开启", "打开系统设置"),
        ]},
        { title: "更新", rows: [
          // 状态点挂在动作行上（与「通知 → 系统权限」同构）：statusKey 是替换该行 detail 的，
          // 挂组首读作「软件更新：已是最新版本 [现在检查]」。
          action("checkForUpdates", "软件更新", "从 Aster 官方更新源检查是否有新版本", "现在检查", {
            capability: "softwareUpdate",
            unsupportedDetail: "此构建未启用自动更新（开发构建或未配置更新源）",
            statusKey: "update.statusText",
            statusStateKey: "update.statusState",
          }),
          row("update.automaticallyChecks", "自动检查更新", "每天在后台查询一次新版本", "toggle", {
            capability: "softwareUpdate",
          }),
          // disabledWhen 只认真值不认取反，因此依赖原生侧下发的派生键 update.automaticChecksDisabled。
          // 用 disabledWhen 而不是 visibleWhen：关掉自动检查时该行应变灰但可见，让用户知道能力存在。
          row("update.automaticallyDownloads", "自动下载并安装", "后台静默下载，退出 Aster 后自动完成安装", "toggle", {
            capability: "softwareUpdate",
            disabledWhen: "update.automaticChecksDisabled",
            disabledDetail: "需要先开启“自动检查更新”",
          }),
          row("update.channel", "更新通道", "稳定版只接收正式发布；预览版会更早收到测试构建，也更可能遇到问题", "select", {
            capability: "softwareUpdate",
            options: options.updateChannel,
          }),
        ]},
        { title: "关于", rows: [
          row("about.version", "Aster", "当前应用版本", "readonly"),
          action("openCredits", "致谢", "查看第三方组件及许可证", "打开"),
        ]},
      ]
    },
    {
      id: "shell", title: "Shell", description: "工作目录、Shell 集成、CLI、恢复、声音与通知。", groups: [
        { title: "工作目录", rows: [
          row("general.windowWorkingDirectory", "新窗口", "新窗口的初始目录", "select", { options: options.workingDirectory }),
          row("general.tabWorkingDirectory", "新标签页", "新标签页的初始目录", "select", { options: options.workingDirectory }),
          row("general.splitWorkingDirectory", "新分屏", "新 Pane 的初始目录", "select", { options: options.workingDirectory }),
          row("general.customWorkingDirectory", "自定义目录", "工作目录策略选择“自定义”时使用", "text"),
        ]},
        { title: "Shell 集成", rows: [
          row("shell.shellIntegration", "提供 Shell 集成", "支撑提示符标记、工作目录跟踪、命令状态以及 edit/view/jump 包装命令——会在 shell 启动文件里加一行"),
          action("configureShells", "按 Shell 单独配置", "分别启用 zsh、fish 与 bash", "配置…"),
          row("shell.sshIntegration", "SSH 集成", "包装 SSH 命令以转发环境变量、安装 terminfo，并保持远端目录与标题跟踪"),
        ]},
        { title: "Aster CLI", rows: [
          action("installCLI", "命令", "将 `aster` 命令安装到 PATH", "安装 CLI"),
          row("general.omitAsterPrefix", "省略 `aster` 前缀", "在 Aster 启动的 shell 中直接输入 edit foo.txt，无需写 aster edit foo.txt；自动注入 edit、view、watch、jump、learn 函数"),
          row("general.cliAllowOverwrite", "覆盖已有命令", "启用“省略 aster 前缀”或“自定义别名”时，覆盖你已定义的 edit/view/jump 等 shell 函数，而非保留原定义"),
          action("editCLIAliases", "自定义别名", "为内置命令设置别名（例如 v → view），仅在 Aster 启动的 shell 中生效；编辑后请重新打开 shell", "配置…"),
          action("openCLIDocs", "了解更多", "查看完整的 Aster CLI 使用指南", "打开文档"),
        ]},
        { title: "常用文件夹", rows: [
          row("shell.frecencyAutoRecord", "自动记录访问过的文件夹", "将每次工作目录变更记录到 jump 数据库，为 aster jump 和 Open Quickly 的“文件夹”标签提供数据"),
          action("manageFolders", "已跟踪与已忽略的文件夹", "浏览、添加或移除 jump 数据库记录的文件夹，可在“已跟踪”与“已忽略”列表之间移动", "管理文件夹…"),
          row("shell.zoxideEnabled", "与 Zoxide 同步", "运行 aster ignore 或使用“忘记此文件夹”时，同时从本地 zoxide 数据库移除该路径（如已安装 zoxide）"),
        ]},
        { title: "会话恢复", rows: [
          row("shell.restoreMultiplexerSessions", "恢复复用器会话", "恢复窗口时重新附着 tmux / screen 复用器会话"),
          // 与「智能体 → 智能体行为 → 恢复时重连会话」是同一个开关的双入口（对齐 Otty）。
          row("agents.resumeSessions", "恢复 Code Agent 会话", "恢复终端时继续 Agent CLI 的原生会话"),
          row("shell.terminalResumeProtocol", "终端恢复协议", "允许编辑器、SSH 和编码代理声明如何重新启动自身，以便 Aster 在重启后恢复它们（OSC 88）"),
          row("shell.restoreProcessesMode", "恢复时重新运行进程", "恢复窗口时，重新启动每个面板中正在运行的命令", "select", { options: options.restoreProcesses }),
          row("shell.restoreProcessAllowlist", "命令白名单", "可重新运行的命令，按逗号分隔的前缀匹配", "text", { visibleWhen: ["shell.restoreProcessesMode", "whitelist"] }),
        ]},
        { title: "声音", rows: [
          row("shell.terminalBell", "允许终端响铃", "允许 shell 程序通过 BEL 字符播放提示音"),
          row("shell.soundOnErrorExit", "命令出错时蜂鸣", "命令以非零状态退出时发出蜂鸣"),
        ]},
        { title: "通知", rows: [
          action("openNotificationSettings", "系统权限", "查看或修改 macOS 通知权限", "打开系统设置", { statusKey: "shell.notificationPermission", statusStateKey: "shell.notificationPermissionState" }),
          row("shell.notificationShellControlled", "允许应用通知", "允许 shell 程序发送系统通知"),
          row("shell.notifyOnFinish", "命令完成时通知", "后台命令完成时发送通知"),
          row("shell.notifyOnError", "命令出错时通知", "命令失败时发送通知"),
          row("shell.notifyOnWatchFinish", "watch 命令完成时通知", "aster watch 包装的命令完成时发送通知"),
          row("shell.notifyWhileForeground", "前台时的通知", "Aster 处于前台时横幅的显示行为", "select", { options: options.foreground }),
          row("shell.notificationSound", "通知声音", "为选中的通知类别播放声音；默认静音", "multiselect", { emptyLabel: "无", options: [
            ["shell.notificationSound.errorExit", "命令出错退出时"],
            ["shell.notificationSound.commandFinish", "命令完成时"],
            ["shell.notificationSound.application", "应用通知"],
          ] }),
          row("shell.bounceDockIcon", "Dock 图标跳动", "Aster 不在前台时，收到通知则让 Dock 图标持续跳动，切回 Aster 即停"),
        ]},
        { title: "标签徽章", rows: [
          row("shell.badgeCommandFinish", "命令完成徽章", "成功退出后显示圆点"),
          row("shell.badgeCommandFailure", "命令失败徽章", "错误退出时显示警告"),
          row("shell.badgeAwaitingInput", "等待输入徽章", "检测交互提示并显示等待状态"),
        ]},
        { title: "终端标识", rows: [
          row("appearance.terminalIdentityMode", "TERM", "向子进程声明的“终端类型”。Auto 是安全的默认值，优先使用内置 xterm-ghostty，缺条目回退 xterm-256color", "select", { options: options.term }),
          row("appearance.terminalIdentity", "自定义 TERM", "值必须存在对应 terminfo 条目；无效时回退到 xterm-256color，保证行编辑正常工作", "text", { visibleWhen: ["appearance.terminalIdentityMode", "custom"] }),
          action("openTermDocs", "了解更多", "TERM 取值与 terminfo 条目的说明", "打开文档"),
        ]},
      ]
    },
    {
      id: "controls", title: "控制", description: "键盘、鼠标、链接、选择、剪贴板和滚动。", special: "controls", groups: [
        { title: "自动补全", rows: [
          row("controls.autocompleteShortcut", "接受候选", "接受 inline suggestion 的快捷键", "select", { options: options.autocompleteShortcut }),
          row("controls.autocompleteCandidatePanel", "候选面板", "自动显示或使用快捷键打开", "select", { options: options.candidatePanel }),
          row("controls.autocompleteInlineSuggestion", "Inline suggestion", "在终端光标后显示候选后缀"),
          row("controls.autocompleteOnDeviceLearning", "本机学习", "只保存脱敏后的本机历史"),
          row("controls.autocompleteDatabaseStatus", "补全数据库状态", "已安装的命令规格数量与当前版本", "readonly"),
          action("updateAutocomplete", "补全数据库", "检查当前规格状态并从官方源更新", "立即更新"),
          action("clearAutocomplete", "清除补全数据", "选择清除历史、固定命令或目录频率数据", "清除…", { danger: true }),
        ]},
        { title: "选择", rows: [
          row("controls.shiftArrowSelection", "Shift + 方向键选择", "选择文本而不是发送转义序列"),
          row("controls.clearSelectionOnTyping", "输入时清除选区", "键盘输入后取消当前选择"),
          row("controls.clearSelectionOnCopy", "复制后清除选区", "显式复制完成后取消选择", "toggle", { disabledWhen: "controls.copyOnSelect", disabledDetail: "启用“选中即复制”时，选区会保留，因此此项不可用" }),
          row("controls.selectionBackspaceDeletes", "退格删除选区", "仅在可靠的当前 Shell 提示符行中一次删除整个选择"),
        ]},
        { title: "滚动", rows: [
          row("controls.scrollPastLastLine", "滚动超出末尾", "控制末行或光标行在视口中的锚点", "select", { options: options.scrollLast }),
          row("controls.scrollPastFirstLine", "滚动超出首行", "控制历史首行在视口中的锚点", "select", { options: options.scrollFirst }),
          row("controls.smoothScrolling", "平滑滚动", "触控板按像素滚动，结束时对齐字符行"),
        ]},
        { title: "打开方式", rows: [
          row("controls.linkOpenWith", "默认链接打开方式", "URL 在哪里打开", "select", { options: options.openLink }),
          row("controls.fileOpenWith", "默认文件打开方式", "文件在哪里打开", "select", { options: options.openFile }),
          row("controls.folderOpenWith", "默认文件夹打开方式", "文件夹在哪里打开", "select", { options: options.openFolder }),
          row("controls.defaultGitClient", "默认 Git 客户端", "Git 仓库优先使用的桌面客户端；自动会跟随可用应用", "select", { options: [["auto", "自动"], ["com.github.GitHubClient", "GitHub Desktop"], ["com.DanPristupov.Fork", "Fork"], ["com.fournova.Tower3", "Tower"], ["com.torusknot.SourceTreeNotMAS", "Sourcetree"], ["com.axosoft.gitkraken", "GitKraken"], ["com.sublimehq.Sublime-Merge", "Sublime Merge"]] }),
          action("configureOpenWithApps", "自定义打开方式", "向文件和文件夹菜单添加第三方应用", "配置…"),
        ]},
        { title: "链接协议", rows: [
          row("controls.linkSchemes", "自动识别链接协议", "识别所有合法协议，或只识别标准协议和自定义列表", "select", { options: [["all", "全部"], ["custom", "自定义"]] }),
          action("configureLinkSchemes", "自定义链接协议", "管理允许识别的协议，例如 codex、ssh、vscode", "配置…", { visibleWhen: ["controls.linkSchemes", "custom"] }),
          row("controls.showLinkPreviews", "显示链接预览", "按住 Command 悬停时在底部显示完整路径或 URL"),
          action("resetLinkApprovals", "重置安全提示", "清除打开外部链接、自定义协议和可执行文件的“始终允许”授权", "重置", { danger: true, confirmDuration: 1600, confirmedLabel: "已重置" }),
        ]},
        { title: "键盘", rows: [
          row("controls.optionAsMetaMode", "将 Option 键用作 Meta 键", "控制左右 Option 是否发送 Esc 前缀", "select", { options: options.optionMeta }),
          row("controls.vtKeypadAppAllowed", "允许 VT100 应用程序数字键盘模式", "响应 DECKPAM，让小键盘发送 SS3 序列"),
        ]},
        { title: "鼠标", rows: [
          row("controls.focusFollowsMouse", "鼠标悬停切换焦点", "悬停的分屏自动获得焦点"),
          row("controls.rightClickAction", "右键动作", "Control + 右键始终打开菜单", "select", { options: options.rightClick }),
          row("controls.mouseHideWhileTyping", "输入时隐藏鼠标", "键盘输入期间隐藏指针，移动鼠标后恢复"),
          row("controls.linkClickOverMouseMode", "鼠标模式下 Command + 点击打开链接", "不把这次链接点击发送给全屏应用"),
          row("controls.bypassMouseReporting", "绕过鼠标上报", "按住修饰键时把手势交给本地选择", "select", { options: options.bypassMouse }),
          row("controls.cursorClickToMove", "点击移动 Shell 光标", "在可靠提示符行通过方向键移动输入光标"),
          row("controls.allowMouseReporting", "允许应用捕获鼠标", "供 vim、tmux、htop 等 TUI 使用"),
        ]},
        { title: "安全输入", rows: [
          row("controls.secureInputAutomatically", "自动启用安全键盘输入", "检测到关闭回显的密码提示时启用"),
          row("controls.secureInputIndication", "显示安全输入指示", "标题栏显示安全输入胶囊"),
        ]},
        { title: "剪贴板", rows: [
          row("controls.copyOnSelect", "选中即复制", "完成文本选择后自动复制"),
          row("controls.trimTrailingSpaces", "复制时去除行尾空格", "只移除每个物理行末尾空白"),
          row("controls.pasteProtection", "粘贴前确认不安全内容", "多行、控制字符和提权命令需要确认"),
          row("controls.pasteBracketedSafe", "Bracketed Paste 视为安全", "应用明确支持括号粘贴时跳过确认"),
        ]},
      ]
    },
    {
      id: "editor", title: "编辑器", description: "文件 Pane 的编辑与打开行为。", groups: [
        { title: "编辑", rows: [
          row("editor.lineWrap", "自动换行", "长行软换行而不是水平滚动"),
          row("editor.showLineNumbers", "显示行号", "在文本 Pane 左侧显示行号"),
          row("editor.showVisibleWhitespace", "显示空白字符", "显示空格、Tab 和换行符号"),
          row("editor.tabSize", "Tab 宽度", "Tab 字符的视觉列宽", "number", { min: 2, max: 8, step: 1 }),
          row("editor.scrollPastEnd", "允许滚动超出末尾", "让最后一行可滚动到视口顶部"),
          row("editor.vimKeyBindings", "Vim 按键", "文件 Pane 默认进入 Normal 模式"),
        ]},
        { title: "打开文件", rows: [
          row("editor.previewRichDocuments", "以预览 / 只读方式打开", "Markdown、SVG、HTML 默认显示渲染预览"),
        ]},
      ]
    },
    { id: "agents", title: "智能体", description: "连接 Agent，显示状态并恢复原生会话。", special: "agents", groups: [
      { title: "智能体行为", rows: [
        row("agents.badgeProcessing", "处理中显示角标", "Agent 执行任务期间显示状态"),
        row("agents.badgeTaskComplete", "任务完成显示角标", "完成一轮任务后显示圆点"),
        row("agents.badgeAwaitingInput", "等待输入显示角标", "Agent 等待批准或输入时显示状态"),
        row("agents.notifyTaskComplete", "任务完成时通知", "Agent 完成任务后发送系统通知"),
        row("agents.notifyAwaitingInput", "等待输入时通知", "Agent 等待用户时发送系统通知"),
        row("agents.preventSleepWhileProcessing", "处理期间阻止睡眠", "Agent 工作时保持 macOS 唤醒"),
        row("agents.resumeSessions", "恢复时重连会话", "窗口恢复时继续 Agent 原生会话"),
      ]},
      { title: "Session Memory 记录", description: "记录终端活动，让 Agent 能查到项目的历史工作过程。数据只保存在本机 ~/Library/Application Support/Aster/Memory/。", rows: [
        row("memory.recordingMode", "记录模式", "“记录中”会在本机保存命令、退出码与输出摘录；“隐身”与“关闭”都零落盘", "select", { options: options.recordingMode }),
        row("memory.excludedPaths", "排除目录", "逗号分隔的绝对路径；这些目录下的活动从不写入数据库。~/.ssh、~/.gnupg、~/.aws、~/.kube、~/.password-store 已内置排除", "text"),
        action("addMemoryExcludedPath", "添加排除目录", "从文件选择器挑一个目录加入排除列表", "选择目录…"),
        row("memory.excludedCommands", "排除命令", "逗号分隔的命令名；命中的命令连同它的输出都不记录。op、vault、pass、gpg、security 已内置排除", "text"),
        row("memory.storeSize", "已用存储", "数据库与输出正文占用的磁盘空间", "readonly"),
        action("openMemoryFolder", "存储位置", "打开数据库与输出正文所在目录", "打开"),
        action("clearMemoryStore", "清空全部记录", "删除所有 session、事件、输出正文与已提炼的 Memory", "清空…", { danger: true }),
      ]},
      { title: "Memory 提炼", description: "会话结束后把事件流提炼成可复用的结论。本地规则式提炼始终启用；CLI Agent 提炼是可选增强。", rows: [
        row("memory.extractionEnabled", "使用 CLI Agent 提炼", "会话结束后调用本机 Agent CLI 生成叙述性 Memory；这会把会话摘要发送到该 Agent 的云端"),
        row("memory.extractionProvider", "提炼使用的 Agent", "承担提炼的本机 Agent CLI", "select", { options: options.memoryExtractionProvider, disabledWhen: "memory.extractionDisabled", disabledDetail: "先开启 CLI Agent 提炼" }),
        action("previewExtractionPayload", "查看将发送的内容", "预览提炼时会离开本机的会话摘要", "查看…"),
      ]},
    ]},
    { id: "appearance", title: "外观", description: "主题、字体、光标、布局和窗口。", special: "appearance", groups: [
      { title: "主题", rows: [
        row("appearance.appearance", "界面外观", "跟随系统或固定明暗模式", "select", { options: [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]] }),
        row("appearance.useSeparateDarkTheme", "深色模式使用独立主题", "跟随系统配色方案：浅色模式使用上方主题，深色模式使用下方深色主题。"),
        action("importTheme", "导入主题", "选择 .astertheme 文件加入主题库", "导入主题…"),
        action("openThemesFolder", "主题文件夹", "打开 ~/.config/aster/themes，直接编辑主题文件", "打开"),
      ]},
      { title: "字体", rows: [
        row("appearance.autoMatchFontStyles", "自动匹配粗细与样式", "开启时由普通字体自动派生粗体、斜体和粗斜体"),
        row("appearance.fontFamily", "字体", "全局主等宽字体", "text"),
        row("appearance.fontFamilyBold", "字体（粗体）", "清空时自动匹配", "text"),
        row("appearance.fontFamilyItalic", "字体（斜体）", "清空时自动匹配", "text"),
        row("appearance.fontFamilyBoldItalic", "字体（粗斜体）", "清空时自动匹配", "text"),
        row("appearance.fontFamilyFallback", "字体族回退", "逗号分隔；缺少字形时按顺序尝试", "text"),
        row("appearance.fontFamilyFallbackBold", "字体族回退（粗体）", "留空时继承普通样式的 fallback", "text"),
        row("appearance.fontFamilyFallbackItalic", "字体族回退（斜体）", "留空时继承普通样式的 fallback", "text"),
        row("appearance.fontFamilyFallbackBoldItalic", "字体族回退（粗斜体）", "留空时继承普通样式的 fallback", "text"),
        row("appearance.fontSize", "字号", "终端字体大小", "range", { min: 9, max: 32, step: .5, suffix: " pt" }),
        row("appearance.lineHeight", "行高", "字体默认行高的缩放倍数", "range", { min: .8, max: 2, step: .02 }),
        row("appearance.adjustCellHeight", "调整单元格高度", "在计算行高后增加或减少像素", "range", { min: -8, max: 16, step: 1, suffix: " px" }),
        row("appearance.fontSmoothing", "字体平滑", "使用 macOS 字体抗锯齿"),
        row("appearance.fontBlending", "字体混合", "终端字形 Alpha 的颜色混合空间", "select", { options: options.fontBlending, platform: "macOS" }),
        row("appearance.windowsTextRendering", "Windows 文本渲染", "DirectWrite 栅格化模式；仅用于跨平台配置往返", "select", { options: options.windowsText, platform: "Windows", capability: "windowsTextRendering" }),
        row("appearance.fontThicken", "字形加粗", "对渲染后的字形轮廓做细微加粗", "range", { min: 0, max: 4, step: .1, suffix: " px" }),
        action("openFontsFolder", "字体文件夹", "打开 ~/Library/Fonts", "打开"),
      ]},
      { title: "文本", rows: [
        row("appearance.bidirectionalText", "双向文本", "按 Unicode 双向算法显示 RTL 文本"),
        row("appearance.ligatureLevel", "连字", "控制 calt / dlig", "select", { options: options.ligatures }),
        row("appearance.ligatureAlphabet", "字母和数字也参与连字", "不只对标点应用字体连字"),
        row("appearance.boldRendering", "加粗", "缺少原生粗体时的回退策略", "select", { options: options.textStyle }),
        row("appearance.italicRendering", "斜体", "缺少原生斜体时的回退策略", "select", { options: options.textStyle }),
        row("appearance.underlineRendering", "下划线", "渲染终端下划线属性"),
        row("appearance.blinkRendering", "闪烁", "是否允许终端闪烁文字", "select", { options: [["steady", "稳定显示"], ["blink", "允许闪烁"], ["hidden", "隐藏闪烁文字"]] }),
      ]},
      { title: "光标", rows: [
        row("appearance.cursorStyle", "光标样式", "块状、竖线、下划线或空心块", "select", { options: options.cursorStyle }),
        // 长文案对齐 Otty；\e 需要写成 \\e 才能原样显示转义序列。
        row("appearance.cursorBlinkMode", "光标闪烁方式", "「默认」项设定初始闪烁状态，但允许程序覆盖（DECSCUSR \\e[5 q / \\e[2 q、DEC mode 12）；「始终」项则固定光标、忽略程序控制。", "select", { options: options.cursorBlink }),
        row("appearance.cursorAnimation", "光标动画", "「平滑」会让光标在同一行内移动时插值滑动，并在点击 / 聚焦时弹一下。", "select", { options: options.cursorAnimation }),
        row("appearance.cursorOpacity", "光标不透明度", "光标颜色的 Alpha", "range", { min: .1, max: 1, step: .05 }),
        row("appearance.cursorColor", "光标颜色", "留空时跟随主题", "color"),
        row("appearance.cursorTextColor", "光标下文字颜色", "留空时跟随主题", "color"),
      ]},
      { title: "布局与标签栏", rows: [
        row("tabBarLayout", "窗口布局", "顶部、底部或垂直标签栏", "select", { options: options.layout }),
        row("appearance.showTabBar", "显示标签栏", "关闭后隐藏标签栏或垂直标签面板"),
        row("appearance.tabBarVisibility", "自动隐藏标签栏", "顶部 / 底部标签栏的可见策略", "select", { options: options.tabVisibility }),
        row("appearance.tabsPanelVisibility", "自动隐藏标签面板", "垂直布局的可见策略", "select", { options: options.tabVisibility }),
        row("appearance.sidebarWidth", "标签面板宽度", "最近活动工作区的左侧标签面板宽度", "range", { min: 180, max: 360, step: 1, suffix: " pt" }),
        row("appearance.inspectorWidth", "详情面板宽度", "最近活动工作区的右侧详情面板宽度", "range", { min: 240, max: 480, step: 1, suffix: " pt" }),
      ]},
      { title: "窗口", rows: [
        row("appearance.windowSizeMode", "窗口大小", "新窗口尺寸的决定方式", "select", { options: options.windowSize }),
        row("appearance.windowColumns", "列数", "网格尺寸模式下的终端列数", "number", { min: 40, max: 400, step: 1 }),
        row("appearance.windowRows", "行数", "网格尺寸模式下的终端行数", "number", { min: 12, max: 200, step: 1 }),
        row("appearance.windowWidth", "窗口宽度", "像素尺寸模式下的内容宽度", "number", { min: 820, max: 3840, step: 10 }),
        row("appearance.windowHeight", "窗口高度", "像素尺寸模式下的内容高度", "number", { min: 520, max: 2160, step: 10 }),
        row("appearance.unfocusedSplitOpacity", "非焦点分屏不透明度", "未获得焦点的分屏窗格淡化到什么程度。设为 1.00 则所有窗格都保持完全清晰。", "range", { min: 0.15, max: 1, step: 0.05, valueFirst: true, format: value => Number(value).toFixed(2) }),
        // Dock 三行文案对齐 Otty；warning 是描述下方的橙色耗电提示行。
        row("appearance.animateDockIconOnProgress", "任务进行时旋转", "会话运行时，图标中间的星芒持续旋转", "toggle", { warning: "会话运行时会增加 CPU 和电量消耗" }),
        row("appearance.redDockIconOnError", "出错时变红", "任务出错时图标变红；点击 Dock 图标可跳转到出错的标签"),
        row("shell.bounceDockIcon", "收到通知时跳动", "Aster 不在前台时，收到通知则让 Dock 图标持续跳动，切回 Aster 即停"),
      ]},
    ]},
    { id: "recipes", title: "Recipes", description: "保存并重放标签页、分屏、命令和文本片段。", special: "recipes", groups: [
      { title: "命令重放", rows: [
        row("recipes.savedReplayMode", "已保存的 Recipe", "打开 Aster 内保存的 Recipe 时如何运行命令", "select", { options: options.replay }),
        row("recipes.fileReplayMode", "外部 Recipe 文件", "打开外部 .asterrecipe 时如何运行命令", "select", { options: options.replay }),
      ]},
    ]},
    { id: "shortcuts", title: "快捷键", description: "为菜单、工作区、Pane、Recipe 和文本序列绑定按键。", special: "shortcuts", groups: [] },
    { id: "advanced", title: "高级", description: "配置文件、终端兼容性、调试和导入导出。", groups: [
      { title: "配置文件", rows: [
        row("advanced.configPath", "路径", "Aster 可编辑配置文件", "readonly"),
        action("openConfig", "打开配置文件", "在默认编辑器中打开", "打开"),
        action("reloadConfig", "重新加载配置", "校验成功后原子替换当前设置", "重新加载"),
      ]},
      { title: "终端兼容性", rows: [
        row("advanced.autoProgressCommands", "自动进度命令", "逗号分隔；按命令 token 前缀识别长任务，留空即关闭", "text"),
        row("advanced.scrollbackLines", "Scrollback 行数", "每个终端保留的最大历史行数", "number", { min: 1000, max: 1000000, step: 1000 }),
        row("advanced.minimumContrast", "最小对比度", "自动提高低对比度文字的可读性", "range", { min: 1, max: 21, step: .1 }),
        row("advanced.backgroundOpacity", "终端背景不透明度", "与主题背景 Alpha 相乘", "range", { min: 0, max: 1, step: .05 }),
        row("advanced.faintOpacity", "Faint 不透明度", "SGR faint 文字强度", "range", { min: .05, max: 1, step: .05 }),
        row("advanced.mouseScrollMultiplier", "鼠标滚动倍率", "离散滚轮的行数倍率", "range", { min: .1, max: 10, step: .1 }),
        row("advanced.liveResizeDelayMS", "实时缩放 SIGWINCH 延迟", "窗口拖动期间合并网格更新", "number", { min: 0, max: 5000, step: 10 }),
        row("advanced.freezeInactiveTabs", "冻结非活动标签", "停止非活动终端的可见重绘，不停止进程"),
        row("advanced.deduplicateTUIRepaints", "移除 TUI 重绘产生的重复历史", "检测超过视口的区域重绘并避免旧行堆积"),
        row("advanced.stripCJKWrapPadding", "隐藏 CJK 换行残留块", "清理双宽字符在行尾的填充单元"),
        row("advanced.joinArrowBoxDrawing", "箭头连接 Box Drawing", "让箭头与相邻线框连续绘制"),
        row("advanced.kittyKeyboard", "Kitty Keyboard Protocol", "允许终端应用协商增强键盘协议"),
        row("advanced.allowVTKAM", "允许 VT KAM", "允许应用锁定键盘输入"),
        row("advanced.titleShellControlled", "标题 — Shell Controlled", "允许 OSC 修改标签和窗口标题"),
        row("advanced.titleReport", "标题报告", "允许 XTWINOPS 读取当前标题"),
      ]},
      { title: "控制扩展", rows: [
        row("controls.linkDetectionEnabled", "识别可点击目标", "关闭终端中的 URL、文件路径和自定义协议识别"),
        row("controls.autocompleteHistoryIgnore", "Autocomplete 历史忽略模式", "逗号分隔的 glob；命中的命令不进入本机学习", "text"),
        row("controls.autocompleteDescriptionLanguage", "Autocomplete 描述语言", "候选说明的首选语言", "select", { options: options.descriptionLanguage }),
        row("controls.clipboardWriteAccess", "终端写入剪贴板", "OSC 52 写请求的权限", "select", { options: [["allow", "允许"], ["ask", "询问"], ["deny", "拒绝"]] }),
        row("controls.clipboardReadAccess", "终端读取剪贴板", "OSC 52 读请求的权限", "select", { options: [["allow", "允许"], ["ask", "询问"], ["deny", "拒绝"]] }),
        row("controls.ipcAllowSendKeys", "IPC 允许发送输入", "允许已鉴权的本机 CLI 向 Pane 写入"),
        row("controls.ipcAllowSensitiveSessions", "IPC 允许敏感会话", "额外允许写入 ssh 或 sudo Pane"),
      ]},
      { title: "East Asian Ambiguous 宽度", rows: [
        row("advanced.widened.enclosed-alphanumerics", "Enclosed Alphanumerics", "①、Ⓐ、ⓐ 等字符按双宽显示"),
        row("advanced.widened.number-forms", "Number Forms", "分数与罗马数字等字符按双宽显示"),
        row("advanced.widened.math-operators", "Mathematical Operators", "数学运算符按双宽显示"),
        row("advanced.widened.misc-technical", "Miscellaneous Technical", "⌘、⌥ 等技术符号按双宽显示"),
        row("advanced.widened.misc-symbols", "Miscellaneous Symbols", "气象、星象等杂项符号按双宽显示"),
        row("advanced.widened.dingbats", "Dingbats", "装饰符号和标记字符按双宽显示"),
        row("advanced.widened.arrows", "Arrows", "Unicode 箭头字符按双宽显示"),
        row("advanced.widened.geometric-shapes", "Geometric Shapes", "几何图形字符按双宽显示"),
      ]},
      { title: "日志与调试", rows: [
        row("advanced.sessionLogMode", "会话日志", "关闭、脱敏记录或保存原始 PTY 输出", "select", { options: [["off", "关闭"], ["redacted", "脱敏"], ["plain", "原始输出"]] }),
        row("advanced.sessionLogSizeMB", "会话日志上限", "单个会话日志最大尺寸", "number", { min: 1, max: 1024, step: 1 }),
        row("advanced.debugMode", "调试模式", "记录额外的本机诊断事件"),
        action("openDebugLog", "调试日志", "打开当前本机 JSONL 日志", "打开日志文件"),
      ]},
      { title: "导入与导出", rows: [
        action("importGhostty", "从 Ghostty 导入", "逐项显示已支持、冲突、相似和不支持设置", "导入"),
        action("exportGhostty", "导出到 Ghostty", "报告无法映射的 Aster 设置", "导出"),
        action("exportConfiguration", "导出 Aster 配置", "保存可备份的 JSON 文件", "导出"),
        action("importConfiguration", "导入 Aster 配置", "校验后替换当前设置并剥离本机授权", "导入"),
      ]},
      { title: "重置", rows: [
        action("resetWarnings", "重置所有警告", "清除安全授权和已忽略的集成提示", "重置", { danger: true }),
        action("resetAdvanced", "重置高级设置", "只恢复高级分类的默认值", "重置", { danger: true }),
        action("resetAll", "恢复全部默认设置", "保留 Recipe、主题文件和工作区文件", "重置", { danger: true }),
      ]},
    ]},
  ];

  const sectionMap = new Map(sections.map(section => [section.id, section]));
  let snapshot = null;
  let selectedSection = "general";
  let searchText = "";
  // 当前展开的 multiselect 菜单的 item.key；快照重渲染后按它恢复展开态。
  let openMultiselect = null;
  document.addEventListener("click", () => {
    if (openMultiselect === null) return;
    openMultiselect = null;
    for (const menu of document.querySelectorAll(".multiselect-menu")) menu.hidden = true;
  });
  let pendingRequest = 0;
  // lineHeightChoice 记录行高 segmented 最近一次点击（「默认」与「紧凑 (1.0)」
  // 写入同一组值，只能靠它消歧选中态）。
  const appearanceUIState = { fontScope: "computed", themeEditorOpen: false, lineHeightChoice: null };
  // 编程智能体卡片的展开状态：快照推送会整页重渲染，用模块级 Set 记住哪些行展开。
  const agentUIState = { expanded: new Set() };

  const app = document.getElementById("app");
  const nav = document.getElementById("settings-nav");
  const content = document.getElementById("settings-content");
  const search = document.getElementById("settings-search");
  const toastRegion = document.getElementById("toast-region");

  function send(kind, payload = {}) {
    const handler = window.webkit?.messageHandlers?.asterSettings;
    if (!handler) {
      showToast("设置桥接不可用", true);
      return;
    }
    pendingRequest += 1;
    handler.postMessage({
      version: 1,
      requestID: String(pendingRequest),
      baseRevision: snapshot?.revision ?? 0,
      kind,
      ...payload,
    });
  }

  function showToast(message, error = false) {
    if (!message) return;
    const toast = document.createElement("div");
    toast.className = `toast${error ? " error" : ""}`;
    toast.textContent = message;
    toastRegion.appendChild(toast);
    window.setTimeout(() => toast.remove(), 3600);
  }

  function setSection(sectionID, { focusContent = false, highlightKey = null } = {}) {
    if (!sectionMap.has(sectionID)) return;
    selectedSection = sectionID;
    searchText = "";
    search.value = "";
    render();
    content.scrollTop = 0;
    if (focusContent) content.focus({ preventScroll: true });
    if (highlightKey) {
      window.requestAnimationFrame(() => {
        const target = content.querySelector(`[data-setting-key="${CSS.escape(highlightKey)}"]`);
        if (!target) return;
        target.scrollIntoView({ block: "center" });
        target.classList.add("highlight");
        target.addEventListener("animationend", () => target.classList.remove("highlight"), { once: true });
      });
    }
  }

  function renderNav() {
    nav.replaceChildren(...sections.map(section => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "nav-item";
      button.dataset.section = section.id;
      if (!searchText && selectedSection === section.id) button.setAttribute("aria-current", "page");
      button.innerHTML = `<svg viewBox="0 0 16 16" aria-hidden="true">${icons[section.id]}</svg><span>${section.title}</span>`;
      button.addEventListener("click", () => setSection(section.id, { focusContent: true }));
      return button;
    }));
  }

  function settingValue(key) {
    return snapshot?.values?.[key];
  }

  function isSupported(item) {
    return !item.capability || snapshot?.capabilities?.[item.capability] !== false;
  }

  function isDisabled(item) {
    return !isSupported(item) || Boolean(item.disabledWhen && settingValue(item.disabledWhen));
  }

  function isVisible(item) {
    return !item.visibleWhen || settingValue(item.visibleWhen[0]) === item.visibleWhen[1];
  }

  function commitValue(item, value) {
    send("set", { changes: [{ key: item.key, value }] });
  }

  function controlOptions(item) {
    const base = [...(item.options ?? [])];
    if (item.key !== "controls.defaultGitClient") return base;
    const seen = new Set(base.map(([value]) => value));
    for (const application of settingValue("controls.openWithApps") ?? []) {
      if (!application?.bundleId || seen.has(application.bundleId)) continue;
      seen.add(application.bundleId);
      base.push([application.bundleId, application.name || application.bundleId]);
    }
    const selected = String(settingValue(item.key) ?? "auto");
    if (!seen.has(selected)) base.push([selected, selected]);
    return base;
  }

  function makeControl(item) {
    const value = Object.prototype.hasOwnProperty.call(item, "value") ? item.value : settingValue(item.key);
    const supported = !isDisabled(item);
    const commit = nextValue => item.onCommit ? item.onCommit(nextValue) : commitValue(item, nextValue);
    if (item.type === "readonly") {
      const output = document.createElement("span");
      output.className = "setting-detail";
      output.textContent = value ?? "—";
      return output;
    }
    if (item.type === "toggle") {
      const label = document.createElement("label");
      label.className = "toggle";
      const input = document.createElement("input");
      input.type = "checkbox";
      input.checked = Boolean(value);
      input.disabled = !supported;
      input.setAttribute("aria-label", item.label);
      input.addEventListener("change", () => commit(input.checked));
      const track = document.createElement("span");
      track.className = "toggle-track";
      label.append(input, track);
      return label;
    }
    if (item.type === "select") {
      const select = document.createElement("select");
      select.className = "control";
      select.disabled = !supported;
      for (const [optionValue, label] of controlOptions(item)) {
        const option = document.createElement("option");
        option.value = optionValue;
        option.textContent = label;
        option.selected = String(value ?? "") === optionValue;
        select.appendChild(option);
      }
      select.addEventListener("change", () => commit(select.value));
      return select;
    }
    if (item.type === "number") {
      const input = document.createElement("input");
      input.className = "control";
      input.type = "number";
      input.value = Number.isFinite(Number(value)) ? String(value) : "";
      input.min = item.min;
      input.max = item.max;
      input.step = item.step;
      input.disabled = !supported;
      input.addEventListener("change", () => commit(Number(input.value)));
      return input;
    }
    if (item.type === "range") {
      const wrap = document.createElement("div");
      wrap.className = "range-control";
      const input = document.createElement("input");
      input.type = "range";
      input.min = item.min;
      input.max = item.max;
      input.step = item.step;
      // 先声明范围再赋值；反过来会先按 HTML 默认 0...100 钳制，之后修改 max 时把
      // 1.0 误变成 0.1，Panel 宽度也会落到最小值。
      input.value = Number.isFinite(Number(value)) ? String(value) : String(item.min);
      input.disabled = !supported;
      const output = document.createElement("span");
      output.className = "range-value";
      // format 允许行自定义数值显示（如非焦点分屏不透明度固定两位小数）。
      const updateOutput = () => { output.textContent = item.format ? item.format(input.value) : `${input.value}${item.suffix ?? ""}`; };
      updateOutput();
      input.addEventListener("input", updateOutput);
      input.addEventListener("change", () => commit(Number(input.value)));
      // valueFirst 把数值放到滑杆左侧（Otty 的分屏不透明度布局）。
      if (item.valueFirst) {
        wrap.classList.add("value-first");
        wrap.append(output, input);
      } else {
        wrap.append(input, output);
      }
      return wrap;
    }
    if (item.type === "color") {
      const input = document.createElement("input");
      input.className = "control";
      input.type = "text";
      input.placeholder = "跟随主题";
      input.value = typeof value === "string" ? value : "";
      input.disabled = !supported;
      input.addEventListener("change", () => commit(input.value.trim()));
      return input;
    }
    if (item.type === "multiselect") {
      // 每次 set 都会触发整页快照重渲染，菜单展开态记录在模块级变量里，重渲染后按
      // item.key 恢复，连续勾选多个类别时菜单不会自动收起。
      const wrap = document.createElement("div");
      wrap.className = "multiselect";
      const enabledLabels = item.options
        .filter(([optionKey]) => Boolean(settingValue(optionKey)))
        .map(([, label]) => label);
      const button = document.createElement("button");
      button.type = "button";
      button.className = "control multiselect-summary";
      button.textContent = enabledLabels.length ? enabledLabels.join("、") : (item.emptyLabel ?? "无");
      button.disabled = !supported;
      const menu = document.createElement("div");
      menu.className = "multiselect-menu";
      menu.hidden = openMultiselect !== item.key;
      for (const [optionKey, label] of item.options) {
        const option = document.createElement("label");
        option.className = "multiselect-option";
        const box = document.createElement("input");
        box.type = "checkbox";
        box.checked = Boolean(settingValue(optionKey));
        box.addEventListener("change", () => commitValue({ key: optionKey }, box.checked));
        option.append(box, document.createTextNode(label));
        menu.appendChild(option);
      }
      button.addEventListener("click", event => {
        event.stopPropagation();
        openMultiselect = menu.hidden ? item.key : null;
        menu.hidden = !menu.hidden;
      });
      menu.addEventListener("click", event => event.stopPropagation());
      wrap.append(button, menu);
      return wrap;
    }
    if (item.type === "action") {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `action-button${item.danger ? " danger" : ""}`;
      button.textContent = item.button;
      button.disabled = !supported;
      if (item.action === "recordShortcut" && item.payload?.id) {
        button.addEventListener("click", () => {
          const previous = button.textContent;
          button.textContent = "请按快捷键…";
          const capture = event => {
            event.preventDefault();
            event.stopPropagation();
            if (event.key === "Escape") {
              button.textContent = previous;
              return;
            }
            const modifiers = `${event.metaKey ? "⌘" : ""}${event.altKey ? "⌥" : ""}${event.shiftKey ? "⇧" : ""}${event.ctrlKey ? "⌃" : ""}`;
            if (!modifiers || ["Meta", "Alt", "Shift", "Control"].includes(event.key)) {
              button.textContent = previous;
              return;
            }
            const keyNames = { ArrowUp: "↑", ArrowDown: "↓", ArrowLeft: "←", ArrowRight: "→", Enter: "↩", Backspace: "⌫", Delete: "⌦", Tab: "⇥", " ": "Space" };
            const key = keyNames[event.key] ?? (event.key.length === 1 ? event.key.toUpperCase() : event.key);
            commitValue({ key: `shortcuts.${item.payload.id}` }, `${modifiers}${key}`);
          };
          window.addEventListener("keydown", capture, { once: true, capture: true });
          button.blur();
        });
      } else {
        button.addEventListener("click", () => {
          if (item.action === "configureLinkSchemes") {
            openStringListDialog({
              title: "自定义链接协议",
              description: "输入要识别的协议名称；不需要添加 ://。",
              key: "controls.customLinkSchemes",
              placeholder: "codex",
            });
            return;
          }
          if (item.action === "configureOpenWithApps") {
            openApplicationsDialog();
            return;
          }
          send("action", { action: item.action, payload: item.payload ?? {} });
          if (item.confirmDuration) {
            const original = button.textContent;
            button.textContent = item.confirmedLabel ?? "完成";
            button.disabled = true;
            window.setTimeout(() => {
              button.textContent = original;
              button.disabled = false;
            }, item.confirmDuration);
          }
        });
      }
      return button;
    }
    const input = document.createElement("input");
    input.className = "control";
    input.type = "text";
    input.value = Array.isArray(value) ? value.join(", ") : (value ?? "");
    input.disabled = !supported;
    input.addEventListener("change", () => commit(input.value));
    return input;
  }

  function makeRow(item) {
    const host = document.createElement("div");
    host.className = `setting-row${isDisabled(item) ? " is-disabled" : ""}`;
    host.dataset.settingKey = item.key ?? item.action;
    const copy = document.createElement("div");
    copy.className = "setting-copy";
    const label = document.createElement("span");
    label.className = "setting-label";
    label.textContent = item.label;
    if (item.platform) {
      const badge = document.createElement("span");
      badge.className = "platform-badge";
      badge.textContent = item.platform;
      label.appendChild(badge);
    }
    const detail = document.createElement("span");
    detail.className = "setting-detail";
    // capability 缺失的原因不总是「平台不支持」——例如开发构建没有更新器，
    // 因此允许行自带 unsupportedDetail 说明真实原因。
    detail.textContent = !isSupported(item)
      ? (item.unsupportedDetail ?? `${item.detail}（当前平台不可用）`)
      : (isDisabled(item) ? (item.disabledDetail ?? item.detail) : item.detail);
    copy.append(label, detail);
    // 橙色警告行（如 Dock 旋转的耗电提示）排在描述之后，对齐 Otty。
    if (item.warning) {
      const warning = document.createElement("span");
      warning.className = "setting-warning";
      warning.textContent = `⚠ ${item.warning}`;
      copy.appendChild(warning);
    }
    // statusKey 行（如通知系统权限）用彩色圆点 + 状态文本替代静态描述，状态由原生侧
    // 随快照下发；statusStateKey 决定圆点颜色。
    if (item.statusKey && settingValue(item.statusKey)) {
      const status = document.createElement("span");
      status.className = "setting-status";
      const dot = document.createElement("i");
      dot.className = "setting-status-dot";
      dot.dataset.state = String(settingValue(item.statusStateKey) ?? "unknown");
      status.append(dot, document.createTextNode(String(settingValue(item.statusKey))));
      detail.replaceWith(status);
    }
    const control = document.createElement("div");
    control.className = "setting-control";
    control.appendChild(makeControl(item));
    host.append(copy, control);
    return host;
  }

  function makeGroup(group) {
    const host = document.createElement("section");
    host.className = "group";
    const title = document.createElement("h2");
    title.className = "group-title";
    title.textContent = group.title;
    host.appendChild(title);
    if (group.description) {
      const description = document.createElement("p");
      description.className = "group-description";
      description.textContent = group.description;
      host.appendChild(description);
    }
    const card = document.createElement("div");
    card.className = "card";
    card.append(...group.rows.filter(isVisible).map(makeRow));
    host.appendChild(card);
    return host;
  }

  /// Otty 的协议列表使用页内模态框编辑。每行只接受单一 scheme，保存前仍由原生桥
  /// 再次执行语法、数量和长度校验，网页不是安全边界。
  function openStringListDialog({ title, description, key, placeholder }) {
    const overlay = document.createElement("div");
    overlay.className = "settings-dialog-overlay";
    const dialog = document.createElement("div");
    dialog.className = "settings-dialog";
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    const heading = document.createElement("h2");
    heading.textContent = title;
    const detail = document.createElement("p");
    detail.textContent = description;
    const field = document.createElement("textarea");
    field.className = "control settings-dialog-list";
    field.placeholder = placeholder;
    field.value = String(settingValue(key) ?? "").split(",").map(value => value.trim()).filter(Boolean).join("\n");
    const actions = document.createElement("div");
    actions.className = "settings-dialog-actions";
    const cancel = document.createElement("button");
    cancel.className = "action-button";
    cancel.textContent = "取消";
    const done = document.createElement("button");
    done.className = "action-button primary";
    done.textContent = "完成";
    const close = () => overlay.remove();
    cancel.addEventListener("click", close);
    done.addEventListener("click", () => {
      const values = field.value.split(/[\n,]/).map(value => value.trim().replace(/:\/\/$/, "")).filter(Boolean);
      commitValue({ key }, values.join(", "));
      close();
    });
    overlay.addEventListener("click", event => { if (event.target === overlay) close(); });
    overlay.addEventListener("keydown", event => { if (event.key === "Escape") close(); });
    actions.append(cancel, done);
    dialog.append(heading, detail, field, actions);
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);
    field.focus();
  }

  function openApplicationsDialog() {
    const overlay = document.createElement("div");
    overlay.className = "settings-dialog-overlay";
    const dialog = document.createElement("div");
    dialog.className = "settings-dialog";
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    const heading = document.createElement("h2");
    heading.textContent = "自定义打开方式";
    const detail = document.createElement("p");
    detail.textContent = "这些应用会加入文件和文件夹的打开方式菜单。";
    const list = document.createElement("div");
    list.className = "settings-dialog-apps";
    const applications = [...(settingValue("controls.openWithApps") ?? [])];
    const close = () => overlay.remove();
    const renderApplications = () => {
      list.replaceChildren();
      if (!applications.length) {
        const empty = document.createElement("span");
        empty.className = "setting-detail";
        empty.textContent = "尚未添加应用";
        list.appendChild(empty);
        return;
      }
      applications.forEach((application, index) => {
        const item = document.createElement("div");
        item.className = "settings-dialog-app";
        const copy = document.createElement("span");
        copy.innerHTML = "<strong></strong><small></small>";
        copy.firstElementChild.textContent = application.name;
        copy.lastElementChild.textContent = application.bundleId;
        const remove = document.createElement("button");
        remove.className = "action-button danger";
        remove.textContent = "移除";
        remove.addEventListener("click", () => {
          applications.splice(index, 1);
          commitValue({ key: "controls.openWithApps" }, applications);
          renderApplications();
        });
        item.append(copy, remove);
        list.appendChild(item);
      });
    };
    renderApplications();
    const actions = document.createElement("div");
    actions.className = "settings-dialog-actions split";
    const add = document.createElement("button");
    add.className = "action-button";
    add.textContent = "+ 添加应用";
    add.addEventListener("click", () => {
      send("action", { action: "configureOpenWithApps", payload: {} });
      close();
    });
    const done = document.createElement("button");
    done.className = "action-button primary";
    done.textContent = "完成";
    done.addEventListener("click", close);
    overlay.addEventListener("click", event => { if (event.target === overlay) close(); });
    actions.append(add, done);
    dialog.append(heading, detail, list, actions);
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);
  }

  function makeAppearanceGroup(titleText, body, className = "") {
    const group = document.createElement("section");
    group.className = `group appearance-group ${className}`.trim();
    const title = document.createElement("h2");
    title.className = "group-title";
    title.textContent = titleText;
    group.append(title, body);
    return group;
  }

  function appearanceRows(section) {
    return new Map(section.groups.flatMap(group => group.rows.map(item => [item.key ?? item.action, item])));
  }

  function cardForRows(rowMap, keys, className = "") {
    const card = document.createElement("div");
    card.className = `card ${className}`.trim();
    for (const key of keys) {
      const item = rowMap.get(key);
      if (item) card.appendChild(makeRow(item));
    }
    return card;
  }

  function makeLayoutChooser() {
    const card = document.createElement("div");
    card.className = "card layout-choice-grid";
    const current = settingValue("tabBarLayout");
    const choices = [
      ["vertical", "垂直标签", "sidebar"],
      ["horizontalTop", "顶部标签", "top"],
      ["horizontalBottom", "底部标签", "bottom"],
    ];
    for (const [value, label, position] of choices) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `layout-choice${current === value ? " selected" : ""}`;
      button.setAttribute("aria-pressed", String(current === value));
      button.innerHTML = `<span class="layout-mini layout-mini-${position}"><i></i><b></b></span><span></span>`;
      button.lastElementChild.textContent = label;
      button.addEventListener("click", () => commitValue({ key: "tabBarLayout" }, value));
      card.appendChild(button);
    }
    return makeAppearanceGroup("布局", card, "layout-group");
  }

  function makeThemeTerminalPreview(editor) {
    const preview = document.createElement("div");
    preview.className = "terminal-preview";
    const foreground = editor?.slots?.find(slot => slot.id === "terminal.foreground")?.resolved ?? "#e8e8e6";
    const background = editor?.slots?.find(slot => slot.id === "terminal.background")?.resolved ?? "#171817";
    // 首行行尾的闪烁光标用主题 cursor 色渲染（Otty 如此），缺失时回退前景色。
    const cursorColor = editor?.slots?.find(slot => slot.id === "cursor.background")?.resolved ?? foreground;
    const ansi = editor?.ansi ?? [];
    preview.style.setProperty("--terminal-fg", foreground);
    preview.style.setProperty("--terminal-bg", background);
    preview.style.setProperty("--terminal-cursor", cursorColor);
    preview.innerHTML = [
      `<div><span class="ansi-2">aster</span><span class="ansi-5">@macbook</span>:~ $ open <span class="terminal-inverse">readme.md</span> -a Typora<i class="terminal-cursor"></i></div>`,
      `<div><span class="ansi-2">aster</span><span class="ansi-5">@macbook</span>:~ $ eza -la --color=always --icons --git</div>`,
      `<div class="terminal-heading">Permissions   Size User    Date Modified  Git Name</div>`,
      `<div><span class="ansi-2">.drwxr-xr-x</span>      - aster   22 Aug 13:42    --    .cache</div>`,
      `<div><span class="ansi-2">.drwxr-xr-x</span>      - aster   20 Aug 09:15    -M    .config</div>`,
      `<div><span class="ansi-6">.lrwxrwxrwx</span>      9 aster    9 Feb 20:32    --  → etc → /etc</div>`,
      `<div><span class="ansi-3">.-rwxr-xr-x</span>    12k aster   15 Jun 10:45    --    build.sh</div>`,
      `<div><span class="ansi-1">.-rw-r--r--</span>   856k aster    3 Apr 09:11    -N    banner.png</div>`,
    ].join("");
    ansi.forEach((color, index) => preview.style.setProperty(`--ansi-${index}`, color));
    return preview;
  }

  function makeThemePalette(editor) {
    const palette = document.createElement("div");
    palette.className = "theme-palette";
    const primary = document.createElement("div");
    primary.className = "theme-primary-swatches";
    for (const id of ["terminal.foreground", "terminal.background"]) {
      const slot = editor?.slots?.find(value => value.id === id);
      const swatch = document.createElement("button");
      swatch.type = "button";
      swatch.className = "theme-primary-swatch";
      swatch.style.backgroundColor = slot?.resolved ?? "transparent";
      swatch.title = slot?.title ?? id;
      swatch.addEventListener("click", () => openThemeToken(editor, id));
      primary.appendChild(swatch);
    }
    const ansi = document.createElement("div");
    ansi.className = "theme-ansi-grid";
    for (const [index, color] of (editor?.ansi ?? []).entries()) {
      const dot = document.createElement("button");
      dot.type = "button";
      dot.className = "theme-ansi-dot";
      dot.style.backgroundColor = color;
      dot.title = `ANSI ${index}`;
      dot.addEventListener("click", () => openThemeToken(editor, `ansi.${index}`));
      ansi.appendChild(dot);
    }
    palette.append(primary, ansi);
    return palette;
  }

  function openThemeToken(editor, slotID) {
    appearanceUIState.themeEditorOpen = true;
    renderContent();
    window.requestAnimationFrame(() => {
      const input = content.querySelector(`[data-theme-slot="${CSS.escape(slotID)}"] input`);
      input?.focus();
      input?.select();
    });
  }

  // UI 元素 pill 条按 Otty 顺序显式映射 slot（去掉 Terminal 组：前景/背景已有大色板）；
  // 英文标签硬编码、光标/选区用中文，与 Otty 一致。
  function makeThemeTokenPills(editor) {
    const pills = document.createElement("div");
    pills.className = "theme-token-pills";
    const slotByID = new Map((editor?.slots ?? []).map(slot => [slot.id, slot]));
    const groups = [
      ["Window", ["interface.window"]],
      ["Container", ["container.background", "container.border"]],
      ["Panel", ["panel.background", "panel.surface", "panel.border"]],
      ["Sidebar", ["sidebar.background", "sidebar.foreground", "sidebar.border"]],
      ["Titlebar", ["titlebar.background", "titlebar.foreground"]],
      ["Tabbar", ["tabbar.background", "tabbar.border"]],
      ["Tab", ["tab.foreground", "tab.hoverBackground", "tab.activeBackground", "tab.activeForeground", "tab.activeBorderColor"]],
      ["Accents", ["interface.accent", "interface.foreground", "interface.secondaryForeground", "interface.tertiaryForeground", "interface.border"]],
      ["光标", ["cursor.background", "cursor.foreground"]],
      ["选区", ["selection.background", "selection.foreground"]],
    ];
    for (const [label, ids] of groups) {
      const slots = ids.map(id => slotByID.get(id)).filter(Boolean);
      if (!slots.length) continue;
      const button = document.createElement("button");
      button.type = "button";
      button.className = "theme-token-pill";
      const caption = document.createElement("span");
      caption.textContent = label;
      button.appendChild(caption);
      for (const slot of slots) {
        const dot = document.createElement("i");
        dot.style.backgroundColor = slot.resolved;
        dot.title = slot.title;
        button.appendChild(dot);
      }
      button.addEventListener("click", () => openThemeToken(editor, slots[0].id));
      pills.appendChild(button);
    }
    return pills;
  }

  function makeThemeEditor(editor) {
    const editorCard = document.createElement("div");
    editorCard.className = `card theme-color-grid${appearanceUIState.themeEditorOpen ? " open" : ""}`;
    editorCard.hidden = !appearanceUIState.themeEditorOpen;
    for (const slot of editor?.slots ?? []) {
      const row = document.createElement("label");
      row.className = "theme-color-row";
      row.dataset.themeSlot = slot.id;
      const swatch = document.createElement("span");
      swatch.className = "theme-color-swatch";
      swatch.style.backgroundColor = slot.resolved;
      const copy = document.createElement("span");
      copy.className = "theme-color-copy";
      copy.innerHTML = `<span class="setting-label"></span><span class="setting-detail"></span>`;
      copy.firstElementChild.textContent = slot.title;
      copy.lastElementChild.textContent = `${slot.id}${slot.derived ? " · 跟随派生色" : ""}`;
      const input = document.createElement("input");
      input.className = "control theme-color-input";
      input.type = "text";
      input.value = slot.value ?? slot.resolved;
      input.addEventListener("change", () => send("action", {
        action: "setThemeColor",
        payload: { themeID: editor.id, slotID: slot.id, color: input.value.trim() },
      }));
      row.append(swatch, copy, input);
      editorCard.appendChild(row);
    }
    const ansiNames = ["黑", "红", "绿", "黄", "蓝", "品红", "青", "白", "亮黑", "亮红", "亮绿", "亮黄", "亮蓝", "亮品红", "亮青", "亮白"];
    for (const [index, color] of (editor?.ansi ?? []).entries()) {
      const row = document.createElement("label");
      row.className = "theme-color-row";
      row.dataset.themeSlot = `ansi.${index}`;
      const swatch = document.createElement("span");
      swatch.className = "theme-color-swatch";
      swatch.style.backgroundColor = color;
      const copy = document.createElement("span");
      copy.className = "theme-color-copy";
      copy.innerHTML = `<span class="setting-label"></span><span class="setting-detail"></span>`;
      copy.firstElementChild.textContent = ansiNames[index] ?? `ANSI ${index}`;
      copy.lastElementChild.textContent = `terminal.palette[${index}]`;
      const input = document.createElement("input");
      input.className = "control theme-color-input";
      input.type = "text";
      input.value = color;
      input.addEventListener("change", () => send("action", {
        action: "setThemeANSIColor",
        payload: { themeID: editor.id, index, color: input.value.trim() },
      }));
      row.append(swatch, copy, input);
      editorCard.appendChild(row);
    }
    const reset = document.createElement("button");
    reset.type = "button";
    reset.className = "action-button danger theme-color-reset";
    reset.textContent = "恢复主题原始参数";
    reset.addEventListener("click", () => send("action", {
      action: "resetThemeColors", payload: { themeID: editor.id },
    }));
    editorCard.appendChild(reset);
    return editorCard;
  }

  // Otty 画法的主题预览卡：4:3 外框底=终端背景，左 20% 侧栏三根圆头横线，右侧
  // 内容面板底=surface（圆点 + 三根 2px 横线模拟文本），卡下 10px 主题名。
  function makeThemePreviewCard(theme) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `theme-card${theme.focused ? " selected" : ""}${theme.selected ? " configured" : ""}`;
    button.style.setProperty("--theme-background", theme.background);
    button.style.setProperty("--theme-foreground", theme.foreground);
    button.style.setProperty("--theme-accent", theme.accent);
    button.style.setProperty("--theme-surface", theme.surface ?? theme.background);
    button.innerHTML = `<span class="theme-thumb"><span class="theme-thumb-side"><i></i><i></i><i></i></span><span class="theme-thumb-panel"><span class="theme-thumb-lead"><i class="theme-thumb-dot"></i><i class="theme-thumb-line"></i></span><i class="theme-thumb-line"></i><i class="theme-thumb-line"></i></span></span><span class="theme-name"></span>`;
    button.querySelector(".theme-name").textContent = theme.name;
    button.addEventListener("click", () => send("action", { action: "selectTheme", payload: { id: theme.id } }));
    return button;
  }

  // 主题选择器：全部主题常开显示——浅色组在前、深色组在后，各一个 4 列 grid，
  // 无组标题文字（用户确认不要折叠态）。
  function makeThemePicker() {
    const picker = document.createElement("div");
    picker.className = "theme-picker";
    const themes = snapshot?.themes ?? [];
    for (const mode of ["light", "dark"]) {
      const grid = document.createElement("div");
      grid.className = "theme-grid";
      grid.dataset.themeMode = mode;
      for (const theme of themes.filter(item => item.mode === mode)) grid.appendChild(makeThemePreviewCard(theme));
      picker.appendChild(grid);
    }
    return picker;
  }

  // 操作按钮区（Otty 两行结构）；当前主题有用户覆盖色时上方多一行「恢复主题预设」。
  function makeThemeActions(editor) {
    const host = document.createElement("div");
    host.className = "theme-actions-area";
    const rowFor = buttons => {
      const line = document.createElement("div");
      line.className = "theme-actions";
      for (const [label, handler] of buttons) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "action-button";
        button.textContent = label;
        button.addEventListener("click", handler);
        line.appendChild(button);
      }
      return line;
    };
    if (editor?.hasOverrides) {
      host.appendChild(rowFor([
        ["恢复主题预设", () => send("action", { action: "resetThemeColors", payload: { themeID: editor.id } })],
      ]));
    }
    host.appendChild(rowFor([
      ["复制", () => send("action", { action: "duplicateTheme", payload: { id: editor.id } })],
      ["编辑当前主题", () => { appearanceUIState.themeEditorOpen = !appearanceUIState.themeEditorOpen; renderContent(); }],
    ]));
    host.appendChild(rowFor([
      ["打开主题文件夹", () => send("action", { action: "openThemesFolder", payload: {} })],
      ["导入主题…", () => send("action", { action: "importTheme", payload: {} })],
    ]));
    return host;
  }

  // 单张「主题」卡（Otty 结构）：选择器、详情（终端预览 + 色板 + pill 条）、按钮区
  // 三段共用一张卡、divider 分隔；内联 token 编辑器与「深色独立主题」行跟在卡后。
  function makeThemeGroup(rowMap) {
    const editor = snapshot?.themeEditor;
    const shell = document.createElement("div");
    shell.className = "appearance-theme-shell";
    const card = document.createElement("div");
    card.className = "card theme-shell-card";
    const divider = () => {
      const line = document.createElement("div");
      line.className = "theme-divider";
      return line;
    };
    card.appendChild(makeThemePicker());
    card.appendChild(divider());
    const detail = document.createElement("div");
    detail.className = "theme-detail";
    const detailTitle = document.createElement("h3");
    detailTitle.className = "theme-detail-title";
    detailTitle.textContent = "详情";
    detail.append(detailTitle, makeThemeTerminalPreview(editor), makeThemePalette(editor), makeThemeTokenPills(editor));
    card.appendChild(detail);
    card.appendChild(divider());
    card.appendChild(makeThemeActions(editor));
    shell.append(card, makeThemeEditor(editor));
    const separate = rowMap.get("appearance.useSeparateDarkTheme");
    if (separate) shell.appendChild(cardForRows(rowMap, [separate.key], "separate-theme-card"));
    return makeAppearanceGroup("主题", shell, "theme-group");
  }

  function makeFontStepper(rowMap) {
    const item = rowMap.get("appearance.fontSize");
    const row = makeRow({ ...item, type: "readonly" });
    const control = row.querySelector(".setting-control");
    control.replaceChildren();
    const stepper = document.createElement("div");
    stepper.className = "font-stepper";
    const value = Number(settingValue(item.key) ?? 13);
    for (const [label, delta] of [["−", -0.5], [String(value), 0], ["+", 0.5]]) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = label;
      button.disabled = delta === 0;
      if (delta !== 0) button.addEventListener("click", () => commitValue(item, Math.min(32, Math.max(9, value + delta))));
      stepper.appendChild(button);
    }
    control.appendChild(stepper);
    return row;
  }

  function makeBlinkRow(rowMap) {
    const item = rowMap.get("appearance.blinkRendering");
    return makeRow({
      ...item,
      type: "toggle",
      value: settingValue("appearance.blinkRendering") === "blink",
      onCommit: enabled => commitValue(item, enabled ? "blink" : "steady"),
    });
  }

  // 行高 segmented 的选中态推导。Aster 语义 1.0=字体默认行高，因此「默认」和
  // 「紧凑 (1.0)」写入同一组值（1.0 + 0px），只能靠 appearanceUIState.lineHeightChoice
  // 记住用户最近一次点击来消歧；任何其它组合（含历史默认 1.08）归为「自定义」。
  function lineHeightMode() {
    if (appearanceUIState.lineHeightChoice === "custom") return "custom";
    const height = Number(settingValue("appearance.lineHeight"));
    const adjust = Number(settingValue("appearance.adjustCellHeight") ?? 0);
    if (adjust !== 0) return "custom";
    if (Math.abs(height - 1) < 0.001) return appearanceUIState.lineHeightChoice === "compact" ? "compact" : "default";
    if (Math.abs(height - 1.2) < 0.001) return "relaxed";
    return "custom";
  }

  // 「行高」四段 segmented（默认/紧凑/宽松/自定义），对齐 Otty；只做 UI 映射，
  // 不改 Swift 侧 lineHeight/adjustCellHeight 的语义。
  function makeLineHeightRow() {
    const mode = lineHeightMode();
    const rowHost = makeRow({ key: "appearance.lineHeight", label: "行高", detail: "终端每行高度的预设或自定义组合", type: "readonly", value: "" });
    const control = rowHost.querySelector(".setting-control");
    control.replaceChildren();
    const segmented = document.createElement("div");
    segmented.className = "segmented";
    for (const [id, label] of [["default", "默认"], ["compact", "紧凑 (1.0)"], ["relaxed", "宽松 (1.2)"], ["custom", "自定义"]]) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = mode === id ? "active" : "";
      button.textContent = label;
      button.addEventListener("click", () => {
        appearanceUIState.lineHeightChoice = id;
        // 「自定义」只展开数字行，不动当前值；预设项一次提交两个键，避免中间态重渲染。
        if (id === "custom") { renderContent(); return; }
        send("set", { changes: [
          { key: "appearance.lineHeight", value: id === "relaxed" ? 1.2 : 1 },
          { key: "appearance.adjustCellHeight", value: 0 },
        ] });
      });
      segmented.appendChild(button);
    }
    control.appendChild(segmented);
    return rowHost;
  }

  // 「自定义」档展开的两行：行高倍数写 appearance.lineHeight，逐像素调整写现有
  // appearance.adjustCellHeight 兼容键。
  function makeLineHeightCustomRows() {
    return [
      makeRow({ key: "appearance.lineHeight", label: "自定义行高", detail: "字体默认行高的缩放倍数", type: "number", min: 0.8, max: 2, step: 0.1 }),
      makeRow({ key: "appearance.adjustCellHeight", label: "调整单元格高度", detail: "在计算行高后增加或减少像素（px）", type: "number", min: -8, max: 16, step: 1 }),
    ];
  }

  function makeFontFamilyCard(rowMap) {
    const host = document.createElement("div");
    const scopes = [["computed", "计算值"], ["global", "全局"], ["theme", "主题"], ["fallback", "回退"]];
    const tabs = document.createElement("div");
    tabs.className = "font-scope-tabs";
    const caption = document.createElement("span");
    caption.textContent = "设置范围";
    tabs.appendChild(caption);
    for (const [id, label] of scopes) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = appearanceUIState.fontScope === id ? "active" : "";
      button.textContent = label;
      button.addEventListener("click", () => { appearanceUIState.fontScope = id; renderContent(); });
      tabs.appendChild(button);
    }
    const card = document.createElement("div");
    card.className = "card font-scope-card";
    const roles = [["regular", "字体"], ["bold", "字体（粗体）"], ["italic", "字体（斜体）"], ["boldItalic", "字体（粗斜体）"]];
    if (appearanceUIState.fontScope === "computed") {
      const hint = document.createElement("p");
      hint.className = "font-scope-hint";
      hint.textContent = "按 全局 → 主题 → 回退 解析后的实际字体";
      card.appendChild(hint);
      card.appendChild(makeRow(rowMap.get("appearance.autoMatchFontStyles")));
      for (const [role, label] of roles) card.appendChild(makeRow({ key: `computed.${role}`, label, detail: "", type: "readonly", value: snapshot?.computedFonts?.[role] }));
    } else if (appearanceUIState.fontScope === "global") {
      card.appendChild(makeRow(rowMap.get("appearance.autoMatchFontStyles")));
      for (const key of ["appearance.fontFamily", "appearance.fontFamilyBold", "appearance.fontFamilyItalic", "appearance.fontFamilyBoldItalic"]) card.appendChild(makeRow(rowMap.get(key)));
    } else if (appearanceUIState.fontScope === "theme") {
      const fonts = snapshot?.themeEditor?.fonts ?? {};
      for (const [role, label] of roles) {
        const row = makeRow({
          key: `themeFont.${role}`, label,
          detail: "追加到当前主题参数；不会自动创建副本", type: "text",
          value: fonts[role] ?? "",
          onCommit: value => send("action", {
            action: "setThemeFont",
            payload: { themeID: snapshot.themeEditor.id, role, value: value.trim() },
          }),
        });
        card.appendChild(row);
      }
    } else {
      for (const key of ["appearance.fontFamilyFallback", "appearance.fontFamilyFallbackBold", "appearance.fontFamilyFallbackItalic", "appearance.fontFamilyFallbackBoldItalic"]) card.appendChild(makeRow(rowMap.get(key)));
    }
    const actions = document.createElement("div");
    actions.className = "font-actions";
    for (const [action, label] of [["installFont", "安装字体"], ["openFontsFolder", "打开字体文件夹"]]) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "action-button";
      button.textContent = label;
      button.addEventListener("click", () => send("action", { action, payload: {} }));
      actions.appendChild(button);
    }
    card.appendChild(actions);
    host.append(tabs, card);
    return makeAppearanceGroup("字体系列", host, "font-family-group");
  }

  function makeCursorGroup(rowMap) {
    const host = document.createElement("div");
    const card = cardForRows(rowMap, [
      "appearance.cursorColor", "appearance.cursorTextColor", "appearance.cursorOpacity",
      "appearance.cursorStyle", "appearance.cursorBlinkMode", "appearance.cursorAnimation",
    ], "cursor-card");
    // 实时预览随当前设置联动（Otty 行为）：底色/前景取主题终端色，光标颜色留空时
    // 回退主题 cursor 色；样式（块/竖线/下划线/空心块）与不透明度取当前值；是否闪烁
    // 跟随「光标闪烁方式」（默认开启/始终开启才闪）。CSP 禁内联脚本，闪烁由 CSS
    // @keyframes + blinking class 驱动。
    const editor = snapshot?.themeEditor;
    const slotColor = id => editor?.slots?.find(slot => slot.id === id)?.resolved;
    const preview = document.createElement("div");
    preview.className = "cursor-preview";
    preview.style.setProperty("--terminal-fg", slotColor("terminal.foreground") ?? "#e8e8e6");
    preview.style.setProperty("--terminal-bg", slotColor("terminal.background") ?? "#171817");
    preview.style.setProperty("--cursor-color", settingValue("appearance.cursorColor") || slotColor("cursor.background") || "#e8e8e6");
    preview.style.setProperty("--cursor-text", settingValue("appearance.cursorTextColor") || slotColor("cursor.foreground") || "#171817");
    preview.style.setProperty("--cursor-opacity", settingValue("appearance.cursorOpacity") ?? 1);
    preview.innerHTML = `<span class="ansi-2">abner</span><span class="ansi-5">@macbook</span>$ git commit -am "<i class="cursor-demo"></i>`;
    const cursorDemo = preview.querySelector(".cursor-demo");
    const cursorStyle = String(settingValue("appearance.cursorStyle") || "block");
    cursorDemo.classList.add(`cursor-style-${cursorStyle}`);
    const blinkMode = String(settingValue("appearance.cursorBlinkMode") || "defaultOn");
    if (blinkMode === "defaultOn" || blinkMode === "alwaysOn") cursorDemo.classList.add("blinking");
    // 卡顶部先放描述再放实时预览（Otty 结构）。
    const description = document.createElement("p");
    description.className = "cursor-card-desc";
    description.textContent = "实时预览光标的颜色、样式、不透明度与闪烁行为。";
    card.prepend(description, preview);
    host.appendChild(card);
    return makeAppearanceGroup("光标", host, "cursor-group");
  }

  // Dock 图标组：左侧预览内联 Aster 品牌 logo（真值是 Resources/AsterIcon.svg，
  // 逐路径保持一致；改 logo 时需同步这里），右侧是三个 Dock 行为开关。
  function makeDockGroup(rowMap) {
    const card = cardForRows(rowMap, [
      "appearance.animateDockIconOnProgress", "appearance.redDockIconOnError", "shell.bounceDockIcon",
    ], "dock-card");
    const icon = document.createElement("div");
    icon.className = "dock-icon-preview";
    icon.innerHTML = `<svg viewBox="0 0 1024 1024" aria-hidden="true">
      <rect x="0" y="0" width="1024" height="1024" rx="230" fill="#EA6D49"/>
      <path d="M156 260 278 356 156 452" fill="none" stroke="#FFFFFF" stroke-width="52" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M684 676 C754 586 794 488 768 398 C731 272 597 231 474 286 C349 342 284 466 307 592 C331 724 445 797 572 800 C670 802 756 779 860 748 L860 610" fill="none" stroke="#FFFFFF" stroke-width="52" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M548 405 C558 480 599 520 674 530 C599 540 558 580 548 655 C538 580 497 540 422 530 C497 520 538 480 548 405Z" fill="#FFFFFF"/>
    </svg>`;
    card.prepend(icon);
    return makeAppearanceGroup("Dock 图标", card, "dock-group");
  }

  function makeAppearancePage(section) {
    const rows = appearanceRows(section);
    const fragment = document.createDocumentFragment();
    fragment.appendChild(makeLayoutChooser());
    // 「标签栏」行按当前布局显隐（Otty 行为）：垂直布局没有横向标签栏的自动隐藏，
    // 横向布局没有标签面板及其宽度。
    const layout = settingValue("tabBarLayout");
    const tabKeys = ["appearance.newTabPosition", "appearance.showTabBar"];
    if (layout !== "vertical") tabKeys.push("appearance.tabBarVisibility");
    if (layout === "vertical") tabKeys.push("appearance.tabsPanelVisibility", "appearance.sidebarWidth");
    tabKeys.push("appearance.inspectorWidth");
    fragment.appendChild(makeAppearanceGroup("标签栏", cardForRows(rows, tabKeys)));
    const windowKeys = ["appearance.windowSizeMode"];
    const sizeMode = settingValue("appearance.windowSizeMode");
    if (sizeMode === "grid") windowKeys.push("appearance.windowColumns", "appearance.windowRows");
    if (sizeMode === "frame") windowKeys.push("appearance.windowWidth", "appearance.windowHeight");
    windowKeys.push("appearance.unfocusedSplitOpacity");
    fragment.appendChild(makeAppearanceGroup("窗口", cardForRows(rows, windowKeys)));
    fragment.appendChild(makeThemeGroup(rows));
    const textCard = cardForRows(rows, [
      "appearance.boldRendering", "appearance.italicRendering", "appearance.underlineRendering",
      "appearance.ligatureLevel", "appearance.fontBlending",
      "appearance.fontSmoothing", "appearance.fontThicken",
      "appearance.bidirectionalText", "appearance.ligatureAlphabet", "appearance.windowsTextRendering",
    ], "text-card");
    textCard.prepend(makeFontStepper(rows));
    const underlineRow = textCard.querySelector('[data-setting-key="appearance.underlineRendering"]');
    underlineRow?.after(makeBlinkRow(rows));
    // 行高 segmented 插在「字体混合」之后；选「自定义」时展开两行数字输入。
    const blendingRow = textCard.querySelector('[data-setting-key="appearance.fontBlending"]');
    const lineHeightRows = [makeLineHeightRow()];
    if (lineHeightMode() === "custom") lineHeightRows.push(...makeLineHeightCustomRows());
    blendingRow?.after(...lineHeightRows);
    fragment.appendChild(makeAppearanceGroup("文本", textCard));
    fragment.appendChild(makeFontFamilyCard(rows));
    fragment.appendChild(makeCursorGroup(rows));
    fragment.appendChild(makeDockGroup(rows));
    return fragment;
  }

  /// 编程智能体卡片，对齐 Otty settings-ui 的结构：折叠行（图标、名称 + CLI 路径、集成
  /// 状态、集成开关、展开箭头），展开后显示集成说明、快速启动开关与启动命令。
  function makeAgentGroup() {
    const group = document.createElement("section");
    group.className = "group";
    const title = document.createElement("h2");
    title.className = "group-title";
    title.textContent = "编程智能体";
    const description = document.createElement("p");
    description.className = "group-description";
    description.textContent = "接入你的编程智能体，获得实时角标、通知与会话恢复。";
    const card = document.createElement("div");
    card.className = "card agent-list";
    for (const agent of snapshot?.agents ?? []) {
      const expanded = agentUIState.expanded.has(agent.id);
      const toggleExpanded = () => {
        if (expanded) agentUIState.expanded.delete(agent.id);
        else agentUIState.expanded.add(agent.id);
        renderContent();
      };
      const row = document.createElement("div");
      row.className = expanded ? "agent-row expanded" : "agent-row";

      const head = document.createElement("div");
      head.className = "agent-head";
      const main = document.createElement("button");
      main.type = "button";
      main.className = "agent-head-main";
      main.addEventListener("click", toggleExpanded);
      // 图标只从后端固定 token 映射到本地字形，不接受快照注入任意 HTML/SVG。
      const iconMarks = {
        claude: "✳",
        codex: "⌬",
        opencode: "▣",
        cursor: "◆",
        kimi: "K",
        pi: "Pı",
        omp: "T",
      };
      const iconName = Object.hasOwn(iconMarks, agent.icon) ? agent.icon : "default";
      const icon = document.createElement("span");
      icon.className = `agent-icon agent-icon-${iconName}`;
      icon.setAttribute("aria-hidden", "true");
      icon.textContent = iconMarks[iconName] ?? "›_";
      const copy = document.createElement("div");
      copy.className = "agent-copy";
      const name = document.createElement("span");
      name.className = "agent-name";
      name.textContent = agent.name;
      const cli = document.createElement("span");
      cli.className = agent.executablePath ? "agent-cli detected" : "agent-cli";
      cli.textContent = agent.executablePath || "未安装";
      if (agent.executablePath) cli.title = agent.executablePath;
      copy.append(name, cli);
      main.append(icon, copy);
      const state = document.createElement("span");
      state.className = agent.integrated ? "agent-state installed" : "agent-state";
      state.textContent = agent.integrated ? "已安装" : "关闭";
      const enabled = document.createElement("label");
      enabled.className = "toggle";
      const enabledInput = document.createElement("input");
      enabledInput.type = "checkbox";
      enabledInput.checked = agent.integrated;
      enabledInput.setAttribute("aria-label", `${agent.integrated ? "卸载" : "安装"} ${agent.name} 集成`);
      enabledInput.addEventListener("change", () => send("action", {
        action: agent.integrated ? "uninstallAgent" : "installAgent",
        payload: { provider: agent.id },
      }));
      const enabledTrack = document.createElement("span");
      enabledTrack.className = "toggle-track";
      enabled.append(enabledInput, enabledTrack);
      const chevron = document.createElement("button");
      chevron.type = "button";
      chevron.className = "agent-chevron";
      chevron.setAttribute("aria-label", expanded ? `收起 ${agent.name}` : `展开 ${agent.name}`);
      chevron.setAttribute("aria-expanded", String(expanded));
      chevron.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24"><path fill="currentColor" d="M8.47 4.22a.75.75 0 0 0 0 1.06L15.19 12l-6.72 6.72a.75.75 0 1 0 1.06 1.06l7.25-7.25a.75.75 0 0 0 0-1.06L9.53 4.22a.75.75 0 0 0-1.06 0"/></svg>`;
      chevron.addEventListener("click", toggleExpanded);
      head.append(main, state, enabled, chevron);
      row.appendChild(head);

      if (expanded) {
        const detail = document.createElement("div");
        detail.className = "agent-detail";
        const hookDetail = document.createElement("p");
        hookDetail.className = "agent-hook-detail";
        hookDetail.textContent = agent.hookDetail;
        const providerEnabled = document.createElement("label");
        providerEnabled.className = "agent-provider-enabled";
        const providerEnabledCopy = document.createElement("span");
        providerEnabledCopy.textContent = "在快速启动中启用";
        const providerToggle = document.createElement("span");
        providerToggle.className = "toggle";
        const providerInput = document.createElement("input");
        providerInput.type = "checkbox";
        providerInput.checked = agent.enabled;
        providerInput.setAttribute("aria-label", `在快速启动中启用 ${agent.name}`);
        providerInput.addEventListener("change", () => commitValue(
          { key: `agents.enabled.${agent.id}` },
          providerInput.checked
        ));
        const providerTrack = document.createElement("span");
        providerTrack.className = "toggle-track";
        providerToggle.append(providerInput, providerTrack);
        providerEnabled.append(providerEnabledCopy, providerToggle);
        const commandField = document.createElement("label");
        commandField.className = "agent-command-field";
        const commandLabel = document.createElement("span");
        commandLabel.textContent = "启动命令";
        const commandInput = document.createElement("input");
        commandInput.className = "control";
        commandInput.type = "text";
        commandInput.spellcheck = false;
        commandInput.placeholder = agent.defaultCommand;
        commandInput.value = agent.customCommand;
        commandInput.addEventListener("change", () => commitValue(
          { key: `agents.launchCommand.${agent.id}` },
          commandInput.value.trim()
        ));
        const commandHint = document.createElement("span");
        commandHint.className = "agent-command-hint";
        commandHint.textContent = "可选的可执行文件、wrapper 与全局参数；Aster 会自动追加原生 resume / fork 参数，留空恢复默认。";
        commandField.append(commandLabel, commandInput, commandHint);
        detail.append(hookDetail, providerEnabled, commandField);
        row.appendChild(detail);
      }
      card.appendChild(row);
    }
    group.append(title, description, card);
    return group;
  }

  /// MCP 注册卡片。按钮文案随状态变化（安装 / 已安装 / 修复路径），因此必须由快照
  /// 驱动动态渲染，不能写进静态 rows 数组。
  function makeMemoryMCPGroup() {
    const state = snapshot?.memoryMCP ?? {};
    const group = document.createElement("section");
    group.className = "group";
    const title = document.createElement("h2");
    title.className = "group-title";
    title.textContent = "项目记忆 MCP";
    const description = document.createElement("p");
    description.className = "group-description";
    description.textContent = "把 Aster 的项目记忆接给 Agent，让它们查得到这个项目过去发生了什么。";
    const card = document.createElement("div");
    card.className = "card";

    card.appendChild(makeRow({
      key: "memoryMCP.projectPath",
      label: "当前项目",
      detail: "注册项写入该目录的 .mcp.json",
      type: "readonly",
      value: state.projectPath || "—",
    }));

    // Claude Code 一行两个按钮：主动作随状态变化，移除只在已注册时出现。
    const claudeRow = document.createElement("div");
    claudeRow.className = "setting-row";
    claudeRow.dataset.settingKey = "installMemoryMCP";
    const copy = document.createElement("div");
    copy.className = "setting-copy";
    const label = document.createElement("span");
    label.className = "setting-label";
    label.textContent = `Claude Code — ${state.status ?? "未知"}`;
    const detail = document.createElement("span");
    detail.className = "setting-detail";
    detail.textContent = state.detail ?? "";
    copy.append(label, detail);
    const controls = document.createElement("div");
    controls.className = "setting-control";
    if (state.installed) {
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "action-button danger";
      remove.textContent = "移除";
      remove.addEventListener("click", () => send("action", { action: "uninstallMemoryMCP", payload: {} }));
      controls.appendChild(remove);
    }
    const primary = document.createElement("button");
    primary.type = "button";
    primary.className = "action-button";
    primary.textContent = state.actionTitle ?? "安装";
    // 已注册且路径正确时没有可做的动作，按钮保持禁用而不是假装可点。
    primary.disabled = state.canInstall === false || state.actionTitle === "已安装";
    primary.addEventListener("click", () => send("action", { action: "installMemoryMCP", payload: {} }));
    controls.appendChild(primary);
    claudeRow.append(copy, controls);
    card.appendChild(claudeRow);

    card.appendChild(makeRow({
      label: "Codex",
      detail: "Codex 读全局 ~/.codex/config.toml，Aster 不会替你改它——复制下面的片段自行追加。",
      type: "action",
      action: "copyCodexMCPInstructions",
      button: "复制配置",
      confirmDuration: 1600,
      confirmedLabel: "已复制",
    }));

    group.append(title, description, card);
    return group;
  }

  function makeRecipesGroup() {
    const group = document.createElement("section");
    group.className = "group";
    const title = document.createElement("h2");
    title.className = "group-title";
    title.textContent = "已保存的 Recipes";
    const card = document.createElement("div");
    card.className = "card recipe-list";
    const recipes = snapshot?.recipes ?? [];
    if (recipes.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = "暂无已保存的 Recipe。可从“工作区 → 保存为 Recipe”创建。";
      card.appendChild(empty);
    } else {
      for (const recipe of recipes) {
        card.appendChild(makeRow({
          label: recipe.name,
          detail: recipe.summary,
          type: "action",
          action: "openRecipeDetail",
          button: recipe.shortcut || "查看",
          payload: { id: recipe.id },
        }));
      }
    }
    const actions = document.createElement("div");
    actions.className = "setting-row";
    actions.appendChild(document.createElement("div"));
    const controls = document.createElement("div");
    controls.className = "setting-control";
    for (const [name, label] of [["createTextSnippet", "新建文本片段"], ["openRecipesFolder", "打开 Recipe 文件夹"]]) {
      const button = document.createElement("button");
      button.className = "action-button";
      button.textContent = label;
      button.addEventListener("click", () => send("action", { action: name, payload: {} }));
      controls.appendChild(button);
    }
    actions.appendChild(controls);
    card.appendChild(actions);
    group.append(title, card);
    return group;
  }

  function makeShortcutsGroup() {
    const groups = new Map();
    for (const shortcut of snapshot?.shortcuts ?? []) {
      if (!groups.has(shortcut.group)) groups.set(shortcut.group, []);
      groups.get(shortcut.group).push(shortcut);
    }
    const fragment = document.createDocumentFragment();
    for (const [groupName, shortcuts] of groups) {
      const group = document.createElement("section");
      group.className = "group";
      const title = document.createElement("h2");
      title.className = "group-title";
      title.textContent = groupName;
      const card = document.createElement("div");
      card.className = "card";
      for (const shortcut of shortcuts) {
        const item = {
          label: shortcut.label,
          detail: shortcut.detail || "点击录制新的快捷键",
          type: "action",
          action: "recordShortcut",
          button: shortcut.keys || "无快捷键",
          payload: { id: shortcut.id },
        };
        const row = makeRow(item);
        row.querySelector("button").classList.add("shortcut-chip");
        card.appendChild(row);
      }
      group.append(title, card);
      fragment.appendChild(group);
    }
    return fragment;
  }

  function makeSearchResults() {
    const query = searchText.trim().toLocaleLowerCase();
    const results = [];
    for (const section of sections) {
      for (const group of section.groups) {
        for (const item of group.rows) {
          const haystack = `${section.title} ${group.title} ${item.label} ${item.detail} ${item.key ?? item.action}`.toLocaleLowerCase();
          if (haystack.includes(query)) results.push({ section, group, item });
        }
      }
    }
    const page = document.createElement("div");
    page.className = "page";
    const header = document.createElement("header");
    header.className = "page-header";
    const title = document.createElement("h1");
    title.className = "page-title";
    title.textContent = "搜索设置";
    const description = document.createElement("p");
    description.className = "page-description";
    description.textContent = results.length ? `找到 ${results.length} 项` : "没有匹配的设置";
    header.append(title, description);
    page.appendChild(header);
    const list = document.createElement("div");
    list.className = "search-results";
    for (const result of results) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "search-result";
      button.innerHTML = `<strong></strong><span class="search-result-section"></span>`;
      button.querySelector("strong").textContent = result.item.label;
      button.querySelector(".search-result-section").textContent = `${result.section.title} · ${result.group.title} — ${result.item.detail}`;
      button.addEventListener("click", () => setSection(result.section.id, { focusContent: true, highlightKey: result.item.key ?? result.item.action }));
      list.appendChild(button);
    }
    page.appendChild(list);
    return page;
  }

  function renderContent() {
    if (!snapshot) return;
    if (searchText.trim()) {
      content.replaceChildren(makeSearchResults());
      return;
    }
    const section = sectionMap.get(selectedSection) ?? sections[0];
    const page = document.createElement("div");
    page.className = "page";
    page.dataset.section = section.id;
    const header = document.createElement("header");
    header.className = "page-header";
    const title = document.createElement("h1");
    title.className = "page-title";
    title.textContent = section.title;
    const description = document.createElement("p");
    description.className = "page-description";
    description.textContent = section.description;
    header.append(title, description);
    page.appendChild(header);
    if (snapshot.message) {
      const message = document.createElement("div");
      message.className = "message-banner";
      message.textContent = snapshot.message;
      page.appendChild(message);
    }
    if (section.special === "agents") page.appendChild(makeAgentGroup());
    if (section.special === "appearance") page.appendChild(makeAppearancePage(section));
    if (section.special === "recipes") page.appendChild(makeRecipesGroup());
    if (section.special === "shortcuts") page.appendChild(makeShortcutsGroup());
    if (section.special !== "appearance") {
      for (const group of section.groups) page.appendChild(makeGroup(group));
    }
    // MCP 卡片排在记录与提炼之后：先决定记不记、怎么提炼，才轮到交给谁用。
    if (section.special === "agents") page.appendChild(makeMemoryMCPGroup());
    content.replaceChildren(page);
  }

  function render() {
    renderNav();
    renderContent();
  }

  search.addEventListener("input", () => {
    searchText = search.value;
    render();
    content.scrollTop = 0;
  });

  window.AsterSettings = {
    receive(message) {
      if (!message || typeof message !== "object") return;
      if (message.type === "snapshot") {
        snapshot = message.snapshot;
        app.setAttribute("aria-busy", "false");
        render();
      } else if (message.type === "selectSection") {
        setSection(message.section);
      } else if (message.type === "toast") {
        showToast(message.message, message.level === "error");
      }
    },
  };

  send("ready");
})();
