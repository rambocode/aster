import AppKit
import AsterCore
@preconcurrency import GhosttyKit

struct GhosttyHintTarget {
  let text: String
  let label: String
  let source: DetectedTargetSource
  let screenRow: Int
  let column: Int
}

/// Ghostty 的 Vi/Mark/Hint adapter。导航状态机继续复用 AsterCore；本文件只负责把
/// retained-screen row 与稳定 page anchor 转换成 ABI selection，并绘制本地 HUD。
extension GhosttySurfaceView {
  private static var targetExpression: NSRegularExpression? {
    try? NSRegularExpression(
      pattern: #"(?:[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"'`，。；：！？（）【】]+|(?:~|\.{1,2}|/)[^\s<>\"'`]+)"#
    )
  }

  var navigationMode: TerminalNavigationMode { ghosttyPaneModeState.navigationMode }
  var viCursor: TerminalBufferPoint? { ghosttyViEngine?.cursor }
  var hintTargetCount: Int { ghosttyHintTargets.count }

  func consumeObservedPTYRead(_ bytes: [UInt8]) {
    if navigationMode == .hint {
      leaveGhosttyHintMode()
    } else if case .vi = navigationMode {
      // 输出可能裁剪 page 或让 row reflow；当前 ABI 能检测失效但不能无损重映射
      // reflow 后的每个 grapheme，因此安全退出，不让旧端点静默选中另一段内容。
      leaveGhosttyViMode(clearSelection: true)
    }
    // 新输出会改变视口内容，Command 按住期间下划线要合并重扫。
    scheduleLinkUnderlineRefresh()
    onPTYRead?(bytes[...])
  }

  func enterViMode() { beginGhosttyViMode(style: .vi) }
  func enterMarkMode() { beginGhosttyViMode(style: .mark) }

  func openHintMode() {
    guard let info = bufferInfo() else { NSSound.beep(); return }
    let first = Int(clamping: info.viewport_top)
    let last = min(Int(clamping: info.screen_rows), first + Int(info.viewport_rows))
    var candidates: [(String, Int, Int)] = []
    var seen = Set<String>()
    for row in first..<last {
      let mapped = ghosttyCellText(row: row, columns: Int(info.columns))
      guard !mapped.text.isEmpty, let expression = Self.targetExpression else { continue }
      let range = NSRange(mapped.text.startIndex..<mapped.text.endIndex, in: mapped.text)
      for match in expression.matches(in: mapped.text, range: range) {
        guard let swiftRange = Range(match.range, in: mapped.text) else { continue }
        let text = String(mapped.text[swiftRange])
        let characterOffset = mapped.text.distance(from: mapped.text.startIndex, to: swiftRange.lowerBound)
        guard mapped.columns.indices.contains(characterOffset) else { continue }
        let column = mapped.columns[characterOffset]
        let key = "\(row):\(column):\(text)"
        if seen.insert(key).inserted { candidates.append((text, row, column)) }
        if candidates.count >= 26 * 26 { break }
      }
      if candidates.count >= 26 * 26 { break }
    }
    let labels = TerminalHintLabeler.labels(count: candidates.count)
    guard !labels.isEmpty else { NSSound.beep(); return }
    ghosttyHintTargets = zip(candidates, labels).map { candidate, label in
      GhosttyHintTarget(
        text: candidate.0,
        label: label,
        source: .plainText,
        screenRow: candidate.1,
        column: candidate.2
      )
    }
    ghosttyHintMatcher = TerminalHintMatcher(labels: labels)
    ghosttyPaneModeState.enterHintMode()
    onPaneModeActivated?()
    ensureGhosttyModeHUD()
    updateGhosttyModeHUD()
  }

  func toggleViKeyHints() {
    guard case .vi = navigationMode else { return }
    ghosttyShowsViKeyHints.toggle()
    updateGhosttyModeHUD()
  }

  func handleGhosttyViewportChange() {
    if navigationMode == .hint { leaveGhosttyHintMode() }
    updateGhosttyModeHUD()
  }

  func handleGhosttyGeometryChange() {
    guard navigationMode != .normal else { return }
    if navigationMode == .hint {
      leaveGhosttyHintMode()
    } else {
      leaveGhosttyViMode(clearSelection: true)
    }
  }

