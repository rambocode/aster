//
//  BidirectionalText.swift
//
//  Logical-to-visual terminal cell mapping built from the platform Unicode BiDi shaper.
//

import Foundation
#if canImport(CoreText)
import CoreText
#endif

/// One logical terminal grapheme and the fixed grid span assigned by the parser.
struct TerminalBidirectionalCell: Equatable {
    let text: String
    let logicalColumn: Int
    let width: Int
}

/// A logical cell placed at a visual grid column after Unicode BiDi reordering.
struct TerminalBidirectionalVisualCell: Equatable {
    let cell: TerminalBidirectionalCell
    let visualColumn: Int

    var text: String { cell.text }
    var logicalColumn: Int { cell.logicalColumn }
    var width: Int { cell.width }
}

/// Maps the terminal's immutable logical grid to renderer and pointer visual columns.
///
/// The terminal buffer is never reordered. CoreText is used only to obtain UAX #9 run order;
/// copying, search, escape-sequence processing, and process I/O therefore retain logical order.
struct TerminalBidirectionalMap: Equatable {
    let visualCells: [TerminalBidirectionalVisualCell]
    private let logicalToVisual: [Int]
    private let visualToLogical: [Int]

    static func identity(cells: [TerminalBidirectionalCell], columnCount: Int) -> Self {
        makeMap(orderedCells: cells, columnCount: columnCount)
    }

    static func make(cells: [TerminalBidirectionalCell], columnCount: Int) -> Self {
        guard columnCount > 0, !cells.isEmpty else {
            return makeMap(orderedCells: cells, columnCount: max(0, columnCount))
        }

        #if canImport(CoreText)
        let text = NSMutableString()
        var utf16Ranges: [Range<Int>] = []
        utf16Ranges.reserveCapacity(cells.count)
        for cell in cells {
            let start = text.length
            text.append(cell.text.isEmpty ? " " : cell.text)
            utf16Ranges.append(start..<text.length)
        }

        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let attributed = NSAttributedString(
            string: text as String,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        var orderedIndices: [Int] = []
        var seen: Set<Int> = []

        // CoreText returns runs in visual order. A run's string range remains logical, so RTL
        // runs are traversed backwards while LTR runs stay forwards. This also covers ligatures:
        // ordering cells by the run range does not depend on one-glyph-per-character shaping.
        for run in runs {
            let range = CTRunGetStringRange(run)
            guard range.location != kCFNotFound, range.length > 0 else { continue }
            let runRange = range.location..<(range.location + range.length)
            var indices = utf16Ranges.indices.filter { utf16Ranges[$0].overlaps(runRange) }
            if CTRunGetStatus(run).contains(.rightToLeft) {
                indices.reverse()
            }
            for index in indices where seen.insert(index).inserted {
                orderedIndices.append(index)
            }
        }

        // Defensive fallback for controls or malformed shaping output that CoreText omitted.
        for index in cells.indices where seen.insert(index).inserted {
            orderedIndices.append(index)
        }
        return makeMap(orderedCells: orderedIndices.map { cells[$0] }, columnCount: columnCount)
        #else
        return identity(cells: cells, columnCount: columnCount)
        #endif
    }

    func visualColumn(forLogicalColumn column: Int) -> Int {
        guard !logicalToVisual.isEmpty else { return 0 }
        return logicalToVisual[max(0, min(column, logicalToVisual.count - 1))]
    }

    func logicalColumn(forVisualColumn column: Int) -> Int {
        guard !visualToLogical.isEmpty else { return 0 }
        return visualToLogical[max(0, min(column, visualToLogical.count - 1))]
    }

    /// Returns the logical cell reached by one visual left/right step. Wide-cell continuation
    /// columns resolve to their owning grapheme so one arrow event never lands mid-glyph.
    func logicalColumn(visuallyAdjacentToLogicalColumn column: Int, offset: Int) -> Int {
        guard offset != 0,
              let currentIndex = visualCells.firstIndex(where: {
                  let upper = $0.logicalColumn + max(1, $0.width)
                  return column >= $0.logicalColumn && column < upper
              })
        else { return column }
        let targetIndex = currentIndex + (offset < 0 ? -1 : 1)
        guard visualCells.indices.contains(targetIndex) else { return column }
        return visualCells[targetIndex].logicalColumn
    }

    private static func makeMap(
        orderedCells: [TerminalBidirectionalCell],
        columnCount: Int
    ) -> Self {
        guard columnCount > 0 else {
            return Self(visualCells: [], logicalToVisual: [], visualToLogical: [])
        }
        var logicalToVisual = Array(0..<columnCount)
        var visualToLogical = Array(0..<columnCount)
        var visualCells: [TerminalBidirectionalVisualCell] = []
        var visualColumn = 0

        for cell in orderedCells {
            guard cell.logicalColumn >= 0, cell.logicalColumn < columnCount,
                  visualColumn < columnCount else { continue }
            let logicalCapacity = columnCount - cell.logicalColumn
            let boundedWidth = min(max(1, cell.width), logicalCapacity, columnCount - visualColumn)
            visualCells.append(.init(cell: cell, visualColumn: visualColumn))
            for offset in 0..<boundedWidth {
                let logical = cell.logicalColumn + offset
                logicalToVisual[logical] = visualColumn + offset
                visualToLogical[visualColumn + offset] = logical
            }
            visualColumn += boundedWidth
        }

        return Self(
            visualCells: visualCells,
            logicalToVisual: logicalToVisual,
            visualToLogical: visualToLogical
        )
    }
}
