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
The project signs ad hoc; `install.sh` signs the installed copy with this Mac's Apple Development
certificate where there is one (the team is read from the certificate, never written here: the
repo is public), so macOS takes each install for the same app. It also gives it its identifier and
team as entitlements (`PRDesk/PRDesk.entitlements`), with the provisioning profile they need,
which Xcode makes with the account in its settings; without either it signs as before and says
so. Test copies stay ad hoc, and must not take that entitlements file: without a profile macOS
won't start an app that has them.

The iPad and iPhone are installed apart, with `scripts/install-devices.sh`: one Release build,
installed on every paired device in reach (by cable, or over the network at home; an office's
Wi-Fi usually keeps devices apart), the others named and left. Not after every change, which
would stop the app in the user's hand all day: when pushing, or when asked. A new device is set
up once with `setup-device.sh` (below). Every install is stamped with its commit
(`PRDESK_COMMIT` → `AppVersion`), which Settings shows with how far `main` has moved on since, as
a note: that is how to tell which device has what.

Debug builds accept `-PRDeskAppearance dark|light` to force an appearance, `-PRDeskNoSync YES`
to skip syncing on their own (no searches, board, inbox or prefetched details; only what is opened,
and ⌘R), `-PRDeskCompanion YES` to run the Mac as a companion (a first sync of 14 days, no
prefetched details, affiliation work or board rules: for a second Mac starting from an empty
database), and
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
- A real device: `scripts/setup-device.sh <name or udid>` builds Release for it (automatic
  signing with this Mac's development team, which needs an account in Xcode › Settings ›
  Accounts to register a new device), installs it with `devicectl`, and sends this Mac's token,
  bot webhooks and ids and badges repository as one file into the app's Documents, which the app
  imports at launch and deletes (`SetupImport`). A Release build reads no environment and writes
  to GitHub for real.
