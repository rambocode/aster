import Foundation

/// Pane 内互斥的键盘导航模式。Read-only 是独立锁，进入临时模式时不会被清除。
public enum TerminalNavigationMode: Equatable, Sendable {
  case normal
  case vi(TerminalViStyle)
  case hint
}

public enum TerminalViStyle: Equatable, Sendable {
  case vi
  case mark
}

public enum TerminalPaneInputDecision: Equatable, Sendable {
  case forwardToProcess
  case consumeLocally
  case rejectWithFeedback
}

/// 统一决定所有用户输入是否能到达 PTY，避免粘贴、IME 或鼠标报告绕过只读锁。
public struct TerminalPaneModeState: Equatable, Sendable {
  public private(set) var navigationMode = TerminalNavigationMode.normal
  public private(set) var readOnly = false
  private var modeBeforeHint = TerminalNavigationMode.normal

  public init() {}

  public var inputDecision: TerminalPaneInputDecision {
    if navigationMode != .normal { return .consumeLocally }
    return readOnly ? .rejectWithFeedback : .forwardToProcess
  }

  public var showsReadOnlyIndicator: Bool {
    readOnly && navigationMode == .normal
  }

  public mutating func toggleReadOnly() {
    readOnly.toggle()
  }

  public mutating func setReadOnly(_ value: Bool) {
    readOnly = value
  }

  public mutating func enterViMode(style: TerminalViStyle) {
    navigationMode = .vi(style)
  }

  public mutating func enterHintMode() {
    modeBeforeHint = navigationMode
    navigationMode = .hint
  }

  public mutating func leaveHintMode() {
    guard navigationMode == .hint else { return }
    navigationMode = modeBeforeHint == .hint ? .normal : modeBeforeHint
    modeBeforeHint = .normal
  }

  public mutating func leaveNavigationMode() {
    navigationMode = .normal
    modeBeforeHint = .normal
  }
}

/// Hint Mode 使用固定键位顺序；目标多于 26 个时全部改用两字符，保证标签无前缀歧义。
public enum TerminalHintLabeler {
  private static let alphabet = Array("asdfghjklqwertyuiopzxcvbnm")

  public static func labels(count: Int) -> [String] {
    guard count > 0 else { return [] }
    if count <= alphabet.count {
      return alphabet.prefix(count).map(String.init)
    }
    let maximum = alphabet.count * alphabet.count
    return (0..<min(count, maximum)).map { index in
      String(alphabet[index / alphabet.count]) + String(alphabet[index % alphabet.count])
    }
  }
}

public enum TerminalHintMatchResult: Equatable, Sendable {
  case pending(prefix: String)
  case selected(index: Int, copies: Bool)
  case noMatch
}

/// 逐键匹配无前缀歧义的 Hint 标签。只有命中标签的最后一键带 Shift 才进入复制动作。
public struct TerminalHintMatcher: Equatable, Sendable {
  public let labels: [String]
  public private(set) var prefix = ""

  public init(labels: [String]) {
    self.labels = labels
  }

  public mutating func consume(_ character: Character, shifted: Bool) -> TerminalHintMatchResult {
    let candidate = prefix + String(character).lowercased()
    let possible = labels.enumerated().filter { $0.element.hasPrefix(candidate) }
    guard !possible.isEmpty else {
      prefix = ""
      return .noMatch
    }
    if let exact = possible.first(where: { $0.element == candidate }) {
      prefix = ""
      return .selected(index: exact.offset, copies: shifted)
    }
    prefix = candidate
    return .pending(prefix: candidate)
  }
}

/// Vi 导航只读取逻辑文本快照，不持有终端 Buffer 或 AppKit 对象。
public struct TerminalNavigationSnapshot: Equatable, Sendable {
  public let lines: [String]
  public let columns: Int
  public let viewport: Range<Int>
  /// 每个元素对应一个终端 cell；宽字符的后续占位 cell 为 nil，普通空白仍为 " "。
  private let cellLines: [[Character?]]

  public init(lines: [String], columns: Int, viewport: Range<Int>) {
    let normalizedColumns = max(1, columns)
    self.columns = normalizedColumns
    self.lines = lines
    cellLines = lines.map { line in
      Array(line.prefix(normalizedColumns)).map(Optional.some)
    }
    let lower = min(max(0, viewport.lowerBound), lines.count)
    let upper = min(max(lower, viewport.upperBound), lines.count)
    self.viewport = lower..<upper
  }

