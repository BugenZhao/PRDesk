import AppKit
import Foundation
import Observation
import os

enum ItemAction {
    /// Sets the board Status; choosing the current one again clears it (back to Triage).
    case triage(TriageStatus)
    /// Sets the board Priority; choosing the current one again clears it.
    case priority(Priority?)
    case togglePin
    case markRead
    case openInBrowser
    /// Opens the GitHub profiles of the items' authors.
    case openAuthorProfile
    /// Copies the items' GitHub links, one per line.
    case copyLink
    /// Vote on the item's author; voting the same way again clears the vote.
    case voteAuthor(Vote)
    /// Brings an item opened from a link onto the desk.
    case addToDesk
    /// Sends the items to a Grok Bot with the request's emoji.
    case sendToBot(BotRequest)
}

/// A send to a Grok Bot waiting for the viewer's go-ahead: every merge, and any request the items
/// were already sent with.
struct PendingBotSend: Identifiable {
    let id = UUID()
    var request: BotRequest
    var items: [Item]
    /// How many of `items` were sent with this request before.
    var resends: Int
}

@MainActor
@Observable
final class AppModel {
    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    /// Seconds between automatic syncs, set in Settings. Each round costs a few GraphQL points.
    var syncInterval: Int = Defaults.get(.syncInterval) ?? 300 {
        didSet { Defaults.set(syncInterval, for: .syncInterval) }
    }

    static let syncIntervals = [60, 120, 300, 600, 900]
    /// Rounds are timed from the last attempt, so a failing sync isn't retried every tick.
    @ObservationIgnored private var lastSyncAttemptAt: Date?
    /// How often the poll loop checks whether a sync is due, so a new interval applies promptly.
    private static let pollTick: Duration = .seconds(15)

    private(set) var viewer: String?
    private(set) var syncState: SyncState = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var rateLimit: RateLimit?

    /// The flattened table: section headers and their item rows.
    private(set) var rows: [TableRow] = []
    /// Number of distinct items that pass the filter.
    private(set) var visibleCount = 0

    var filterText = "" { didSet { rebuild() } }
    var sort: ItemSort { didSet { Defaults.set(sort, for: .sort); rebuild() } }
    var collapsed: Set<ListSection> { didSet { Defaults.set(collapsed, for: .collapsed); rebuild() } }
    var selection: TableSelection? {
        didSet {
            if hasSelection != (selection != nil) { hasSelection.toggle() }
            let isPullRequest = selectedItem?.kind == .pullRequest
            if selectionIsPullRequest != isPullRequest { selectionIsPullRequest = isPullRequest }
            restoredSelection = nil
            if selection != oldValue { Defaults.set(selection, for: .selection) }
            selectionChanged(from: oldValue)
        }
    }

    /// Whether anything is selected. Observed apart from `selection`, so views that only care
    /// about this (the menu commands) aren't rebuilt each time the selection moves.
    private(set) var hasSelection = false
    /// Whether the selection is a PR, which has the Checks and Files tabs; observed apart from it
    /// for the same reason.
    private(set) var selectionIsPullRequest = false

    enum DetailTab: Hashable {
        case conversation, checks, files
    }

    /// The detail pane's tab. Here rather than in the pane, for the View menu's commands.
    var detailTab: DetailTab = .conversation

    enum ListMode: String, Hashable, Codable {
        case dashboard, inbox, parity
    }

    var mode: ListMode = Defaults.get(.mode) ?? .dashboard {
        didSet {
            Defaults.set(mode, for: .mode)
            rebuild()
        }
    }

    /// The selection when the app last quit, put back once the list first has rows.
    @ObservationIgnored private var restoredSelection: TableSelection? = Defaults.get(.selection)
    /// Unread notifications for issues and PRs in the repository, newest first.
    private(set) var inbox: [InboxNote] = [] {
        didSet { updateDockBadge() }
    }

    /// Muted items' notifications don't count; GitHub can't always be stopped from sending them.
    var unreadInboxCount: Int { inbox.count { !$0.isRead && !isMuted($0) } }

    private func isMuted(_ note: InboxNote) -> Bool {
        note.isUpstream && board[note.number]?.triage == .muted
    }

