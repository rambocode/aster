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
  overscroll limits, and gesture-locked mouse-reporting/link bypass rules.
- `Apple/AppleTerminalView.swift` and `Apple/Metal/MetalTerminalRenderer.swift` apply the fractional
  viewport translation to Core Graphics and Metal rendering; the iOS view provides the shared API
  with a zero translation.
- `Terminal.swift` and `Buffer.swift` expose stable absolute buffer coordinates and an opt-in
  embedder identity used for conservative DA1/DA2 and XTVERSION replies.
- `Apple/AppleTerminalView.swift` exposes a read-only selection range for prompt safety checks;
  `Mac/MacTerminalView.swift` makes `keyDown` open so Aster can consume Backspace only inside a
  verified OSC 133 prompt range.