  /// 使用终端 cell 真值构建快照；该入口让宽字符、组合字符和普通空 cell 不会把字符
  /// 索引误当成网格列。每行可省略末尾未使用 cell。
  public init(cellLines: [[Character?]], columns: Int, viewport: Range<Int>) {
    let normalizedColumns = max(1, columns)
    let normalizedCellLines = cellLines.map { Array($0.prefix(normalizedColumns)) }
    self.columns = normalizedColumns
    self.cellLines = normalizedCellLines
    lines = normalizedCellLines.map { cells in String(cells.compactMap { $0 }) }
    let lower = min(max(0, viewport.lowerBound), cellLines.count)
    let upper = min(max(lower, viewport.upperBound), cellLines.count)
    self.viewport = lower..<upper
  }

  fileprivate func cells(at row: Int) -> [Character?] {
    guard cellLines.indices.contains(row) else { return [] }
    return cellLines[row]
  }

  fileprivate func lastContentColumn(at row: Int) -> Int {
    let cells = cells(at: row)
    return cells.indices.reversed().first(where: { cells[$0] != nil }) ?? 0
  }

  fileprivate func firstNonBlankColumn(at row: Int) -> Int {
    let cells = cells(at: row)
    return min(cells.firstIndex(where: { $0.map { !$0.isWhitespace } == true }) ?? 0, columns - 1)
  }

  public func lastNavigableColumn(at row: Int) -> Int {
    lastContentColumn(at: row)
  }
}

/// 活动终端 Buffer 内的逻辑网格位置。与 Shell Integration 的单调绝对行号不同，
/// scrollback 被裁剪后这里的 row 会重新从 0 开始，以便直接映射 SwiftTerm 选区。
public struct TerminalBufferPoint: Equatable, Sendable {
  public let column: Int
  public let row: Int

  public init(column: Int, row: Int) {
    self.column = max(0, column)
    self.row = max(0, row)
  }
}

public enum TerminalViSelectionKind: Equatable, Sendable {
  case character
  case line
  case block
}

public struct TerminalViSelection: Equatable, Sendable {
  public let kind: TerminalViSelectionKind
  public let anchor: TerminalBufferPoint
  public let focus: TerminalBufferPoint

  public init(kind: TerminalViSelectionKind, anchor: TerminalBufferPoint, focus: TerminalBufferPoint) {
    self.kind = kind
    self.anchor = anchor
    self.focus = focus
  }
}

public enum TerminalViSearchDirection: Equatable, Sendable {
  case forward
  case backward
}

public enum TerminalNavigationDirection: Equatable, Sendable {
  case left
  case right
  case up
  case down
}

public enum TerminalViInput: Equatable, Sendable {
  case character(Character)
  case arrow(TerminalNavigationDirection)
  case controlUp
  case controlDown
  case controlBackward
  case controlForward
  case controlVisualBlock
  case escape
  case enter
}

public enum TerminalViResult: Equatable, Sendable {
  case updated
  case ignored
  case copyAndExit
  case search(TerminalViSearchDirection)
  case repeatSearch(reverse: Bool)
  case enterHintMode
  case exit
}

/// Vi/Mark Mode 的纯状态机。位置使用终端逻辑网格坐标，复制仍由 SwiftTerm 从原始
/// Buffer 产生，因此视觉导航不会改写 PTY 字节或 Unicode 文本顺序。
public struct TerminalViEngine: Equatable, Sendable {
  public private(set) var cursor: TerminalBufferPoint
  public private(set) var selection: TerminalViSelection?
  public private(set) var pendingCount: Int?
  private var countDigits = ""
  private var awaitsSecondG = false

  public init(cursor: TerminalBufferPoint) {
    self.cursor = cursor
  }

