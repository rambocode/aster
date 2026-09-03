import AppKit
import AsterCore
@preconcurrency import GhosttyKit

/// 视口内一个可点击目标在终端网格上的位置：`screenRow` 为 retained-screen 行号，
/// 列区间为闭区间，已含宽字符占用的第二列。
struct GhosttyInlineLinkTarget: Equatable {
  let text: String
  let screenRow: Int
  let startColumn: Int
  let endColumn: Int
}

/// Ghostty 引擎下 Aster 侧的链接识别：Command 按下时给视口内所有 URL 与本地路径画
/// 下划线，悬停时显示预览与手形指针，Command 点击交给 `TerminalTargetOpenCoordinator`。
///
/// Ghostty 原生的 `link-url` 已关闭（见 `GhosttyConfiguration`），普通文字 URL 与路径
/// 只有这一条通道；OSC 8 显式链接仍由 Ghostty 原生处理，原生 open_url / mouse_over_link
/// 经主队列异步回流，因此这里的点击与预览都要避让原生来源。
extension GhosttySurfaceView {
  /// Command 点击允许的按下/抬起位移，超过视为拖拽选区而不是点击。
  private static let commandClickSlop: CGFloat = 4

  // MARK: - 状态入口

  /// Command 修饰键状态变化：按下即扫描视口画线，松开清除。
  func handleCommandModifierChange(pressed: Bool) {
    linkCommandHeld = pressed
    if pressed {
      activateLinkUnderlines()
    } else {
      deactivateLinkUnderlines()
    }
  }

  /// 鼠标移动：带 Command 时保证下划线已激活并刷新悬停指针，否则清理残留状态。
  func handleLinkHoverMouseMoved(with event: NSEvent) {
    lastLinkHoverLocation = convert(event.locationInWindow, from: nil)
    linkCommandHeld = event.modifierFlags.contains(.command)
    if linkCommandHeld {
      if !linkUnderlinesActive { activateLinkUnderlines() }
    } else if linkUnderlinesActive {
      deactivateLinkUnderlines()
    }
    updateLinkHoverCursor()
  }

  /// 指针离开 surface：下划线与手形指针一起撤掉，避免另一个 Pane 接管时残留。
  func handleLinkHoverMouseExited() {
    lastLinkHoverLocation = nil
    deactivateLinkUnderlines()
  }

