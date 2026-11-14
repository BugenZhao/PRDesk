# PR Desk — Spec v0.1

A native macOS workbench for vLLM PRs and issues: dense and keyboard-driven. A clean-room
implementation that doesn't consult the source of any existing tool.

## 1. Scope

- Repository: `vllm-project/vllm`; also the parity agent's staging PRs on `BugenZhao/vllm`, which
  appear only in the Parity tab (§3.2)
- Items: PRs and issues
- User: the user signed in to `gh` (BugenZhao); every "me / you" means them
- Source of truth for triage and pins: the GitHub Project **Bugen's Board** (`vllm-project` #56), see §3.1
- Out of scope: Claude / terminal panels, task items, collections, notes, IDE / worktree integration
- Grok Bot: the app only hands items to bots (§3.3); it doesn't run agents or read bot
  conversations or state

## 2. Tech stack

| Area | Choice |
|---|---|
| System | macOS 26+, follows the system's light / dark appearance |
| Language | Swift 6 (strict concurrency) |
| Project | Tuist (same as MNGA) |
| UI | SwiftUI for the shell (window, split view, detail, settings); the main list is an AppKit `NSTableView` (through `NSViewRepresentable`) for density, performance and keyboard feel at hundreds of rows |
| Body rendering | The whole timeline (event rows, avatars, author badges, collapsing, times, review states and the `bodyHTML` GitHub returns) renders in **one** `WKWebView` page with its own CSS following the system colors, so code blocks, tables, images and `<details>` display correctly. The page stays loaded: switching items only sends new data, which is patched in place by item id, keeping scroll position, expansion state and loaded images; collapsed items don't render their bodies. Scrolling, selecting text across comments and find (⌘F) are left to WebKit |
| Storage | SQLite (GRDB), in `~/Library/Application Support/PR Desk/` |
| Network | Mainly GitHub GraphQL, with REST for the rest (notifications, a few writes) |
| Auth | A PAT saved in Settings (stored in the Keychain) if there is one, otherwise `gh auth token` |

## 3. Data sync

- **Tracked set**: items in `repo:vllm-project/vllm` matching any of
  - `involves:@me` (author / assignee / mentioned / commented)
  - `review-requested:@me`, `reviewed-by:@me`
  - `label:rust`
  - on the board (including items added by hand on the web)
  - The first sync looks back 90 days; closed / merged items fade out after 14 days
- **By hand**: add an item to the board on GitHub (no Status means untriaged) and the next sync
  tracks it
- **Incremental**: on a timer (every 5 minutes by default, adjustable in Settings → General, the
  same in the foreground and background), one advanced search fetches what changed:
  `(involves:@me OR review-requested:@me OR reviewed-by:@me OR label:rust) updated:>=<last sync>`,
  20 per page (the first sync uses 50 per page, split into time windows fetched in parallel); ⌘R
  syncs now
- **Detail**: after each sync, details for items in Working, Good, Triage, Inbox, Pinned and
  Recently viewed are prefetched in the background, only where the cache is missing or older than
  the item, 2 at a time. Selecting an item shows the cache first and fetches live when the cache is
  older than the item or more than 2 minutes old. One detail fetch is two parallel GraphQL queries:
  one for the body and timeline, one for a PR's checks
- **Rate limit**: the status bar shows the remaining GraphQL quota; below 500 the polling slows
  down automatically
- **Board**: all board items (Status, Priority, Comment) are read at most every 3 minutes, and
  always on ⌘R; board items that aren't local yet are fetched by id
- **Inbox**: GitHub notifications (only this repository and the parity fork, only participating,
  not watching); the unread count shows on the tab, the Dock and the menu bar; opening an item or
  pressing `n` marks it read on GitHub

## 3.1 Triage (Bugen's Board)

Triage is a manual decision, written to the board; an item's live state (Turn, approvals, CI,
conflicts, merged / closed) is computed from the API, not maintained by hand. The app never changes
Status on its own, with the single exception of approvals below.