  func handleGhosttyPaneModeKeyDown(_ event: NSEvent) {
    if event.keyCode == 53 || event.characters?.first == "\u{1B}" {
      if navigationMode == .hint {
        leaveGhosttyHintMode()
      } else {
        leaveGhosttyViMode(clearSelection: true)
      }
      return
    }
    switch navigationMode {
    case .normal:
      return
    case .hint:
      handleGhosttyHintKeyDown(event)
    case .vi:
      if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "/" {
        toggleViKeyHints()
        return
      }
      guard let input = ghosttyViInput(for: event), var engine = ghosttyViEngine,
        let snapshot = ghosttyNavigationSnapshot
      else { return }
      let result = engine.consume(input, in: snapshot)
      ghosttyViEngine = engine
      handleGhosttyViResult(result)
    }
  }

  private func beginGhosttyViMode(style: TerminalViStyle) {
    if navigationMode == .hint { leaveGhosttyHintMode() }
    guard let state = makeGhosttyNavigationSnapshot(), !state.snapshot.lines.isEmpty else {
      NSSound.beep()
      return
    }
    ghosttyNavigationSnapshot = state.snapshot
    ghosttyModeFirstScreenRow = state.firstScreenRow
    ghosttyModeColumns = state.snapshot.columns
    let row = min(
      max(0, Int(clamping: state.info.cursor.screen_row) - state.firstScreenRow),
      state.snapshot.lines.count - 1
    )
    let column = min(Int(state.info.cursor.column), state.snapshot.lastNavigableColumn(at: row))
    ghosttyViEngine = TerminalViEngine(cursor: .init(column: column, row: row))
    ghosttyPaneModeState.enterViMode(style: style)
    onPaneModeActivated?()
    if style == .mark, var engine = ghosttyViEngine {
      _ = engine.consume(.character("v"), in: state.snapshot)
      ghosttyViEngine = engine
    }
    applyGhosttyViSelection()
    ensureGhosttyModeHUD()
    updateGhosttyModeHUD()
  }

  private func makeGhosttyNavigationSnapshot() -> (
    snapshot: TerminalNavigationSnapshot,
    firstScreenRow: Int,
    info: ghostty_aster_buffer_info_s
  )? {
    guard let info = bufferInfo(), info.columns > 0 else { return nil }
    let totalRows = Int(clamping: info.screen_rows)
    let columns = Int(info.columns)
    let maximumRows = min(200_000, max(1, 16_000_000 / max(columns, 1)))
    let first = max(0, totalRows - maximumRows)
    var cellLines: [[Character?]] = []
    cellLines.reserveCapacity(totalRows - first)
    for row in first..<totalRows {
      cellLines.append(ghosttyCells(row: row, columns: columns))
    }
    let viewportLower = min(max(0, Int(clamping: info.viewport_top) - first), cellLines.count)
    let viewportUpper = min(cellLines.count, viewportLower + Int(info.viewport_rows))
    return (
      TerminalNavigationSnapshot(
        cellLines: cellLines,
        columns: columns,
        viewport: viewportLower..<viewportUpper
      ),
      first,
      info
    )
  }

  private func ghosttyCells(row: Int, columns: Int) -> [Character?] {
    guard let surface, columns > 0, row >= 0 else { return [] }
    var cells = Array(repeating: ghostty_aster_cell_s(), count: columns)
    let count = cells.withUnsafeMutableBufferPointer { buffer in
      ghostty_aster_surface_read_cells(surface, UInt64(row), buffer.baseAddress, buffer.count)
    }
    guard count > 0 else { return [] }
    return cells.prefix(count).map { cell in
      guard cell.width > 0, cell.has_text, let scalar = UnicodeScalar(cell.codepoint) else {
        return nil
      }
      return Character(String(scalar))
    }
  }

  private func ghosttyCellText(row: Int, columns: Int) -> (text: String, columns: [Int]) {
    let cells = ghosttyCells(row: row, columns: columns)
    var text = ""
    var mappedColumns: [Int] = []
    for (column, character) in cells.enumerated() {
      guard let character else { continue }
      text.append(character)
      mappedColumns.append(column)
    }
    return (text, mappedColumns)
  }

  private func ghosttyViInput(for event: NSEvent) -> TerminalViInput? {
    switch event.keyCode {
    case 123: return .arrow(.left)
    case 124: return .arrow(.right)
    case 125: return .arrow(.down)
    case 126: return .arrow(.up)
    case 36, 76: return .enter
    default: break
    }
    if let scalar = event.characters?.unicodeScalars.first?.value {
      switch scalar {
      case 0x02: return .controlBackward
      case 0x04: return .controlDown
      case 0x06: return .controlForward
      case 0x15: return .controlUp
      case 0x16: return .controlVisualBlock
      default: break
      }
    }
    guard !event.modifierFlags.contains(.command), let character = event.characters?.first else {
      return nil
    }
    return .character(character)
  }

