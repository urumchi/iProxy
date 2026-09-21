# Repository Guidelines

## Project Structure & Module Organization

iProxy is a macOS SwiftUI app that blocks network access per application using a
Network Extension content filter.

- `iProxy/` — main app target: `iProxyApp.swift` (entry point), `ContentView.swift`
  (UI), `AppStore.swift` (view-model state), `RuleStore.swift` (JSON persistence),
  `FilterConfigurationService.swift` (pushes rules to the system filter),
  `ApplicationScanner.swift`, `Models.swift`, and `Assets.xcassets`.
- `ContentFilter/` — the `NEFilterDataProvider` system extension. `main.swift`
  starts system-extension mode; `FilterDataProvider.swift` decides each flow.
  Entitlements live in `ContentFilter.entitlements`.
- `iProxyTests/` (Swift Testing) and `iProxyUITests/` (XCTest) — test targets.
- `iProxy.xcodeproj` — single project holding all four targets.

Rules are persisted to `~/Library/Application Support/iProxy/rules.json`.

## Build, Test, and Development Commands

```sh
xcodebuild -project iProxy.xcodeproj -scheme iProxy build        # build the app
xcodebuild -project iProxy.xcodeproj -scheme iProxy test \
  -destination 'platform=macOS'                                  # run all tests
xcodebuild -project iProxy.xcodeproj -scheme ContentFilter build # build the extension
```

Or use Xcode (`open iProxy.xcodeproj`). Deployment target is macOS 26.5, Swift
5.0, bundle ID `org.mktime.hmccb.iProxy`. The content filter requires signing
with the `content-filter-provider` entitlement and manual approval in System
Settings; it will not activate in an unsigned build.

## Coding Style & Naming Conventions

- Four-space indentation; follow existing Xcode defaults. No linter or formatter
  is configured, so match surrounding code.
- Types are `UpperCamelCase`, members and locals `lowerCamelCase`; name each file
  after its primary type.
- Mark UI-owning types `@MainActor` and shared model types `Sendable`, matching
  `Models.swift` and `AppStore.swift`.
- User-facing strings are Simplified Chinese; keep new copy consistent.

## Testing Guidelines

Add unit tests in `iProxyTests/` using Swift Testing (`@Test`, `#expect`) and UI
coverage in `iProxyUITests/` with XCTest. Name tests after the behavior they
verify, and run them before opening a pull request. No coverage threshold is
enforced.

## Commit & Pull Request Guidelines

History is a single `Initial Commit`, so use imperative, capitalized subjects
(for example, `Add per-application rule export`). Keep commits scoped to one
change. Pull requests should describe the change, note how it was tested, link
related issues, and include screenshots for UI changes.

## Security & Configuration Tips

Never hard-code signing identities or credentials. Treat
`FilterConfigurationService` as the only path for installing rule payloads: the
extension, not the UI process, must decide each new network flow.
