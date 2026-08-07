//
//  SelectionService.swift
//  iOS
//
//  Created by Miguel de Icaza on 3/5/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

/**
 * Tracks the selection state in the terminal, the selection is determined by the `active`
 * property, and if that is true, then the `start` and `end` represents offsets within
 * the terminal's buffer.  They are guaranteed to be ordered.
 */
class SelectionService: CustomDebugStringConvertible {
    var terminal: Terminal
    
    public init (terminal: Terminal)
    {
        self.terminal = terminal
        _active = false
        start = Position(col: 0, row: 0)
        end = Position(col: 0, row: 0)
        pivot = Position(col: 0, row: 0)
        hasSelectionRange = false
    }
    
    /**
     * Controls whether the selection is active or not.   Changing the value will invoke the `selectionChanged`
     * method on the terminal's delegate if the state changes.
     */
    var _active: Bool = false
    public var active: Bool {
        get {
            return _active
        }
        set(newValue) {
            if _active != newValue {
                _active = newValue
                terminal.tdel?.selectionChanged (source: terminal)
            }
            if active == false {
                pivot = nil
            }
        }
    }
    
    // This avoids the user visible cache
    func setActiveAndNotify () {
        _active = true
        terminal.tdel?.selectionChanged (source: terminal)
    }

    /**
     * Whether any range is selected
     */
    public private(set) var hasSelectionRange: Bool

    /**
     * Returns the selection starting point in buffer coordinates
     */
    public private(set) var start: Position {
        didSet {
          hasSelectionRange = start != end
        }
    }

    /**
     * Used to track the pivot point when selection in iOS-style selection
     */
    public var pivot: Position?

    /// Keyboard selection keeps an explicit anchor/focus pair so repeatedly crossing the anchor
    /// can collapse and then grow in the opposite direction without losing the original caret.
    private var keyboardAnchor: Position?
    private var keyboardFocus: Position?

    /// Rectangular ranges select the same half-open column interval on every covered row.
    public private(set) var isRectangular = false

    /**
     * When `selectWordOrExpression` seeds a selection (a double-click), the
     * selected range is recorded here so that a subsequent word-mode drag can
     * pivot around the whole seed word.  Without this, dragging *backwards*
     * past the seed word would leave `start` pinned at the seed word's start
     * and the seed word would be dropped from the selection.
     */
    var wordSelectionAnchor: (start: Position, end: Position)?

    /**
     * Returns the selection ending point in buffer coordinates
     */
    public private(set) var end: Position {
        didSet {
          hasSelectionRange = start != end
        }
    }
    
    /// True if the selection spans more than one line
    public var isMultiLine: Bool {
        return start.row != end.row
    }
    
    /**
     * Starts the selection from the specific screen-relative location
     */
    public func startSelection (row: Int, col: Int)
    {
        resetKeyboardSelection(rectangular: false)
        setSoftStart(row: row, col: col)
        selectionMode = .character
        wordSelectionAnchor = nil
        setActiveAndNotify()
    }
        
    func clamp (_ buffer: Buffer, _ p: Position) -> Position {
        let maxRow = max(0, buffer.lines.count - 1)
        return Position(col: min(p.col, buffer.cols - 1), row: min(p.row, maxRow))
    }
    /**
     * Sets the selection, this is validated against the
     */
    public func setSelection (start: Position, end: Position) {
        resetKeyboardSelection(rectangular: false)
        let buffer = terminal.displayBuffer
        let sclamped = clamp (buffer, start)
        let eclamped = clamp (buffer, end)
        
        self.start = sclamped
        self.end = eclamped
        
        setActiveAndNotify()
    }
    
    /**
     * Starts selection, the range is determined by the last start position
     */
    public func startSelection ()
    {
        end = start
        selectingRows = false
        selectionMode = .character
        wordSelectionAnchor = nil
        setActiveAndNotify()
    }
    
    /**
     * Sets the start and end positions but does not start selection
     * this lets us record the last position of mouse clicks so that
     * drag and shift+click operations know from where to start selection
     * from.
     *
     * The location is screen-relative
     */
    public func setSoftStart (row: Int, col: Int) {
        setSoftStart (bufferPosition: Position(col: col, row: row + terminal.displayBuffer.yDisp))
    }
    
