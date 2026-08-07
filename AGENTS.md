# Repository Guidelines

## Project Structure & Module Organization

Aster Terminal is a native macOS 14+ AppKit application built with Swift Package Manager.

- `Sources/AsterPTY/` contains the small C POSIX PTY bridge.
- `Sources/AsterCore/` contains framework-independent domain models, persistence, layouts, themes, and terminal state.
- `Sources/Aster/` contains the AppKit executable and its SwiftTerm integration.
- `Tests/AsterCoreTests/` and `Tests/AsterTests/` contain domain and AppKit tests respectively.
- `Resources/` contains the app bundle metadata and icon; `scripts/` builds the app and DMG.
- `docs/developer/` and `docs/user/` hold implementation and user-facing documentation.

Keep serializable descriptors separate from runtime objects; never persist PIDs, file descriptors, or runtime-only state.

## Build, Test, and Development Commands

```bash
swift build                    # Debug build
swift test                     # Run the complete test suite
swift test --no-parallel       # Required for release validation; PTY tests are timing-sensitive
swift test --filter <name>     # Run tests matching a name fragment
./scripts/build-app.sh         # Build and sign dist/Aster.app
./scripts/build-dmg.sh         # Build and verify a versioned DMG
open dist/Aster.app            # Launch the packaged application
```

Use `ASTER_SIGN_IDENTITY="Developer ID Application: ..."` for Developer ID builds; the default signature is ad hoc.

## Coding Style & Naming Conventions

Follow existing Swift formatting and use two-space indentation in `Package.swift` and shell scripts. Use `UpperCamelCase` for types and `lowerCamelCase` for properties and methods. Keep domain logic in `AsterCore`; AppKit, SwiftTerm, and process concerns belong in `Aster`. `Sources/Aster` must not import SwiftUI or create hosting views. Route colors through `ThemeRuntime`; comment non-obvious lifecycle, layout, security, and compatibility decisions.

## Testing Guidelines

Use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest. Name tests after observable behavior. Tests involving `AppPreferences` or `AppModel` must use an isolated `UserDefaults` suite; AppKit tests should remain `@MainActor`. Run focused tests during iteration, then `swift test --no-parallel` before delivery.

## Commit & Pull Request Guidelines

Use concise Conventional Commit-style subjects such as `feat(workspace): ...`, `fix(settings): ...`, or `chore: ...`. Keep commits focused and explain user impact when behavior changes. Pull requests should list tested commands, link the relevant issue or decision, include UI screenshots, and call out persistence, security, or compatibility implications.

## Documentation & Security

Synchronize relevant files under `docs/developer/` and `docs/user/help.md` whenever behavior or interaction changes; record visual acceptance updates in `design-qa.md`. Preserve import size limits and reject FIFO/device-file reads. Imported recipes may store commands for compatibility but must never execute external commands. Validate untrusted data before creating runtime state.
