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
  reflowed coordinates.
- `Apple/AppleTerminalView.swift` and `Apple/Metal/MetalTerminalRenderer.swift` apply the fractional
  viewport translation to Core Graphics and Metal rendering; the iOS view provides the shared API
  with a zero translation.
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
- `SelectionService.swift` and `Apple/AppleTerminalView.swift` expose programmatic rectangular
  selections; `Terminal.swift` provides a bounded, deduplicated visible-link enumeration seam for
  Aster's keyboard Hint Mode and a scroll-invariant line range for Vi Mode snapshots. The outer
  `shouldSendUserData(_:)` is an overridable preflight hook so Read-only can reject input before
  selection/viewport side effects.