    /**
     * Sets the start and end positions but does not start selection
     * this lets us record the last position of mouse clicks so that
     * drag and shift+click operations know from where to start selection
     * from.
     *
     * The locoation is buffer-relative
     */
    public func setSoftStart (bufferPosition: Position) {
        keyboardAnchor = nil
        keyboardFocus = nil
        start = bufferPosition
        end = bufferPosition
        setActiveAndNotify()
    }
    
    /**
     * Extends the selection based on the user "shift" clicking. This has
     * slightly different semantics than a "drag" extension because we can
     * shift the start to be the last prior end point if the new extension
     * is before the current start point.
     *
     * The row is screen-relative
     */
    public func shiftExtend (row: Int, col: Int)
    {
        var newPos = Position  (col: col, row: row + terminal.displayBuffer.yDisp)
        if selectingRows {
            if Position.compare(start, newPos) == .before {
                newPos.col = terminal.cols - 1
            } else {
                newPos.col = 0
            }
        }
        print("SelectinRows=\(selectingRows)")
        shiftExtend (bufferPosition: newPos)
    }
    
    /**
     * Extends the selection based on the user "shift" clicking. This has
     * slightly different semantics than a "drag" extension because we can
     * shift the start to be the last prior end point if the new extension
     * is before the current start point.
     *
     * The bufferPosition is buffer-relative
     */
    public func shiftExtend (bufferPosition newEnd: Position) {
        var adjustedNewEnd = newEnd
        
        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(newEnd, start) == .before ? -1 : 1
            adjustedNewEnd = extendToWordBoundary(position: newEnd, in: terminal.displayBuffer, direction: direction)
        }
        
        var shouldSwapStart = false
        if Position.compare (start, end) == .before {
            // start is before end, is the new end before Start
            if Position.compare (adjustedNewEnd, start) == .before {
                // yes, swap Start and End
                shouldSwapStart = true
            }
        } else if Position.compare (start, end) == .after {
            if Position.compare (adjustedNewEnd, start) == .after {
                // yes, swap Start and End
                shouldSwapStart = true
            }
        }
        if (shouldSwapStart) {
            start = end
        }
        end = adjustedNewEnd
        