  private func handleGhosttyViResult(_ result: TerminalViResult) {
    switch result {
    case .updated:
      applyGhosttyViSelection()
      revealGhosttyViCursor()
      updateGhosttyModeHUD()
    case .ignored:
      break
    case .copyAndExit:
      applyGhosttyViSelection()
      if let text = readSelection(), !text.isEmpty {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
      leaveGhosttyViMode(clearSelection: true)
    case .search(let direction):
      onRequestViSearch?(direction)
    case .repeatSearch(let reverse):
      onRepeatViSearch?(reverse)
    case .enterHintMode:
      openHintMode()
    case .exit:
      leaveGhosttyViMode(clearSelection: true)
    }
  }

  private func applyGhosttyViSelection() {
    guard let selection = ghosttyViEngine?.selection else {
      if let surface { ghostty_aster_surface_clear_selection(surface) }
      return
    }
    let anchor = selection.anchor
    let focus = selection.focus
    let startPoint: TerminalBufferPoint
    let endPoint: TerminalBufferPoint
    let rectangle: Bool
    switch selection.kind {
    case .character:
      startPoint = anchor
      endPoint = focus
      rectangle = false
    case .line:
      startPoint = .init(column: 0, row: min(anchor.row, focus.row))
      endPoint = .init(column: max(0, ghosttyModeColumns - 1), row: max(anchor.row, focus.row))
      rectangle = false
    case .block:
      startPoint = .init(
        column: min(anchor.column, focus.column), row: min(anchor.row, focus.row))
      endPoint = .init(
        column: max(anchor.column, focus.column), row: max(anchor.row, focus.row))
      rectangle = true
    }
    guard let start = ghosttyPoint(for: startPoint), let end = ghosttyPoint(for: endPoint),
      let surface
    else { return }
    var range = ghostty_aster_buffer_range_s(start: start, end: end, rectangle: rectangle)
    _ = ghostty_aster_surface_set_selection(surface, &range)
  }

  private func ghosttyPoint(for point: TerminalBufferPoint) -> ghostty_aster_buffer_point_s? {
    guard let surface else { return nil }
    let row = ghosttyModeFirstScreenRow + point.row
    guard row >= 0 else { return nil }
    var result = ghostty_aster_buffer_point_s()
    return ghostty_aster_surface_point_at(
      surface, UInt64(row), UInt32(point.column), &result) ? result : nil
  }

  private func revealGhosttyViCursor() {
    guard let cursor = ghosttyViEngine?.cursor, let info = bufferInfo() else { return }
    let row = ghosttyModeFirstScreenRow + cursor.row
    let firstVisible = Int(clamping: info.viewport_top)
    let lastVisible = firstVisible + max(0, Int(info.viewport_rows) - 1)
    if row < firstVisible {
      _ = revealScreenRow(row)
    } else if row > lastVisible {
      _ = revealScreenRow(max(0, row - Int(info.viewport_rows) + 1))
    }
  }

  private func handleGhosttyHintKeyDown(_ event: NSEvent) {
    guard !event.modifierFlags.contains(.command), let character = event.characters?.first else {
      return
    }
    switch ghosttyHintMatcher.consume(character, shifted: event.modifierFlags.contains(.shift)) {
    case .pending:
      updateGhosttyModeHUD()
    case .noMatch:
      NSSound.beep()
      updateGhosttyModeHUD()
    case .selected(let index, let copies):
      guard ghosttyHintTargets.indices.contains(index) else { leaveGhosttyHintMode(); return }
      let target = ghosttyHintTargets[index]
      if copies {
        guard let value = onResolveHintCopyTarget?(target.text, target.source) else {
          NSSound.beep()
          leaveGhosttyHintMode()
          return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
      } else {
        onRequestOpenTarget?(target.text, target.source)
      }
      leaveGhosttyHintMode()
    }
  }

  private func leaveGhosttyHintMode() {
    ghosttyHintTargets.removeAll(keepingCapacity: false)
    ghosttyHintMatcher = TerminalHintMatcher(labels: [])
    ghosttyPaneModeState.leaveHintMode()
    updateGhosttyModeHUD()
  }

  private func leaveGhosttyViMode(clearSelection: Bool) {
    ghosttyPaneModeState.leaveNavigationMode()
    ghosttyViEngine = nil
    ghosttyNavigationSnapshot = nil
    if clearSelection, let surface { ghostty_aster_surface_clear_selection(surface) }
    _ = performBindingAction("scroll_to_bottom")
    updateGhosttyModeHUD()
  }

  private func ensureGhosttyModeHUD() {
    guard ghosttyModeHUD.superview !== self else { return }
    ghosttyModeHUD.frame = bounds
    addSubview(ghosttyModeHUD, positioned: .above, relativeTo: nil)
  }

  func layoutGhosttyModeHUD() {
    guard ghosttyModeHUD.superview === self else { return }
    ghosttyModeHUD.frame = bounds
    updateGhosttyModeHUD()
  }

  private func updateGhosttyModeHUD() {
    let pill: String?
    let detail: String?
    var keyHints = false
    switch navigationMode {
    case .normal:
      pill = readOnly ? "READ ONLY" : nil
      detail = nil
    case .hint:
      pill = "HINT"
      detail = ghosttyHintMatcher.prefix.isEmpty ? nil : ghosttyHintMatcher.prefix.uppercased()
    case .vi(let style):
      pill = style == .mark ? "MARK MODE" : "VI MODE"
      detail = ghosttyViEngine?.pendingCount.map(String.init)
      keyHints = ghosttyShowsViKeyHints
    }
    let cursorFrame = ghosttyViEngine.flatMap { ghosttyFrame(for: $0.cursor) }
    let labels = ghosttyHintTargets.compactMap { target -> TerminalPaneModeHUD.HintLabel? in
      guard let frame = ghosttyFrame(screenRow: target.screenRow, column: target.column) else {
        return nil
      }
      return .init(
        text: target.label,
        frame: NSRect(
          x: frame.minX, y: frame.minY,
          width: max(frame.width, CGFloat(target.label.count * 9 + 8)), height: frame.height)
      )
    }
    ghosttyModeHUD.update(
      pillText: pill,
      detail: detail,
      showsKeyHints: keyHints,
      cursorFrame: cursorFrame,
      hints: labels
    )
  }

  private func ghosttyFrame(for point: TerminalBufferPoint) -> NSRect? {
    ghosttyFrame(
      screenRow: ghosttyModeFirstScreenRow + point.row,
      column: point.column
    )
  }

  /// Command 悬停的 Aster 侧预览:普通文字 URL 与本地路径由 `inlineLinkTarget(at:)` 识别；
  /// OSC 8 由 Ghostty 原生 mouse_over_link 上报，原生预览存在时不被 Aster 侧覆盖。
  func updateCommandHoverPreview(with event: NSEvent) {
    // flagsChanged 是键盘事件，locationInWindow 不代表鼠标位置；沿用悬停缓存，
    // 避免松开 Command 后把有效坐标覆盖成窗口原点。
    if event.type != .flagsChanged {
      lastLinkHoverLocation = convert(event.locationInWindow, from: nil)
    }
    linkCommandHeld = event.modifierFlags.contains(.command)
    guard linkCommandHeld else {
      if !linkPreviewIsNative { removeLinkPreview() }
      return
    }
    refreshCommandHoverPreview()
  }

  /// 按最近一次指针位置重新计算 Aster 侧预览；原生 OSC 8 预览仍在显示时保持不动。
  func refreshCommandHoverPreview() {
    guard linkPreviewEnabled, navigationMode == .normal else { return }
    if linkPreviewIsNative, linkPreviewBadge != nil { return }
    guard linkCommandHeld, let location = lastLinkHoverLocation,
      let target = inlineLinkTarget(at: location)
    else {
      if !linkPreviewIsNative { removeLinkPreview() }
      return
    }
    showLinkPreview(target.text, native: false)
  }

  private func ghosttyFrame(screenRow: Int, column: Int) -> NSRect? {
    guard let surface, let info = bufferInfo() else { return nil }
    let row = screenRow - Int(clamping: info.viewport_top)
    let size = ghostty_surface_size(surface)
    guard row >= 0, row < Int(info.viewport_rows), column >= 0, column < Int(info.columns),
      size.cell_width_px > 0, size.cell_height_px > 0
    else { return nil }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let width = CGFloat(size.cell_width_px) / scale
    let height = CGFloat(size.cell_height_px) / scale
    return NSRect(
      x: CGFloat(column) * width,
      y: bounds.maxY - CGFloat(row + 1) * height,
      width: width,
      height: height
    )
  }
}
