# PR Desk

Native macOS (26+) dashboard for PRs and issues in `vllm-project/vllm`, and the same desk for the
iPad (an iPad mini first) and iPhone (`PRDeskMobile`, iOS 27+). Product spec: `SPEC.md`.

## Build and run

```sh
tuist generate --no-open
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -derivedDataPath .build/DerivedData build
open .build/DerivedData/Build/Products/Debug/PRDesk.app
```

`scripts/install.sh` builds Release and installs it as `/Applications/PR Desk.app` (quitting any
running copy first) — that is the copy for daily use. Keep the build free of warnings.

Debug builds accept `-PRDeskAppearance dark|light` to force an appearance, `-PRDeskNoSync YES`
to skip syncing on their own (no searches, board, inbox or prefetched details; only what is opened,
and ⌘R), and
`-PRDeskDryRunWrites YES` to log writes to GitHub (comments, reviews, marking notifications read,
board fields, subscriptions, files marked viewed, the badges file, messages to Grok Bots) instead of sending them — use it whenever a test could trigger a write.
`-PRDeskBadgesFile <path>` shares badges through that local file instead of the repository in
Settings (the Mac writes it at launch, a simulator reads it), with no request. These flags are
compiled out of Release builds: a Release test copy writes to GitHub for real, so only measure with
one (benchmarks, profiling) and never press keys, click rows or select items in it.
Local data lives in `~/Library/Application Support/PR Desk/` (SQLite via GRDB, avatar cache).

## Testing in the running app

Check UI changes in a separate test copy, never the installed app or another session's debug build:

```sh
DD=<your scratch dir>/DerivedData   # not .build/DerivedData, which other sessions build into
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -derivedDataPath "$DD" \
  PRODUCT_BUNDLE_IDENTIFIER=com.bugenzhao.PRDesk.perftest build
"$DD/Build/Products/Debug/PRDesk.app/Contents/MacOS/PRDesk" -PRDeskDryRunWrites YES -PRDeskNoSync YES &
```

- Mind the GraphQL quota (5,000 points an hour, shared with the installed app and the user's own
  use; each detail is an expensive nested query). Keep `-PRDeskNoSync YES` unless the test is
  about syncing, open only the items the test needs, and don't relaunch over and over. Check
  `gh api rate_limit --jq .resources.graphql` (free) before and after. Never make a migration
  empty `detailCache`: every copy then refetches every detail; decode old rows leniently instead.

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

### On the iPad and iPhone

Build for a simulator and launch it with `simctl`, so debug flags and a token reach it (iOS has
no `gh`; debug builds read `PRDESK_GITHUB_TOKEN` from the environment):

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
- The app has its own database in the simulator's app container. Its syncs spend the same
  GraphQL quota as the Mac's (5,000 points an hour, per user): a first sync is about a thousand
  items. Seed it from the Mac's instead and launch with `-PRDeskNoSync YES`, which costs nothing
  and shows real rows: install the app, then

  ```sh
  D="$(xcrun simctl get_app_container <udid> com.bugenzhao.PRDesk.mobile data)/Library/Application Support/PR Desk"
  mkdir -p "$D" && sqlite3 ~/Library/Application\ Support/PR\ Desk/db.sqlite ".backup '$D/db.sqlite'"
  cp -R ~/Library/Application\ Support/PR\ Desk/avatars "$D/"
  ```

  It is a copy: what the simulator marks read or sets stays in it.
