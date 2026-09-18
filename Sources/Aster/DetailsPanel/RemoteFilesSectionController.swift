// 详情面板 Files 页的远端模式：状态机、路径栏、列表、右键菜单与目录缓存。
// 传输（上传 / 下载 / 拖入）的编排在 RemoteFilesDropSupport.swift。

import AppKit
import AsterCore
import Foundation

/// 远端 Files 页的状态。每个状态对应完全不同的下一步动作，因此不合并成「加载中 / 出错」两态。
enum RemoteFilesState: Equatable {
  /// 还没激活（面板收起、或当前 Pane 不是远端）。
  case idle
  /// 远端模式但还没拿到远端目录：显示安装远端集成的引导横幅。
  case awaitingIntegration
  /// 正在读取目录；已有列表继续作为不可交互视觉帧保留。
  case loading(String)
  /// 列表就绪。
  case listed(RemoteDirectoryListing)
  /// 读取失败，`directory` 为失败时请求的目录。
  case failed(RemoteInspectionFailure, String?)
  /// 正在传输文件，附一句进度文案。
  case transferring(String)
}

/// Files 页远端模式的子控制器。
///
/// 自持表格并自任 delegate，不复用主控制器的表格与行高回调——主控制器实现了
/// `tableView(_:heightOfRow:)`，一旦共用就得为远端行再分一支，反而更脆。
@MainActor
final class RemoteFilesSectionController: NSViewController, NSTableViewDataSource,
  NSTableViewDelegate, NSMenuDelegate
{
  // MARK: - 依赖与身份

  let client: RemoteInspectionClient
  /// 结果提交后通知主控制器撤下 Pane 刷新屏障。
  private let onCommitted: @MainActor () -> Void
  /// 把命令预填到当前 Pane 的终端输入行（不回车）。
  private let prefillCommand: @MainActor (String) -> Void
  /// 面板级提示。
  private let notify: @MainActor (String) -> Void

  private(set) var host: RemoteInspectionHost?
  /// 同一 Pane 内的请求序号；切 Pane、切页、收起面板都会推进它，迟到结果据此丢弃。
  private var generation: UInt64 = 0
  /// 已提交列表的次数。宽限期用它判断「这一轮是否真的拿到了新列表」，不能用
  /// `state == .listed` 代替：同一条通道断开重连（exit 后再 ssh）时通道身份没变，
  /// 页面状态仍停在上一次连接的列表上，用状态判断会让横幅永远出不来。
  private var listingSequence: UInt64 = 0
  private var isActive = false

  /// 当前展示的目录（远端 `pwd -P` 解析后的绝对路径）。
  private(set) var activeDirectory: String?
  /// 最近一次请求携带的目录参数；空串表示「远端登录目录」。
  private var requestedDirectory: String?

  private var listTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var graceTask: Task<Void, Never>?
  var transferTask: Task<Void, Never>?

  /// 按通道分桶的目录缓存。切 Pane 不清空：切回同一台远端可以先出旧帧再刷新。
  private var cache: [String: RemoteDirectoryCache] = [:]

  // MARK: - 视图状态

  private(set) var state: RemoteFilesState = .idle
  /// 当前可见行。右键菜单在动作扩展里，需要读到它。
  private(set) var rows: [RemoteDirectoryEntry] = []
  private var query = ""
  private var showHidden = false
  private var directoriesFirst = true

  /// 表格与菜单需要被同模块的动作扩展访问，因此保持 internal。
  let table = NSTableView()
  private let pathLabel = makeLabel("", size: 11, monospaced: true)
  private let truncationLabel = makeLabel("", size: 10, color: AsterTheme.tertiaryInk)
  private let messageStack = NSStackView()
  let banner = RemoteIntegrationBanner()
  private weak var upButton: NSButton?
  private weak var searchField: NSSearchField?
  private weak var hiddenButton: NSButton?
  private weak var sortButton: NSButton?

  // MARK: - 生命周期

  init(
    client: RemoteInspectionClient,
    onCommitted: @escaping @MainActor () -> Void,
    prefillCommand: @escaping @MainActor (String) -> Void,
    notify: @escaping @MainActor (String) -> Void
  ) {
    self.client = client
    self.onCommitted = onCommitted
    self.prefillCommand = prefillCommand
    self.notify = notify
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    listTask?.cancel()
    debounceTask?.cancel()
    graceTask?.cancel()
    transferTask?.cancel()
  }

  override func loadView() {
    let root = RemoteFilesDropView()
    root.identifier = NSUserInterfaceItemIdentifier("details-remote-files")
    root.onDrop = { [weak self] urls, row in self?.handleDrop(urls: urls, row: row) }
    root.rowAtPoint = { [weak self] point in self?.dropRow(at: point) }

    let up = IconHoverButton(symbol: "arrow.up", accessibilityDescription: L("返回上级")) {
      [weak self] in self?.navigateToParent()
    }
    up.identifier = NSUserInterfaceItemIdentifier("details-remote-files-up")
    up.toolTip = L("返回上级")
    upButton = up
    pathLabel.lineBreakMode = .byTruncatingHead
    let pathRow = NSStackView(views: [up, pathLabel])
    pathRow.orientation = .horizontal
    pathRow.alignment = .centerY
    pathRow.spacing = 6

    let search = NSSearchField()
    search.placeholderString = "Find"
    search.target = self
    search.action = #selector(searchChanged)
    search.sendsSearchStringImmediately = true
    search.sendsWholeSearchString = false
    searchField = search
    let sort = ActionButton(symbol: "arrow.up.arrow.down", bezelStyle: .accessoryBarAction) {
      [weak self] in
      guard let self else { return }
      self.directoriesFirst.toggle()
      self.rebuildRows()
    }
    sort.isBordered = false
    sortButton = sort
    let hidden = ActionButton(symbol: "eye.slash", bezelStyle: .accessoryBarAction) { [weak self] in
      guard let self else { return }
      // 隐藏项由远端一次性全量下发，切换开关只改本地过滤，不重跑远端脚本。
      self.showHidden.toggle()
      self.updateToolbarButtons()
      self.rebuildRows()
    }
    hidden.isBordered = false
    hidden.identifier = NSUserInterfaceItemIdentifier("details-remote-files-show-hidden")
    hiddenButton = hidden
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let toolbar = NSStackView(views: [search, spacer, sort, hidden])
    toolbar.orientation = .horizontal
    toolbar.alignment = .centerY
    toolbar.spacing = 6
    search.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

    table.identifier = NSUserInterfaceItemIdentifier("details-remote-files-table")
    table.headerView = nil
    table.backgroundColor = .clear
    table.style = .plain
    table.rowHeight = 24
    table.intercellSpacing = .zero
    table.selectionHighlightStyle = .none
    table.dataSource = self
    table.delegate = self
    let menu = NSMenu()
    menu.delegate = self
    table.menu = menu
    if table.tableColumns.isEmpty {
      let column = NSTableColumn(
        identifier: NSUserInterfaceItemIdentifier("details-remote-files-name"))
      column.resizingMask = .autoresizingMask
      table.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = table

    messageStack.orientation = .vertical
    messageStack.alignment = .leading
    messageStack.spacing = 8
    messageStack.isHidden = true

    let column = NSStackView(views: [pathRow, toolbar, truncationLabel, messageStack, scroll])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 6
    column.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 0, right: 8)
    column.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      column.topAnchor.constraint(equalTo: root.topAnchor),
      column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    for arranged in [pathRow, toolbar, truncationLabel, messageStack, scroll] as [NSView] {
      arranged.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16).isActive = true
    }
    view = root
    updateToolbarButtons()
    applyState()
  }

  // MARK: - 激活与挂起

  /// 主控制器在「远端模式 + Files 页可见」时调用。宿主换了通道就重置整页状态，
  /// 只是目录变化则保留当前列表，走一次去抖刷新。
  func activate(host newHost: RemoteInspectionHost) {
    let previous = host
    host = newHost
    isActive = true
    loadViewIfNeeded()
    if previous?.addressesSameChannel(as: newHost) != true {
      generation &+= 1
      listTask?.cancel()
      debounceTask?.cancel()
      rows = []
      activeDirectory = nil
      requestedDirectory = nil
      state = .idle
      table.reloadData()
    }
    if let directory = newHost.workingDirectory?.path {
      graceTask?.cancel()
      graceTask = nil
      requestListing(directory)
      return
    }
    // 受管终端可以用监控脚本的 `[cwd]` 段兜底；场景 A 只能等远端集成上报。
    startAwaitingIntegration()
  }

  /// 切页、切 Pane、收起面板都会调用：推进 generation 并取消全部在途工作，
  /// 保证面板收起后不留任何轮询或传输任务。
  func suspend() {
    isActive = false
    generation &+= 1
    listTask?.cancel()
    listTask = nil
    debounceTask?.cancel()
    debounceTask = nil
    graceTask?.cancel()
    graceTask = nil
  }

  // MARK: - 请求

  /// 目录请求统一入口：先出缓存帧，再 300ms 去抖发真实请求。
  ///
  /// 去抖是必需的：远端 `cd` 连续触发 OSC 7 时，不去抖会为每一次中间目录都开一次
  /// ssh exec，用户只会看到最后一个目录，中间的全是浪费。
  private func requestListing(_ directory: String) {
    guard let host else { return }
    requestedDirectory = directory
    if let cached = cache[host.channelKey]?.listing(for: directory) {
      commit(listing: cached, requestKey: directory, cacheIt: false)
    } else {
      state = .loading(directory)
      applyState()
    }
    debounceTask?.cancel()
    debounceTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(300))
      } catch {
        return
      }
      guard let self, !Task.isCancelled, self.isActive else { return }
      self.startListing(directory)
    }
  }

  private func startListing(_ directory: String) {
    guard let host else { return }
    listTask?.cancel()
    generation &+= 1
    let identity = RemoteInspectionRequestIdentity(
      tabID: host.tabID,
      paneID: host.paneID,
      channelKey: host.channelKey,
      directory: directory,
      generation: generation
    )
    let context = host.context
    let client = client
    listTask = Task { @MainActor [weak self] in
      let result = await client.listDirectory(context, directory)
      guard let self, !Task.isCancelled, self.matches(identity) else { return }
      switch result {
      case .success(let listing):
        self.commit(listing: listing, requestKey: directory, cacheIt: true)
      case .failure(let failure):
        self.state = .failed(failure, directory)
        self.applyState()
        self.onCommitted()
      }
    }
  }

  /// 结果提交前的身份校验：Tab、Pane、通道、目录、序号全等才写界面。
  private func matches(_ identity: RemoteInspectionRequestIdentity) -> Bool {
    guard let host else { return false }
    return host.tabID == identity.tabID && host.paneID == identity.paneID
      && host.channelKey == identity.channelKey && requestedDirectory == identity.directory
      && generation == identity.generation
  }

  /// 提交一份列表。
  ///
  /// `requestKey` 是发起请求时用的目录参数，可能是空串（远端登录目录），与远端解析出的
  /// `listing.directory` 不同。缓存按 `requestKey` 存：后续同一次请求才命中得了，
  /// 否则「浏览 $HOME」这类请求会永远缓存未命中。
  private func commit(listing: RemoteDirectoryListing, requestKey: String, cacheIt: Bool) {
    if cacheIt, let key = host?.channelKey {
      cache[key, default: RemoteDirectoryCache()].store(listing, for: requestKey)
    }
    activeDirectory = listing.directory
    listingSequence &+= 1
    state = .listed(listing)
    rebuildRows()
    applyState()
    onCommitted()
  }

  /// 远端还没上报目录：先给 1.5 秒宽限，避免登录过程中横幅闪一下。
  /// 受管终端在宽限期内用监控脚本的 `[cwd]` 段兜底，拿到就直接列目录。
  private func startAwaitingIntegration() {
    guard graceTask == nil, let host else { return }
    let sequenceAtStart = listingSequence
    graceTask = Task { @MainActor [weak self] in
      // 受管终端能从监控脚本的 `[cwd]` 段读到远端 Shell 的真实目录；场景 A 没有这条路，
      // 只能等远端集成上报，所以先给 1.5 秒宽限，避免登录过程中横幅闪一下。
      if case .managed(_, _, let pid) = host.context, let pid {
        let result = await self?.client.monitor(host.context, pid)
        guard let self, !Task.isCancelled, self.host?.addressesSameChannel(as: host) == true else {
          return
        }
        // 只当初始目录用，不回写 session：受管终端的权威 cwd 仍由服务端状态负责。
        if case .success(let snapshot) = result, let cwd = snapshot.cwd, !cwd.isEmpty {
          self.graceTask = nil
          self.requestListing(cwd)
          return
        }
      } else {
        do {
          try await Task.sleep(for: .milliseconds(1_500))
        } catch {
          return
        }
      }
      guard let self, !Task.isCancelled, self.isActive, self.host?.workingDirectory == nil else {
        return
      }
      self.graceTask = nil
      // 只有「这一轮宽限期内新提交的列表」才免横幅；停留在上一次连接的旧列表不算。
      if self.listingSequence != sequenceAtStart { return }
      self.state = .awaitingIntegration
      self.applyState()
      self.onCommitted()
    }
  }

  /// 重新读取当前目录（Retry、传输完成后刷新都走它）。
  func reloadCurrentDirectory() {
    guard let directory = requestedDirectory ?? activeDirectory else { return }
    requestedDirectory = directory
    startListing(directory)
  }

  // MARK: - 导航

  private func navigateToParent() {
    guard let directory = activeDirectory, directory != "/" else { return }
    let parent = (directory as NSString).deletingLastPathComponent
    requestListing(parent.isEmpty ? "/" : parent)
  }

  /// 进入子目录。名字有损解码的条目一律拒绝：那个名字回传远端已经不是原来的文件。
  func enter(_ entry: RemoteDirectoryEntry) {
    guard entry.isNavigable, let directory = activeDirectory else { return }
    requestListing(remotePath(directory: directory, name: entry.name))
  }

  /// 拼远端绝对路径。只做本地字符串拼接，拼完仍作为位置参数传给远端脚本。
  func remotePath(directory: String, name: String) -> String {
    directory.hasSuffix("/") ? "\(directory)\(name)" : "\(directory)/\(name)"
  }

  // MARK: - 渲染

  private func rebuildRows() {
    guard case .listed(let listing) = state else {
      rows = []
      table.reloadData()
      return
    }
    var entries = listing.entries
    if !showHidden { entries.removeAll { $0.isHidden } }
    if !query.isEmpty { entries.removeAll { !$0.name.localizedCaseInsensitiveContains(query) } }
    entries.sort { lhs, rhs in
      if directoriesFirst, lhs.targetIsDirectory != rhs.targetIsDirectory {
        return lhs.targetIsDirectory
      }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    rows = entries
    table.reloadData()
  }

  private func applyState() {
    guard isViewLoaded else { return }
    let label = host?.context.displayLabel ?? ""
    pathLabel.stringValue = activeDirectory.map { "\(label) · \($0)" } ?? label
    upButton?.isEnabled = (activeDirectory.map { $0 != "/" } ?? false)
    truncationLabel.isHidden = true
    banner.setStatus("")
    // 只有列表就绪时才接收拖入：未知目录下落盘等于往不确定的地方写文件。
    if case .listed = state {
      (view as? RemoteFilesDropView)?.acceptsDrops = true
    } else {
      (view as? RemoteFilesDropView)?.acceptsDrops = false
    }

    for subview in messageStack.arrangedSubviews { subview.removeFromSuperview() }
    switch state {
    case .idle:
      messageStack.isHidden = true
    case .awaitingIntegration:
      // 还没拿到本次连接的目录上报，旧列表与旧路径都不能再展示：它们属于上一条会话，
      // 留着会让用户以为看到的是当前远端的内容。
      if !rows.isEmpty {
        rows = []
        table.reloadData()
      }
      activeDirectory = nil
      requestedDirectory = nil
      pathLabel.stringValue = label
      upButton?.isEnabled = false
      configureBanner()
      messageStack.addArrangedSubview(banner)
      messageStack.isHidden = false
    case .loading:
      messageStack.addArrangedSubview(
        makeLabel(L("正在读取远端目录…"), size: 11, color: AsterTheme.secondaryInk))
      messageStack.isHidden = false
    case .transferring(let text):
      messageStack.addArrangedSubview(makeLabel(text, size: 11, color: AsterTheme.secondaryInk))
      messageStack.isHidden = false
    case .failed(let failure, _):
      populateFailure(failure)
      messageStack.isHidden = false
    case .listed(let listing):
      messageStack.isHidden = true
      if listing.isTruncated {
        truncationLabel.stringValue = L(
          "已显示 \(String(listing.entries.count)) / \(String(listing.totalCount)) 项，已截断")
        truncationLabel.isHidden = false
      }
      if rows.isEmpty {
        messageStack.addArrangedSubview(
          makeLabel(L("目录为空。"), size: 11, color: AsterTheme.secondaryInk))
        messageStack.isHidden = false
      }
    }
  }

  private func populateFailure(_ failure: RemoteInspectionFailure) {
    messageStack.addArrangedSubview(
      makeLabel(failure.message, size: 11, color: AsterTheme.secondaryInk))
    let actions = NSStackView()
    actions.orientation = .horizontal
    actions.spacing = 6
    switch failure {
    case .directoryMissing, .directoryNotReadable:
      actions.addArrangedSubview(
        ActionButton(title: L("返回上级"), bezelStyle: .rounded) { [weak self] in
          self?.navigateToParent()
        })
      actions.addArrangedSubview(
        ActionButton(title: L("浏览 $HOME"), bezelStyle: .rounded) { [weak self] in
          self?.requestListing("")
        })
    case .authenticationRequired:
      break
    default:
      let retry = ActionButton(title: L("重试"), bezelStyle: .rounded) { [weak self] in
        self?.reloadCurrentDirectory()
      }
      retry.identifier = NSUserInterfaceItemIdentifier("details-remote-files-retry")
      actions.addArrangedSubview(retry)
    }
    if !actions.arrangedSubviews.isEmpty { messageStack.addArrangedSubview(actions) }
  }

  private func updateToolbarButtons() {
    let hiddenTitle = showHidden ? L("不包含隐藏文件") : L("包含隐藏文件")
    hiddenButton?.image = NSImage(
      systemSymbolName: showHidden ? "eye" : "eye.slash", accessibilityDescription: hiddenTitle)
    hiddenButton?.toolTip = hiddenTitle
    sortButton?.toolTip = directoriesFirst
      ? L("目录优先（点击切换为按名称）") : L("按名称（点击切换为目录优先）")
  }

  @objc private func searchChanged() {
    query = searchField?.stringValue ?? ""
    rebuildRows()
    applyState()
  }

  // MARK: - 表格

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard rows.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("details-remote-file-row")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? RemoteFileRowView
      ?? RemoteFileRowView(identifier: identifier)
    let entry = rows[row]
    cell.configure(entry: entry) { [weak self] in self?.enter(entry) }
    return cell
  }

  /// 拖入命中的行：只有目录行才把文件放进它的子目录。
  func dropRow(at point: NSPoint) -> Int? {
    guard isViewLoaded else { return nil }
    let local = table.convert(point, from: nil)
    let row = table.row(at: local)
    guard rows.indices.contains(row), rows[row].isNavigable else { return nil }
    return row
  }

  /// 拖入目标目录：命中目录行则是该子目录，否则是当前目录。
  func dropDirectory(for row: Int?) -> String? {
    guard let directory = activeDirectory else { return nil }
    guard let row, rows.indices.contains(row) else { return directory }
    return remotePath(directory: directory, name: rows[row].name)
  }

  /// 传输状态与提示统一走这里，保证进度文案和刷新时机一致。
  func setTransferring(_ text: String?) {
    if let text {
      state = .transferring(text)
    } else if let listing = cachedCurrentListing() {
      state = .listed(listing)
    }
    applyState()
  }

  func showNotice(_ text: String) { notify(text) }

  /// 把命令预填到当前 Pane 的终端输入行；只预填，不回车。
  func prefillTerminal(_ command: String) { prefillCommand(command) }

  /// 打开一个远端目录。横幅与右键菜单的公共入口。
  func openDirectory(_ path: String) { requestListing(path) }

  private func cachedCurrentListing() -> RemoteDirectoryListing? {
    guard let key = host?.channelKey, let directory = requestedDirectory else { return nil }
    return cache[key]?.listing(for: directory)
  }
}

/// 单条通道的目录 LRU 缓存。
///
/// 容量固定 32 项：远端目录列表可能有两千条记录，无上限缓存会把长会话的内存吃掉；
/// 32 项足够覆盖一次正常的来回浏览。
struct RemoteDirectoryCache {
  private static let capacity = 32

  private var entries: [String: RemoteDirectoryListing] = [:]
  /// 访问顺序，末尾最新。
  private var order: [String] = []

  mutating func store(_ listing: RemoteDirectoryListing, for key: String) {
    entries[key] = listing
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > Self.capacity, let oldest = order.first {
      order.removeFirst()
      entries.removeValue(forKey: oldest)
    }
  }

  func listing(for directory: String) -> RemoteDirectoryListing? { entries[directory] }
}