    /// What waits on the viewer in the Parity tab, for the tab's count: staging PRs to review, and
    /// upstream PRs whose Turn is the viewer's.
    private(set) var parityWaitingCount = 0
    /// Where each item of the Parity tab is listed, as of the last rebuild.
    @ObservationIgnored private var paritySections: [Item.ID: ListSection] = [:]

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = unreadInboxCount == 0 ? nil : String(unreadInboxCount)
    }
    /// Working and Good items regardless of the filter, the viewer's move first (for the menu bar).
    private(set) var workingItems: [ItemRow] = []

    /// The last write to the board that failed, shown until dismissed.
    var writeError: String?
    /// The last send to a Grok Bot that failed, shown until dismissed.
    var botError: String?
    var pendingBotSend: PendingBotSend?

    /// Bumped to move keyboard focus to the filter field or back to the table.
    private(set) var filterFocusRequest = 0
    private(set) var tableFocusRequest = 0
    private(set) var composerFocusRequest = 0

    private(set) var affiliations = Affiliations()

    /// Authors with at least this many merged PRs get the regular-contributor mark.
    var mergedThreshold: Int = Defaults.get(.mergedThreshold) ?? 10 {
        didSet {
            Defaults.set(mergedThreshold, for: .mergedThreshold)
            affiliationsVersion += 1
            rebuild()
        }
    }

    func contribution(for login: String?) -> Contribution? {
        guard let login, let merged = affiliations.users[login.lowercased()]?.mergedCount else { return nil }
        return Contribution(merged: merged, threshold: mergedThreshold)
    }
    /// Bumped when `affiliations` changes, for views that cache rendered badges.
    private(set) var affiliationsVersion = 0

    enum DetailState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// Detail of the selected item; may briefly be a cached copy while a fresh one loads.
    private(set) var detail: ItemDetail? {
        didSet { if let detail { rememberDetail(detail) } }
    }

    /// Recently shown details, so returning to an item shows it at once rather than after a
    /// database read.
    @ObservationIgnored private var recentDetails: [Item.ID: ItemDetail] = [:]
    @ObservationIgnored private var recentDetailOrder: [Item.ID] = []
    private static let recentDetailLimit = 20

    private func rememberDetail(_ detail: ItemDetail) {
        recentDetails[detail.id] = detail
        recentDetailOrder.removeAll { $0 == detail.id }
        recentDetailOrder.append(detail.id)
        if recentDetailOrder.count > Self.recentDetailLimit {
            recentDetails[recentDetailOrder.removeFirst()] = nil
        }
    }

    private(set) var detailState: DetailState = .idle

    /// `seenAt` of the selected item when it was opened, before opening moved it forward.
    private(set) var selectedItemPreviousSeenAt: Date?

    @ObservationIgnored private var snapshot = Snapshot()
    @ObservationIgnored private var itemsByID: [Item.ID: Item] = [:]
    @ObservationIgnored let db: AppDatabase
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let affiliationEngine: AffiliationEngine
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    /// Cached details older than this are refreshed when shown, even if the item looks unchanged.
    private static let detailMaxAge: TimeInterval = 120
    @ObservationIgnored private let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "App")

    init(db: AppDatabase) {
        self.db = db
        let client = GitHubClient()
        engine = SyncEngine(client: client, db: db)
        affiliationEngine = AffiliationEngine(client: client, db: db)
        sort = Defaults.get(.sort) ?? ItemSort()
        collapsed = Self.loadCollapsed()
    }

    /// The saved collapsed sections, skipping any that no longer exist; sections added since they
    /// were saved start out as their defaults.
    private static func loadCollapsed() -> Set<ListSection> {
        // Sections weren't recorded before the Parity tab; everything else predates it.
        let known: Set<String> = Defaults.get(.knownSections)
            ?? Set(ListSection.allCases.filter { !Parity.sections.contains($0) }.map(\.rawValue))
        Defaults.set(Set(ListSection.allCases.map(\.rawValue)), for: .knownSections)
        guard let saved: [String] = Defaults.get(.collapsed) else { return ListSection.defaultCollapsed }
        let added = ListSection.defaultCollapsed.filter { !known.contains($0.rawValue) }
        let collapsed = Set(saved.compactMap(ListSection.init(rawValue:))).union(added)
        Defaults.set(collapsed, for: .collapsed)
        return collapsed
    }

    var selectedItem: Item? {
        selection.flatMap { itemsByID[$0.itemID] }
    }

    /// Votes on people, by lowercased login.
    private(set) var votes: [String: Vote] = [:]

    func vote(for login: String?) -> Vote? {
        login.flatMap { votes[$0.lowercased()] }
    }

    /// Sets or (with nil) clears the vote on `login`.
    func setVote(_ vote: Vote?, for login: String) {
        Task {
            do {
                try await db.setVote(vote, for: login)
            } catch {
                logger.error("Failed to vote on \(login): \(error)")
            }
        }
    }

    func state(for item: Item) -> ItemState {
        snapshot.states[item.id] ?? ItemState(itemID: item.id)
    }

    /// The triage board by item number; observed (unlike `snapshot`) so the detail pane follows it.
    private(set) var board: [Int: BoardEntry] = [:]

    /// Only upstream items are on the board; its numbers are upstream ones.
    func board(for item: Item) -> BoardEntry? {
        item.isUpstream ? board[item.number] : nil
    }

    /// The item's Status on the board as the list treats it: none for a Skipped item that was
    /// woken. What toggles act on, so the default Working of the viewer's own items is left out.
    func triage(for item: Item) -> TriageStatus? {
        board(for: item)?.triage == nil ? nil : row(for: item).listedTriage
    }

    /// The Status the list shows, the default Working of the viewer's own items included.
    func listedTriage(for item: Item) -> TriageStatus? {
        row(for: item).listedTriage
    }

    private func row(for item: Item) -> ItemRow {
        let state = state(for: item)
        return ItemRow(
            item: item, state: state,
            insight: insight(for: item, state: state),
            authorVote: vote(for: item.author),
            board: board(for: item)
        )
    }

    private struct InsightInputs: Equatable {
        var item: Item
        var state: ItemState
        var viewer: String?
        var baseline: Date?
    }

    /// Insights by item, reused while what they are worked out from stays the same: every
    /// rebuild (each keystroke in the filter) makes rows for all items.
    @ObservationIgnored private var insights: [Item.ID: (inputs: InsightInputs, insight: ItemInsight)] = [:]

    private func insight(for item: Item, state: ItemState) -> ItemInsight {
        let inputs = InsightInputs(item: item, state: state, viewer: viewer, baseline: snapshot.baseline)
        if let cached = insights[item.id], cached.inputs == inputs { return cached.insight }
        let insight = ItemInsight(item: item, state: state, viewer: viewer, baseline: snapshot.baseline)
        insights[item.id] = (inputs, insight)
        return insight
    }

    // MARK: Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        // A mouse's back and forward buttons move through the history like ⌘[ and ⌘].
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            let button = event.buttonNumber
            guard button == 3 || button == 4 else { return event }
            MainActor.assumeIsolated {
                if button == 3 { self?.goBack() } else { self?.goForward() }
            }
            return nil
        }
        tasks.append(Task { [weak self, db] in
            do {
                for try await snapshot in db.observeSnapshot() {
                    guard let self else { return }
                    self.snapshot = snapshot
                    migrateDrafts()
                    for item in snapshot.items {
                        if let author = item.author, let url = item.authorAvatarURL { AvatarCache.remember(url, for: author) }
                    }
                    if votes != snapshot.votes { votes = snapshot.votes }
                    if board != snapshot.board {
                        board = snapshot.board
                        updateDockBadge()
                    }
                    rebuild()
                    restoreSelection()
                    if let item = selectedItem, let detail, detail.id == item.id, detail.itemUpdatedAt < item.updatedAt {
                        loadDetail()
                    }
                }
            } catch {
                self?.logger.error("Observation failed: \(String(describing: error), privacy: .public)")
            }
        })
        tasks.append(Task { [weak self, db] in
            do {
                for try await affiliations in db.observeAffiliations() {
                    guard let self else { return }
                    self.affiliations = affiliations
                    affiliationsVersion += 1
                    if filterText.contains("org:") || filterText.contains("merged:") || filterText.contains("is:") { rebuild() }
                }
            } catch {
                self?.logger.error("Affiliation observation failed: \(String(describing: error), privacy: .public)")
            }
        })
        tasks.append(Task { [weak self] in
            if let viewer = try? await self?.engine.viewer() {
                self?.viewer = viewer
                self?.rebuild()
            }
            while !Task.isCancelled {
                guard let self else { return }
                if lastSyncAttemptAt.map({ Date().timeIntervalSince($0) >= TimeInterval(syncInterval) }) ?? true {
                    await sync(includeBoard: false)
                }
                try? await Task.sleep(for: Self.pollTick)
            }
        })
    }

    /// Syncs now. Unless it is the timer's round, this also reads the board.
    func sync(includeBoard: Bool = true) async {
        guard syncState != .syncing else { return }
        syncState = .syncing
        lastSyncAttemptAt = Date()
        do {
            if let result = try await engine.sync(includeBoard: includeBoard) {
                if viewer != result.viewer {
                    viewer = result.viewer
                    rebuild()
                }
                lastSyncedAt = result.finishedAt
                rateLimit = result.rateLimit
            }
            syncState = .idle
            await syncInbox()
            Task { await refreshAffiliations() }
            prefetchDetails()
        } catch {
            logger.error("Sync failed: \(String(describing: error), privacy: .public)")
            syncState = .failed(error.localizedDescription)
        }
    }

    private func syncInbox() async {
        do {
            let notes = try await engine.fetchInbox()
            // Notifications can be for items no tracking search found; fetch a few at a time.
            let known = Set(snapshot.items.map(\.repoNumber))
            var seen = Set<String>()
            let missing = notes.filter { !known.contains($0.repoNumber) && seen.insert($0.repoNumber).inserted }
            for note in missing.prefix(10) {
                _ = try? await engine.fetchItem(repo: note.repo, number: note.number)
            }
            inbox = notes.sorted { $0.updatedAt > $1.updatedAt }
            rebuild()
            restoreSelection()
        } catch {
            logger.error("Inbox sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Marks the item's notification thread read on GitHub, if it has one.
    private func markNotificationRead(_ item: Item) {
        guard let index = inbox.firstIndex(where: { $0.repoNumber == item.repoNumber && !$0.isRead }) else { return }
        let note = inbox[index]
        // Keep the row in place so the selection doesn't jump; the next sync drops it.
        inbox[index].isRead = true
        rebuild()
        Task { [engine, logger] in
            do {
                try await engine.markThreadRead(note.threadID)
            } catch {
                logger.error("Failed to mark thread read: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Writing

    /// Unsent composer text per item, kept across selection changes and launches.
    @ObservationIgnored private var drafts: [Item.ID: String] = Defaults.get(.itemDrafts) ?? [:]

    func draft(for itemID: Item.ID) -> String {
        drafts[itemID] ?? ""
    }

    /// Drafts were once kept by number, which only names an upstream item; moves them over once
    /// the items are known.
    private func migrateDrafts() {
        guard let old: [Int: String] = Defaults.get(.drafts), !snapshot.items.isEmpty else { return }
        for item in snapshot.items where item.isUpstream {
            if let text = old[item.number], drafts[item.id] == nil { drafts[item.id] = text }
        }
        Defaults.set(drafts, for: .itemDrafts)
        Defaults.remove(.drafts)
    }

    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?

    /// Updates the draft in memory at once and persists it shortly after typing pauses.
    func setDraft(_ text: String, for itemID: Item.ID) {
        drafts[itemID] = text.isEmpty ? nil : text
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            Defaults.set(drafts, for: .itemDrafts)
        }
    }

    func submit(_ submission: Submission, body: String, item: Item, detail: ItemDetail) async throws {
        try await engine.submit(submission, body: body, subjectID: detail.id)
        setDraft("", for: item.id)
        // Our own action shouldn't make the item look unread.
        updateState(item) { $0.seenAt = Date() }
        _ = try? await engine.refresh(ids: [item.id])
        loadDetail(force: true)
    }

    /// Adds or takes back the viewer's reaction on `subjectID` in the shown detail, at once on screen
    /// and then on GitHub; a failed write puts it back.
    func toggleReaction(_ content: Reaction.Content, on subjectID: String) {
        guard var changed = detail, let reactions = changed.reactions(on: subjectID) else { return }
        let reacted = !(reactions.first { $0.content == content }?.viewerHasReacted ?? false)
        changed.setReactions(Reaction.toggling(content, in: reactions, viewer: viewer), on: subjectID)
        detail = changed
        Task { [weak self, engine] in
            do {
                try await engine.setReaction(content, on: subjectID, reacted: reacted)
            } catch {
                guard let self else { return }
                logger.error("Reacting to \(subjectID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if var current = detail, current.number == changed.number, let now = current.reactions(on: subjectID) {
                    current.setReactions(Reaction.toggling(content, in: now, viewer: viewer), on: subjectID)
                    detail = current
                }
            }
        }
    }

    /// Closes the item, posting `comment` on it first unless it is empty.
    func close(_ item: Item, detail: ItemDetail, reason: CloseReason?, comment: String) async throws {
        if !comment.isEmpty {
            try await engine.submit(.comment, body: comment, subjectID: detail.id)
            setDraft("", for: item.id)
        }
        try await engine.close(subjectID: detail.id, isPullRequest: item.kind == .pullRequest, reason: reason)
        updateState(item) { $0.seenAt = Date() }
        _ = try? await engine.refresh(ids: [item.id])
        loadDetail(force: true)
    }

    /// Parks a parity staging PR (makes it a draft) or resumes it (marks it ready for review).
    func setParked(_ parked: Bool, _ item: Item) async throws {
        try await engine.setDraft(parked, pullRequestID: item.id)
        updateState(item) { $0.seenAt = Date() }
        _ = try? await engine.refresh(ids: [item.id])
        loadDetail(force: true)
    }

    func renderMarkdown(_ text: String, in item: Item) async throws -> String {
        try await engine.renderMarkdown(text, repo: item.repo)
    }

    func requestComposerFocus() { composerFocusRequest += 1 }

    @ObservationIgnored private var filesCache: [Item.ID: (updatedAt: Date?, files: [PullFile])] = [:]

    /// Changed files of a PR, cached until the PR is updated.
    func files(for item: Item) async throws -> [PullFile] {
        let updatedAt = itemsByID[item.id]?.updatedAt ?? item.updatedAt
        if let cached = filesCache[item.id], cached.updatedAt == updatedAt { return cached.files }
        let files = try await engine.fetchFiles(repo: item.repo, number: item.number)
        filesCache[item.id] = (updatedAt, files)
        return files
    }

    // MARK: Opened from links

    /// Issues and PRs opened from links in the detail pane that aren't on the desk, newest first.
    /// They stay in the Opened section for this session, until added or replaced.
    private(set) var openedItems: [Item] = []
    private static let openedLimit = 10

    /// Opens issue or PR `number` of `repo`: selects it where the list shows it, reveals it if it is
    /// on the desk (or in the Parity tab) but hidden, and otherwise fetches it into Opened.
    func openItem(repo: String, number: Int) {
        let key = "\(repo.lowercased())#\(number)"
        let isTarget = { (item: Item) in item.repoNumber == key }
        if let selection = rows.lazy.compactMap(\.selectionID).first(where: { self.itemsByID[$0.itemID].map(isTarget) == true && $0.section != .recent }) {
            self.selection = selection
        } else if let item = snapshot.items.first(where: isTarget), isOnDesk(item) {
            reveal(item.id)
        } else if let item = snapshot.items.first(where: isTarget) ?? openedItems.first(where: isTarget) {
            showOpened(item)
        } else {
            Task {
                do {
                    showOpened(try await engine.fetchItem(repo: repo, number: number, store: false))
                } catch {
                    logger.error("Opening #\(number) failed: \(String(describing: error), privacy: .public)")
                    writeError = "Couldn't open #\(number): \(error.localizedDescription)"
                }
            }
        }
    }

    private func showOpened(_ item: Item) {
        openedItems.removeAll { $0.id == item.id }
        openedItems.insert(item, at: 0)
        if openedItems.count > Self.openedLimit { openedItems.removeLast() }
        collapsed.remove(.opened)
        rebuild()
        selection = TableSelection(section: .opened, itemID: item.id)
    }

    /// Whether the item is only in Opened: fetched from a link and not stored, so not on the desk.
    func isOpenedOnly(_ item: Item) -> Bool {
        !snapshot.items.contains { $0.id == item.id }
    }

    /// Whether adding the item would list it: not for one closed too long ago (pinning keeps it).
    func canAddToDesk(_ item: Item) -> Bool {
        isOpenedOnly(item) && isOnDesk(item)
    }

    /// Stores items opened from links, which puts them on the desk (in Triage, without a Status).
    private func addToDesk(_ items: [Item]) {
        let new = items.filter(isOpenedOnly)
        guard !new.isEmpty else { return }
        Task {
            do {
                try await db.upsert(new)
            } catch {
                logger.error("Adding items failed: \(error)")
            }
        }
    }

    /// Listed in some dashboard section (or for a staging PR, in the Parity tab), rather than left
    /// out by age or as the other tracker's.
    private func isOnDesk(_ item: Item) -> Bool {
        if item.isParity { return paritySections[item.id] != nil }
        let row = row(for: item)
        if row.board?.isForeign == true { return false }
        let cutoff = Date().addingTimeInterval(-ListSection.closedRetention)
        return item.isOpen || (item.closedAt ?? item.updatedAt) >= cutoff || row.state.isPinned
    }

    // MARK: History

    /// Items selected before the current one, for Back (⌘[), and those gone back over, for Forward.
    @ObservationIgnored private var backHistory: [Item.ID] = [] {
        didSet { if canGoBack == backHistory.isEmpty { canGoBack.toggle() } }
    }
    @ObservationIgnored private var forwardHistory: [Item.ID] = [] {
        didSet { if canGoForward == forwardHistory.isEmpty { canGoForward.toggle() } }
    }
    /// Observed instead of the histories, which change on every selection.
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored private var isMovingInHistory = false
    @ObservationIgnored private var mouseMonitor: Any?
    private static let historyLimit = 100

    func goBack() {
        moveInHistory(from: &backHistory, to: &forwardHistory)
    }

    func goForward() {
        moveInHistory(from: &forwardHistory, to: &backHistory)
    }

    /// Selects the newest item of `source` that can still be shown, pushing the current one onto
    /// `destination`.
    private func moveInHistory(from source: inout [Item.ID], to destination: inout [Item.ID]) {
        while let id = source.popLast() {
            guard let target = historyTarget(for: id) else { continue }
            if let current = selection?.itemID { destination.append(current) }
            isMovingInHistory = true
            defer { isMovingInHistory = false }
            switch target {
            case let .row(row): selection = row
            case .reveal: reveal(id)
            }
            return
        }
    }

    private enum HistoryTarget {
        case row(TableSelection)
        /// On the desk, but hidden by the filter or a collapsed section.
        case reveal
    }

    /// Where `id` can be selected again, or nil once it has left the desk.
    private func historyTarget(for id: Item.ID) -> HistoryTarget? {
        if let row = rows.lazy.compactMap(\.selectionID).first(where: { $0.itemID == id && $0.section != .recent }) {
            return .row(row)
        }
        if openedItems.contains(where: { $0.id == id }) { return .row(TableSelection(section: .opened, itemID: id)) }
        if let item = itemsByID[id], isOnDesk(item) { return .reveal }
        return nil
    }

    private func recordHistory(from old: TableSelection?) {
        guard !isMovingInHistory, let old, old.itemID != selection?.itemID else { return }
        if backHistory.last != old.itemID { backHistory.append(old.itemID) }
        if backHistory.count > Self.historyLimit { backHistory.removeFirst() }
        forwardHistory = []
    }

    /// Shows an item in the section it belongs to (on the dashboard, or in the Parity tab for a
    /// parity PR), clearing anything that would hide it.
    func reveal(_ itemID: Item.ID) {
        guard let item = itemsByID[itemID] else { return }
        if item.isParity {
            guard let section = paritySections[itemID] else { return }
            mode = .parity
            filterText = ""
            collapsed.remove(section)
            selection = TableSelection(section: section, itemID: itemID)
            requestTableFocus()
            return
        }
        guard let section = ListSection.triageSection(of: row(for: item)) else { return }
        mode = .dashboard
        filterText = ""
        collapsed.remove(section)
        selection = TableSelection(section: section, itemID: itemID)
        requestTableFocus()
    }

    // MARK: Actions

    func perform(_ action: ItemAction, on itemID: Item.ID) {
        perform(action, on: [itemID])
    }

    /// Applies `action` to several items at once. Toggles work on the group: if every item already
    /// has the status, priority, pin or vote, it is cleared from all; otherwise all get it.
    func perform(_ action: ItemAction, on itemIDs: [Item.ID]) {
        var items = itemIDs.compactMap { itemsByID[$0] }
        guard !items.isEmpty else { return }
        let now = Date()
        switch action {
        case .triage, .priority:
            // The other tracker's items stay its own, and only upstream items go on the board;
            // anything opened from a link joins the desk.
            items = items.filter { $0.isUpstream && board(for: $0)?.isForeign != true }
            addToDesk(items)
        case .togglePin:
            // Pinned is a dashboard section, which staging PRs stay out of.
            items = items.filter { $0.isUpstream && !$0.isParity }
            addToDesk(items)
        case .addToDesk:
            addToDesk(items.filter(canAddToDesk))
        case let .sendToBot(request):
            items = items.filter(request.applies)
        default:
            break
        }
        guard !items.isEmpty else { return }
        switch action {
        case let .triage(status):
            // A woken Skipped item is back in Triage, so skipping it again renews the skip.
            let has = { (item: Item) in self.triage(for: item) == status }
            let next = items.allSatisfy(has) ? nil : status
            let changes = next == nil ? items : items.filter { !has($0) }
            setTriage(changes.map { ($0, next) })
        case let .priority(priority):
            let next = items.allSatisfy { board(for: $0)?.priorityValue == priority } ? nil : priority
            let changes = items.filter { board(for: $0)?.priorityValue != next }
            guard !changes.isEmpty else { return }
            setPriority(changes.map { ($0, next) })
        case .togglePin:
            let pin = !items.allSatisfy { state(for: $0).isPinned }
            setPins(items.map { ($0, pin ? state(for: $0).pinnedAt ?? now : nil) })
        case .markRead:
            for item in items {
                updateState(item) { $0.seenAt = now }
                markNotificationRead(item)
            }
        case .openInBrowser:
            // Opening dozens of tabs is never what a stray keypress meant.
            for item in items.prefix(Self.maxTabsAtOnce) {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            }
        case .openAuthorProfile:
            var seen = Set<String>()
            let authors = items.compactMap(\.author).filter { seen.insert($0.lowercased()).inserted }
            for author in authors.prefix(Self.maxTabsAtOnce) {
                Self.openProfile(author)
            }
        case .copyLink:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(items.map(\.url).joined(separator: "\n"), forType: .string)
            // A single link also goes as a URL, so apps that take one (Mail, Notes) make it a link.
            if items.count == 1 { pasteboard.setString(items[0].url, forType: .URL) }
        case let .voteAuthor(vote):
            let authors = Array(Set(items.compactMap(\.author)))
            let clear = authors.allSatisfy { self.vote(for: $0) == vote }
            setVotes(authors.map { ($0, clear ? nil : vote) })
        case .addToDesk:
            break
        case let .sendToBot(request):
            let resends = items.count { state(for: $0).sentAt(request) != nil }
            if request == .merge || resends > 0 {
                pendingBotSend = PendingBotSend(request: request, items: items, resends: resends)
            } else {
                sendToBot(request, items: items)
            }
        }
    }

    /// Sends `items` to the request's bot in one message, then marks them sent.
    func sendToBot(_ request: BotRequest, items: [Item]) {
        let text = GrokBot.message(request, items: items)
        let bot = request.bot
        Task {
            do {
                try await GrokBot.send(text, to: bot)
            } catch {
                logger.error("Failed to send to \(bot, privacy: .public): \(String(describing: error), privacy: .public)")
                botError = "Couldn't send \(request.emoji) to \(bot): \(error.localizedDescription)"
                return
            }
            let now = Date()
            for item in items {
                updateState(item) { $0.setSentAt(now, for: request) }
            }
        }
    }

    private static let maxTabsAtOnce = 10

    static func profileURL(for login: String) -> URL? {
        URL(string: "https://github.com/\(login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login)")
    }

    /// Opens a person's GitHub profile in the browser.
    static func openProfile(_ login: String) {
        if let url = profileURL(for: login) { NSWorkspace.shared.open(url) }
    }

    /// Runs a board write, reporting failure in `writeError`.
    // MARK: Undo

    /// Undo for list actions: Status, Priority, pins and author votes. The table answers ⌘Z with
    /// it while it has focus; text fields keep their own. Each step records what it replaced, so
    /// undoing it registers the redo.
    @ObservationIgnored let undoManager = UndoManager()

    private func registerUndo(_ name: String, _ undo: @escaping @MainActor (AppModel) -> Void) {
        undoManager.registerUndo(withTarget: self) { model in MainActor.assumeIsolated { undo(model) } }
        undoManager.setActionName(name)
    }

    private func setTriage(_ changes: [(item: Item, status: TriageStatus?)]) {
        guard !changes.isEmpty else { return }
        let previous = changes.map { (item: $0.item, status: board(for: $0.item)?.triage) }
        registerUndo("Set Status") { $0.setTriage(previous) }
        let what = changes.count == 1 ? "#\(changes[0].item.number)" : "\(changes.count) items"
        writeBoard("set the status of \(what)", numbers: changes.map(\.item.number)) { engine in
            for change in changes {
                try await engine.setTriage(change.status, number: change.item.number, contentID: change.item.id)
            }
        }
    }

    private func setPriority(_ changes: [(item: Item, priority: Priority?)]) {
        guard !changes.isEmpty else { return }
        let previous = changes.map { (item: $0.item, priority: board(for: $0.item)?.priorityValue) }
        registerUndo("Set Priority") { $0.setPriority(previous) }
        let what = changes.count == 1 ? "#\(changes[0].item.number)" : "\(changes.count) items"
        writeBoard("set the priority of \(what)", numbers: changes.map(\.item.number)) { engine in
            for change in changes {
                try await engine.setPriority(change.priority, number: change.item.number, contentID: change.item.id)
            }
        }
    }

    private func setPins(_ changes: [(item: Item, pinnedAt: Date?)]) {
        guard !changes.isEmpty else { return }
        let previous = changes.map { (item: $0.item, pinnedAt: state(for: $0.item).pinnedAt) }
        registerUndo(changes.contains { $0.pinnedAt != nil } ? "Pin" : "Unpin") { $0.setPins(previous) }
        for change in changes {
            let pinnedAt = change.pinnedAt
            updateState(change.item) { $0.pinnedAt = pinnedAt }
        }
    }

    private func setVotes(_ changes: [(author: String, vote: Vote?)]) {
        guard !changes.isEmpty else { return }
        let previous = changes.map { (author: $0.author, vote: vote(for: $0.author)) }
        registerUndo("Vote") { $0.setVotes(previous) }
        for change in changes {
            setVote(change.vote, for: change.author)
        }
    }

    /// The latest board write for each item. A write waits for those of its items before it, so an
    /// undo never reaches GitHub ahead of what it undoes; other items' writes don't wait.
    @ObservationIgnored private var pendingBoardWrites: [Int: Task<Void, Never>] = [:]

    private func writeBoard(_ what: String, numbers: [Int], _ write: @escaping @Sendable (SyncEngine) async throws -> Void) {
        let earlier = numbers.compactMap { pendingBoardWrites[$0] }
        let task = Task { [engine, logger] in
            for task in earlier { await task.value }
            do {
                try await write(engine)
            } catch {
                logger.error("Failed to \(what, privacy: .public): \(String(describing: error), privacy: .public)")
                self.writeError = if case BoardError.subscription = error {
                    error.localizedDescription
                } else {
                    "Couldn't \(what): \(error.localizedDescription)"
                }
            }
        }
        for number in numbers { pendingBoardWrites[number] = task }
    }

    /// Updates affiliation data for everyone who appears in the list.
    func refreshAffiliations(force: Bool = false) async {
        let authors = Set(snapshot.items.compactMap(\.author))
        let logins = authors.union(snapshot.items.flatMap { $0.events.compactMap(\.actor) })
        do {
            try await affiliationEngine.refresh(logins: logins, authors: authors, force: force)
        } catch {
            logger.error("Affiliation refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    func setOverride(_ override: OrgOverride) {
        Task { try? await db.save(override) }
    }

    func removeOverride(_ override: OrgOverride) {
        Task { try? await db.delete(override) }
    }

    func requestFilterFocus() { filterFocusRequest += 1 }
    func requestTableFocus() { tableFocusRequest += 1 }

    func toggleCollapsed(_ section: ListSection) {
        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
    }

    private func updateState(_ item: Item, _ change: @escaping @Sendable (inout ItemState) -> Void) {
        Task {
            do {
                try await db.updateState(item.id, change)
            } catch {
                logger.error("Failed to update state of #\(item.number): \(error)")
            }
        }
    }

    /// Shows the cached detail of the selected item at once, then fetches a fresh one if needed.
    func loadDetail(force: Bool = false) {
        detailTask?.cancel()
        guard let item = selectedItem else {
            detail = nil
            detailState = .idle
            return
        }
        if detail?.id != item.id {
            detail = recentDetails[item.id]
        }
        detailState = .idle
        detailTask = Task { [weak self, db, engine] in
            if self?.detail == nil, let cached = try? await db.cachedDetail(itemID: item.id) {
                guard !Task.isCancelled else { return }
                self?.detail = cached
            }
            if !force, let current = self?.detail,
               current.itemUpdatedAt >= item.updatedAt,
               Date().timeIntervalSince(current.fetchedAt) < Self.detailMaxAge
            {
                return
            }
            self?.detailState = .loading
            do {
                let fresh = try await engine.fetchDetail(of: item)
                try? await db.saveDetail(fresh)
                guard !Task.isCancelled, let self else { return }
                detail = fresh
                detailState = .idle
                let actors = Set(fresh.entries.compactMap(\.actor))
                Task { try? await self.affiliationEngine.refresh(logins: actors) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.logger.error("Detail of #\(item.number) failed: \(String(describing: error), privacy: .public)")
                self?.detailState = .failed(error.localizedDescription)
            }
        }
    }

    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    private static let prefetchConcurrency = 2

    /// Fetches ahead the details of items likely to be opened (Working, Good, Triage, the Inbox,
    /// Pinned, Recently viewed and the open parity staging PRs) whose cache is missing or older than
    /// the item, so opening one shows its cache at once. A round still running skips the next; the
    /// sync after picks it up.
    private func prefetchDetails() {
        guard prefetchTask == nil else { return }
        let inboxItems = Set(inbox.filter { !isMuted($0) }.map(\.repoNumber))
        let recent = Set(snapshot.items
            .filter { state(for: $0).viewedAt != nil }
            .sorted { state(for: $0).viewedAt! > state(for: $1).viewedAt! }
            .prefix(ListSection.recentLimit)
            .map(\.id))
        let candidates = snapshot.items.filter { item in
            let row = row(for: item)
            if row.board?.isForeign == true { return false }
            if item.isParity, item.isOpen, !item.isDraft { return true }
            if let section = ListSection.triageSection(of: row), [.working, .good, .triage].contains(section) { return true }
            return row.state.isPinned || inboxItems.contains(item.repoNumber) || recent.contains(item.id)
        }
        prefetchTask = Task { [weak self, db, engine, logger] in
            defer { self?.prefetchTask = nil }
            let cached = (try? await db.cachedDetailTimes()) ?? [:]
            let stale = candidates.filter { item in cached[item.id].map { $0 < item.updatedAt } ?? true }
            guard !stale.isEmpty else { return }
            logger.info("Prefetching \(stale.count) details")
            var actors: Set<String> = []
            await withTaskGroup(of: Set<String>.self) { group in
                var queue = stale.makeIterator()
                let fetch = { @Sendable (item: Item) async -> Set<String> in
                    do {
                        let detail = try await engine.fetchDetail(of: item)
                        try await db.saveDetail(detail)
                        return Set(detail.entries.compactMap(\.actor))
                    } catch {
                        logger.error("Prefetching the detail of #\(item.number) failed: \(String(describing: error), privacy: .public)")
                        return []
                    }
                }
                for _ in 0 ..< Self.prefetchConcurrency {
                    if let item = queue.next() { group.addTask { await fetch(item) } }
                }
                for await found in group {
                    actors.formUnion(found)
                    if let item = queue.next() { group.addTask { await fetch(item) } }
                }
            }
            try? await self?.affiliationEngine.refresh(logins: actors)
        }
    }

    @ObservationIgnored private var isAutoSelecting = false

    /// Selects without counting as the user opening the item: nothing is marked viewed or read.
    /// Otherwise each read Inbox row leaving the list would select (and then read) the next one.
    /// Reopens on the item selected when the app quit, as the app selecting it rather than the
    /// user opening it: it isn't marked viewed or read.
    private func restoreSelection() {
        guard let restored = restoredSelection, selection == nil, !rows.isEmpty,
              // The Inbox comes from GitHub after launch; wait for it.
              restored.section != .inbox || !inbox.isEmpty
        else { return }
        restoredSelection = nil
        // Its section may be collapsed or the item gone by now; then start without a selection.
        guard rows.contains(where: { $0.selectionID == restored }) else { return }
        autoSelect(restored)
    }

    func autoSelect(_ selection: TableSelection?) {
        isAutoSelecting = true
        defer { isAutoSelecting = false }
        self.selection = selection
    }

    private func selectionChanged(from old: TableSelection?) {
        guard selection?.itemID != old?.itemID else { return }
        recordHistory(from: old)
        loadDetail()
        guard let item = selectedItem else {
            selectedItemPreviousSeenAt = nil
            return
        }
        selectedItemPreviousSeenAt = [state(for: item).seenAt, snapshot.baseline].compactMap(\.self).max()
        // Opening counts at once; only the user's own selections open anything.
        guard !isAutoSelecting else { return }
        let now = Date()
        // Recently viewed is ordered by this time, so moving through it doesn't reorder it under the
        // selection (where j would bounce between the top two rows).
        let bumpsRecent = selection?.section != .recent
        updateState(item) { state in
            if bumpsRecent { state.viewedAt = now }
            state.seenAt = now
        }
        markNotificationRead(item)
    }

    // MARK: Rows

    private static let dashboardSections: [ListSection] = [.recent, .pinned, .working, .good, .triage, .backlog, .closed, .skipped, .muted]

    private func rebuild() {
        itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        // Opened items that were added since are on the desk now; follow the selection there.
        let added = openedItems.filter { item in itemsByID[item.id].map(isOnDesk) ?? false }
        if !added.isEmpty {
            openedItems.removeAll { item in added.contains { $0.id == item.id } }
            if let selection, selection.section == .opened, let item = itemsByID[selection.itemID], added.contains(where: { $0.id == item.id }),
               let section = ListSection.triageSection(of: row(for: item))
            {
                autoSelect(TableSelection(section: section, itemID: item.id))
            }
        }
        for item in openedItems where itemsByID[item.id] == nil {
            itemsByID[item.id] = item
        }
        let openedRows: [TableRow] = openedItems.isEmpty ? [] : {
            let isCollapsed = collapsed.contains(.opened)
            return [.header(.opened, count: openedItems.count, collapsed: isCollapsed)]
                + (isCollapsed ? [] : openedItems.map { .item(.opened, row(for: itemsByID[$0.id] ?? $0)) })
        }()
        let cutoff = Date().addingTimeInterval(-ListSection.closedRetention)
        let filter = ItemFilter(filterText)
        let affiliations = affiliations
        let badges = { (login: String) in affiliations.badges(for: login) }
        let threshold = mergedThreshold
        let contribution = { (login: String) in
            affiliations.users[login.lowercased()]?.mergedCount.map { Contribution(merged: $0, threshold: threshold) }
        }

        let all: [ItemRow] = snapshot.items.compactMap { item in
            let row = row(for: item)
            // Items of the other tracker sharing the board are none of the app's business.
            if row.board?.isForeign == true { return nil }
            if !item.isOpen, (item.closedAt ?? item.updatedAt) < cutoff, !row.state.isPinned { return nil }
            return row
        }
        // Staging PRs and the upstream PRs promoted from them show in the Parity tab, not the dashboard.
        let candidates = all.filter { $0.item.isUpstream && !$0.item.isParity }
        let parity = Parity.sections(of: all)
        paritySections = [:]
        for (section, rows) in parity {
            for row in rows { paritySections[row.item.id] = section }
        }
        let waiting = (parity[.parityReview]?.count ?? 0) + (parity[.parityUpstream] ?? []).count { $0.insight.turn == .me }
        if parityWaitingCount != waiting { parityWaitingCount = waiting }

        workingItems = Self.mineFirst(Self.yourMoveFirst(candidates
            .filter { [.working, .good].contains(ListSection.triageSection(of: $0)) }
            .sorted { $0.item.updatedAt > $1.item.updatedAt }))
        let visible = filter.isEmpty ? candidates : candidates.filter { filter.matches($0, badges: badges, contribution: contribution) }

        visibleCount = visible.count

        if mode == .parity {
            var rows = openedRows
            var count = 0
            for section in Parity.sections {
                let members = (parity[section] ?? [])
                    .filter { filter.isEmpty || filter.matches($0, badges: badges, contribution: contribution) }
                    .sorted(by: sort.areInIncreasingOrder)
                count += members.count
                let isCollapsed = filter.isEmpty && collapsed.contains(section)
                rows.append(.header(section, count: members.count, collapsed: isCollapsed))
                if !isCollapsed {
                    rows += Self.yourMoveFirst(members).map { .item(section, $0) }
                }
            }
            visibleCount = count
            self.rows = rows
            return
        }

        if mode == .inbox {
            let byRepoNumber = Dictionary(snapshot.items.map { ($0.repoNumber, $0) }, uniquingKeysWith: { a, _ in a })
            let rows: [ItemRow] = inbox.compactMap { note in
                guard let item = byRepoNumber[note.repoNumber] else { return nil }
                var row = row(for: item)
                if row.triage == .muted { return nil }
                row.note = note
                return filter.matches(row, badges: badges, contribution: contribution) ? row : nil
            }
            visibleCount = rows.count
            self.rows = openedRows + [.header(.inbox, count: rows.count, collapsed: false)] + rows.map { .item(.inbox, $0) }
            return
        }

        let ordered = visible.sorted(by: sort.areInIncreasingOrder)
        var members: [ListSection: [ItemRow]] = [:]
        members[.recent] = Array(visible
            .filter { $0.state.viewedAt != nil }
            .sorted { $0.state.viewedAt! > $1.state.viewedAt! }
            .prefix(ListSection.recentLimit))
        members[.pinned] = ordered.filter(\.state.isPinned)
        for row in ordered {
            if let section = ListSection.triageSection(of: row) { members[section, default: []].append(row) }
        }
        members[.working] = Self.mineFirst(Self.yourMoveFirst(members[.working] ?? []))
        for section in [ListSection.good, .backlog] {
            members[section] = Self.mineFirst(members[section] ?? [])
        }
        // Downvoted authors still get triaged, just last.
        let triage = members[.triage] ?? []
        members[.triage] = triage.filter { $0.authorVote != .down } + triage.filter { $0.authorVote == .down }

        // Promoted parity PRs live in the Parity tab; the sections they'd be in say how many.
        var inParity: [ListSection: Int] = [:]
        for row in all where row.item.isParityUpstream && row.item.isOpen {
            guard filter.isEmpty || filter.matches(row, badges: badges, contribution: contribution),
                  let section = ListSection.statusSection(of: row)
            else { continue }
            inParity[section, default: 0] += 1
        }

        var rows = openedRows
        for section in Self.dashboardSections {
            let items = members[section] ?? []
            // While filtering, show every match rather than hiding some in collapsed sections.
            let isCollapsed = filter.isEmpty && collapsed.contains(section)
            rows.append(.header(section, count: items.count, collapsed: isCollapsed, inParity: inParity[section] ?? 0))
            if !isCollapsed {
                rows += items.map { .item(section, $0) }
            }
        }
        self.rows = rows
    }

    /// Stable partition putting items whose turn is the viewer's first.
    private static func yourMoveFirst(_ rows: [ItemRow]) -> [ItemRow] {
        rows.filter { $0.insight.turn == .me } + rows.filter { $0.insight.turn != .me }
    }

    /// The viewer's own items first; each part keeps its order.
    private static func mineFirst(_ rows: [ItemRow]) -> [ItemRow] {
        rows.filter(\.insight.isMine) + rows.filter { !$0.insight.isMine }
    }
}

/// Small typed wrapper over UserDefaults for UI preferences.
enum Defaults {
    enum Key: String {
        case sort, collapsed, mergedThreshold, syncInterval, selection, mode
        /// Composer drafts by item number, from before drafts were kept by item id.
        case drafts
        case itemDrafts
        /// List sections as of the last launch, so new ones can start collapsed by default.
        case knownSections
    }

    static func get<T: Decodable>(_ key: Key) -> T? {
        UserDefaults.standard.data(forKey: key.rawValue).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func set(_ value: some Encodable, for key: Key) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key.rawValue)
    }

    static func remove(_ key: Key) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }
}
