# PR Desk

Native macOS (26+) dashboard for PRs and issues in `vllm-project/vllm`, with an iPhone and iPad
companion (`PRDeskMobile`, iOS 26+). Product spec: `SPEC.md`.

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
board fields, subscriptions, files marked viewed, messages to Grok Bots) instead of sending them — use it whenever a test could trigger a write. Both flags are
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
- Web pages (`Shared/Resources/Web/`) can also be checked headless: load `WebResources.page(_:)` into an
  offscreen `WKWebView` with the scripts, render a payload built from `detailCache` rows, and
  `takeSnapshot`. Offscreen views don't animate or tick timers at full rate, so judge timing and
  transitions in the app instead.

### The iOS companion

Build for a simulator and launch it with `simctl`, so debug flags and a token reach it (the phone
has no `gh`; debug builds read `PRDESK_GITHUB_TOKEN` from the environment):

```sh
DD=<your scratch dir>/DerivedDataMobile
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDeskMobile -derivedDataPath "$DD" \
  -destination 'platform=iOS Simulator,id=<udid>' CODE_SIGNING_ALLOWED=NO build
xcrun simctl install <udid> "$DD/Build/Products/Debug-iphonesimulator/PRDeskMobile.app"
SIMCTL_CHILD_PRDESK_GITHUB_TOKEN="$(gh auth token)" xcrun simctl launch --terminate-running-process \
  <udid> com.bugenzhao.PRDesk.mobile -PRDeskDryRunWrites YES
```

- Quote the `-destination`: split by the shell, it quietly builds for a generic device instead and
  the simulator keeps the old app.
- The companion has its own database in the simulator's app container. Its syncs spend the same
  GraphQL quota as the Mac's (5,000 points an hour, per user): a first sync is about a thousand
  items; don't relaunch it over and over with an empty database.

## Layout

Both apps compile `Shared/`; each adds its own views and platform parts. Put new logic in
`Shared/` and keep platform code to the thin files around it, so the apps don't drift.

- `Shared/Sources/GitHub` — `GitHubClient` (GraphQL + REST, retries), queries and mutations
- `Shared/Sources/Sync` — `SyncEngine` (tracked items, details, inbox, the triage board),
  `AffiliationEngine` (badges)
- `Shared/Sources/Store` — GRDB records and migrations (`AppDatabase`); migrations are append-only
- `Shared/Sources/Model` — pure logic: `ItemInsight` (Turn, unread, review-request classification),
  filter parsing, sections and sorting, state icons
- `Shared/Sources/App` — `AppModel` (the `@Observable` main-actor state both apps drive)
- `Shared/Sources/Support` — `Platform` (opening links, the pasteboard, the badge count),
  `DeviceRole` (only the Mac, the primary, follows the board with rules and prefetches details),
  `AvatarStore`
- `Shared/Sources/Bots` — `GrokBot` messages (SPEC §3.3); each app sends them its way
- `Shared/Sources/Web` — the detail pages: `WebDocument` (one long-lived `WKWebView` that Swift
  fills with JSON from `TimelineDocument` / `FilesDocument` and `detail.js` patches in place by
  block id), `WebResources`, `AvatarSchemeHandler`
- `Shared/Sources/UI` — SwiftUI views both apps use: the composer, checks, header components, the
  bot send sheet, alerts
- `Shared/Resources` — the web pages' styles and scripts (`Web/`, with highlight.js), the asset
  catalog, the app icon
- `PRDesk/Sources` — the Mac: the app entry, `AppModel+Mac` (mouse buttons, Yab), the list (an
  `NSTableView` with drawn cells, `UI/ItemTable/`), the detail pane, `WebDocument+Mac` (find bar,
  menus), `WebImages+Mac`, the grokbot CLI sender (`Bots/GrokBot+CLI`, built by
  `scripts/embed-grokbot.sh` at a pinned commit, needs `~/.cargo`), `Yab/YabFrontTab` for ⌃⌥⌘D
  (SPEC §6)
- `PRDeskMobile/Sources` — the phone: tabs, list and detail screens, settings, its `WebImages`,
  `AvatarCache` and web view host, and a Grok sender that opens Grok Bot with the message as a
  draft (`grokbot://app/v1/prompt`)

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
  subscriptions) or message Grok Bots while testing; use the dry-run flag above. A dry-run send
  waits about as long as the CLI (so the faint in-flight mark shows) and still marks the item
  sent in the shared database; clear the `*SentAt` columns of `itemState`
  afterwards.
- Yab's `native_context` and `tabs` only see the space on screen, `native_context` gives tab URLs
  as origins only (join with `tabs` by the first 8 characters of the id). `yab exec` is documented to open a hidden Yab if none is running. Stay on
  `yab exec` rather than AppleScript: PR Desk is ad-hoc signed, so the Automation prompt would likely
  come back after each install.
- `scripts/embed-grokbot.sh` runs cargo with `env -i`: under Xcode's environment proc-macro
  crates fail to build ("can't find crate for `serde_derive`"), and the half-built target dir
  keeps failing until it is deleted (`~/Library/Caches/com.bugenzhao.PRDesk.build/grokbot`).
- The triage board (GitHub Project `vllm-project` #56) is the source of truth for Status, Priority,
  Comment and pins (its Pinned field) (SPEC §3.1). The app writes them only on an explicit user action, never from a rule (an off-board PR the user approves is added as Good, standing in for the board's own approval workflow, and 🚀 sets Merging once the board's automation has had its say);
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
- PR state icons in `Shared/Resources/Assets.xcassets` (`pr-open`, `pr-draft`, `pr-conflict`, `pr-merged`,
  `pr-closed`) are GitHub Octicons at 16 px (MIT, `Shared/Resources/octicons.LICENSE`). Octicons has no
  conflict glyph: `pr-conflict` is `git-pull-request` with its top-left node swapped for the ✕ and
  stem of `git-pull-request-closed`. The repo is public: don't add assets taken from other apps.
- The app icon is an Icon Composer bundle (`Shared/Resources/AppIcon.icon`: `icon.json` + SVG layers on a
  1024 canvas). Layers must be filled shapes — strokes render as solid fills. Keep same-colored
  parts in one layer and make pieces overlap rather than abut, or the glass rendering shows
  hairline seams. The `.icns` that `actool` emits is a flat iOS 26-style fallback; judge the
  design by what the OS draws instead: compile with `actool` into a throwaway `.app` (needs an
  executable and `CFBundleIconName`) and render `NSWorkspace.shared.icon(forFile:)`.