  public mutating func consume(
    _ input: TerminalViInput,
    in snapshot: TerminalNavigationSnapshot
  ) -> TerminalViResult {
    guard !snapshot.lines.isEmpty else {
      return input == .escape ? .exit : .ignored
    }
    clampCursor(to: snapshot)

    switch input {
    case .escape:
      resetPrefix()
      return .exit
    case .enter:
      resetPrefix()
      return selection == nil ? .exit : .copyAndExit
    case .controlVisualBlock:
      toggleSelection(.block)
      resetPrefix()
      return .updated
    case .controlUp:
      awaitsSecondG = false
      moveRows(-max(1, snapshot.viewport.count / 2) * consumeCount(), snapshot: snapshot)
      return finishMotion()
    case .controlDown:
      awaitsSecondG = false
      moveRows(max(1, snapshot.viewport.count / 2) * consumeCount(), snapshot: snapshot)
      return finishMotion()
    case .controlBackward:
      awaitsSecondG = false
      moveRows(-max(1, snapshot.viewport.count) * consumeCount(), snapshot: snapshot)
      return finishMotion()
    case .controlForward:
      awaitsSecondG = false
      moveRows(max(1, snapshot.viewport.count) * consumeCount(), snapshot: snapshot)
      return finishMotion()
    case .arrow(let direction):
      awaitsSecondG = false
      move(direction: direction, count: consumeCount(), snapshot: snapshot)
      return finishMotion()
    case .character(let character):
      return consume(character, snapshot: snapshot)
    }
  }

  /// Scrollback 达到上限后，SwiftTerm 会从 Buffer 头部裁剪行。Vi 坐标必须同步左移，
  /// 否则光标会无声跳到另一段文本；已经被裁掉的端点安全夹到最早保留行。
  public mutating func rebaseAfterDroppingLines(
    _ count: Int,
    in snapshot: TerminalNavigationSnapshot
  ) -> Bool {
    guard count > 0 else { return true }
    guard !snapshot.lines.isEmpty, cursor.row >= count else { return false }
    if let selection,
      selection.anchor.row < count || selection.focus.row < count
    {
      // 任一选区端点已消失时没有无损重映射；调用方必须退出，不能把它夹到新首行。
      return false
    }
    func rebased(_ point: TerminalBufferPoint) -> TerminalBufferPoint {
      TerminalBufferPoint(column: point.column, row: point.row - count)
    }
    cursor = rebased(cursor)
    if let selection {
      self.selection = TerminalViSelection(
        kind: selection.kind,
        anchor: rebased(selection.anchor),
        focus: rebased(selection.focus)
      )
    }
    clampCursor(to: snapshot)
    updateSelectionFocus()
    return true
  }

  private mutating func consume(
    _ character: Character,
    snapshot: TerminalNavigationSnapshot
  ) -> TerminalViResult {
    if character.isNumber, let digit = character.wholeNumberValue,
      digit != 0 || !countDigits.isEmpty
    {
      if countDigits.count < 4 { countDigits.append(character) }
      pendingCount = Int(countDigits)
      awaitsSecondG = false
      return .updated
    }

    if awaitsSecondG {
      awaitsSecondG = false
      if character == "g" {
        let targetRow = min(pendingCount.map { max(0, $0 - 1) } ?? 0, snapshot.lines.count - 1)
        cursor = TerminalBufferPoint(
          column: min(cursor.column, snapshot.lastContentColumn(at: targetRow)),
          row: targetRow
        )
        resetPrefix()
        updateSelectionFocus()
        return .updated
      }
      resetPrefix()
    }

    switch character {
    case "h":
      move(direction: .left, count: consumeCount(), snapshot: snapshot)
      return finishMotion()
    case "j":
      move(direction: .down, count: consumeCount(), snapshot: snapshot)
      return finishMotion()
    case "k":
      move(direction: .up, count: consumeCount(), snapshot: snapshot)
      return finishMotion()
    case "l":
      move(direction: .right, count: consumeCount(), snapshot: snapshot)
      return finishMotion()
    case "w":
      let count = consumeCount()
      for _ in 0..<count { moveWordForward(snapshot: snapshot) }
      return finishMotion()
    case "b":
      let count = consumeCount()
      for _ in 0..<count { moveWordBackward(snapshot: snapshot) }
      return finishMotion()
    case "e":
      let count = consumeCount()
      for _ in 0..<count { moveWordEnd(snapshot: snapshot) }
      return finishMotion()
    case "0":
      cursor = TerminalBufferPoint(column: 0, row: cursor.row)
      resetPrefix()
      return finishMotion()
    case "$":
      cursor = TerminalBufferPoint(
        column: snapshot.lastContentColumn(at: cursor.row), row: cursor.row)
      resetPrefix()
      return finishMotion()
    case "^":
      cursor = TerminalBufferPoint(
        column: snapshot.firstNonBlankColumn(at: cursor.row), row: cursor.row)
      resetPrefix()
      return finishMotion()
    case "H":
      cursor = TerminalBufferPoint(column: cursor.column, row: snapshot.viewport.first ?? 0)
      clampColumn(to: snapshot)
      resetPrefix()
      return finishMotion()
    case "M":
      cursor = TerminalBufferPoint(
        column: cursor.column,
        row: snapshot.viewport.isEmpty
          ? 0 : snapshot.viewport.lowerBound + (snapshot.viewport.count - 1) / 2)
      clampColumn(to: snapshot)
      resetPrefix()
      return finishMotion()
    case "L":
      cursor = TerminalBufferPoint(
        column: cursor.column,
        row: max(snapshot.viewport.lowerBound, snapshot.viewport.upperBound - 1))
      clampColumn(to: snapshot)
      resetPrefix()
      return finishMotion()
    case "G":
      let row: Int
      if let count = pendingCount {
        row = min(max(count - 1, 0), snapshot.lines.count - 1)
      } else {
        row = snapshot.lines.count - 1
      }
      cursor = TerminalBufferPoint(column: cursor.column, row: row)
      clampColumn(to: snapshot)
      resetPrefix()
      return finishMotion()
    case "g":
      awaitsSecondG = true
      return .updated
    case "v":
      toggleSelection(.character)
      resetPrefix()
      return .updated
    case "V":
      toggleSelection(.line)
      resetPrefix()
      return .updated
    case "o":
      if let selection {
        cursor = selection.anchor
        self.selection = TerminalViSelection(
          kind: selection.kind, anchor: selection.focus, focus: selection.anchor)
      }
      resetPrefix()
      return .updated
    case "y":
      resetPrefix()
      return selection == nil ? .ignored : .copyAndExit
    case "/":
      resetPrefix()
      return .search(.forward)
    case "?":
      resetPrefix()
      return .search(.backward)
    case "n":
      resetPrefix()
      return .repeatSearch(reverse: false)
    case "N":
      resetPrefix()
      return .repeatSearch(reverse: true)
    case "f":
      resetPrefix()
      return .enterHintMode
    case "q":
      resetPrefix()
      return .exit
    default:
      resetPrefix()
      return .ignored
    }
  }

