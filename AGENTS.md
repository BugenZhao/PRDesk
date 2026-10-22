# PR Desk

Native macOS (26+) dashboard for PRs and issues in `vllm-project/vllm`. Product spec: `SPEC.md`.

## Build and run

```sh
tuist generate --no-open
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Debug/PRDesk.app
```

`scripts/install.sh` builds Release and installs it as `/Applications/PR Desk.app` (quitting any
running copy first) — that is the copy for daily use. Keep the build free of warnings.

Debug builds accept `-PRDeskAppearance dark|light` to force an appearance.
Local data lives in `~/Library/Application Support/PR Desk/` (SQLite via GRDB, avatar cache).

## Layout

- `PRDesk/Sources/GitHub` — `GitHubClient` (GraphQL + REST, retries), queries and mutations
- `PRDesk/Sources/Sync` — `SyncEngine` (tracked items, details, inbox), `AffiliationEngine` (badges)
- `PRDesk/Sources/Store` — GRDB records and migrations (`AppDatabase`); migrations are append-only
- `PRDesk/Sources/Model` — pure logic: `ItemInsight` (Turn, unread, review-request classification),
  filter parsing, sections and sorting
- `PRDesk/Sources/App` — `AppModel` (the `@Observable` main-actor state) and the app entry point
- `PRDesk/Sources/UI` — SwiftUI shell; the list is an `NSTableView` with drawn cells (`ItemTable/`);
  the detail timeline is native with per-comment `WKWebView` bodies (`Detail/`)

## Apple's coding-assistant docs

Xcode ships guides for its own coding assistant. They cover APIs newer than most training data —
read the relevant one before touching these areas, and prefer it over memory. They live inside
Xcode (not copied here, so they stay current with the installed Xcode):

```sh
XC="$(xcode-select -p)/.."
ls "$XC/PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/AdditionalDocumentation"  # new SDK APIs
ls "$XC/PlugIns/IDEAnalytics.framework/Versions/A/Resources/TriageDocs"  # crash/hang/launch/energy analysis
```

| Area | Doc |
|---|---|
| Toolbars, toolbar spacers, badges | `AdditionalDocumentation/SwiftUI-New-Toolbar-Features.md` |
| Liquid Glass in SwiftUI / AppKit | `AdditionalDocumentation/SwiftUI-Implementing-Liquid-Glass-Design.md`, `AppKit-Implementing-Liquid-Glass-Design.md` |
| SwiftUI `WebView` / `WebPage` | `AdditionalDocumentation/SwiftUI-WebKit-Integration.md` |
| Rich text editing, `AttributedString` | `AdditionalDocumentation/SwiftUI-Styled-Text-Editing.md`, `Foundation-AttributedString-Updates.md` |
| Swift 6.2 concurrency | `AdditionalDocumentation/Swift-Concurrency-Updates.md` |
| Hangs, launch time, crashes, energy | `TriageDocs/*.md` |

Some snippets in these docs don't match the shipped SDK (e.g. `WebPage.NavigationDeciding`
signatures, `webViewContentBackground`, `attributedTextFormattingDefinition`). Before relying on a
snippet, check the API in the SDK's `.swiftinterface`
(`$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/<Framework>.framework/Modules/`).

Decisions already made against these docs: keep the `WKWebView` comment bodies (SwiftUI `WebView`
can't hand scrolling to the outer list); don't adopt default `MainActor` isolation (most model types
are used off the main actor); no glass on content (cards, chips, rows).

## Gotchas learned here

- Never give views in the window a vertical `fixedSize` or a layout that grows tall at tiny widths:
  the window measures its minimum size with a very narrow proposal, and the result can force the
  window taller than the screen. `NSViewRepresentable`s should implement `sizeThatFits`.
- Don't touch `NSApplication.shared` in `App.init`; the app uses its own `PRDesk/Info.plist`
  (Tuist's default names a storyboard that doesn't exist).
- GitHub GraphQL mutations must be run with `strict: true`: a failed write comes back as `data`
  with `errors`, not an HTTP error.
- Heavy fields in the list search (e.g. comment bodies) push pages past GitHub's time limit
  (502s and truncated JSON); keep the list query lean and fetch detail on selection.
- Never post to GitHub (comments, reviews, marking notifications read) while testing.
- The app icon is an Icon Composer bundle (`PRDesk/AppIcon.icon`: `icon.json` + SVG layers on a
  1024 canvas). Layers must be filled shapes — strokes render as solid fills. Keep same-colored
  parts in one layer and make pieces overlap rather than abut, or the glass rendering shows
  hairline seams. The `.icns` that `actool` emits is a flat iOS 26-style fallback; judge the
  design by what the OS draws instead: compile with `actool` into a throwaway `.app` (needs an
  executable and `CFBundleIconName`) and render `NSWorkspace.shared.icon(forFile:)`.