- Check both an iPad mini (on its side: list beside detail; upright: the list floats over it) and an iPhone,
  and window sizes in between: `DeskLayout` is a pure function of the width, so every size must
  come out right whatever came before. An iPad simulator only rotates; an iPhone simulator's app
  can be put on a freely sized display (`devicectl device appResize`, wrapped by the `duo-hinge`
  skill's `resize start|set|stop`, screenshots with `simctl io <udid> screenshot
  --display=resizable`). Also try the keyboard up on the iPad on its side, the shortest the detail
  gets.
- Xcode's own skills are worth reading before SwiftUI work here. Export them into the project
  (`xcrun agent skills export --output-dir "$PWD/.agents/skills"`, an absolute path; the folder
  is ignored by git, being Apple's text in a public repository) and read:
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
  as the detail's sidebar, or a page on a phone, by `DeskLayout`), `ListPane` and `ItemRowView` (a SwiftUI `List`; rows of
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
- `NavigationSplitView` lays out by the horizontal size class (compact: one column, the list a
  page; regular: the list a sidebar, which the system floats over the detail in a narrower
  window). `DeskLayout` takes the system's class, except for the Full-Width List, where
  `DeskView` sets it to compact on the split view to get the system's own one column on an iPad.
  Don't lay anything else out by the class under it. After having been one column, the split
  view still writes `preferredCompactColumn = .sidebar` while regular: the binding drops the
  selection only while the list is a page.
- The detail's bar title is a view of our own in `ToolbarItem(placement: .title)`, which the
  system keeps between the bar's buttons (a `principal` item took the width it liked, over them).
  The bar centers it at the width it asks for, so it asks for more than any bar has
  (`idealWidth`) and aligns its text to the leading end of what it is given.
  `.toolbarTitleDisplayMode(.inlineLarge)`, the system's leading title, is for a text title: it
  left this view centered, and a view in `.largeTitle` didn't show at all. The title is always
  there and fades by opacity once the header's own title has scrolled under the bar. The header
  is an overlay clipped at the bar's edge, or it shows through the bar's buttons.
- Going between one column and two (the Full-Width List), the split view rebuilds its columns
  at once: `withAnimation` around the change animates nothing. `DeskView.dissolveWindow` adds a
  fade `CATransition` to the window's layer just before the change, which crossfades whatever
  that turn of the run loop changes (checked frame by frame in a simulator recording).
- The split view writes `columnVisibility` itself: `.detailOnly` when the window gets narrower
  or comes out of one column, and in the background (snapshots at other sizes), and it writes
  *before* the view sees the new width. Don't take a write for the viewer's choice at once, and
  don't hand it a computed binding (a getter that still says `.all` after the system showed
  `.detailOnly` moves nothing). `DeskView` keeps real `@State`, records a write as the choice
  only if no rearrangement follows within 400 ms, and puts the choice back after each
  rearrangement (`settle`). What must survive the app being stopped is `@SceneStorage`.
- `xcrun simctl spawn <udid> defaults write <bundle id>` does not reach the app: an app reads
  the plist in its own container (`Library/Preferences/<bundle id>.plist`). Edit that with
  `plutil` while the app is stopped. `simctl get_app_container` changes after a reinstall.
- The pages' web views are `.mobile` content mode on iOS: an iPad's default (desktop) sizes text
  by rules of its own, and CSS `zoom` on the root then moved the boxes and left the text at
  13 px. The zoom is set from Swift (`PRDesk.setTextScale`: 1.2 times the Dynamic Type factor).
  `@ScaledMetric` of 1 comes back rounded to 1 at every size; scale 100 and divide.
- The list switcher is a real `UITabBar` on its own (`ListTabBar`): the user requires the
  system's selection lens, which only the real control has (a SwiftUI imitation in the bar's
  glass was tried and rejected for lacking it, and felt slow). A tab bar isn't made for a
  toolbar, so `TabBarHost` lays it out 1000 pt wide, finds where it drew its capsule (its first
  subview's frame) and shows exactly that; `ListTabBar` sizes the item from the measure. Don't
  put set frames, crops or offsets back. What was learned measuring it:
  - `traitOverrides.horizontalSizeClass = .regular` always: there the capsule is as wide as
    its items need. Compact, the capsule fills the bar's width.
  - The capsule's height follows the bar's (54 → 34, 64 → 44): the host tries heights until the
    capsule is 44, the bar buttons' height.
  - Measure only in a window. Before, the bar lays out otherwise (three even items, 274 pt),
    and an item reported too wide is dropped from the bar for good, never to be measured again:
    until measured the item is three buttons wide.
  - Symbols: `SymbolConfiguration(textStyle: .body, scale: .large)` with medium weight is the
    bar buttons' own (the same magnifying glass measured 42 px in both, at the same height);
    a point size set by eye was 9% small.
  - Symbols alone, always (the user's call, after names that opened out at full width proved
    one trick too many). A tab bar's items have names wherever the system uses one, and without
    them two things come out wrong, each measured in the laid-out bar and made up for:
    - A symbol is 3 pt past the middle of its button. `centerSymbols` gives the items pictures
      of the symbols with that room (twice the shift) added after them. An alignment rectangle
      on the symbol does the same for `image` only: the bar drops it from `selectedImage`.
      `imageInsets` does nothing in this bar.
    - The bar's own badge (`badgeValue`) is in the air past its symbol: it goes at the end of
      the name. It can't be moved: `badgePositionAdjustment` does nothing in this bar, a
      transform on the badge's view is gone once the badge has appeared, and a move of the
      view the badges are in the bar makes up for at its next layout (it lays a badge out by
      converting from its item), so the badge jumped back and forth between symbols at every
      selection. The badges are the host's own views instead (`placeBadges`), over the bar:
      middle on the symbol's trailing edge, top at the button's top, in the system badge's
      measures, with a rim in the ground's color (a blue badge on a chosen list's blue
      symbol ran into it). They draw themselves: a `UILabel` in a bar's glass is drawn in one
      color with the glass's other content and came out a white disc.
  - Under a finger the lens draws the chosen item at 1.16 times its size and animates it back.
    Taken out of its window meanwhile (⤢ right after picking a list: the split view rebuilds
    its columns), the bar loses the animation and the item stays large: `settleLens` puts the
    buttons' transforms back when the host is in a window again.
  - UIKit doesn't fill the chosen item's symbol as a SwiftUI `TabView` does: `selectedImage`.
  - `didSelect` hands the change to the model on the next turn of the run loop, so rebuilding
    the list doesn't hold up the bar's own selection.
  - A simulator's pixels are antialiased where its window, shown smaller than the device, is
    not: judge an edge by `simctl io screenshot`, enlarged, not by the window.
  A segmented `Picker` could not do this either: a segment is text or an image, never both,
  draws an image small and light whatever its font, and takes no badge.
- The system's search button joins the capsule of whatever is at the bar's end unless it is
  placed by name (`DefaultToolbarItem(kind: .search, placement: .topBarTrailing)`) with a
  `ToolbarSpacer(.fixed)` on each side; in a compact window it is placed in the bottom bar.
- Liquid Glass (read `SwiftUI-Implementing-Liquid-Glass-Design.md` first; the exported skills
  don't cover it): buttons are the system's glass ones (`.buttonStyle(.glass)`, `.glassProminent`
  for the one that matters) with the labels the system gives them, which are the label color,
  not the tint; never bordered or tinted-blue buttons. The composer is one card of glass with
  those buttons on it, which the user chose over a field and buttons floating apart. Give the
  buttons of a row labels of one height (symbols in a square frame), or a chevron and an eye come
  out as circles of two sizes.
- A foreground style set around a view takes over the labels of the buttons and menus inside it
  (a prominent button's white comes out black, a bar's `Menu` all but vanishes).
- Gray text and symbols in a view an iPad shows take `.secondaryText` / `.tertiaryText`
  (`PlatformColors`: the hierarchical styles on the Mac, the Mac's values as colors on iOS, in
  `detail.css` too; the user chose the Mac's own values over darker ones that made up for the
  Mac's heavier text smoothing), never `.secondary` / `.tertiary`. iOS's grays are lighter than
  the Mac's, and setting darker ones around a view
  (`foregroundStyle(_:_:_:)`) didn't reach a `Text` styled itself: tags came out as iOS's
  tertiary, the latest event (tertiary in a secondary line) as its quaternary. Check a gray by
  its pixels in a simulator screenshot (50% black on white is 128, 26% is 189).
- In a web page under a finger, WebKit sends a click only to what it takes for clickable: a
  link, a button, an element with a click listener of its own, or, when the *document* has a
  click listener, an element with `cursor: pointer`. A listener on the window (a bare
  `addEventListener`) counts for nothing: touch and pointer events arrived and no click did, so
  cards didn't fold and files didn't open on the iPad. `detail.js` listens on `document`, and
  `detail.css` gives the page's own controls a pointer cursor on iOS; give a new tappable
  element one too.
- Handoff (`ItemHandoff`, a view of no size in each app's root background) can't be tried in a
  simulator or a test copy: the system hands off only between apps signed by one team on
  devices of one iCloud account. Both apps declare the type in `NSUserActivityTypes` (the Mac's
  `Info.plist`, `Project.swift` for iOS), and a new type needs both. The two directions take
  the team from different places: an activity is *received* by the team of the app's
  certificate, but *offered* under the team in its `application-identifier` entitlement
  (`useractivityd`). The Mac app signed with the certificate alone took activities from the
  phone, while the phone was offered the Mac's as its web page in Safari: hence the
  entitlements in `install.sh`.
- A popover's `attachmentAnchor: .rect(.rect(…))` is in the space of the view the popover is
  on, not the window's. A page gives its menus' points in the window (`webView.convert(_:to:
  nil)`), and the desk begins below the status bar on a phone, so the pages' popovers pointed
  62 pt too low: `DeskView` takes its own origin off. Left to itself a popover goes beside its
  anchor where it likes, even where it doesn't fit: the reactions say `arrowEdge: .top`.
- The pages' colors are WebKit's system color keywords, and several are the Mac's alone
  (`-apple-system-control-accent`, `-control-background`, `-text-background`): on iOS a custom
  property holding one is invalid where it is used, quietly, so links had the text's color and
  cards no ground. `detail.css` sets those by value for iOS; check a new keyword on both.
- Bodies are `overflow-wrap: anywhere`, which also lets a table's columns shrink to a letter's
  width: in a narrow pane a wide table was never too wide, just a column of single letters, so
  `overflow-x: auto` on it never scrolled. `fragment()` puts each table in a `.tscroll` box
  and `markdown.css` lays the table out at `max-content` up to `max(100%, 46em)` with words
  whole (`overflow-wrap: normal`) and code breakable; `break-word` would be whole words too,
  as it doesn't count for a column's minimum. Without the box (`display: block` on the table)
  the table can only be as wide as the pane or its longest words.
- A bottom-bar item taken out of `.toolbar` in the same change that brings the keyboard up left
  the detail pane laid out about a hundred points too high (header over the bar, composer under
  the keyboard). The composer's button stays in the toolbar and the bar is hidden with
  `toolbarVisibility` instead.
- A touch on the detail's pager while it slides to a tab stops it at the nearest page with the
  `ScrollPosition` still naming the tab asked for: once the scroll is idle after a touch, the
  tab is set from the offset (`onScrollPhaseChange`). Only after a touch: a pager just made
  reports idle on its first page before it goes to the tab asked for, and setting the tab from
  that took a link's Files back to Conversation on a phone.
- A link can arrive before the stored items are read (Handoff or the hot key starting the
  app): `AppModel.open` holds it until the first snapshot. Opened at once it found nothing,
  fetched the item and listed it as opened from a link on the tab last shown.
- Views in a `ScrollView` can't reach under the bars with `ignoresSafeArea`, and a
  `safeAreaInset` on the scroll view pushes its content down. The detail's pager (`DetailPager`)
  gives each page negative padding to the window's edges and `safeAreaPadding` back, and the
  header is an overlay. `scrollPosition(id:)` with a hand-made `Binding` scrolled one way only;
  it uses a `ScrollPosition` and two `onChange`s.
- The split view's edge swipe (the list out over the detail, iPad upright) gives way to any
  horizontal scroll view's pan under the finger once that pan begins, even one at its start with
  bounces off, or made to wait on an edge recognizer of our own. The detail's pager turns its pan
  off for a touch that lands at the window's edge on its first page (`FirstPageEdgeYield`).
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
  `yab exec` rather than AppleScript: a copy signed ad hoc (any test copy, and the installed one on
  a Mac without a development certificate) gets the Automation prompt again after each build.
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
