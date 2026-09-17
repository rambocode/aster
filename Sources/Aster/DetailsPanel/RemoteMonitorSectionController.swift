// 详情面板 Info 页的远端模式：服务器监控的轮询、身份校验与分段渲染。

import AppKit
import AsterCore
import Foundation

/// 远端监控页的状态。
enum RemoteMonitorState: Equatable {
  /// 还没激活。
  case idle
  /// 首次采集中。
  case loading
  /// 已有快照；后续 tick 原地替换，不回到 loading。
  case snapshot(RemoteHostMonitorSnapshot)
  /// 采集失败。
  case failed(RemoteInspectionFailure)
}

/// Info 页远端模式的子控制器。
///
/// 轮询沿用本地 Info 的做法：单次延迟任务自续，而不是常驻 Timer——切 Pane、切页、
/// 收起面板和控制器释放都能走同一套 cancellation，不会留下无主的 RunLoop source。
@MainActor
final class RemoteMonitorSectionController: NSViewController {
  /// 轮询间隔。一个 tick 就是一次 ssh exec，间隔太短会把连接占满。
  static let pollInterval = Duration.seconds(3)

  private let client: RemoteInspectionClient
  private let onCommitted: @MainActor () -> Void

  private(set) var host: RemoteInspectionHost?
  private var generation: UInt64 = 0
  private var isActive = false
  /// 上一个 tick 还没回来就跳过本次，不排队堆积。
  private(set) var isFetching = false
  private var fetchTask: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?

  /// 是否还排着下一次 tick。面板收起后必须为 false，否则隐藏页仍在打远端。
  var hasScheduledPoll: Bool { pollTask != nil }

  /// 按通道保存的上一次 CPU 采样。远端不 sleep，占用率靠相邻两次采样差分，
  /// 因此首个 tick 一定显示「—」，而不是假装是 0%。
  private var previousCPUSamples: [String: RemoteCPUStatSample] = [:]
  private var cpuPercent: Double?
  /// 进程表按 CPU 还是按内存排序。
  private var processesByCPU = true

  private(set) var state: RemoteMonitorState = .idle
  private let contentStack = NSStackView()

  init(client: RemoteInspectionClient, onCommitted: @escaping @MainActor () -> Void) {
    self.client = client
    self.onCommitted = onCommitted
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    fetchTask?.cancel()
    pollTask?.cancel()
  }

