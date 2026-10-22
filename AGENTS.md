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

Debug builds accept `-PRDeskAppearance dark|light` to force an appearance, and
`-PRDeskDryRunWrites YES` to log writes to GitHub (comments, reviews, marking notifications read,
board fields, subscriptions) instead of sending them — use it whenever a test could trigger a write. Both flags are
compiled out of Release builds: a Release test copy writes to GitHub for real, so only measure with
one (benchmarks, profiling) and never press keys, click rows or select items in it.
Local data lives in `~/Library/Application Support/PR Desk/` (SQLite via GRDB, avatar cache).

## Testing in the running app

Check UI changes in a separate test copy, never the installed app or another session's debug build:

```sh
DD=<your scratch dir>/DerivedData   # not .build/DerivedData, which other sessions build into
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -derivedDataPath "$DD" \
  PRODUCT_BUNDLE_IDENTIFIER=com.bugenzhao.PRDesk.perftest build
"$DD/Build/Products/Debug/PRDesk.app/Contents/MacOS/PRDesk" -PRDeskDryRunWrites YES &
```

- The own bundle id keeps it apart from `com.bugenzhao.PRDesk` (the installed copy and
  `scripts/install.sh`, which quits that id) and gives it its own preferences (collapsed sections,
  column widths). Launch the binary directly; `open` may just activate another copy.
- Drive it with computer use in the background (`app_screenshot`, `app_click`, `app_menu`,
  `app_zoom` on `com.bugenzhao.PRDesk.perftest`), so the user keeps working. Menu commands go
  through `app_menu`; context menus can't be opened in the background.
- It shares the real database: selecting an item marks it viewed and read, and adding or pinning
  stores it. Pick items already in Recently viewed, and don't add, pin or set fields unless that is
  what's being tested. Quit the copy when done.
- Web pages (`PRDesk/Web/`) can also be checked headless: load `WebResources.page(_:)` into an
  offscreen `WKWebView` with the scripts, render a payload built from `detailCache` rows, and
  `takeSnapshot`. Offscreen views don't animate or tick timers at full rate, so judge timing and
  transitions in the app instead.

## Layout

- `PRDesk/Sources/GitHub` — `GitHubClient` (GraphQL + REST, retries), queries and mutations
- `PRDesk/Sources/Sync` — `SyncEngine` (tracked items, details, inbox, the triage board),
  `AffiliationEngine` (badges)
- `PRDesk/Sources/Store` — GRDB records and migrations (`AppDatabase`); migrations are append-only
- `PRDesk/Sources/Model` — pure logic: `ItemInsight` (Turn, unread, review-request classification),
  filter parsing, sections and sorting
- `PRDesk/Sources/App` — `AppModel` (the `@Observable` main-actor state) and the app entry point
- `PRDesk/Sources/UI` — SwiftUI shell; the list is an `NSTableView` with drawn cells (`ItemTable/`);
  the conversation and the files diff are each one long-lived `WKWebView` page (`Detail/WebDocument`)
  that Swift fills with JSON (`TimelineDocument`, `FilesDocument`) and `PRDesk/Web/detail.js` patches
  in place by block id; styles, scripts and highlight.js live in `PRDesk/Web/`

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

Decisions already made against these docs: keep `WKWebView` for the detail pages (SwiftUI `WebView`
lacks the find bar client, context-menu control and URL scheme handlers they use); don't adopt default `MainActor` isolation (most model types
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
- Never post to GitHub (comments, reviews, marking notifications read, board fields,
  subscriptions) while testing; use the dry-run flag above.
- The triage board (GitHub Project `vllm-project` #56) is the source of truth for Status, Priority
  and Comment (SPEC §3.1). The app writes them only on an explicit user action, never from a rule;
  it also shares the board with another tracker (`Python Parity Backlog`), whose items it must
  leave alone.
- Menu commands live in `AppCommands`, apart from the scenes, and read only observed flags that
  change when they flip (`hasSelection`, `canGoBack`, `selectionIsPullRequest`): reading the
  selection there rebuilds the menus and redraws the menu bar extra on every move.
- A background test copy sometimes shows the detail web pages empty (seen on builds old and new)
  while the page reports every render as done; this hasn't been seen in the front app. Don't
  bisect on it from background screenshots alone.
- List rows draw their cells into the row's layer (`canDrawSubviewsIntoLayer`). Never fade a cell
  with `alphaValue` (AppKit then renders it offscreen, ~50 ms a row; use `RunsCellView.opacity`),
  and don't set per-cell tooltips (the table shows one for the hovered cell, worked out lazily).
- Only user-initiated selection counts as opening an item (viewed, unread cleared, notification
  marked read). Selections the table makes itself go through `AppModel.autoSelect`; otherwise a
  row leaving the list selects its neighbor, which gets read and leaves too, in a chain.
- PR state icons in `PRDesk/Assets.xcassets` (`pr-open`, `pr-draft`, `pr-conflict`, `pr-merged`,
  `pr-closed`) are glyphs from the anthropicons font inside the local Claude desktop app
  (`app.asar`), exported as template SVGs at `opsz` 16. They are Anthropic's assets: fine for this
  personal app, don't publish them.
- The app icon is an Icon Composer bundle (`PRDesk/AppIcon.icon`: `icon.json` + SVG layers on a
  1024 canvas). Layers must be filled shapes — strokes render as solid fills. Keep same-colored
  parts in one layer and make pieces overlap rather than abut, or the glass rendering shows
  hairline seams. The `.icns` that `actool` emits is a flat iOS 26-style fallback; judge the
  design by what the OS draws instead: compile with `actool` into a throwaway `.app` (needs an
  executable and `CFBundleIconName`) and render `NSWorkspace.shared.icon(forFile:)`.
