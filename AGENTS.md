# Repository Guidelines

## Project Structure & Module Organization

Aster is a SwiftPM/AppKit macOS terminal workspace. `Sources/Aster` contains the application and UI; keep Ghostty bridging inside `Sources/Aster/Ghostty`. `Sources/AsterCore` holds AppKit-independent domain models, while `Sources/AsterMemory`, `Sources/AsterMemoryMCP`, and `Sources/AsterPTY` provide persistence, the read-only MCP executable, and PTY primitives. Tests mirror these targets under `Tests/`. Assets live in `Resources/`, build helpers in `scripts/`, third-party code in `Vendor/`, and documentation in `docs/`.

## Code Search

This repository is indexed by CodeGraph through `.codegraph/`. When locating or understanding code, query CodeGraph first with `codegraph_explore` when the MCP tool is available, or `codegraph explore "<question or symbols>"` from the shell. Fall back to `rg` or direct file inspection only when the index is unavailable, stale, or does not cover the required result.

## Build, Test, and Development Commands

The project requires macOS 14+, Swift 6.2, Zig 0.15.2, and the Xcode Metal Toolchain.

- `./scripts/setup-ghostty.sh` builds the pinned Ghostty XCFramework and resources; `build-app.sh` also runs it.
- `swift build` creates a debug build.
- `./scripts/test.sh --no-parallel` runs the full suite safely; PTY lifecycle tests are concurrency-sensitive.
  Use this wrapper instead of bare `swift test`: the xctest host lives outside the `.app` layout, so it needs
  `DYLD_FRAMEWORK_PATH` injected to load the Sparkle framework.
- `./scripts/test.sh --filter <name>` runs a focused `@Test` function.
- `./scripts/build-app.sh` assembles and signs `dist/Aster.app`. Requires `rsvg-convert`
  (`brew install librsvg`) to rasterize `Resources/AsterIcon.svg` into the icon master with a real
  alpha channel; the script fails hard when it is missing rather than falling back to an opaque
  Quick Look thumbnail, which would bake a white square behind the icon.
- `./scripts/build-dmg.sh` creates and verifies the DMG.
- `./scripts/release.sh --short <version> --bundle <int>` cuts a full release (version bump, notarized DMG, GitHub release, appcast). See `docs/developer/software-update.md`.
- `open dist/Aster.app` launches the packaged application for manual checks.

## Coding Style & Naming Conventions

Follow existing Swift style: two-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, and files named for their principal type or domain. Keep reusable business rules in `AsterCore`; UI controllers should validate, coordinate, and render. Do not introduce SwiftUI into `Sources/Aster`. Document public APIs and non-obvious lifecycle, concurrency, security, or compatibility decisions. Preserve target boundaries and avoid editing generated Ghostty artifacts.

## Testing Guidelines

Tests use `swift-testing` (`import Testing`, `@Test`, and `#expect`), not XCTest. Name files `*Tests.swift` and give tests behavior-focused names. AppKit tests normally require `@MainActor`; preferences tests must use isolated `UserDefaults` suites. Add focused coverage for meaningful logic and failure paths, then run the full non-parallel suite before submission. Update the relevant `docs/developer/` page and `docs/user/help.md` for user-visible behavior changes.

## Commit & Pull Request Guidelines

Use Conventional Commits as seen in history, for example `feat(workspace): add tab layout` or `fix(packaging): preserve resource bundles`. Keep each commit scoped to one concern. Pull requests should explain behavior and architectural impact, link related issues, list verification commands, and include screenshots or recordings for UI changes. Call out signing, vendored-code, persistence, or compatibility effects explicitly; update vendored provenance or patch documentation when applicable.

## Security & Configuration Tips

Keep signing identities and notarization profiles in `ASTER_SIGN_IDENTITY` and `ASTER_NOTARY_PROFILE`; never commit credentials. The Sparkle EdDSA private key lives in the login keychain and must never be exported into the repository; `CFBundleVersion` must increase monotonically on every release because Sparkle uses it to compare versions and published values cannot be recalled. Build outputs such as `.build/`, `dist/`, generated Ghostty resources, and `Vendor/GhosttyKit.xcframework` remain untracked. For architecture, input-validation, or release changes, consult `CLAUDE.md` and the matching `docs/developer/` domain guide before editing.
