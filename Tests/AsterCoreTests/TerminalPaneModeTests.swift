import Testing
@testable import AsterCore

@Test func paneModeKeepsReadOnlyLockAcrossTemporaryNavigationModes() {
  var state = TerminalPaneModeState()

  state.toggleReadOnly()
  #expect(state.readOnly)
  #expect(state.inputDecision == .rejectWithFeedback)
  #expect(state.showsReadOnlyIndicator)

  state.enterViMode(style: .vi)
  #expect(state.inputDecision == .consumeLocally)
  #expect(!state.showsReadOnlyIndicator)

  state.enterHintMode()
  #expect(state.inputDecision == .consumeLocally)
  state.leaveHintMode()
  #expect(state.navigationMode == .vi(.vi))

  state.leaveNavigationMode()
  #expect(state.readOnly)
  #expect(state.inputDecision == .rejectWithFeedback)
  #expect(state.showsReadOnlyIndicator)
}

@Test func hintLabelsArePrefixSafeAndShiftCopiesTheResolvedTarget() {
  let short = TerminalHintLabeler.labels(count: 3)
  let long = TerminalHintLabeler.labels(count: 30)
  #expect(short == ["a", "s", "d"])
  #expect(long.count == 30)
  #expect(long.allSatisfy { $0.count == 2 })
  #expect(Set(long).count == long.count)

  var matcher = TerminalHintMatcher(labels: ["aa", "as", "ad"])
  #expect(matcher.consume("a", shifted: false) == .pending(prefix: "a"))
  #expect(matcher.consume("s", shifted: true) == .selected(index: 1, copies: true))
}

@Test func viModeSupportsCountsMotionsAndVisualSelection() {
  let snapshot = TerminalNavigationSnapshot(
    lines: ["alpha beta", "  second", "third"],
    columns: 12,
    viewport: 0..<3
  )
  var engine = TerminalViEngine(cursor: TerminalBufferPoint(column: 0, row: 0))

  #expect(engine.consume(.character("3"), in: snapshot) == .updated)
  #expect(engine.consume(.character("l"), in: snapshot) == .updated)
  #expect(engine.cursor == TerminalBufferPoint(column: 3, row: 0))
  #expect(engine.pendingCount == nil)

  #expect(engine.consume(.character("w"), in: snapshot) == .updated)
  #expect(engine.cursor == TerminalBufferPoint(column: 6, row: 0))
  #expect(engine.consume(.character("v"), in: snapshot) == .updated)
  #expect(engine.consume(.character("j"), in: snapshot) == .updated)
  #expect(engine.selection?.kind == .character)
  #expect(engine.selection?.anchor == TerminalBufferPoint(column: 6, row: 0))
  #expect(engine.selection?.focus == TerminalBufferPoint(column: 6, row: 1))
  #expect(engine.consume(.character("y"), in: snapshot) == .copyAndExit)
}

@Test func viModeCoversLineViewportScrollbackSearchHintAndExitCommands() {
  let snapshot = TerminalNavigationSnapshot(
    lines: ["zero", " one", "two", "three", "four"],
    columns: 10,
    viewport: 1..<4
  )
  var engine = TerminalViEngine(cursor: TerminalBufferPoint(column: 4, row: 2))

  #expect(engine.consume(.character("0"), in: snapshot) == .updated)
  #expect(engine.cursor.column == 0)
  #expect(engine.consume(.character("$"), in: snapshot) == .updated)
  #expect(engine.cursor.column == 2)
  #expect(engine.consume(.character("H"), in: snapshot) == .updated)
  #expect(engine.cursor.row == 1)
  #expect(engine.consume(.character("G"), in: snapshot) == .updated)
  #expect(engine.cursor.row == 4)
  #expect(engine.consume(.character("g"), in: snapshot) == .updated)
  #expect(engine.consume(.character("g"), in: snapshot) == .updated)
  #expect(engine.cursor.row == 0)
  #expect(engine.consume(.character("3"), in: snapshot) == .updated)
  #expect(engine.consume(.character("g"), in: snapshot) == .updated)
  #expect(engine.consume(.character("g"), in: snapshot) == .updated)
  #expect(engine.cursor.row == 2)

  #expect(engine.consume(.character("/"), in: snapshot) == .search(.forward))
  #expect(engine.consume(.character("?"), in: snapshot) == .search(.backward))
  #expect(engine.consume(.character("n"), in: snapshot) == .repeatSearch(reverse: false))
  #expect(engine.consume(.character("N"), in: snapshot) == .repeatSearch(reverse: true))
  #expect(engine.consume(.character("f"), in: snapshot) == .enterHintMode)
  #expect(engine.consume(.escape, in: snapshot) == .exit)
}

@Test func viModeUsesTerminalCellsForWideCharacterMovement() {
  let snapshot = TerminalNavigationSnapshot(
    cellLines: [["你", nil, "a"]],
    columns: 4,
    viewport: 0..<1
  )
  var engine = TerminalViEngine(cursor: TerminalBufferPoint(column: 2, row: 0))

  #expect(engine.consume(.character("h"), in: snapshot) == .updated)
  #expect(engine.cursor.column == 0)
  #expect(engine.consume(.character("l"), in: snapshot) == .updated)
  #expect(engine.cursor.column == 2)
}

@Test func viModeRebasesCursorAndSelectionWhenScrollbackIsTrimmed() {
  let before = TerminalNavigationSnapshot(
    lines: ["zero", "one", "two", "three", "four"],
    columns: 8,
    viewport: 2..<5
  )
  let after = TerminalNavigationSnapshot(
    lines: ["two", "three", "four"],
    columns: 8,
    viewport: 0..<3
  )
  var engine = TerminalViEngine(cursor: TerminalBufferPoint(column: 1, row: 3))
  _ = engine.consume(.character("v"), in: before)
  _ = engine.consume(.character("j"), in: before)

  let didRebase = engine.rebaseAfterDroppingLines(2, in: after)
  #expect(didRebase)

  #expect(engine.cursor == TerminalBufferPoint(column: 1, row: 2))
  #expect(engine.selection?.anchor == TerminalBufferPoint(column: 1, row: 1))
  #expect(engine.selection?.focus == TerminalBufferPoint(column: 1, row: 2))
}

@Test func viModeRejectsRebaseWhenCursorOrSelectionWasTrimmed() {
  let before = TerminalNavigationSnapshot(
    lines: ["zero", "one", "two"], columns: 8, viewport: 0..<3)
  let after = TerminalNavigationSnapshot(
    lines: ["two", "three"], columns: 8, viewport: 0..<2)
  var engine = TerminalViEngine(cursor: TerminalBufferPoint(column: 2, row: 0))
  _ = engine.consume(.character("v"), in: before)

  let didRebase = engine.rebaseAfterDroppingLines(2, in: after)
  #expect(!didRebase)
  #expect(engine.cursor == TerminalBufferPoint(column: 2, row: 0))
}

@Test func viModeCancelsPendingGPrefixWhenAnotherMotionRuns() {
  let snapshot = TerminalNavigationSnapshot(
    lines: ["zero", "one", "two"], columns: 8, viewport: 0..<3)
  var engine = TerminalViEngine(cursor: TerminalBufferPoint(column: 0, row: 1))

  _ = engine.consume(.character("g"), in: snapshot)
  _ = engine.consume(.arrow(.right), in: snapshot)
  _ = engine.consume(.character("g"), in: snapshot)

  #expect(engine.cursor.row == 1)
}
