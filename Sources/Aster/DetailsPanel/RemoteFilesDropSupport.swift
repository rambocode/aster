// 远端 Files 页的文件动作：右键菜单、拖入上传的视图、上传/下载面板与串行传输编排。

import AppKit
import AsterCore
import Foundation

/// 远端 Files 页的根视图：接收从 Finder 拖进来的文件 URL。
///
/// 只接受普通文件。目录需要递归遍历与远端建树，第一版不做——把目录悄悄拍平或只传
/// 第一层都会让用户拿到一个和本地不一样的结果。
@MainActor
final class RemoteFilesDropView: NSView {
  /// 拖入完成回调，`row` 为命中的表格行（目录行）索引。
  var onDrop: (([URL], Int?) -> Void)?
  /// 由控制器解析拖放点命中的目录行。
  var rowAtPoint: ((NSPoint) -> Int?)?
  /// 当前是否允许接收；非 `listed` 状态下拒绝，避免往未知目录写。
  var acceptsDrops = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { nil }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    acceptsDrops && !fileURLs(from: sender).isEmpty ? .copy : []
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    acceptsDrops && !fileURLs(from: sender).isEmpty ? .copy : []
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let urls = fileURLs(from: sender)
    guard acceptsDrops, !urls.isEmpty else { return false }
    let point = sender.draggingLocation
    onDrop?(urls, rowAtPoint?(point))
    return true
  }

  private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
    return (objects as? [URL]) ?? []
  }
}

// MARK: - 传输编排

extension RemoteFilesSectionController {
  // MARK: - 右键菜单

  func menuWillOpen(_ menu: NSMenu) {
    guard menu === table.menu else { return }
    menu.removeAllItems()
    guard let directory = activeDirectory else { return }
    let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    guard rows.indices.contains(row) else {
      menu.addItem(
        ActionMenuItem(title: L("上传到此目录…")) { [weak self] in
          self?.presentUploadPanel(directory: directory)
        })
      return
    }
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    populateMenu(menu, entry: rows[row], directory: directory)
  }

  private func populateMenu(_ menu: NSMenu, entry: RemoteDirectoryEntry, directory: String) {
    let path = remotePath(directory: directory, name: entry.name)
    if entry.isNavigable {
      menu.addItem(ActionMenuItem(title: L("进入")) { [weak self] in self?.enter(entry) })
      menu.addItem(
        ActionMenuItem(title: L("在终端 cd 过去")) { [weak self] in
          // 只预填，不回车：执行与否由用户决定，与 Git 页所有写操作的规则一致。
          self?.prefillTerminal("cd \(RemoteSSHInvocation.quote(path))")
        })
    }
    if !entry.nameDecodedLossy, entry.kind != .directory {
      menu.addItem(
        ActionMenuItem(title: L("下载到…")) { [weak self] in
          self?.presentDownloadPanel(entry: entry, remotePath: path)
        })
    }
    menu.addItem(ActionMenuItem(title: L("复制路径")) { [weak self] in self?.copy(path) })
    menu.addItem(ActionMenuItem(title: L("复制相对路径")) { [weak self] in self?.copy(entry.name) })
    menu.addItem(
      ActionMenuItem(title: L("上传到此目录…")) { [weak self] in
        guard let self else { return }
        self.presentUploadPanel(
          directory: entry.isNavigable ? path : directory)
      })
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    let copied = NSPasteboard.general.setString(text, forType: .string)
    showNotice(copied ? L("已复制远端路径。") : L("无法复制远端路径。"))
  }

  /// 单个文件上传上限。
  static var maximumUploadBytes: Int64 { 512 * 1_024 * 1_024 }
  /// 一次最多上传的文件个数。
  static var maximumUploadCount: Int { 20 }
  /// 超过这个个数就先确认。
  static var uploadConfirmCount: Int { 5 }
  /// 超过这个总量就先确认。
  static var uploadConfirmBytes: Int64 { 50 * 1_024 * 1_024 }

  /// 拖入上传。目标目录：命中目录行则是该子目录，否则是当前目录。
  func handleDrop(urls: [URL], row: Int?) {
    guard let directory = dropDirectory(for: row) else { return }
    beginUpload(urls: urls, directory: directory)
  }