  override func loadView() {
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 12
    contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let document = FlippedDocumentView()
    document.addSubview(contentStack)
    let scroll = NSScrollView()
    scroll.identifier = NSUserInterfaceItemIdentifier("details-remote-monitor")
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.hasHorizontalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = document
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
      contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor),
    ])
    view = scroll
    render()
  }

  // MARK: - 激活与挂起

  /// Info 页在远端模式下可见时调用。换通道会清掉快照，但保留该通道的 CPU 采样。
  func activate(host newHost: RemoteInspectionHost) {
    let previous = host
    host = newHost
    isActive = true
    loadViewIfNeeded()
    if previous?.addressesSameChannel(as: newHost) != true {
      generation &+= 1
      fetchTask?.cancel()
      isFetching = false
      cpuPercent = nil
      state = .loading
      render()
    }
    fetch()
  }

  /// 切页、切 Pane、收起面板都会调用：推进 generation 并取消轮询，
  /// 保证面板收起后不留任何在途 tick。
  func suspend() {
    isActive = false
    generation &+= 1
    fetchTask?.cancel()
    fetchTask = nil
    pollTask?.cancel()
    pollTask = nil
    isFetching = false
  }

  // MARK: - 采集

  private func fetch() {
    guard isActive, let host else { return }
    // 上一个 tick 还在路上：跳过本次并继续排下一次，避免慢连接把请求堆成队列。
    guard !isFetching else {
      schedulePoll()
      return
    }
    isFetching = true
    generation &+= 1
    let identity = RemoteInspectionRequestIdentity(
      tabID: host.tabID,
      paneID: host.paneID,
      channelKey: host.channelKey,
      generation: generation
    )
    let pid: Int32? = {
      if case .managed(_, _, let pid) = host.context { return pid }
      return nil
    }()
    let context = host.context
    let client = client
    fetchTask = Task { @MainActor [weak self] in
      let result = await client.monitor(context, pid)
      guard let self else { return }
      self.isFetching = false
      guard !Task.isCancelled, self.matches(identity) else { return }
      switch result {
      case .success(let snapshot):
        self.applySnapshot(snapshot, channelKey: identity.channelKey)
      case .failure(let failure):
        self.state = .failed(failure)
        self.render()
        self.onCommitted()
      }
      self.schedulePoll()
    }
  }

  private func matches(_ identity: RemoteInspectionRequestIdentity) -> Bool {
    guard let host else { return false }
    return host.tabID == identity.tabID && host.paneID == identity.paneID
      && host.channelKey == identity.channelKey && generation == identity.generation
  }

  private func applySnapshot(_ snapshot: RemoteHostMonitorSnapshot, channelKey: String) {
    if let sample = snapshot.cpuSample {
      if let previous = previousCPUSamples[channelKey] {
        cpuPercent = RemoteCPUUsage.compute(previous: previous, current: sample)
      } else {
        cpuPercent = nil
      }
      previousCPUSamples[channelKey] = sample
    }
    state = .snapshot(snapshot)
    render()
    onCommitted()
  }

  private func schedulePoll() {
    pollTask?.cancel()
    guard isActive else { return }
    pollTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.pollInterval)
      } catch {
        return
      }
      guard let self, !Task.isCancelled, self.isActive else { return }
      self.fetch()
    }
  }

  // MARK: - 渲染

  private func render() {
    guard isViewLoaded else { return }
    for subview in contentStack.arrangedSubviews { subview.removeFromSuperview() }
    switch state {
    case .idle:
      break
    case .loading:
      contentStack.addArrangedSubview(
        makeLabel(L("正在读取服务器状态…"), size: 11, color: AsterTheme.secondaryInk))
    case .failed(let failure):
      contentStack.addArrangedSubview(
        makeLabel(failure.message, size: 11, color: AsterTheme.secondaryInk))
      if failure.isRetryable {
        let retry = ActionButton(title: L("重试"), bezelStyle: .rounded) { [weak self] in
          self?.fetch()
        }
        retry.identifier = NSUserInterfaceItemIdentifier("details-remote-monitor-retry")
        contentStack.addArrangedSubview(retry)
      }
    case .snapshot(let snapshot):
      renderSnapshot(snapshot)
    }
  }

  private func renderSnapshot(_ snapshot: RemoteHostMonitorSnapshot) {
    addSection(L("主机")) { stack in
      stack.addArrangedSubview(makeLabel(snapshot.host ?? "—", size: 12))
      if let uname = snapshot.uname {
        stack.addArrangedSubview(makeLabel(uname, size: 11, color: AsterTheme.secondaryInk))
      }
      if let uptime = snapshot.uptimeSeconds {
        stack.addArrangedSubview(
          makeLabel(
            L("运行时长") + "  " + RemoteInspectionFormat.duration(uptime),
            size: 11, color: AsterTheme.secondaryInk))
      }
    }

    addSection(L("负载")) { stack in
      guard let load = snapshot.load else {
        stack.addArrangedSubview(unavailableLabel())
        return
      }
      let text = String(format: "%.2f  %.2f  %.2f", load.one, load.five, load.fifteen)
      stack.addArrangedSubview(makeLabel(text, size: 12, monospaced: true))
      stack.addArrangedSubview(
        makeLabel(
          L("CPU") + "  " + RemoteInspectionFormat.percent(cpuPercent),
          size: 11, color: AsterTheme.secondaryInk))
    }

    addSection(L("内存")) { stack in
      guard let memory = snapshot.memory else {
        stack.addArrangedSubview(unavailableLabel())
        return
      }
      stack.addArrangedSubview(
        usageRow(used: memory.usedKiB, total: memory.totalKiB))
      if let swap = snapshot.swap, swap.totalKiB > 0 {
        stack.addArrangedSubview(makeLabel(L("Swap"), size: 11, color: AsterTheme.tertiaryInk))
        stack.addArrangedSubview(usageRow(used: swap.usedKiB, total: swap.totalKiB))
      }
    }

    addSection(L("磁盘")) { stack in
      guard !snapshot.disks.isEmpty else {
        stack.addArrangedSubview(unavailableLabel())
        return
      }
      for disk in snapshot.disks {
        stack.addArrangedSubview(makeLabel(disk.mount, size: 11))
        stack.addArrangedSubview(usageRow(used: disk.usedKiB, total: disk.sizeKiB))
      }
    }

    addProcessSection(snapshot)
    addPortSection(snapshot)
  }

  private func addProcessSection(_ snapshot: RemoteHostMonitorSnapshot) {
    let title = processesByCPU ? L("进程（按 CPU）") : L("进程（按内存）")
    addSection(title) { stack in
      let toggle = ActionButton(
        title: processesByCPU ? L("按内存排序") : L("按 CPU 排序"),
        bezelStyle: .inline
      ) { [weak self] in
        guard let self else { return }
        self.processesByCPU.toggle()
        self.render()
      }
      toggle.isBordered = false
      toggle.contentTintColor = AsterTheme.accent
      toggle.identifier = NSUserInterfaceItemIdentifier("details-remote-monitor-process-order")
      stack.addArrangedSubview(toggle)
      let processes = processesByCPU ? snapshot.topByCPU : snapshot.topByMemory
      guard !processes.isEmpty else {
        stack.addArrangedSubview(unavailableLabel())
        return
      }
      for process in processes {
        let detail = processesByCPU
          ? String(format: "%.1f%%", process.cpuPercent)
          : RemoteInspectionFormat.kibibytes(process.residentKiB)
        stack.addArrangedSubview(
          makeLabel(
            "\(process.command)  \(String(process.pid))  \(detail)", size: 10.5, monospaced: true))
      }
    }
  }

  private func addPortSection(_ snapshot: RemoteHostMonitorSnapshot) {
    addSection(L("监听端口")) { stack in
      guard !snapshot.listeningPorts.isEmpty else {
        stack.addArrangedSubview(unavailableLabel())
        return
      }
      // 非 root 看不到其他用户的进程，进程列会整片为空；不提示的话会被读成「没人监听」。
      if snapshot.listeningPorts.allSatisfy({ $0.processName == nil }) {
        stack.addArrangedSubview(
          makeLabel(
            L("非 root 用户看不到其他用户的进程"), size: 10.5, color: AsterTheme.tertiaryInk))
      }
      for port in snapshot.listeningPorts {
        let owner = port.processName.map { "\($0)  " } ?? ""
        stack.addArrangedSubview(
          makeLabel(
            "\(owner)\(port.networkProtocol.rawValue)  \(port.address):\(String(port.port))",
            size: 10.5, monospaced: true))
      }
    }
  }

  /// 缺段统一文案。把缺段画成 0 会让用户以为远端真的没有内存或磁盘。
  private func unavailableLabel() -> NSTextField {
    makeLabel(L("此平台不提供该项"), size: 11, color: AsterTheme.tertiaryInk)
  }

  private func addSection(_ title: String, build: (NSStackView) -> Void) {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.addArrangedSubview(
      makeLabel(title, size: 10, weight: .semibold, color: AsterTheme.tertiaryInk))
    build(stack)
    contentStack.addArrangedSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28).isActive = true
  }

  /// 「已用 / 总量」一行加一根占比条。
  private func usageRow(used: UInt64, total: UInt64) -> NSView {
    let ratio = total == 0 ? 0 : min(1, Double(used) / Double(total))
    let label = makeLabel(
      "\(RemoteInspectionFormat.kibibytes(used)) / \(RemoteInspectionFormat.kibibytes(total))",
      size: 11,
      monospaced: true
    )
    let track = NSView()
    track.wantsLayer = true
    track.layer?.cornerRadius = 2
    track.layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.1).cgColor
    let fill = NSView()
    fill.wantsLayer = true
    fill.layer?.cornerRadius = 2
    fill.layer?.backgroundColor = AsterTheme.accent.cgColor
    track.addSubview(fill)
    track.translatesAutoresizingMaskIntoConstraints = false
    fill.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      track.heightAnchor.constraint(equalToConstant: 4),
      fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
      fill.topAnchor.constraint(equalTo: track.topAnchor),
      fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
      fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.001, ratio)),
    ])
    let row = NSStackView(views: [label, track])
    row.orientation = .vertical
    row.alignment = .leading
    row.spacing = 3
    track.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
    return row
  }
}
