//
//  TerminalOptions.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 2/29/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

/// Configuration option for the desired cursor style, this style can also be overwritten by the application
/// inside the terminal, and the UI control can choose to honor this request.
public enum CursorStyle {
    case blinkBlock
    case steadyBlock
    case blinkHollowBlock
    case steadyHollowBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar
    
    public static func from (string: String) -> CursorStyle? {
        switch string {
        case "blinkBlock":
            return .blinkBlock
        case "steadyBlock":
            return .steadyBlock
        case "blinkHollowBlock":
            return .blinkHollowBlock
        case "steadyHollowBlock":
            return .steadyHollowBlock
        case "blinkUnderline":
            return .blinkUnderline
        case "steadyUnderline":
            return .steadyUnderline
        case "blinkBar":
            return .blinkBar
        case "steadyBar":
            return .steadyBar
        default:
            return nil
        }
    }
}

/// Width to assign to individual (unpaired) Regional Indicator symbols (U+1F1E6–U+1F1FF).
/// Combined flag pairs (e.g. 🇺🇸) are always rendered as width 2 regardless of this setting.
public enum RegionalIndicatorWidth: Sendable {
    /// Width 2: matches kitty, Ghostty, iTerm2, and the Python wcwidth >= 0.5.2 library.
    /// This is the default and preserves SwiftTerm's existing behavior.
    case wide
    /// Width 1: matches system wcwidth() on macOS/Linux, Alacritty, WezTerm, Windows Terminal,
    /// and the Unicode East Asian Width property (Neutral). Use this when running inside tmux
    /// or other multiplexers that use wcwidth() for cursor positioning.
    case narrow
}

/// Unicode blocks whose East-Asian-Ambiguous characters should occupy two terminal cells.
///
/// A block policy is deliberately used instead of a global "ambiguous is wide" switch: it
/// matches terminal configuration UIs while limiting cursor-width divergence with remote hosts.
public struct EastAsianAmbiguousWidthBlocks: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let enclosedAlphanumerics = Self(rawValue: 1 << 0)
    public static let numberForms = Self(rawValue: 1 << 1)
    public static let arrows = Self(rawValue: 1 << 2)
    public static let mathematicalOperators = Self(rawValue: 1 << 3)
    public static let miscellaneousTechnical = Self(rawValue: 1 << 4)
    public static let geometricShapes = Self(rawValue: 1 << 5)
    public static let miscellaneousSymbols = Self(rawValue: 1 << 6)
    public static let dingbats = Self(rawValue: 1 << 7)
    public static let all: Self = [
        .enclosedAlphanumerics, .numberForms, .arrows, .mathematicalOperators,
        .miscellaneousTechnical, .geometricShapes, .miscellaneousSymbols, .dingbats,
    ]
}

/// Configuration options for the terminal at startup, these values are only read at startup
public struct TerminalOptions {
    /// Desired number of columns at startup (default 80)
    public var cols: Int
    /// Desired number of rows at startup (default 25)
    public var rows: Int
    /// Controls whether a Line-Feed character will also behave like a carriage return (true) or not (false).  defaults to false)
    public var convertEol: Bool
    /// Desired value for the terminal name, defaults to xterm-color
    public var termName: String
    /// The desired startup cursor style, this merely sets an internal variable, it is the view job to render it
    public var cursorStyle: CursorStyle
    /// Deprecated?   The new accessibility work will make this useless
    public var screenReaderMode: Bool
    /// Size of the scrollback buffer, defaults to 500 lines
    public var scrollback: Int
    /// Default size of the tabs, defaults to 8
    public var tabStopWidth: Int
    /// Whether to report that sixel support is present
    public var enableSixelReported:Bool
    /// Maximum total bytes to keep for kitty image data; defaults to 320MB and is clamped to 4GB.
    public var kittyImageCacheLimitBytes: Int
    /// Strategy used to derive the 256-color palette from the base 16 colors.
    public var ansi256PaletteStrategy: Ansi256PaletteStrategy
    /// Width for individual Regional Indicator symbols. `.wide` (default) preserves existing
    /// behavior. `.narrow` matches system wcwidth() and avoids cursor divergence with tmux.
    public var regionalIndicatorWidth: RegionalIndicatorWidth
    /// Ambiguous-width blocks rendered as two cells. Otty-compatible defaults widen only
    /// enclosed alphanumerics; callers may opt into the remaining blocks independently.
    public var widenedEastAsianAmbiguousBlocks: EastAsianAmbiguousWidthBlocks

    /// Default options
    public static let `default` = TerminalOptions.init(cols: 80,
                                                       rows: 25,
                                                       convertEol: false,
                                                       termName: "xterm-256color",
                                                       cursorStyle: .blinkBlock,
                                                       screenReaderMode: false,
                                                       scrollback: 500,
                                                       tabStopWidth: 8,
                                                       enableSixelReported: true,
                                                       kittyImageCacheLimitBytes: 320 * 1024 * 1024,
                                                       ansi256PaletteStrategy: .base16Lab,
                                                       regionalIndicatorWidth: .wide,
                                                       widenedEastAsianAmbiguousBlocks: [.enclosedAlphanumerics])

  public init(cols: Int = Self.default.cols, rows: Int = Self.default.rows, convertEol: Bool = Self.default.convertEol, termName: String = Self.default.termName, cursorStyle: CursorStyle = Self.default.cursorStyle, screenReaderMode: Bool = Self.default.screenReaderMode, scrollback: Int = Self.default.scrollback, tabStopWidth: Int = Self.default.tabStopWidth,
              enableSixelReported: Bool = Self.default.enableSixelReported, kittyImageCacheLimitBytes: Int = Self.default.kittyImageCacheLimitBytes, ansi256PaletteStrategy: Ansi256PaletteStrategy = Self.default.ansi256PaletteStrategy,
              regionalIndicatorWidth: RegionalIndicatorWidth = Self.default.regionalIndicatorWidth,
              widenedEastAsianAmbiguousBlocks: EastAsianAmbiguousWidthBlocks = Self.default.widenedEastAsianAmbiguousBlocks) {
        self.cols = cols
        self.rows = rows
        self.convertEol = convertEol
        self.termName = termName
        self.cursorStyle = cursorStyle
        self.screenReaderMode = screenReaderMode
        self.scrollback = scrollback
        self.tabStopWidth = tabStopWidth
        self.enableSixelReported = enableSixelReported
        self.kittyImageCacheLimitBytes = kittyImageCacheLimitBytes
        self.ansi256PaletteStrategy = ansi256PaletteStrategy
        self.regionalIndicatorWidth = regionalIndicatorWidth
        self.widenedEastAsianAmbiguousBlocks = widenedEastAsianAmbiguousBlocks
    }
}