  /// 「上传到此目录…」：选普通文件，不允许选目录。
  func presentUploadPanel(directory: String) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.prompt = L("上传")
    guard panel.runModal() == .OK else { return }
    beginUpload(urls: panel.urls, directory: directory)
  }

  /// 「下载到…」：默认文件名剥掉路径分隔符与 `..`，远端名字绝不能决定本地写到哪。
  func presentDownloadPanel(entry: RemoteDirectoryEntry, remotePath: String) {
    guard !entry.nameDecodedLossy else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = Self.sanitizedDownloadName(entry.name)
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let localURL = panel.url else { return }
    beginDownload(remotePath: remotePath, localURL: localURL, displayName: entry.name)
  }

  /// 把远端文件名收敛成安全的本地文件名。
  static func sanitizedDownloadName(_ name: String) -> String {
    let flattened = name
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return "download" }
    return trimmed
  }

  // MARK: 上传

  private func beginUpload(urls: [URL], directory: String) {
    guard transferTask == nil, let host else { return }
    let files = Self.regularFiles(in: urls)
    guard !files.isEmpty else {
      showNotice(L("只能上传普通文件"))
      return
    }
    guard files.count <= Self.maximumUploadCount else {
      showNotice(L("一次最多上传 \(String(Self.maximumUploadCount)) 个文件"))
      return
    }
    if let oversize = files.first(where: { $0.size > Self.maximumUploadBytes }) {
      showNotice(
        L(
          "单个文件超过 \(RemoteInspectionFormat.bytes(Self.maximumUploadBytes)) 上限：\(oversize.url.lastPathComponent)"
        ))
      return
    }
    let total = files.reduce(Int64(0)) { $0 + $1.size }
    if files.count > Self.uploadConfirmCount || total > Self.uploadConfirmBytes {
      guard confirmUpload(count: files.count, bytes: total, directory: directory) else { return }
    }
    runUpload(files: files, directory: directory, host: host)
  }

  /// 串行上传：并行会让远端同时出现多个 staging 文件，失败清理与进度都说不清。
  private func runUpload(files: [UploadCandidate], directory: String, host: RemoteInspectionHost) {
    let client = client
    transferTask = Task { @MainActor [weak self] in
      defer { self?.transferTask = nil }
      for (index, file) in files.enumerated() {
        guard let self, self.host?.addressesSameChannel(as: host) == true else { return }
        let name = file.url.lastPathComponent
        self.setTransferring(
          L("正在上传 \(name)（\(String(index + 1))/\(String(files.count))）"))
        let remotePath = self.remotePath(directory: directory, name: name)
        if await client.fileExists(host.context, remotePath) {
          guard self.confirmOverwrite(name: name) else { continue }
        }
        let result = await client.upload(host.context, file.url, directory, name)
        guard self.host?.addressesSameChannel(as: host) == true else { return }
        if case .failure(let failure) = result {
          self.setTransferring(nil)
          self.showNotice(L("上传失败：\(failure.message)"))
          return
        }
      }
      guard let self else { return }
      self.setTransferring(nil)
      self.showNotice(L("上传完成"))
      self.reloadCurrentDirectory()
    }
  }

  private func confirmUpload(count: Int, bytes: Int64, directory: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = L("上传到此目录…")
    alert.informativeText = L(
      "即将上传 \(String(count)) 个文件（共 \(RemoteInspectionFormat.bytes(bytes))）到 \(directory)")
    alert.addButton(withTitle: L("上传"))
    alert.addButton(withTitle: L("取消"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func confirmOverwrite(name: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = L("远端已存在同名文件")
    alert.informativeText = L("覆盖 \(name)？")
    alert.addButton(withTitle: L("覆盖"))
    alert.addButton(withTitle: L("跳过"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: 下载

  private func beginDownload(remotePath: String, localURL: URL, displayName: String) {
    guard transferTask == nil, let host else { return }
    let client = client
    setTransferring(L("正在下载 \(displayName)"))
    transferTask = Task { @MainActor [weak self] in
      defer { self?.transferTask = nil }
      let result = await client.download(host.context, remotePath, localURL)
      guard let self, self.host?.addressesSameChannel(as: host) == true else { return }
      self.setTransferring(nil)
      switch result {
      case .success:
        self.showNotice(L("下载完成：\(localURL.lastPathComponent)"))
      case .failure(let failure):
        self.showNotice(L("下载失败：\(failure.message)"))
      }
    }
  }

  // MARK: 候选文件

  /// 一个待上传文件及其大小。
  struct UploadCandidate {
    let url: URL
    let size: Int64
  }

  /// 过滤出普通文件并读出大小；目录、符号链接、特殊文件全部丢弃。
  static func regularFiles(in urls: [URL]) -> [UploadCandidate] {
    urls.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true
      else { return nil }
      return UploadCandidate(url: url, size: Int64(values.fileSize ?? 0))
    }
  }
}
