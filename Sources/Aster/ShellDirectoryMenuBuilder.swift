import AppKit
import AsterCore

/// Shell 菜单与工作区标题 popover 共用的「打开方式 / Git」菜单构建器。
/// 单一真值来源：菜单栏与 popover 展示的条目集合、可用性与注入语义必须一致。
@MainActor
enum ShellDirectoryMenuBuilder {

  /// 「打开方式」子菜单：新建终端标签、文件面板、检测到的编辑器与用户配置的应用。
  static func openInMenu(
    directory: String,
    model: AppModel,
    tab: TerminalTabItem?,
    preferences: AppPreferences
  ) -> NSMenu {
    let url = URL(fileURLWithPath: directory)
    let menu = NSMenu(title: "打开方式")
    menu.addItem(ActionMenuItem(title: "New Terminal Tab") { [weak model] in
      model?.newTab(workingDirectory: directory)
    })
    menu.addItem(ActionMenuItem(title: "Files Pane") { [weak model, weak tab] in
      tab?.openFileBrowser()
      model?.persistWorkspace()
    })
    let editors = WorkspaceEditorLocator.detect()
    if !editors.isEmpty { menu.addItem(.separator()) }
    for editor in editors {
      menu.addItem(ActionMenuItem(title: editor.name) {
        WorkspaceEditorLocator.open(directory: url, in: editor)
      })
    }
    let editorBundleIdentifiers = Set(editors.map(\.bundleIdentifier))
    for application in preferences.configuration.controls.resolvedOpenWithApplications
      where !editorBundleIdentifiers.contains(application.bundleIdentifier)
    {
      menu.addItem(ActionMenuItem(title: application.name) {
        open(url, withBundleIdentifier: application.bundleIdentifier)
      })
    }
    if editors.isEmpty && preferences.configuration.controls.resolvedOpenWithApplications.isEmpty {
      let unavailable = NSMenuItem(title: "未检测到受支持的编辑器", action: nil, keyEquivalent: "")
      unavailable.isEnabled = false
      menu.addItem(unavailable)
    }
    return menu
  }

  /// 「Git」子菜单：可选的图形客户端入口 + 预填到终端输入行的常用命令。
  /// 命令只经 `typeText` 预填，不自动回车——执行与否始终由用户确认。
  static func gitMenu(tab: TerminalTabItem?, preferences: AppPreferences) -> NSMenu {
    let menu = NSMenu(title: "Git")
    if let directory = tab?.workingDirectory, let client = resolvedGitClient(preferences: preferences) {
      menu.addItem(ActionMenuItem(title: "在 \(client.name) 中打开") {
        open(URL(fileURLWithPath: directory), withBundleIdentifier: client.bundleIdentifier)
      })
      menu.addItem(.separator())
    }
    for (title, command) in [
      ("Commit…", GitCommand.commit), ("Push", .push), ("Pull", .pull), ("Fetch", .fetch),
    ] {
      menu.addItem(ActionMenuItem(title: title) { [weak tab] in
        inject(command, into: tab)
      })
    }
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: "Merge…") { [weak tab] in
      promptBranch(title: "Merge 分支", action: "Merge") { branch in
        inject(.merge(branch: branch), into: tab)
      }
    })
    menu.addItem(ActionMenuItem(title: "Rebase…") { [weak tab] in
      promptBranch(title: "Rebase 到分支", action: "Rebase") { branch in
        inject(.rebase(branch: branch), into: tab)
      }
    })
    return menu
  }

  /// 优先用户显式选择的默认 Git 客户端；否则取首个本机已安装的候选。
  static func resolvedGitClient(preferences: AppPreferences) -> OpenWithApplication? {
    let builtIn = [
      OpenWithApplication(name: "GitHub Desktop", bundleIdentifier: "com.github.GitHubClient"),
      OpenWithApplication(name: "Fork", bundleIdentifier: "com.DanPristupov.Fork"),
      OpenWithApplication(name: "Tower", bundleIdentifier: "com.fournova.Tower3"),
      OpenWithApplication(name: "Sourcetree", bundleIdentifier: "com.torusknot.SourceTreeNotMAS"),
      OpenWithApplication(name: "GitKraken", bundleIdentifier: "com.axosoft.gitkraken"),
      OpenWithApplication(name: "Sublime Merge", bundleIdentifier: "com.sublimehq.Sublime-Merge"),
    ]
    let candidates = builtIn + preferences.configuration.controls.resolvedOpenWithApplications
    if let selected = preferences.configuration.controls.defaultGitClient {
      return candidates.first(where: {
        $0.bundleIdentifier == selected
          && NSWorkspace.shared.urlForApplication(withBundleIdentifier: selected) != nil
      })
    }
    return candidates.first(where: {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
    })
  }

  /// 通过 bundle identifier 打开目录；应用缺失时静默忽略（菜单入口已按安装态过滤）。
  static func open(_ url: URL, withBundleIdentifier bundleIdentifier: String) {
    guard let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: bundleIdentifier) else { return }
    NSWorkspace.shared.open(
      [url],
      withApplicationAt: applicationURL,
      configuration: NSWorkspace.OpenConfiguration()
    )
  }

  /// 把 Git 命令行预填到标签的聚焦终端输入行。
  private static func inject(_ command: GitCommand, into tab: TerminalTabItem?) {
    guard let commandLine = command.commandLine else { return }
    tab?.activeSession?.typeText(commandLine)
  }

  /// Merge/Rebase 的分支名输入框；非法分支名直接放弃，不预填任何命令。
  private static func promptBranch(
    title: String, action: String, completion: @escaping (String) -> Void
  ) {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.placeholderString = "分支名"
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = "命令会预填到终端输入行，确认后回车执行。"
    alert.accessoryView = field
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn,
      let branch = GitCommand.sanitizedBranch(field.stringValue)
    else { return }
    completion(branch)
  }
}
