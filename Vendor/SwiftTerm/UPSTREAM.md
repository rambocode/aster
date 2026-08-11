# SwiftTerm Upstream

Aster vendors the `SwiftTerm` library because the Selection and Scroll feature domains require
small changes inside terminal state that SwiftTerm 1.15 does not expose to host applications.

- Upstream: <https://github.com/migueldeicaza/SwiftTerm>
- Version: `1.15.0`
- Revision: `dd2fb8ac5b861e7bf617c872895e338f38165648`
- License: MIT; see `LICENSE` in this directory.

The imported source was byte-compared with the upstream revision before the first local patch.
Keep Aster-specific changes narrowly commented and covered by tests. When updating, compare the
new upstream tree first, reapply only still-needed patches, run `swift test --no-parallel`, and
record the new version and revision here.

## Aster Patch Surface

- `SelectionService.swift`, `Apple/AppleTerminalView.swift`, and platform views expose keyboard
  anchors, rectangular ranges, configurable clear-on-input behavior, and pointer-selection state.
- `Mac/MacTerminalView.swift` owns precise scroll accumulation, momentum completion, normal-buffer
  overscroll limits, and gesture-locked mouse-reporting/link bypass rules. Its pointer-move and
  wheel entry points are open so Aster's Read-only mode can suppress reports while preserving
  local selection and scrollback; size changes are open so navigation modes can invalidate
  reflowed coordinates. The same host seam accepts a configurable bypass modifier set, tracks the
  physical left/right Option keys for per-side Meta behavior, gates VT100 application-keypad SS3
  encoding, exposes pointer hit positions, and independently enables the URL preview.
- `Apple/AppleTerminalView.swift` and `Apple/Metal/MetalTerminalRenderer.swift` apply the fractional
  viewport translation to Core Graphics and Metal rendering; the iOS view provides the shared API
  with a zero translation.
- `Apple/Metal/MetalTerminalRenderer.swift` resolves the SwiftPM shader bundle from packaged app
  resources and the structured `--test-bundle-path` supplied by SwiftPM's test launcher, without
  touching the generated accessor that can terminate after its build-machine path becomes stale.
  Its bar-cursor geometry also matches the AppKit caret: line spacing expands the grid while the
  visible bar stays at font height and is vertically centered in its cell, so enabling Metal
  cannot make it touch the preceding row or sit low in a prompt.
- `Apple/AppleTerminalView.swift` explicitly requests a frame from the paused Metal view after a
  font change. Invalidating only the parent AppKit view can otherwise update grid metrics without
  presenting glyphs at the new size until later terminal activity.
- `Apple/AppleTerminalView.swift` requests a full Core Graphics corrective redraw when an
  alternate-screen frame ends with protocol/title activity but no dirty grid row. This reconciles
  AppKit's backing store with the final terminal grid so transient TUI spinner/title pixels cannot
  remain beside the restored prompt.
- `Terminal.swift` and `Buffer.swift` expose stable absolute buffer coordinates and an opt-in
  embedder identity used for conservative DA1/DA2 and XTVERSION replies. `Terminal.swift` also
  exposes the active-buffer cursor position used by Vi Mode and distinguishes protocol replies
  from mouse/focus user interaction so Read-only can preserve only the former.
- `EscapeSequenceParser.swift` / `Terminal.swift` add non-consuming OSC observers so Aster can
  mirror progress and notification state without replacing built-in handlers. `Terminal.swift`
  also keeps title reports blank by default, exposes an explicit sanitized opt-in privilege, and
  allows the host to consume OSC 9;4 pause reports without rendering them. The macOS view exposes
  immediate progress clearing for Aster's state 5 completion extension.
- `Apple/AppleTerminalView.swift` exposes a read-only selection range for prompt safety checks;
  `Mac/MacTerminalView.swift` makes `keyDown` open so Aster can consume Backspace only inside a
  verified OSC 133 prompt range. The shared view can also freeze output-following while Vi Mode
  inspects scrollback, then restore the normal follow-only-at-bottom policy.
- `Mac/MacLocalTerminalView.swift` accepts an optional serial PTY callback queue. Aster uses this
  seam to publish raw output through its per-Pane bounded message bus before delivering coalesced,
  read-sized batches to the main-thread terminal grid during the default RunLoop's idle phase;
  Inspector and other AppKit event paths stay independent, including nested tracking loops. `nil`
  preserves upstream main-queue behavior for all other embedders.
- `SelectionService.swift` and `Apple/AppleTerminalView.swift` expose programmatic rectangular
  selections; `Terminal.swift` provides a bounded, deduplicated visible-link enumeration seam for
  Aster's keyboard Hint Mode and a scroll-invariant line range for Vi Mode snapshots. The outer
  `shouldSendUserData(_:)` is an overridable preflight hook so Read-only can reject input before
  selection/viewport side effects.
- `Mac/MacTerminalView.swift` exposes a display-only link preview formatter so Aster can expand
  relative paths with its trusted Session CWD while preserving the original click payload. The
  preview uses an appearance-aware neutral badge whose light/dark palette does not inherit ANSI
  or terminal-theme colors.
  `Apple/AppleTerminalView.swift` renders implicit and OSC 8 link affordances with a continuous
  single underline instead of the low-visibility dashed pattern; AppKit and Metal consume the
  same shared attribute marker. The macOS view also derives its pointing-hand cursor from the
  same link visibility and mouse-reporting gates used by click activation, and keeps
  `cursorUpdate(with:)` open so Aster can include its extended scheme detector.
- `Apple/AppleTerminalView.swift` resolves Private Use Area characters (powerline separators,
  nerd symbols) against the base font's explicit cascade list when building line segments
  (`Utilities.swift` adds `UnicodeUtil.isPrivateUse`). Hidden system UI fonts such as
  `.AppleSystemUIFontMonospaced` skip the custom `kCTFontCascadeListAttribute` for PUA code
  points and shape them to LastResort (a blank/placeholder box), so prompt icons vanish. The
  host cannot fix this at font-construction time; the per-character override feeds both the
  CoreGraphics and Metal renderers through the shared segment builder. Resolution results are
  cached per character+font and cleared with the other attribute caches.