        setActiveAndNotify()
    }
    
    /**
     * Implements the iOS selection around the pivot, that is, the handle that is being dragged
     * becomes the pivot point for start/end
     *
     * The row is screen-relative, for buffer relative use the `pivotExtend(bufferPosition:)` overload
     */
    public func pivotExtend (row: Int, col: Int) {
        let newPoint = Position  (col: col, row: row + terminal.displayBuffer.yDisp)

        return pivotExtend(bufferPosition: newPoint)
    }
    
    /**
     * Implements the iOS selection around the pivot, that is, the handle that is being dragged
     * becomes the pivot point for start/end
     *
     * The position is buffer-relative, for screen relative, use `pivotExtend(row:col:)`
     */
    public func pivotExtend (bufferPosition: Position) {
        guard let pivot = pivot else {
            return
        }
        
        var adjustedPosition = bufferPosition
        
        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(bufferPosition, pivot) == .before ? -1 : 1
            adjustedPosition = extendToWordBoundary(position: bufferPosition, in: terminal.displayBuffer, direction: direction)
        }
        
        switch Position.compare (adjustedPosition, pivot) {
        case .after:
            start = pivot
            end = adjustedPosition
        case .before:
            start = adjustedPosition
            end = pivot
        case .equal:
            start = pivot
            end = pivot
        }
        
        setActiveAndNotify()
    }
    
    /**
     * Extends the selection by moving the end point to the new point.
     * The row is in screen coordinates
     */
    public func dragExtend (row: Int, col: Int)
    {
        dragExtend(bufferPosition: Position(col: col, row: row + terminal.displayBuffer.yDisp))
    }
    
    /**
     * Extends the selection by moving the end point to the new point.
     * The position is in buffer coordinates
     */
    public func dragExtend (bufferPosition: Position) {
        // When the selection was seeded by a double-click (word mode), pivot the
        // drag around the whole seed word.  This keeps the seed word in the
        // selection when the drag goes *backwards* (to the left/up) past it, and
        // snaps both ends to word boundaries in either direction.
        if selectionMode == .word, let anchor = wordSelectionAnchor {
            let buffer = terminal.displayBuffer
            if Position.compare(bufferPosition, anchor.start) == .before {
                start = extendToWordBoundary(position: bufferPosition, in: buffer, direction: -1)
                end = anchor.end
            } else if Position.compare(bufferPosition, anchor.end) == .after {
                start = anchor.start
                end = extendToWordBoundary(position: bufferPosition, in: buffer, direction: 1)
            } else {
                // Still inside the seed word: keep the whole word selected.
                start = anchor.start
                end = anchor.end
            }
            setActiveAndNotify()
            return
        }

        var adjustedEnd = bufferPosition

        // If we're in word selection mode, extend to word boundaries
        if selectionMode == .word {
            let direction = Position.compare(bufferPosition, start) == .before ? -1 : 1
            adjustedEnd = extendToWordBoundary(position: bufferPosition, in: terminal.displayBuffer, direction: direction)
        }

        end = adjustedEnd
        setActiveAndNotify()
    }
    
    /**
     * Selects the entire buffer and triggers the selection
     */
    public func selectAll ()
    {
        resetKeyboardSelection(rectangular: false)
        start = Position(col: 0, row: 0)
        end = Position(col: terminal.cols-1, row: terminal.displayBuffer.lines.maxLength - 1)
        setActiveAndNotify()
    }
    
    public var selectingRows: Bool = false
    
    /// Tracks the current selection mode to maintain consistency during extension
    public enum SelectionMode {
        case character
        case word
        case row
    }
    
    public var selectionMode: SelectionMode = .character
    
    /**
     * Selectss the specified row and triggers the selection
     */
    public func select(row: Int)
    {
        resetKeyboardSelection(rectangular: false)
        start = Position(col: 0, row: row)
        end = Position(col: terminal.cols-1, row: row)
        selectingRows = true
        selectionMode = .row
        wordSelectionAnchor = nil
        setActiveAndNotify()
    }

    private func character (at position: Position, in buffer: Buffer) -> Character
    {
        let cell = buffer.getChar (atBufferRelative: position)
        return terminal.getCharacter (for: cell)
    }

    /**
     * Performs a simple "word" selection based on a function that determines inclussion into the group
     */
    func simpleScanSelection (from position: Position, in buffer: Buffer, includeFunc: (Character)-> Bool)
    {
        // Look backward
        var colScan = position.col
        var left = colScan
        while colScan >= 0 {
            let ch = character (at: Position (col: colScan, row: position.row), in: buffer)
            if !includeFunc (ch) {
                break
            }
            left = colScan
            colScan -= 1
        }
        
        // Look forward
        colScan = position.col
        var right = colScan
        let limit = terminal.cols
        while colScan < limit {
            let ch = character (at: Position (col: colScan, row: position.row), in: buffer)
            if !includeFunc (ch) {
                break
            }
            colScan += 1
            right = colScan
        }
        start = Position (col: left, row: position.row)
        end = Position(col: right, row: position.row)
    }
    
    /**
     * Performs a forward search for the `end` character, but this can extend across matching subexpressions
     * made of pais of parenthesis, braces and brackets.
     */
    func balancedSearchForward (from position: Position, in buffer: Buffer)
    {
        var startCol = position.col
        var wait: [Character] = []
        
        start = position
        
        let maxRow = buffer.rows + buffer.yDisp
        if position.row >= maxRow {
            return
        }
        for line in position.row..<maxRow {
            for col in startCol..<terminal.cols {
                let p =  Position(col: col, row: line)
                let ch = character (at: p, in: buffer)
                
                if ch == "(" {
                    wait.append (")")
                } else if ch == "[" {
                    wait.append ("]")
                } else if ch == "{" {
                    wait.append ("}")
                } else if let v = wait.last {
                    if v == ch {
                        wait.removeLast()
                        if wait.count == 0 {
                            end = Position(col: p.col+1, row: p.row)
                            return
                        }
                    }
                }
            }
            startCol = 0
        }
        start = position
        end = position
    }

    /**
     * Performs a forward search for the `end` character, but this can extend across matching subexpressions
     * made of pais of parenthesis, braces and brackets.
     */
    func balancedSearchBackward (from position: Position, in buffer: Buffer)
    {
        var startCol = position.col
        var wait: [Character] = []

        end = position
        
        for line in (0...position.row).reversed() {
            for col in (0...startCol).reversed() {
                let p =  Position(col: col, row: line)
                let ch = character (at: p, in: buffer)
                
                if ch == ")" {
                    wait.append ("(")
                } else if ch == "]" {
                    wait.append ("[")
                } else if ch == "}" {
                    wait.append ("{")
                } else if let v = wait.last {
                    if v == ch {
                        wait.removeLast()
                        if wait.count == 0 {
                            end = Position(col: end.col+1, row: end.row)
                            start = p
                            return
                        }
                    }
                }
            }
            startCol = terminal.cols-1
        }
        start = position
        end = position
    }

    let nullChar = Character(UnicodeScalar(0))
    
    /**
     * Extends a position to the nearest word boundary based on the character at that position
     */
    func extendToWordBoundary(position: Position, in buffer: Buffer, direction: Int) -> Position {
        let ch = character (at: position, in: buffer)
        var includeFunc: (Character) -> Bool
        
        switch ch {
        case Character(UnicodeScalar(0)):
            includeFunc = { ch in ch == Character(UnicodeScalar(0)) }
        case " ":
            includeFunc = { ch in ch == " " }
        case let ch where ch.isLetter || ch.isNumber:
            includeFunc = { ch in ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" }
        default:
            return position
        }
        
        var result = position
        if direction < 0 {
            // Extend backward
            var col = position.col
            while col >= 0 {
                let testCh = character (at: Position(col: col, row: position.row), in: buffer)
                if !includeFunc(testCh) {
                    break
                }
                result.col = col
                col -= 1
            }
        } else {
            // Extend forward
            var col = position.col
            while col < terminal.cols {
                let testCh = character (at: Position(col: col, row: position.row), in: buffer)
                if !includeFunc(testCh) {
                    break
                }
                col += 1
                result.col = col
            }
        }
        
        return result
    }
    /**
     * Implements the behavior to select the word at the specified position or an expression
     * which is a balanced set parenthesis, braces or brackets
     */
    public func selectWordOrExpression (at uncheckedPosition: Position, in buffer: Buffer)
    {
        resetKeyboardSelection(rectangular: false)
//        let position = Position(
//            col: max (min (uncheckedPosition.col, buffer.cols-1), 0),
//            row: max (min (uncheckedPosition.row, buffer.rows-1+buffer.yDisp), buffer.yDisp))
        let position = Position (col: (min (terminal.cols, max (uncheckedPosition.col, 0))),
                                 row: (max (uncheckedPosition.row, 0)))
        switch character (at: position, in: buffer) {
        case Character(UnicodeScalar(0)):
            simpleScanSelection (from: position, in: buffer) { ch in ch == nullChar }
        case " ":
            // Select all white space
            simpleScanSelection (from: position, in: buffer) { ch in ch == " " }
        case let ch where ch.isLetter || ch.isNumber:
            simpleScanSelection (from: position, in: buffer) { ch in ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" }
        case "{":
            fallthrough
        case "(":
            fallthrough
        case "[":
            balancedSearchForward (from: position, in: buffer)
        case ")":
            fallthrough
        case "]":
            fallthrough
        case "}":
            balancedSearchBackward(from: position, in: buffer)
        default:
            // For other characters, we just stop there
            start = position
            end = position
        }
        selectionMode = .word
        wordSelectionAnchor = (start, end)
        setActiveAndNotify()
    }

    /**
     * Clears the selection
     */
    public func selectNone ()
    {
        if active {
            active = false
            selectionMode = .character
            wordSelectionAnchor = nil
        }
        resetKeyboardSelection(rectangular: false)
    }

    /// Marks the next pointer extension as linear or rectangular and detaches it from any prior
    /// keyboard anchor. Pointer selection owns its own pivot through `start` and `end`.
    func preparePointerSelection(rectangular: Bool) {
        resetKeyboardSelection(rectangular: rectangular)
    }

    /// Records the original mouse-down cell without activating a zero-width selection. Dragging
    /// must grow from this cell, not from the first coalesced drag event, which can arrive several
    /// columns away when the pointer moves quickly.
    func beginPointerSelection(at position: Position, rectangular: Bool) {
        resetKeyboardSelection(rectangular: rectangular)
        let clamped = clamp(terminal.displayBuffer, position)
        if _active {
            active = false
        }
        start = clamped
        end = clamped
        selectingRows = false
        selectionMode = .character
        wordSelectionAnchor = nil
    }

    /// Extends a native keyboard selection from the terminal caret. The focus moves in buffer
    /// coordinates; left/right wrap at row boundaries while up/down preserve the column.
    @discardableResult
    func extendFromCursor(
        _ cursor: Position,
        direction: TerminalSelectionDirection,
        rectangular: Bool
    ) -> Bool {
        let buffer = terminal.displayBuffer
        guard !buffer.lines.isEmpty, terminal.cols > 0 else { return false }

        if keyboardAnchor == nil || keyboardFocus == nil {
            let anchor = clampedKeyboardPosition(cursor, buffer: buffer)
            keyboardAnchor = anchor
            keyboardFocus = anchor
        }
        guard let anchor = keyboardAnchor, let focus = keyboardFocus else { return false }

        let next = movedKeyboardPosition(focus, direction: direction, buffer: buffer)
        guard next != focus else { return false }
        keyboardFocus = next
        isRectangular = rectangular
        selectionMode = .character
        wordSelectionAnchor = nil
        start = anchor
        end = next

        if start == end {
            if _active {
                _active = false
                terminal.tdel?.selectionChanged(source: terminal)
            }
        } else {
            setActiveAndNotify()
        }
        return true
    }

    private func resetKeyboardSelection(rectangular: Bool) {
        keyboardAnchor = nil
        keyboardFocus = nil
        isRectangular = rectangular
    }

    private func clampedKeyboardPosition(_ position: Position, buffer: Buffer) -> Position {
        Position(
            col: max(0, min(position.col, terminal.cols - 1)),
            row: max(0, min(position.row, buffer.lines.count - 1))
        )
    }

    private func movedKeyboardPosition(
        _ position: Position,
        direction: TerminalSelectionDirection,
        buffer: Buffer
    ) -> Position {
        switch direction {
        case .left:
            if position.col > 0 {
                return Position(col: position.col - 1, row: position.row)
            }
            guard position.row > 0 else { return position }
            return Position(col: terminal.cols - 1, row: position.row - 1)
        case .right:
            if position.col < terminal.cols - 1 {
                return Position(col: position.col + 1, row: position.row)
            }
            guard position.row < buffer.lines.count - 1 else { return position }
            return Position(col: 0, row: position.row + 1)
        case .up:
            guard position.row > 0 else { return position }
            return Position(col: position.col, row: position.row - 1)
        case .down:
            guard position.row < buffer.lines.count - 1 else { return position }
            return Position(col: position.col, row: position.row + 1)
        }
    }
    
    public func getSelectedText () -> String {
        if isRectangular {
            let buffer = terminal.displayBuffer
            let firstRow = max(0, min(start.row, end.row))
            let lastRow = min(buffer.lines.count - 1, max(start.row, end.row))
            let firstColumn = max(0, min(start.col, end.col))
            let lastColumn = min(terminal.cols, max(start.col, end.col))
            guard firstRow <= lastRow, firstColumn < lastColumn else { return "" }
            return (firstRow...lastRow).map { row in
                buffer.lines[row].translateToString(
                    startCol: firstColumn,
                    endCol: lastColumn,
                    skipNullCellsFollowingWide: true,
                    // Empty terminal cells carry code point zero internally, but clipboard text
                    // must represent their visual value as spaces rather than hidden NUL bytes.
                    characterProvider: { cell in
                        cell.code == 0 ? " " : self.terminal.getCharacter(for: cell)
                    }
                )
            }.joined(separator: "\n")
        }
        let (min, max) = if Position.compare(start, end) == .before {
            (start, end)
        } else {
            (end, start)
        }
        let r = terminal.getDisplayText(start: min, end: max)
        return r
    }
    
    public var debugDescription: String {
        return "[Selection (active=\(active), start=\(start) end=\(end) hasSR=\(hasSelectionRange) pivot=\(pivot?.debugDescription ?? "nil")]"
    }
}