- Check both an iPad mini (on its side: list beside detail; upright: list alone) and an iPhone,
  and window sizes in between: `DeskLayout` is a pure function of the width, so every size must
  come out right whatever came before. An iPad simulator only rotates; an iPhone simulator's app
  can be put on a freely sized display (`devicectl device appResize`, wrapped by the `duo-hinge`
  skill's `resize start|set|stop`, screenshots with `simctl io <udid> screenshot
  --display=resizable`). Also try the keyboard up on the iPad on its side, the shortest the detail
  gets.
- Xcode's own skills are worth reading before SwiftUI work here (`xcrun agent skills export`):
  `swiftui-whats-new-27` (swipe actions outside lists, toolbar overflow), `swiftui-specialist`
  (list rows with one root view, observation) and `app-resizability` (no `UIScreen.main`,
  interface orientation or idiom to lay out by; the window's size instead).

## Layout

Both apps compile `Shared/`; each adds its own views and platform parts. Put new logic in
`Shared/` and keep platform code to the thin files around it, so the apps don't drift.

- `Shared/Sources/GitHub` — `GitHubClient` (GraphQL + REST, retries), queries and mutations
- `Shared/Sources/Sync` — `SyncEngine` (tracked items, details, inbox, the triage board),
  `AffiliationEngine` (badges), `BadgeShare` (the Mac publishes what its badges come from to a
  private repository, the iPad imports it, SPEC §9)
- `Shared/Sources/Store` — GRDB records and migrations (`AppDatabase`); migrations are append-only
- `Shared/Sources/Model` — pure logic: `ItemInsight` (Turn, unread, review-request classification),
  `RowMarks` (what the Turn, Review and CI columns show, for both lists), filter parsing, sections
  and sorting, state icons
- `Shared/Sources/App` — `AppModel` (the `@Observable` main-actor state both apps drive)
- `Shared/Sources/Support` — `Platform` (opening links, the pasteboard, the badge count),
  `AgentSession` (the board's Session links: agent names, rewrites to desktop-app links),
  `DeviceRole` (only the Mac, the primary, follows the board with rules and prefetches details),
  `AvatarStore`
- `Shared/Sources/Bots` — `GrokBot` messages (SPEC §3.3), posted to a bot's webhook routine
  (`BotHook`, kept in the Keychain) from either app
- `Shared/Sources/Web` — the detail pages: `WebDocument` (one long-lived `WKWebView` that Swift
  fills with JSON from `TimelineDocument` / `FilesDocument` and `detail.js` patches in place by
  block id), `WebResources`, `AvatarSchemeHandler`
- `Shared/Sources/UI` — SwiftUI views both apps use: the composer, checks, header components, the
  Commits and Files tabs, the stack panel and rail, the bot send sheet, alerts; `PlatformStyles`
  for what differs (fonts to measure with, checkboxes, link buttons, row heights)
- `Shared/Resources` — the web pages' styles and scripts (`Web/`, with highlight.js), the asset
  catalog, the app icon
- `PRDesk/Sources` — the Mac: the app entry, `AppModel+Mac` (mouse buttons, Yab), the list (an
  `NSTableView` with drawn cells, `UI/ItemTable/`), the detail pane, `WebDocument+Mac` (find bar,
  menus), `WebImages+Mac`, `Yab/YabFrontTab` for ⌃⌥⌘D (SPEC §6)
- `PRDeskMobile/Sources` — the iPad and iPhone (SPEC §9): `UI/DeskView` (a split view: the list
  alone or as the detail's sidebar, by `DeskLayout`), `ListPane` and `ItemRowView` (a SwiftUI `List`; rows of
  two lines or one, columns by `RowDensity`), `DetailPane` (its header scrolls away with the
  page, `Shared/Sources/UI/PageChrome`), `ItemMenu`, `PageMenu` (the pages' menus, as popovers),
  `SettingsView`, `DeskCommands` (the menu bar and the Mac's keys); and the
  platform parts: its `WebImages`, `AvatarCache` and web view host, and, for a bot without a
  webhook, a Grok sender that opens Grok Bot with the message as a draft
  (`grokbot://app/v1/prompt`)

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

- On iOS, UIKit takes any `@Observable` state a view reads during its `layoutSubviews` as a
  reason to lay it out again when that state changes. A KVO or delegate callback can run inside
  a layout (`WKWebView` sets its scroll view's frame there, which moves `contentOffset`): reading
  observed state in it made the web view lay out at every step of a scroll, which put the offset
  back in bounds and killed the overscroll. Such callbacks write observed state and read only
  unobserved copies (`PageScroll`).
- `NavigationSplitView` lays out by the horizontal size class, and an iPad mini upright is
  regular: `DeskView` sets the class itself to say whether the list is a page (compact) or a
  sidebar (regular). Don't lay anything else out by the class under it. After having been one
  column, the split view still writes `preferredCompactColumn = .sidebar` while regular: the
  binding drops the selection only while the list is a page.
- Views in a `ScrollView` can't reach under the bars with `ignoresSafeArea`, and a
  `safeAreaInset` on the scroll view pushes its content down. The detail's pager (`DetailPager`)
  gives each page negative padding to the window's edges and `safeAreaPadding` back, and the
  header is an overlay. `scrollPosition(id:)` with a hand-made `Binding` scrolled one way only;
  it uses a `ScrollPosition` and two `onChange`s.
- A view whose body reads the detail's tab re-makes its toolbar items when the tab changes, which
  cuts the segments' animation short: `DetailPane.body` leaves the tab to `ActivePage`,
  `DetailTabs` and `DetailPager`.
- A segmented `Picker` in a toolbar is glass itself: give its `ToolbarItem`
  `.sharedBackgroundVisibility(.hidden)`, or it sits in a second sheet of it. Items share one
  capsule unless a `ToolbarSpacer(.fixed)` parts them, and what doesn't fit a phone's bar is
  folded into a menu the system makes (unlabelled), so give a narrow bar less.
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