  private mutating func move(
    direction: TerminalNavigationDirection,
    count: Int,
    snapshot: TerminalNavigationSnapshot
  ) {
    switch direction {
    case .left:
      for _ in 0..<count {
        guard let previous = navigableColumn(
          before: cursor.column, row: cursor.row, snapshot: snapshot
        ) else { break }
        cursor = TerminalBufferPoint(column: previous, row: cursor.row)
      }
    case .right:
      for _ in 0..<count {
        guard let next = navigableColumn(
          after: cursor.column, row: cursor.row, snapshot: snapshot
        ) else { break }
        cursor = TerminalBufferPoint(column: next, row: cursor.row)
      }
    case .up:
      moveRows(-count, snapshot: snapshot)
    case .down:
      moveRows(count, snapshot: snapshot)
    }
  }

  private mutating func moveRows(_ delta: Int, snapshot: TerminalNavigationSnapshot) {
    cursor = TerminalBufferPoint(
      column: cursor.column,
      row: min(max(0, cursor.row + delta), snapshot.lines.count - 1))
    clampColumn(to: snapshot)
  }

  private mutating func moveWordForward(snapshot: TerminalNavigationSnapshot) {
    var position = linearPosition(after: cursor, snapshot: snapshot)
    while let current = position, isWord(character(at: current, snapshot: snapshot)) {
      position = linearPosition(after: current, snapshot: snapshot)
    }
    while let current = position, !isWord(character(at: current, snapshot: snapshot)) {
      position = linearPosition(after: current, snapshot: snapshot)
    }
    if let position { cursor = position }
  }

  private mutating func moveWordBackward(snapshot: TerminalNavigationSnapshot) {
    var position = linearPosition(before: cursor, snapshot: snapshot)
    while let current = position, !isWord(character(at: current, snapshot: snapshot)) {
      position = linearPosition(before: current, snapshot: snapshot)
    }
    while let current = position,
      let previous = linearPosition(before: current, snapshot: snapshot),
      isWord(character(at: previous, snapshot: snapshot))
    {
      position = previous
    }
    if let position { cursor = position }
  }

