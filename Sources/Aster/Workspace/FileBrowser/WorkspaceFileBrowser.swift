import AppKit
import AsterCore
import Combine

/// 工作区文件浏览器控制器；由中央 Pane 内容按需挂载。

@MainActor
final class FileBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  NSMenuDelegate
{
  private let runtime: WorkspacePaneRuntime
  private weak var tab: TerminalTabItem?
  private let model: AppModel
  private var directory: URL
  private var entries: [URL] = []
  private let table = NSTableView()

  init(runtime: WorkspacePaneRuntime, tab: TerminalTabItem, model: AppModel) {
    self.runtime = runtime
    self.tab = tab
    self.model = model
    directory = URL(
      fileURLWithPath: runtime.descriptor.resourcePath ?? runtime.descriptor.workingDirectory)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let column = NSStackView()
    column.orientation = .vertical
    column.spacing = 0
    let toolbar = NSView()
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = AsterTheme.panel.cgColor
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.heightAnchor.constraint(equalToConstant: 36).isActive = true
    let back = ActionButton(symbol: "chevron.left") { [weak self] in self?.goUp() }
    let refresh = ActionButton(symbol: "arrow.clockwise") { [weak self] in self?.reload() }
    let title = makeLabel(directory.lastPathComponent, size: 11, weight: .semibold)
    let row = NSStackView(views: [back, title, NSView(), refresh])
    row.orientation = .horizontal
    row.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)
    toolbar.addSubview(row)
    row.pinEdges(to: toolbar)
    column.addArrangedSubview(toolbar)

    table.headerView = nil
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openSelected)
    table.backgroundColor = AsterTheme.paper
    let contextMenu = NSMenu()
    contextMenu.delegate = self
    table.menu = contextMenu
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    column.addArrangedSubview(scroll)
    view = column
    reload()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard entries.indices.contains(row) else { return nil }
    let url = entries[row]
    let cell = NSTableCellView()
    let directory = isDirectory(url)
    let image = NSImageView(
      image: NSImage(systemSymbolName: directory ? "folder" : "doc", accessibilityDescription: nil)
        ?? NSImage())
    image.contentTintColor = directory ? AsterTheme.accent : AsterTheme.secondaryInk
    let label = makeLabel(url.lastPathComponent, size: 11.5)
    let stack = NSStackView(views: [image, label])
    stack.orientation = .horizontal
    stack.spacing = 8
    cell.addSubview(stack)
    stack.pinEdges(to: cell, insets: NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
    return cell
  }

  private func reload() {
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ).sorted {
        let left = isDirectory($0)
        let right = isDirectory($1)
        return left == right
          ? $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
          : left
      }
    } catch { entries = [] }
    table.reloadData()
  }

  private func goUp() {
    let parent = directory.deletingLastPathComponent()
    guard parent.path != directory.path else { return }
    directory = parent
    reload()
  }

  @objc private func openSelected() {
    guard entries.indices.contains(table.selectedRow) else { return }
    let url = entries[table.selectedRow]
    if isDirectory(url) {
      directory = url
      reload()
    } else {
      tab?.openFile(url)
    }
  }

  /// 根据当前右键命中的行动态生成菜单，避免在目录刷新后菜单仍引用失效 URL。
  func menuWillOpen(_ menu: NSMenu) {
    menu.removeAllItems()
    let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    guard entries.indices.contains(row) else { return }
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    let url = entries[row]
    menu.addItem(
      ActionMenuItem(title: isDirectory(url) ? "打开文件夹" : "打开") { [weak self] in
        self?.openURL(url)
      })
    if !isDirectory(url) {
      menu.addItem(
        ActionMenuItem(title: "在预览中打开") { [weak self] in
          self?.tab?.openPreview(url)
        })
      menu.addItem(
        ActionMenuItem(title: "发送到 Chat") { [weak self] in
          self?.model.sendFileToChat(url)
        })
    }
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: "复制绝对路径") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
      })
    menu.addItem(
      ActionMenuItem(title: "在新终端中打开所在目录") { [weak tab] in
        let directory = self.isDirectory(url) ? url.path : url.deletingLastPathComponent().path
        tab?.split(direction: .right, workingDirectory: directory)
      })
    menu.addItem(
      ActionMenuItem(title: "在当前终端中 cd 到所在目录") { [weak tab] in
        let directory = self.isDirectory(url) ? url.path : url.deletingLastPathComponent().path
        _ = tab?.openDirectoryInTerminal(directory)
      })
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: "在 Finder 中显示") {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      })
    menu.addItem(
      ActionMenuItem(title: "使用默认应用打开") {
        NSWorkspace.shared.open(url)
      })
  }

  private func openURL(_ url: URL) {
    if isDirectory(url) {
      directory = url
      reload()
    } else {
      tab?.openFile(url)
    }
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}

/// Open Quickly 展示时覆盖工作区的轻量 scrim。点击浮层外部关闭，但不抢占
/// 面板内部的鼠标和键盘事件。