  /// 视口内容变化（输出、滚动、尺寸）时的合并刷新；Command 已松开则顺手清除。
  func scheduleLinkUnderlineRefresh() {
    guard linkUnderlinesActive, !linkUnderlineRefreshScheduled else { return }
    linkUnderlineRefreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.linkUnderlineRefreshScheduled = false
      guard self.linkUnderlinesActive, self.linkCommandHeld else {
        self.deactivateLinkUnderlines()
        return
      }
      self.refreshLinkUnderlines()
      self.updateLinkHoverCursor()
    }
  }

  /// 工作目录变化后相对路径的存在性可能翻转，缓存必须作废。
  func invalidateLinkTargetCache() {
    linkPathExistenceCache.removeAll(keepingCapacity: true)
    scheduleLinkUnderlineRefresh()
  }

  // MARK: - Command 点击

  /// 记录 Command 点击的按下位置；抬起时位移超过阈值视为选区拖拽。
  func beginCommandClickTracking(with event: NSEvent) {
    guard event.modifierFlags.contains(.command), navigationMode == .normal else {
      commandClickOrigin = nil
      return
    }
    commandClickOrigin = convert(event.locationInWindow, from: nil)
  }

  /// Command 抬起：命中 Aster 侧目标则打开。原生 OSC 8 的 open_url 会先一步进入主队列，
  /// 因此把打开动作也排到主队列之后，并用序号确认原生没有刚打开过同一次点击。
  func finishCommandClick(with event: NSEvent) {
    defer { commandClickOrigin = nil }
    guard let origin = commandClickOrigin, event.modifierFlags.contains(.command),
      navigationMode == .normal, linkDetectionEnabled
    else { return }
    let local = convert(event.locationInWindow, from: nil)
    guard abs(local.x - origin.x) <= Self.commandClickSlop,
      abs(local.y - origin.y) <= Self.commandClickSlop,
      let target = inlineLinkTarget(at: local)
    else { return }
    let sequence = nativeOpenURLSequence
    DispatchQueue.main.async { [weak self] in
      guard let self, self.nativeOpenURLSequence == sequence else { return }
      self.onRequestOpenTarget?(target.text, .plainText)
    }
  }

  // MARK: - 悬停命中

  /// 返回覆盖视图坐标处单元格的目标文本（已通过 scheme 策略与路径存在性校验）。
  func inlineLinkTarget(at local: NSPoint) -> GhosttyInlineLinkTarget? {
    guard linkDetectionEnabled, bounds.contains(local), let info = bufferInfo(),
      let metrics = cellMetrics()
    else { return nil }
    let rowInViewport = Int((bounds.maxY - local.y) / metrics.height)
    let column = Int(local.x / metrics.width)
    guard rowInViewport >= 0, rowInViewport < Int(info.viewport_rows),
      column >= 0, column < Int(info.columns)
    else { return nil }
    let screenRow = Int(clamping: info.viewport_top) + rowInViewport
    return inlineLinkTargets(screenRow: screenRow, columns: Int(info.columns))
      .first { column >= $0.startColumn && column <= $0.endColumn }
  }

  /// 扫描一行并把候选映射回终端列；路径按当前目录做存在性校验，URL 按 scheme 策略过滤。
  private func inlineLinkTargets(screenRow: Int, columns: Int) -> [GhosttyInlineLinkTarget] {
    let row = inlineLinkRowText(screenRow: screenRow, columns: columns)
    guard !row.text.isEmpty else { return [] }
    var targets: [GhosttyInlineLinkTarget] = []
    for candidate in TerminalInlineTargetScanner.candidates(in: row.text) {
      guard isAcceptedLinkCandidate(candidate) else { continue }
      let lower = candidate.range.lowerBound
      let upper = candidate.range.upperBound - 1
      guard lower < row.columns.count, upper < row.columns.count, upper >= lower else { continue }
      targets.append(
        .init(
          text: candidate.text,
          screenRow: screenRow,
          startColumn: row.columns[lower],
          endColumn: row.columns[upper] + max(row.widths[upper], 1) - 1
        ))
    }
    return targets
  }

  private func isAcceptedLinkCandidate(_ candidate: InlineTargetCandidate) -> Bool {
    switch candidate.kind {
    case .url(let scheme):
      return linkSchemePolicy.detects(scheme)
    case .path:
      if let cached = linkPathExistenceCache[candidate.text] { return cached }
      let exists = linkPathValidator?(candidate.text) ?? false
      // 有界缓存：Command 按住期间同一行会被反复扫描，避免每次输出都重新 stat。
      if linkPathExistenceCache.count >= 4_096 { linkPathExistenceCache.removeAll() }
      linkPathExistenceCache[candidate.text] = exists
      return exists
    }
  }

  /// 读取一行的可见文本及每个字符的起始列与宽度；空单元格被跳过，因此下标只对文本有效。
  private func inlineLinkRowText(screenRow: Int, columns: Int)
    -> (text: String, columns: [Int], widths: [Int])
  {
    guard let surface, columns > 0, screenRow >= 0 else { return ("", [], []) }
    var cells = Array(repeating: ghostty_aster_cell_s(), count: columns)
    let count = cells.withUnsafeMutableBufferPointer { buffer in
      ghostty_aster_surface_read_cells(surface, UInt64(screenRow), buffer.baseAddress, buffer.count)
    }
    guard count > 0 else { return ("", [], []) }
    var text = ""
    var mappedColumns: [Int] = []
    var widths: [Int] = []
    for (column, cell) in cells.prefix(count).enumerated() {
      guard cell.width > 0, cell.has_text, let scalar = UnicodeScalar(cell.codepoint) else {
        continue
      }
      text.unicodeScalars.append(scalar)
      mappedColumns.append(column)
      widths.append(Int(cell.width))
    }
    // 组合字符会把多个 scalar 合并成一个 Character，列映射按 Character 对齐后再返回。
    if text.count != mappedColumns.count {
      var alignedColumns: [Int] = []
      var alignedWidths: [Int] = []
      var scalarIndex = 0
      for character in text {
        alignedColumns.append(mappedColumns[scalarIndex])
        alignedWidths.append(widths[scalarIndex])
        scalarIndex += character.unicodeScalars.count
      }
      return (text, alignedColumns, alignedWidths)
    }
    return (text, mappedColumns, widths)
  }

  // MARK: - 下划线绘制

  private func activateLinkUnderlines() {
    guard linkDetectionEnabled, navigationMode == .normal else { return }
    linkUnderlinesActive = true
    refreshLinkUnderlines()
  }

  private func deactivateLinkUnderlines() {
    linkUnderlinesActive = false
    linkPathExistenceCache.removeAll(keepingCapacity: true)
    linkUnderlineOverlay?.update(segments: [])
    updateLinkHoverCursor()
  }

  /// 扫描整个视口并重绘下划线。
  private func refreshLinkUnderlines() {
    guard linkUnderlinesActive, let info = bufferInfo(), let metrics = cellMetrics() else {
      linkUnderlineOverlay?.update(segments: [])
      return
    }
    let first = Int(clamping: info.viewport_top)
    let last = min(Int(clamping: info.screen_rows), first + Int(info.viewport_rows))
    var segments: [NSRect] = []
    for screenRow in first..<last {
      for target in inlineLinkTargets(screenRow: screenRow, columns: Int(info.columns)) {
        let row = screenRow - first
        segments.append(
          NSRect(
            x: CGFloat(target.startColumn) * metrics.width,
            y: bounds.maxY - CGFloat(row + 1) * metrics.height,
            width: CGFloat(target.endColumn - target.startColumn + 1) * metrics.width,
            height: metrics.height
          ))
      }
    }
    let overlay = ensureLinkUnderlineOverlay()
    overlay.frame = bounds
    overlay.update(segments: segments)
  }

  private func ensureLinkUnderlineOverlay() -> GhosttyLinkUnderlineOverlay {
    if let overlay = linkUnderlineOverlay { return overlay }
    let overlay = GhosttyLinkUnderlineOverlay(frame: bounds)
    overlay.autoresizingMask = [.width, .height]
    overlay.lineColor = linkUnderlineColor
    addSubview(overlay, positioned: .below, relativeTo: linkPreviewBadge)
    linkUnderlineOverlay = overlay
    return overlay
  }

  /// 主题更新后同步下划线颜色。
  func applyLinkUnderlineColor() {
    linkUnderlineOverlay?.lineColor = linkUnderlineColor
  }

  // MARK: - 指针

  /// Command 悬停在目标上时显示手形；离开后恢复 Ghostty 最近一次要求的指针形状。
  private func updateLinkHoverCursor() {
    let hovering: Bool
    if linkUnderlinesActive, let location = lastLinkHoverLocation,
      inlineLinkTarget(at: location) != nil
    {
      hovering = true
    } else {
      hovering = false
    }
    guard hovering != linkHoverCursorActive else { return }
    linkHoverCursorActive = hovering
    if hovering {
      NSCursor.pointingHand.set()
    } else {
      applyMouseShape(lastGhosttyMouseShape)
    }
  }

  // MARK: - 几何

  private func cellMetrics() -> (width: CGFloat, height: CGFloat)? {
    guard let surface else { return nil }
    let size = ghostty_surface_size(surface)
    guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    return (CGFloat(size.cell_width_px) / scale, CGFloat(size.cell_height_px) / scale)
  }
}

/// 下划线覆盖层：不参与命中测试，只按单元格矩形在底边画一条实线。
final class GhosttyLinkUnderlineOverlay: NSView {
  /// 下划线距单元格底边的抬升量与粗细（pt）。
  private static let baselineInset: CGFloat = 1.5
  private static let thickness: CGFloat = 1

  var lineColor: NSColor = .textColor {
    didSet { needsDisplay = true }
  }
  private(set) var segments: [NSRect] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    // 与预览徽章同理：CAMetalLayer 是手工挂在 backing layer 上的同级 sublayer，
    // 必须抬高 zPosition 才能画在终端画面之上。
    layer?.zPosition = 900
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(segments: [NSRect]) {
    self.segments = segments
    isHidden = segments.isEmpty
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !segments.isEmpty else { return }
    lineColor.setFill()
    for segment in segments {
      let line = NSRect(
        x: segment.minX,
        y: segment.minY + Self.baselineInset,
        width: segment.width,
        height: Self.thickness
      )
      guard line.intersects(dirtyRect) else { continue }
      line.fill()
    }
  }
}