  private mutating func moveWordEnd(snapshot: TerminalNavigationSnapshot) {
    var position = linearPosition(after: cursor, snapshot: snapshot)
    while let current = position, !isWord(character(at: current, snapshot: snapshot)) {
      position = linearPosition(after: current, snapshot: snapshot)
    }
    while let current = position,
      let next = linearPosition(after: current, snapshot: snapshot),
      isWord(character(at: next, snapshot: snapshot))
    {
      position = next
    }
    if let position { cursor = position }
  }

  private func linearPosition(
    after position: TerminalBufferPoint,
    snapshot: TerminalNavigationSnapshot
  ) -> TerminalBufferPoint? {
    if let next = navigableColumn(after: position.column, row: position.row, snapshot: snapshot) {
      return TerminalBufferPoint(column: next, row: position.row)
    }
    guard position.row + 1 < snapshot.lines.count else { return nil }
    return TerminalBufferPoint(
      column: firstNavigableColumn(row: position.row + 1, snapshot: snapshot),
      row: position.row + 1
    )
  }

  private func linearPosition(
    before position: TerminalBufferPoint,
    snapshot: TerminalNavigationSnapshot
  ) -> TerminalBufferPoint? {
    if let previous = navigableColumn(
      before: position.column, row: position.row, snapshot: snapshot
    ) {
      return TerminalBufferPoint(column: previous, row: position.row)
    }
    guard position.row > 0 else { return nil }
    return TerminalBufferPoint(
      column: snapshot.lastContentColumn(at: position.row - 1), row: position.row - 1)
  }

  private func character(
    at position: TerminalBufferPoint,
    snapshot: TerminalNavigationSnapshot
  ) -> Character? {
    let cells = snapshot.cells(at: position.row)
    return cells.indices.contains(position.column) ? cells[position.column] : nil
  }

  private func firstNavigableColumn(
    row: Int,
    snapshot: TerminalNavigationSnapshot
  ) -> Int {
    let cells = snapshot.cells(at: row)
    return cells.indices.first(where: { cells[$0] != nil }) ?? 0
  }

  private func navigableColumn(
    after column: Int,
    row: Int,
    snapshot: TerminalNavigationSnapshot
  ) -> Int? {
    let cells = snapshot.cells(at: row)
    guard column + 1 < cells.count else { return nil }
    return (column + 1..<cells.count).first(where: { cells[$0] != nil })
  }

  private func navigableColumn(
    before column: Int,
    row: Int,
    snapshot: TerminalNavigationSnapshot
  ) -> Int? {
    let cells = snapshot.cells(at: row)
    guard column > 0, !cells.isEmpty else { return nil }
    return stride(from: min(column - 1, cells.count - 1), through: 0, by: -1)
      .first(where: { cells[$0] != nil })
  }

  private func isWord(_ character: Character?) -> Bool {
    guard let character else { return false }
    return character == "_" || character.isLetter || character.isNumber
  }

  private mutating func toggleSelection(_ kind: TerminalViSelectionKind) {
    if selection?.kind == kind {
      selection = nil
    } else {
      selection = TerminalViSelection(kind: kind, anchor: cursor, focus: cursor)
    }
  }

  private mutating func updateSelectionFocus() {
    guard let selection else { return }
    self.selection = TerminalViSelection(
      kind: selection.kind, anchor: selection.anchor, focus: cursor)
  }

  private mutating func finishMotion() -> TerminalViResult {
    updateSelectionFocus()
    return .updated
  }

  private mutating func consumeCount() -> Int {
    let value = max(1, pendingCount ?? 1)
    countDigits = ""
    pendingCount = nil
    return value
  }

  private mutating func resetPrefix() {
    countDigits = ""
    pendingCount = nil
    awaitsSecondG = false
  }

  private mutating func clampCursor(to snapshot: TerminalNavigationSnapshot) {
    cursor = TerminalBufferPoint(
      column: cursor.column,
      row: min(max(0, cursor.row), snapshot.lines.count - 1))
    clampColumn(to: snapshot)
  }

  private mutating func clampColumn(to snapshot: TerminalNavigationSnapshot) {
    let maximum = snapshot.lastContentColumn(at: cursor.row)
    var column = min(max(0, cursor.column), maximum)
    let cells = snapshot.cells(at: cursor.row)
    while column > 0, cells.indices.contains(column), cells[column] == nil {
      column -= 1
    }
    cursor = TerminalBufferPoint(
      column: column,
      row: cursor.row)
  }

}