| Status | Meaning | GitHub subscription |
|---|---|---|
| (not on the board, or no Status) | Untriaged | Unchanged |
| **Working** | Needs my attention now | Unchanged |
| **Backlog** | I want to follow it, but later (including stalled items and ones I'd rather not think about for now) | Unchanged |
| **Skipped** | Low quality or low priority; ignored for now | UNSUBSCRIBED (notified only when participating or mentioned) |
| **Muted** | Not following at all; a friendly close | UNSUBSCRIBED (same as Skipped) |
| **Merging** | Merger has taken the PR on to merge it; set by Merger and by the app on 🚀 (§3.3), never offered as a choice | Unchanged |
| **Done** | Merged or closed; set by the board's own workflow, never by the app | Unchanged |

- The names describe only what I did, not a verdict on the PR, since people in the org may see the
  board
- Setting Skipped / Muted first records the subscription at the time (SUBSCRIBED or UNSUBSCRIBED);
  changing to any other status restores the recorded one, or SUBSCRIBED when there is no record
  (e.g. set before this rule existed). So undoing a skip returns exactly to the old subscription
- **Skipped and Muted differ only in the app**: GitHub can no longer fully silence notifications
  for a single PR / issue (neither GraphQL's `IGNORED` nor REST's ignored thread setting works; the
  latter only deletes the thread subscription), so on GitHub both are just UNSUBSCRIBED: mentions
  and review requests still notify. In the app:
  - Skipped items can be woken (see below); Muted ones can't and stay in Muted
  - Inbox and unread counts leave out notifications for Muted items, but count Skipped ones as usual
- Changing subscriptions needs a token with the `notifications` scope
  (`gh auth refresh -h github.com -s notifications`)
- **Items I opened**: with no Status they count as Working (for display and filtering) and don't go
  to Triage, since there's nothing to triage; this default isn't written to the board. `w` / `b` /
  `s` / `m` write Status as usual; choosing Triage in the detail doesn't clear the default
- **PRs I approve**: the board's own "Code review approved" workflow sets PRs on the board to `Good`
  (counted as Working; approved ones go to the Good group). It can't reach PRs that aren't on the
  board (or are archived), so the app adds those to the board as `Good`; for PRs already on the
  board it leaves the write to the workflow. Approvals made in the app are added right away;
  approvals made elsewhere (on the web) are added after the sync that reads the board: only
  approvals since the last check (minus the search's index slack) count, and the first check only
  records a starting point, so approvals from before this rule aren't backfilled. A PR that was
  added and then taken off the board isn't added back for the same approval
- **Priority**: a single-select field on the board: High / Medium / Low
- **Comment**: a text field on the board, the item's note (usually the next step); read-only in the
  app, shown after the title in the list
- **Pinned**: a single-select field on the board with one option, `Pinned`: my pins (`p`), kept on
  the board rather than locally so they're the same wherever the board is read. Pinning an item that
  isn't on the board adds it without a Status (so it shows in Triage unless it's mine; the board's
  automation may still give an approved PR Good). Items of the other tracker can't be pinned
- **Other Statuses**: `Python Parity Backlog` belongs to another tracker; the app ignores those
  items completely (doesn't show or change them). The old `Good` and `Pending` count as Working,
  `Stale` as Backlog; Done on an open item (e.g. reopened) counts as untriaged
- **Woken**: a Skipped item goes back to Triage, with a reason tag, if someone reaches me directly
  after it was skipped; Status itself is unchanged. "Reaches me directly" means:
  - I'm mentioned
  - someone requests my review by hand (not the automatic requests the author sends on opening,
    marking ready or pushing)
  - on an item I've taken part in, someone else comments or reviews after my last activity

  Pressing `s` on a woken item (or choosing Skipped in the detail) skips it again: Skipped is
  written again, its set time refreshed, and the subscription set back to UNSUBSCRIBED (GitHub
  subscribes automatically on mentions)
- **Status changed on the web**: when a sync finds a Status changed outside the app (different
  from the local cache), the subscription follows the rules above, as if changed in the app; only
  once, at the change, so subscriptions changed by hand on GitHub afterwards aren't reverted. Done
  (set by the board's workflow), removal from the board and archiving don't count; neither does the
  first board read, which has nothing to compare against
- Writes take effect locally right away, then go to GitHub; on sync the board wins

## 3.2 Parity (the Rust parity agent)

The Rust frontend's parity agent (`notes/vllm-rust-parity-agent-runbook.md` in the `richard`
repository) opens staging PRs on the fork every day, which I review; after approving, I have the
agent promote them to upstream PRs by hand, and after upstream approval have it merge them. The app
only watches this pipeline and lets me review in it; it doesn't run the agent or read its ledger:
every stage is computed from state on GitHub.

- **Staging PRs**: PRs on `BugenZhao/vllm` opened by `richard-for-bugen[bot]`
  (`author:app/richard-for-bugen`), synced incrementally with the main repository, with the same
  90-day lookback. PRs I opened on the fork myself (e.g. a stack under an upstream PR) aren't
  staging PRs; they don't go to the Parity tab and appear only in the Inbox
- **Matching**: by branch name. Staging branches are `richard/parity-fix-<slug>`,
  `richard/parity-impl-<slug>` or `richard/parity-run-<slug>`; the promoted upstream PR is mine, on
  `bz/rust-parity-<slug>` (a run PR's slug carries the `run-` prefix on both sides). Only open or
  merged upstream PRs count; with several for one slug, the open one wins, then the newest. The
  agent sometimes shortens the slug when promoting (`parity-fix-drop-incomplete-call-markup` →
  `bz/rust-parity-drop-incomplete-call`), so a staging PR with no upstream PR of the same name falls
  back to an upstream PR not claimed by another staging PR, opened after it, with the same title or
  a slug that is its slug cut at a `-` (same title first, then longest slug)
- **My decisions** are actions on GitHub, which the agent reads on its next run:
  - Approve: ready to promote
  - Comment or Request changes: the agent replies or revises on its next run
  - Park (convert to draft): later; the agent parks the item as `backlog`. Resume (mark ready for
    review) undoes it
  - Close: not wanted; the agent records it as `accepted-divergence`
- Staging PRs aren't on the board and have no Status / Priority; `w` / `b` / `s` / `m` and the
  number keys do nothing on them; they don't go to the Dashboard either (nor Recently viewed or
  Pinned). Promoted upstream parity PRs, though mine, are also only in the Parity tab: the agent
  writes and merges them, so in Working they'd just be noise. Their Status / Priority can still be
  set, their notifications still go to the Inbox, and opening one (links, back and forward) jumps to
  the Parity tab. On the Dashboard, the header of the group they would be in notes how many, e.g.
  `Working 19 (+10 in Parity)` (open ones only, following the filter)
- **Turn** (staging PRs): `me` if approved (waiting for me to have the agent promote it); `them` if
  draft; otherwise `me` if I've never commented or reviewed, or the agent pushed or replied after my
  last comment / review, and `them` in all other cases
- Unread, the summary and Turn count the agent's comments and pushes as the other side's actions
  (unlike other bots, which don't count); the detail timeline always shows the agent's comments and
  pushes, regardless of "Show automated"
- **Parity tab** groups, top to bottom:
  - **Review**: open, non-draft, unapproved staging PRs with Turn = me
  - **Discussing**: the same with Turn = them: I've commented and am waiting for the agent
  - **Approved**: approved by me, with no upstream PR yet: waiting to be promoted
  - **Upstream**: the open upstream parity PRs themselves (`bz/rust-parity-*`), so the Review, CI
    and Turn columns are upstream's. Their staging PRs aren't listed separately
  - **Parked**: draft staging PRs, collapsed by default
  - **Landed**: upstream parity PRs merged in the last 14 days (listed as upstream PRs like
    Upstream; on merge the same row moves from Upstream to Landed), collapsed by default
  - **Rejected**: staging PRs closed without merging in the last 14 days, collapsed by default
- The tab sits between Dashboard and Inbox and shows how many wait on me (`Parity 3`): the Review
  group, plus the Upstream rows with Turn = me (upstream reviews, CI failures, conflicts)
- Columns: Author (always the agent or me) becomes **Link**, showing the state icon and number of
  the PR at the other end: upstream PRs in Upstream and Landed show their staging PR; hovering shows
  the repository and title
- Avatars of GitHub Apps (such as the agent) can't be fetched by login; use the avatar URL from
  the sync

## 3.3 Sending to Grok Bots

In Grok Bot chats I hand work to bots with emoji; the app uses the same vocabulary to send selected
items to a bot (through the bundled grokbot CLI, `grokbot ask --no-wait`), and results come back in
Grok Bot as usual:

- 👀 Investigate (`e`) → Richard Loop: have the agent look into it further
- 🔥 Track (`f`) → Richard Loop: add it to the Notion tracker for the next workday; Richard sets
  it to Working on the board, so the app leaves the board alone
- 🚀 Merge (`r`) → Merger: drives CI and merges following the merge skill; only for PRs in the
  repository that are open and approved (reviewDecision = APPROVED, the same condition as the Good
  group). For other items it's grayed out in the context menu and the key is ignored (staging PRs
  go through the parity agent). Giving a PR number is authorization, so it always asks before
  sending

**Merging**: Merger tracks what it is merging on the board, so the app sees every merge in flight,
including ones I asked for in the chat rather than with `r`. Before working on a PR, Merger sets
its Status to **Merging** (adding it to the board if it isn't there); once merged, the board's
workflow sets Done. Merger works through what comes up on the way itself (trivial conflicts, CI
failures, possibly in a short-lived Claude session); only when I explicitly take the PR over or
call the merge off does it set the Status back to Working and write why in the Comment field.
The app sets Merging itself once a 🚀 send goes through, so it shows at once rather than when
Merger gets to it. A PR not on the board yet (or archived) is put on it first, and Merging goes on
only once the board's automation has given it a Status (it sets an approved PR it is given to Good,
which would overwrite Merging), or after 30 s without one; the app shows Merging all along. Merging
is never offered as a choice (the detail shows it while an item has it), and `w` / `b` / `s` / `m`
move an item out as usual. Merging PRs have no group of their
own: they stay in Good (or Working, once no longer approved), at the bottom, with a purple icon
(§4.1). The board's "Code review approved"
workflow may turn a Merging PR back to Good if someone approves it mid-merge; that's accepted

👀 and 🔥 both have Richard open an agent session (Claude Code now, maybe Codex, Kimi and others
later), and it appends the link to the board's **Session** text field (space-separated, oldest
first; for 👀 it adds the item to the board if it isn't there, without setting Status). The app only
reads this field: items with a session show a `terminal` icon after the title, listing the links
on hover; a button at the top of the detail opens the newest (with a menu of all of them when
there are several), and `t` (or Open Agent Session in the context menu) opens the newest for each
selected item. Links can be from any agent, web links or a desktop app's own deep links: agents the
app knows (`AgentSession.known`: Claude Code, Codex, Kimi Code) show their name; Claude Code web
links are rewritten to `claude://code/session_…` to open in the Claude app, while Codex's
`codex://threads/<id>` (ChatGPT app) and Kimi Code's `kimi-lite://sessions/<id>` (Kimi Lite) are
handed to the system as is. Other links are named by their domain (deep links by their scheme) and
opened as is. Switching agents only needs Richard to write that agent's session links; to show a
name or rewrite links, add an entry to `known`.

The message is `[Sent from PR Desk] <emoji> <link> <title>`; with several selected, one message with
a line per item (for 🚀, one batch). Holding ⌥ (`⌥E` / `⌥F` / `⌥R`, or the "…" items that appear in
the context menu while holding ⌥) opens a send panel first, where a note for the bot can be added;
it goes at the end of the message after a blank line, verbatim. 🚀 and re-sends always open this
panel first (the note can be empty; `⌘↩` sends, `esc` cancels). Nothing is drawn on the row: the
status bar shows the send, and what it leads to shows on the board (🔥 → Working, 👀 / 🔥 → a
Session link; 🚀 → Merging, which the app sets itself). The local database keeps the last send of each kind (when, and the
note), which is what makes a send a re-send; the context menu checks the kinds already sent. Bot
names are set in Settings → Grok Bot (name, unique prefix or id); the CLI shares its sign-in with
other grokbot copies (`grokbot login`). At build time `scripts/embed-grokbot.sh` compiles
grokbot-cli at the commit pinned in the script (cached per commit), signs it and puts it in
`Contents/Helpers/`. In tests, dry-run only logs instead of sending.

## 4. Main window

```
┌ Toolbar:                  Dashboard | Parity (n) | Inbox (n)  🔍 Filter (/)  ⟳  ▣ │ Conversation | Checks | Files ┐
├ List ─────────────────────────────────────────────┬ Detail ────────────────────────────────────────────┤
│                                                   │ #56492 [Core] Extensible KV cache                  │
│ ▾ Recently viewed 8                               │ by njhill ◆◆  draft  CI ● 16 failed  conflicts     │
│ ▾ Pinned 2                                        │ [Triage Working Backlog Skipped Muted] [H M L –]   │
│ ▾ Good 1                                          │ [Pin] [Open ↗]   Comment: ...                      │
│ ▾ Working 9                                       │ Conversation | Checks | Files                      │
│ ▾ Triage 180                                      │ ...timeline...                                     │
│ ▸ Backlog 31                                      │                                                    │
│                                                   │ ┌ Comment box ──────────── Comment / Approve … ┐  │
├───────────────────────────────────────────────────┴────────────────────────────────────────────────────┤
└ Status bar: j/k move · w/b/s/m … (shortcut hints)   BugenZhao · vllm-project/vllm · Board #56 · 403 items · Synced 12s ago · API quota 4,821 left ┘
```

The left of the status bar normally shows shortcut hints; while a write is in flight it shows that
write instead (a spinner plus e.g. `#63887 → Working`, `🔥 #63887 → Richard Loop`,
`Approve #63887`), then a checkmark for 3 seconds when done before going back; on failure it goes
straight back, and the error still shows in an alert. This covers board Status / Priority, sends to
Grok Bots, comments / reviews, Close and Park / Resume; with several at once, the newest shows.

After a relaunch the window comes back as it was: Dashboard / Inbox, the selected item (only
selected, not opened: not marked read and not added to Recently viewed), and whether the detail
pane is shown.

### 4.1 Groups

Top to bottom:

- **Recently viewed**: the 8 most recently viewed items (local). Selecting an item views it and
  marks it read, with no delay; only my own selections count, not ones the list makes itself (e.g.
  selecting the neighbor when a row leaves the list, or restoring the selection at launch).
  Selecting inside Recently viewed only marks read and doesn't reorder it, so `j` doesn't bounce
  between the top two rows
- **Pinned**: items pinned with `p` (the board's Pinned field, §3.1)
- **Good**: open items with Status = Working (or Merging), plus open items I opened that have no
  Status, that are approved PRs; mine first, then PRs Merger is merging (Status = Merging) last, so
  what waits for 🚀 comes first. A Merging PR draws its open icon purple (the merge color), unless
  it is a draft or has conflicts, which keep their own icon
- **Working**: the same, without approval; mine first
- **Triage**: untriaged open items opened by others, plus woken Skipped items
- **Backlog**: open items with Status = Backlog, collapsed by default; mine first
- **Recently closed**: items merged / closed in the last 14 days, collapsed by default
- **Skipped**, **Muted**: open items with that Status, collapsed by default

Apart from Recently viewed and Pinned, each item appears in exactly one group. All groups always
show, empty ones too (with a count of 0); a group header's tooltip explains what the group holds
and how it relates to the board. Collapsed state persists, and expanding / collapsing doesn't move
the scroll position. While filtering, all matches show regardless of collapsing. An item whose
Status changes animates to its new group (fading out if the new group is collapsed), and the
selection lands on the next item in its old place; expanding / collapsing and filtering animate
too, however many rows. Group headers are separated by lines

**Stacks**: PRs of one stack in the same group sit together, base on top and the top of the stack at
the bottom, the whole run placed where the base would sort under the current sort (on any column).
Stacks are GitHub's official stacks (`stack` / `stackEntry`, members joined by position), plus PRs
in the same repository whose base branch is another PR's head branch, plus PRs whose commits start
with another PR's (stacks GitHub doesn't know about). The last are stacks from forks, whose authors
can't push branches upstream: every level is based on `main` and carries the commits of the levels
below it until they merge. The list query fetches each PR's first and head commits; for PRs that
share their first commit (and repository and base branch) with another, each sync fetches their
first 100 commits once per head. A PR is on the one whose head commit comes last among its own
commits; with none there (the PR below moved on, e.g. merged `main` in, after this one was cut from
it), on the earlier PR its commits share the longest start with, where both went on past it.
Joined by branches or commits, one PR can have several PRs
on top of it, so a stack is a tree: laid
out depth first, each PR's first child (the next level of an official stack first, then by number)
right after it on the same line, other children after the first child's whole subtree, each on a
new line (like `git log --graph`). Members in different groups stay in their own groups with no
placeholder rows; a group with only one member of a stack doesn't link it to anything. A member
whose neighbor in the stack is in another group (or filtered out) gets a short line fading out
from its node toward the top of the row (the PR it is based on is elsewhere) or the bottom (a PR on
it is elsewhere), stopping short of the row's edge so it stays apart from in-group links; a lone
member gets its node for this too. Not drawn where the node already has a line that way. Recently
viewed (ordered by when each item was opened) and Inbox keep their own order and don't gather
stacks; Pinned sorts like the other groups and gathers them. The Parity tab's groups gather them as
well

### 4.2 Columns

| Column | Content |
|---|---|
| (row) | Closed items are faded as a whole row; so are draft PRs (keeping only the unread dot), setting them apart from PRs waiting for review at a glance |
| (marker) | The first, narrow column: `•` for unread activity from others since I last saw the item: opened it here, or read its notification anywhere (on the web, in GitHub's apps), going by when GitHub says each notification updated in the last 14 days was last read. When the item is in a stack, this column draws the stack's lines (see §4.1), with this dot as the node: the accent color when unread, otherwise gray (the icon before the title shows state), hollow for drafts; a forked child turns from its parent onto its own line to the right; official stacks are joined by solid lines, branch- and commit-joined ones by dashed lines. Two lines fit, with narrower spacing for more. Hovering shows the stack number and position, the base branch, the PR whose commits it starts with (for a commit-joined one), and which members are in other groups. Priority has no column of its own, only the row's background (§4.3) |
| # | Number; small icons tell PRs and issues apart |
| Title | State icon + title (leading `[..]` / `xx:` tags faded), a reason tag on woken items; the matching emoji on items sent to Grok Bots, and a `terminal` icon on items with a board Session (§3.3); then the board Comment, if any; a gray summary of the latest event (e.g. `@xx commented 2h`, `you reviewed 2d`) always right-aligned; truncated text (title, comment, summary) shows in full in a tooltip on hover |
| Author | Avatar + login (italic for first-time contributors); trust marks (seal, org badges, see §5, §5.1) right-aligned |
| Review | A bare ✓ + total approvals (including mine): on others' PRs, green when I've approved, gray when only others have; on my own PRs (which I can't approve), green when reviewDecision = APPROVED (approvals meet the merge requirement, the same condition as the Good group), gray otherwise; a red ✗ follows when I've requested changes. Built like the CI column: a small mark + a number, in fixed positions |
| Turn | `review` (my review requested and not done) / `me` / `them` / empty (closed) |
| CI | A colored dot: green passed / red failed / yellow running / gray cancelled; solid with the `ready` label, hollow without; failed / running counts in the tooltip |
| Size | `+add` on the left, `−del` on the right, in colors a shade darker than the system green / red (GitHub's diff colors), distinct from Review / CI (empty for issues); fits at least `+8888 −8888` |
| Age / Upd | Relative time |

- Every column sorts on click, Upd descending by default; column widths, order and visibility
  persist
- Rows are about 20 pt tall, text 11–12 pt, with monospaced digits in number columns

### 4.3 Colors

- Row background: light orange for H, light yellow for M, none for L and no priority (rows already
  alternate in the system's colors); L has no mark in the list, but `p:l` filters for it
- Turn = me in the body color, bold (no color: color is for priority); merged and closed rows are
  faded as a whole
- The selected row uses the system selection color; every color above has light and dark variants

### 4.4 Filtering

- The filter field sits on the list side of the toolbar (`/` focuses it; return, or esc when empty,
  goes back to the list); free text matches title, number and author
- Tokens: `is:pr` `is:issue` `is:draft` `is:open` `is:unread` `is:pinned` `is:first` `is:regular`
  `status:triage|working|backlog|skipped|muted` `turn:me` `author:x` `label:x` `ci:fail` `p:h`
  `org:redhat` `merged:>=10`; a leading `-` negates

### 4.5 Keyboard shortcuts

| Key | Action |
|---|---|
| `j` / `k`, `↑` / `↓` | Move |
| `esc` | Deselect, returning the detail pane to its empty state; with nothing selected, clear the filter |
| `⌘` / `⇧` click | Multiple selection; the shortcuts below and the context menu act on every selected item (right-clicking a row outside the selection acts on that row only). Toggles act on the whole selection: cleared if all are already set, otherwise set on all |
| `/` | Focus the filter field |
| `w` / `b` / `s` / `m` | Set Status to Working / Backlog / Skipped / Muted; pressing the same key again clears Status (back to untriaged); `s` on a woken Skipped item skips it again instead of clearing |
| `⌘Z` / `⇧⌘Z` | With the list focused, undo / redo list actions: Status, Priority, Pin (Mark as read and Close can't be undone); board writes for one item go out in order, so an undo never reaches GitHub before the original; in text fields it's still text undo |
| `1` / `2` / `3` / `0` | Set Priority to H / M / L / clear |
| `p` | Pin / unpin |
| `n` | Mark read; on a read item, mark unread until opened again or `n` is pressed, even if its notification was read (local only, GitHub notifications unchanged); opening it then shows the latest activity by others as new |
| `o` / `↩`, `⌘O` | Open in the browser (`⌘O` works with any focus, on the current selection) |
| `u`, `⇧⌘O` | Open the author's GitHub profile (also in the row's context menu; `⇧⌘O` works with any focus) |
| `⇧⌘C`, `⌘C` | Copy GitHub links, one per line (`⇧⌘C` works with any focus: all selected items when the list is focused, otherwise the item in the detail; `⌘C` only in the list). Rows can also be dragged out sideways, as links with titles |
| `e` / `f` / `r` | Send to a Grok Bot: 👀 Investigate / 🔥 Track / 🚀 Merge (§3.3; 🚀 and re-sends open the send panel first); with `⌥`, open the panel first to write a note |
| `t` | Open the agent session (the board's Session field, the newest one; in the desktop app when there is one; §3.3) |
| `c` | Focus the comment box |
| `⌘R` | Sync now |
| `⌘1` / `⌘2` / `⌘3` | Switch to Dashboard / Parity / Inbox |
| `⌥⌘1` / `⌥⌘2` / `⌥⌘3` | Switch a PR's detail to Conversation / Checks / Files |
| `⌘B` | Show / hide the detail pane (kept across relaunches) |
| `⌃⌥⌘D` | Global: open the issue / PR of Yab's current tab in the desk (§6, back to the desk from the browser) |
| `⌘V` | With the list focused, open the issue / PR the link on the clipboard points to |
| `⌥↑` / `⌥↓` | Move along the selected PR's stack to the next level (toward the base / the top, §6) |

## 5. Org badges

Badges mean "trusted": **vLLM committer**, **Inferact**, **Red Hat**, **NVIDIA**, and the companies
contributing most in the last six months (picked from the top contributors overall and to the Rust
frontend): **AMD**, **Intel**, **IBM**, **Hugging Face**, **Mistral AI**, **Meta**, **Google**,
**DaoCloud**, **Huawei**, **Microsoft**, **Alibaba**, **Ant Group**, **ByteDance**, **Moonshot AI**,
**Arm**, **Samsung**, **EmbeddedLLM**, **Cohere**, and the companies of the people met most often in
the threads the viewer took part in: **Amazon**, **Baseten**, **DigitalOcean**, **Tencent**,
**CoreWeave**; and **llm-d**, a project several of those companies run
together, which doesn't stand in for anyone's employer. Projects come before companies: vLLM, then
llm-d, then the employer (e.g. llm-d then Red Hat). The icons are bundled in the app, never fetched, and are
transparent graphic marks without text where possible: vLLM, Inferact, NVIDIA, AMD (the arrow),
Meta, Huawei, Mistral AI, DaoCloud, Alibaba (the Alibaba Cloud mark), Ant Group and Moonshot AI
mostly come from Simple Icons (AMD and Moonshot white in dark mode), as do Amazon (the smile, white
in dark mode) and DigitalOcean; Cohere's and Tencent's from Lobe Icons (MIT, Cohere's dark green and
Tencent's blue lightened in dark mode); the GitHub org avatars of Red
Hat, Google, Hugging Face, Microsoft and ByteDance are transparent marks themselves, bundled as
128 px PNGs, and Baseten's (its glyph, cut from the green square, white in dark mode) and
CoreWeave's (cut to its circle) are made transparent; text-only logos (Intel, IBM, Arm, Samsung, EmbeddedLLM) are drawn as small squares in
the brand color with an abbreviation; llm-d's is the hexagon mark from its website's logo
(Apache-2.0, with its own dark variant). vLLM also has a lower, gray tier (the logo desaturated) for
members of the `vllm-project` org and repository collaborators (triage permission or above) who
aren't committers.

Sources, from highest priority to lowest; the first match wins, and hovering shows which one
matched:

1. Manual settings: per person, per org, stored locally (`orgOverride`); badges can be added, or
   forcibly excluded (hiding a detected badge)
   - **Author's Affiliation** in a list row's context menu, and **Affiliation** in the context menu
     of a name in the detail header or timeline: lists every org (with its badge icon), checking
     the ones with a full badge (vLLM's gray tier doesn't count); for a single person, the list and
     timeline menus note each item's source under it (the detected source, or "Added manually" /
     "Hidden manually"); choosing an org toggles it: added by hand if missing (restoring a detected
     badge that was hidden by hand), removed if present (deleted if added by hand, hidden by hand if
     detected). With several rows selected it acts on every author: orgs some have show a dash, and
     choosing one adds it to all
   - **Clear Manual Affiliations** deletes all of a person's manual settings, back to what was
     detected
   - The table in Settings → Affiliations can add and remove too; changes show in the list and
     detail right away
2. vLLM committer: parsed from the repository's `docs/governance/committers.md`, with their areas
   (e.g. "Rust frontend") on hover; people not in it but in `.github/CODEOWNERS` (code owners, which
   needs write permission) also get the colored badge, with the paths they own on hover (the first
   3, the rest counted), and `org:committer` matches them too. Then the gray tier: `vllm-project` org
   members, then repository collaborators (listing collaborators needs push permission; skipped
   without it). `author_association` isn't used: it's attached to a single item, not a person, and
   varies with the viewer's permissions
   - llm-d works the same way: the people in `MAINTAINERS.md` of `llm-d/llm-d` (with their section,
     e.g. "Project Leadership", on hover), then the approvers and reviewers in the `OWNERS` files
     and the people in the `CODEOWNERS` files of every active `llm-d` repository (e.g. "approver of
     llm-d-kv-cache"), fetched in one query; its maintainers are spread across companies (Google,
     IBM, Red Hat and more), and most aren't public members of the org
3. GitHub org membership: the member lists of `Inferact`, `NVIDIA` / `ai-dynamo`,
   `RedHatOfficial` / `redhat-et` / `neuralmagic` and `llm-d` / `llm-d-incubation` are fetched daily (all members are visible for
   orgs you're in, such as Inferact; only public members for the rest); big companies (`amd`,
   `intel`, `google` and so on) have too many public members to list, so only the user's own public
   orgs are checked
4. The profile's company field, matched as whole words (`intel` matches `@intel` and
   `Intel Corporation`, not `Intelligence`), e.g. `@Inferact`, `Red Hat`, `AMD`, `@ROCm`
5. The first `@` mention in the bio other than `@vllm-project`, e.g. "Software Engineer @mistralai",
   when it is one of the org's GitHub orgs or matches its company patterns (`@AMD`, `@llm-d`); later
   mentions tend to be projects contributed to or past jobs ("Contributor to @vllm-project, @llm-d",
   "prev @Huawei")
6. The domain of the public email on the profile, e.g. `@intel.com`, unless the company field names
   another org (a public email can be left over from a past job); profiles stored before bios and
   public emails were read get both in one cheap query per 100 people
7. The email domain of the commit authors on the user's PRs (subdomains included, e.g.
   `us.ibm.com`): `redhat.com`, `nvidia.com`, `amd.com`, `intel.com` and so on
8. Login suffixes, e.g. `-redhat`, `-nv`, `-amd`, `-intel`, `-ibm`, `-cohere`, `-aws`, then prefixes
   for work accounts: `amd-`, `nv-` / `nvidia-`, `intel-`, `aws-` / `amzn-`

`ai-dynamo` stays under NVIDIA rather than getting a badge of its own: nearly everyone working on
Dynamo whom the repository sees is at NVIDIA anyway.

User info is cached for 7 days; committers.md, CODEOWNERS, llm-d's maintainers, org members and collaborators refresh
daily.

Filtering: `org:vllm` matches both tiers, `org:committer` only committers, `org:member` only the
gray tier.

## 5.1 Contributor marks

- Counts each author's merged PRs in vllm (GitHub search, 40 people per batch, refreshed weekly;
  daily for those at 0)
- Merged count ≥ threshold (10 by default, adjustable in Settings → Affiliations): a green outlined
  seal icon, right-aligned with the org badges; not shown for authors who already have an org badge
- Merged count = 0 and no org badge at all: the author's name is italic, meaning "no record, worth
  a look", without taking a badge slot (the reason shows on hover); first-time contributors with an
  org badge aren't italic (`is:first` still filters for them)
- Hovering shows the exact number; shown in the list, detail header and timeline
- Filtering: `merged:N`, `merged:>=N` (also `>`, `<`, `<=`), `is:regular`, `is:first`
- Stored only locally; never written to the board and doesn't affect grouping

## 6. Detail pane

- **Header**: title, author and badges, state (draft / open / merged / closed), CI summary,
  mergeable / conflicts, labels, created and updated times
  - Double-clicking the title renames the item in place, as in Finder: the title becomes a field
    in the same font and place with its text selected; Return or clicking away renames it on
    GitHub, Escape leaves it as it was (an empty or unchanged title does nothing; line breaks
    become spaces). The new title shows in the header and the list at once and the old one comes
    back if the write fails
- **Stack**: when the PR is in a stack (the official stack from the detail query, plus PRs found by
  following base branches (or the commits a PR starts with) down and open PRs on any of those
  branches (or starting with those PRs' commits), all looked up among local items), the header
  shows a small table with the same tree rail as the list on its left (nodes in place of state
  icons; staging PRs merged by promotion in purple): a title row `Stack 66533 · 3 of 4 · 2 merged`
  (`Stacked by branch` / `Stacked by commits` in place of the number for stacks GitHub doesn't
  know about), then the base branch (`main`) as the first row, then positions
  1…N. Adjacent PRs merged together (within a minute, i.e. one stack merge) fold into one row
  `2 merged together · 5h ago` that expands on click; PRs merged on their own get a row each as
  usual. Each row is a state icon, number and title (as in the list: when any row's title doesn't
  fit, every row's leading tags are abbreviated alike, e.g. `[RF][Fix]`), with notes on the right:
  when it was merged / closed; the upstream PR a parity staging PR was promoted to (`⬆#65636` and its
  state, so a closed level on the fork isn't mistaken for a rejection); an orange `on merged #N` for
  an open PR still on the branch, or still carrying the commits, of a merged or closed PR. The current PR is bold and highlighted;
  clicking another row opens it in the app. `⌥↑` / `⌥↓` (with the list or conversation focused)
  move along the stack toward the base / the top. The timeline shows stack join / leave events
- **Actions**: Status (Triage / Working / Backlog / Skipped / Muted), Priority (H / M / L / –), Pin,
  Open ↗; parity staging PRs get Park / Resume instead (§3.2)
- **Conversation**:
  - The timeline includes comments, reviews (with summaries and diff hunks of inline comments),
    pushes, labels and state changes
  - "Show automated" is off by default; when off, automated content is hidden:
    - events by bot and agent accounts (`[bot]` accounts, mergify, github-actions, vllm-agent and
      so on)
    - command-only comments: `[AUTOMATED] …`, or every line a command such as `@codex review`,
      `@claude review` or `/ci …` (3 lines at most)
  - The list's summary, Turn and unread ignore these accounts' actions (the list doesn't fetch
    comment bodies, so command comments still count as taking part there)
  - Clicking a name or avatar opens their GitHub profile (the author name in the detail header
    too); right-clicking a name offers affiliations, opening the profile and copying the login
  - Everything can be expanded / collapsed at once; comments and reviews without a body (mostly
    approvals with no text) show just a header line and can't expand
  - Reactions show under the description, comments, reviews and inline comments (hover to see
    who); clicking one adds or removes mine; a smiley button on card and inline comment headers
    (shown on hover) offers all 8. Clicks take effect locally first and revert if the write fails
  - New content since the last view is highlighted, and the page scrolls to the first new item
- **Checks**: check runs and statuses grouped by state, failures on top; clicking opens the log URL
- **Files**: the changed files and their diffs, also one `WKWebView` page; each file collapsed by
  default, long file names drop the directory part, file headers stick while scrolling; syntax
  highlighting by extension (highlight.js, the old and new sides highlighted separately); copying
  leaves out line numbers and +/-; soft wrap can be toggled; an expanded file's diff is generated
  only when it nears the screen, and filled in before ⌘F finds
  - File headers have GitHub's Viewed checkbox (just the box, no text; also in the file header's
    context menu), synced with the GitHub website: checking collapses the file, unchecking expands
    it again; a file changed by a new push since it was checked gets an orange box; the toolbar
    shows how many are viewed. Clicks take effect locally first and revert if the write fails;
    without the marks, no checkboxes show
- **Links within the repo**: links in the detail to issues / PRs in this repository open in the
  app: ones already in the list are jumped to (expanding their group and clearing the filter if
  needed); others are fetched on the spot into an **Opened from links** group at the top of the
  list (kept only for this run, not stored), where they can be added with Add to Desk (`a`, into
  Triage), and setting Status / Priority / Pin adds them as well. A link to a comment on the current
  item expands and scrolls to that comment. ⌘-click and the ↗ button still open the browser
- **Back to the desk from the browser**: `⌃⌥⌘D` (a global shortcut, a Carbon hot key that needs no
  Accessibility permission; also in the Go menu and the menu bar icon's menu) reads Yab's frontmost
  tab (`yab exec`, read-only), brings the window forward, and opens the issue / PR it points to by
  the rules for links above: selected if in the list; expanded / filter cleared and then selected
  if on the desk but hidden; otherwise fetched into **Opened from links**. This counts as opening
  (marked read, added to Recently viewed). `/files` (or `/changes`) and `/checks` in the link switch
  to that detail tab; `#issuecomment-…`, `#discussion_r…`, `#pullrequestreview-…` and the like scroll
  to that comment once it appears in the conversation (if the cache doesn't have it yet, once the
  live detail arrives). If the tab isn't an issue / PR of these two repositories, an alert says so.
  Without Yab: `⌘V` to paste a link with the list focused, dropping a link on the list, or typing a
  link in the filter field and pressing `↩` does the same; `#123` in the filter field is fetched on
  `↩` only when nothing in the list matches, otherwise `↩` goes back to the list as usual
- **Back / forward**: ⌘[ / ⌘] (and the mouse's side buttons) move between items that were
  selected, restoring each one's scroll position and expansion state on return
- **Writes**: a Markdown comment box at the bottom (with preview, `⌘↩` sends); open items can be
  closed: PRs directly, issues as completed / not planned. With text in the box, it's posted as a
  comment first and then closed (Close with comment). Closing asks for confirmation and has no
  shortcut
  - PRs: Comment / Approve / Request changes, submitted as a whole review with a body
  - Issues: Comment only
  - Inline code comments are for v2, in Files

## 7. Local state (SQLite)

- `items`: PR / issue snapshot fields + the raw JSON, with the repository (numbers are only unique
  within one)
- `item_state`: viewed_at, seen_at, marked_unread_at, when its notification was last read on
  GitHub, the last send time and note of each kind of Grok Bot request (keyed by the item's node id)
- `board_item`: the cache of board items (item id, Status and when it was set, Priority, Comment,
  Session, Pinned)
- `users`: login, avatar, company, orgs, email domains, committer areas, sources, fetched_at
- `org_overrides`: the manual mappings
- `timeline_cache`: the detail cache (with the item's updated time, which prefetching uses to judge
  staleness)
- `sync_meta`: sync metadata

## 8. Turn rules (`me` / `them`)

**I'm the PR author**: `me` if any of these holds, `them` otherwise:

- Unaddressed changes requested
- Comments or reviews from others since my last activity
- CI failing
- Conflicts

**I'm a reviewer**:

- A review request waiting on me (and the PR isn't a draft) → `me`
- I've reviewed, and the author pushed or commented after my last review → `me`
- Otherwise → `them`

**Issues**:

- Assigned to me or mentioning me, with others' latest comment newer than mine → `me`
- Otherwise → `them`

**Merging PRs** (Status = Merging, whoever the author): `me` once the PR is no longer approved,
`them` otherwise; Merger works through conflicts and CI itself.

Empty for closed items.

## 9. Milestones

1. Project skeleton, auth, GraphQL client, first and incremental sync, the list showing items
2. Groups, local state, shortcuts, filtering, colors, persisted sorting and columns
3. Org badges (automatic sources + manual settings)
4. Detail: header, Conversation (native timeline + WebView bodies), Checks
5. Writes: comments, reviews, closing; Inbox
6. Polish: Files diff, unread counts in the menu bar and Dock, performance
