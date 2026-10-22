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
    /// Vote on the item's author; voting the same way again clears the vote.
    case voteAuthor(Vote)
}

@MainActor
@Observable
final class AppModel {
    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    /// Closed or merged items stay visible this long after closing.
    static let closedRetention: TimeInterval = 14 * 24 * 3600
    static let recentLimit = 8
    private static let pollInterval: Duration = .seconds(60)
    /// Minimum gap before re-syncing when the app is activated.
    private static let activationThreshold: TimeInterval = 15
    /// How long an item must stay selected before it counts as viewed.
    private static let dwellBeforeViewed: Duration = .milliseconds(1200)

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
    var selection: TableSelection? { didSet { selectionChanged(from: oldValue) } }

    enum ListMode: Hashable {
        case dashboard, inbox
    }

    var mode: ListMode = .dashboard { didSet { rebuild() } }
    /// Unread notifications for issues and PRs in the repository, newest first.
    private(set) var inbox: [InboxNote] = [] {
        didSet { updateDockBadge() }
    }

    /// Muted items' notifications don't count; GitHub can't always be stopped from sending them.
    var unreadInboxCount: Int { inbox.count { !$0.isRead && board[$0.number]?.triage != .muted } }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = unreadInboxCount == 0 ? nil : String(unreadInboxCount)
    }
    /// Working and Good items regardless of the filter, the viewer's move first (for the menu bar).
    private(set) var workingItems: [ItemRow] = []

    /// The last write to the board that failed, shown until dismissed.
    var writeError: String?

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
    private(set) var detail: ItemDetail?
    private(set) var detailState: DetailState = .idle

    /// `seenAt` of the selected item when it was opened, before opening moved it forward.
    private(set) var selectedItemPreviousSeenAt: Date?

    @ObservationIgnored private var snapshot = Snapshot()
    @ObservationIgnored private var itemsByID: [Item.ID: Item] = [:]
    @ObservationIgnored let db: AppDatabase
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let affiliationEngine: AffiliationEngine
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
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
        collapsed = Defaults.get(.collapsed) ?? ListSection.defaultCollapsed
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
        snapshot.states[item.number] ?? ItemState(number: item.number)
    }

    /// The triage board by item number; observed (unlike `snapshot`) so the detail pane follows it.
    private(set) var board: [Int: BoardEntry] = [:]

    func board(for item: Item) -> BoardEntry? {
        board[item.number]
    }

    private func row(for item: Item) -> ItemRow {
        let state = state(for: item)
        return ItemRow(
            item: item, state: state,
            insight: ItemInsight(item: item, state: state, viewer: viewer, baseline: snapshot.baseline),
            authorVote: vote(for: item.author),
            board: board(for: item)
        )
    }

    // MARK: Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self, db] in
            do {
                for try await snapshot in db.observeSnapshot() {
                    guard let self else { return }
                    self.snapshot = snapshot
                    if votes != snapshot.votes { votes = snapshot.votes }
                    if board != snapshot.board {
                        board = snapshot.board
                        updateDockBadge()
                    }
                    rebuild()
                    if let item = selectedItem, let detail, detail.number == item.number, detail.itemUpdatedAt < item.updatedAt {
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
                await self?.sync()
                try? await Task.sleep(for: Self.pollInterval)
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self else { return }
                if let last = lastSyncedAt, Date().timeIntervalSince(last) < Self.activationThreshold { continue }
                await sync()
            }
        })
    }

    func sync() async {
        guard syncState != .syncing else { return }
        syncState = .syncing
        do {
            if let result = try await engine.sync() {
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
        } catch {
            logger.error("Sync failed: \(String(describing: error), privacy: .public)")
            syncState = .failed(error.localizedDescription)
        }
    }

    private func syncInbox() async {
        do {
            let notes = try await engine.fetchInbox()
            // Notifications can be for items no tracking search found; fetch a few at a time.
            let known = Set(snapshot.items.map(\.number))
            for number in Set(notes.map(\.number)).subtracting(known).prefix(10) {
                _ = try? await engine.fetchItem(number: number)
            }
            inbox = notes.sorted { $0.updatedAt > $1.updatedAt }
            rebuild()
        } catch {
            logger.error("Inbox sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Marks the item's notification thread read on GitHub, if it has one.
    private func markNotificationRead(number: Int) {
        guard let index = inbox.firstIndex(where: { $0.number == number && !$0.isRead }) else { return }
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

    /// Unsent composer text per item number, kept across selection changes and launches.
    @ObservationIgnored private var drafts: [Int: String] = Defaults.get(.drafts) ?? [:]

    func draft(for number: Int) -> String {
        drafts[number] ?? ""
    }

    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?

    /// Updates the draft in memory at once and persists it shortly after typing pauses.
    func setDraft(_ text: String, for number: Int) {
        drafts[number] = text.isEmpty ? nil : text
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            Defaults.set(drafts, for: .drafts)
        }
    }

    func submit(_ submission: Submission, body: String, item: Item, detail: ItemDetail) async throws {
        try await engine.submit(submission, body: body, subjectID: detail.id)
        setDraft("", for: item.number)
        // Our own action shouldn't make the item look unread.
        updateState(item) { $0.seenAt = Date() }
        _ = try? await engine.refresh(ids: [item.id])
        loadDetail(force: true)
    }

    func renderMarkdown(_ text: String) async throws -> String {
        try await engine.renderMarkdown(text)
    }

    func requestComposerFocus() { composerFocusRequest += 1 }

    @ObservationIgnored private var filesCache: [Int: (updatedAt: Date?, files: [ParsedFile])] = [:]

    /// Changed files of a PR with parsed diffs, cached until the PR is updated.
    func files(for number: Int) async throws -> [ParsedFile] {
        let updatedAt = snapshot.items.first { $0.number == number }?.updatedAt
        if let cached = filesCache[number], cached.updatedAt == updatedAt { return cached.files }
        let files = try await ParsedFile.parse(engine.fetchFiles(number: number))
        filesCache[number] = (updatedAt, files)
        return files
    }

    /// Shows an item in the dashboard section it belongs to, clearing anything that would hide it.
    func reveal(_ itemID: Item.ID) {
        guard let item = itemsByID[itemID], let section = ListSection.triageSection(of: row(for: item)) else { return }
        mode = .dashboard
        filterText = ""
        collapsed.remove(section)
        selection = TableSelection(section: section, itemID: itemID)
        requestTableFocus()
    }

    // MARK: Actions

    func perform(_ action: ItemAction, on itemID: Item.ID) {
        guard let item = itemsByID[itemID] else { return }
        let now = Date()
        let entry = board(for: item)
        switch action {
        case let .triage(status):
            let next = entry?.triage == status ? nil : status
            writeBoard("set the status of #\(item.number)") { engine in
                try await engine.setTriage(next, number: item.number, contentID: item.id)
            }
        case let .priority(priority):
            let current = entry?.priorityValue
            let next = priority == current ? nil : priority
            guard next != current else { return }
            writeBoard("set the priority of #\(item.number)") { engine in
                try await engine.setPriority(next, number: item.number, contentID: item.id)
            }
        case .togglePin:
            updateState(item) { $0.pinnedAt = $0.pinnedAt == nil ? now : nil }
        case .markRead:
            updateState(item) { $0.seenAt = now }
            markNotificationRead(number: item.number)
        case .openInBrowser:
            if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
        case let .voteAuthor(vote):
            guard let author = item.author else { return }
            setVote(self.vote(for: author) == vote ? nil : vote, for: author)
        }
    }

    /// Saves the item's board Comment, if it changed.
    func setComment(_ comment: String, for item: Item) {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (board(for: item)?.comment ?? "") else { return }
        writeBoard("save the comment on #\(item.number)") { engine in
            try await engine.setComment(text, number: item.number, contentID: item.id)
        }
    }

    /// Runs a board write, reporting failure in `writeError`.
    private func writeBoard(_ what: String, _ write: @escaping @Sendable (SyncEngine) async throws -> Void) {
        Task { [engine, logger] in
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
    }

    /// Fetches an item by number or URL and adds it to the board (without a Status), so it stays
    /// tracked even if no search finds it.
    func addItem(_ input: String) async throws {
        let digits = input.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
        guard let number = digits else { throw SyncError.notFound(0) }
        let item = try await engine.fetchItem(number: number)
        try await engine.addToBoard(number: number, contentID: item.id)
        mode = .dashboard
        filterText = ""
        // The snapshot with the new item may not have arrived yet; build its row from what's known.
        var row = row(for: item)
        if row.board == nil { row.board = try await db.boardEntry(number: number) }
        let section = ListSection.triageSection(of: row) ?? .triage
        collapsed.remove(section)
        selection = TableSelection(section: section, itemID: item.id)
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
                try await db.updateState(item.number, change)
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
        if detail?.number != item.number {
            detail = nil
        }
        detailState = .idle
        detailTask = Task { [weak self, db, engine] in
            if self?.detail == nil, let cached = try? await db.cachedDetail(number: item.number) {
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
                let fresh = try await engine.fetchDetail(number: item.number)
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

    @ObservationIgnored private var isAutoSelecting = false

    /// Selects without counting as the user opening the item: nothing is marked viewed or read.
    /// Otherwise each read Inbox row leaving the list would select (and then read) the next one.
    func autoSelect(_ selection: TableSelection?) {
        isAutoSelecting = true
        defer { isAutoSelecting = false }
        self.selection = selection
    }

    private func selectionChanged(from old: TableSelection?) {
        guard selection?.itemID != old?.itemID else { return }
        dwellTask?.cancel()
        loadDetail()
        guard let item = selectedItem else {
            selectedItemPreviousSeenAt = nil
            return
        }
        selectedItemPreviousSeenAt = [state(for: item).seenAt, snapshot.baseline].compactMap(\.self).max()
        guard !isAutoSelecting else { return }
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwellBeforeViewed)
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            updateState(item) { state in
                state.viewedAt = now
                state.seenAt = now
            }
            markNotificationRead(number: item.number)
        }
    }

    // MARK: Rows

    private static let dashboardSections: [ListSection] = [.recent, .pinned, .working, .good, .triage, .backlog, .closed, .skipped, .muted]

    private func rebuild() {
        itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        let cutoff = Date().addingTimeInterval(-Self.closedRetention)
        let filter = ItemFilter(filterText)
        let affiliations = affiliations
        let orgs = { (login: String) in affiliations.badges(for: login).map(\.org) }
        let threshold = mergedThreshold
        let contribution = { (login: String) in
            affiliations.users[login.lowercased()]?.mergedCount.map { Contribution(merged: $0, threshold: threshold) }
        }

        let candidates: [ItemRow] = snapshot.items.compactMap { item in
            let row = row(for: item)
            // Items of the other tracker sharing the board are none of the app's business.
            if row.board?.isForeign == true { return nil }
            if !item.isOpen, (item.closedAt ?? item.updatedAt) < cutoff, !row.state.isPinned { return nil }
            return row
        }
        workingItems = Self.yourMoveFirst(candidates
            .filter { [.working, .good].contains(ListSection.triageSection(of: $0)) }
            .sorted { $0.item.updatedAt > $1.item.updatedAt })
        let visible = filter.isEmpty ? candidates : candidates.filter { filter.matches($0, orgs: orgs, contribution: contribution) }

        visibleCount = visible.count

        if mode == .inbox {
            let byNumber = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.number, $0) })
            let rows: [ItemRow] = inbox.compactMap { note in
                guard let item = byNumber[note.number] else { return nil }
                var row = row(for: item)
                if row.triage == .muted { return nil }
                row.note = note
                return filter.matches(row, orgs: orgs, contribution: contribution) ? row : nil
            }
            visibleCount = rows.count
            self.rows = [.header(.inbox, count: rows.count, collapsed: false)] + rows.map { .item(.inbox, $0) }
            return
        }

        let ordered = visible.sorted(by: sort.areInIncreasingOrder)
        var members: [ListSection: [ItemRow]] = [:]
        members[.recent] = Array(visible
            .filter { $0.state.viewedAt != nil }
            .sorted { $0.state.viewedAt! > $1.state.viewedAt! }
            .prefix(Self.recentLimit))
        members[.pinned] = ordered.filter(\.state.isPinned)
        for row in ordered {
            if let section = ListSection.triageSection(of: row) { members[section, default: []].append(row) }
        }
        members[.working] = Self.yourMoveFirst(members[.working] ?? [])
        // Downvoted authors still get triaged, just last.
        let triage = members[.triage] ?? []
        members[.triage] = triage.filter { $0.authorVote != .down } + triage.filter { $0.authorVote == .down }

        var rows: [TableRow] = []
        for section in Self.dashboardSections {
            let items = members[section] ?? []
            guard !items.isEmpty || section == .working || section == .triage else { continue }
            // While filtering, show every match rather than hiding some in collapsed sections.
            let isCollapsed = filter.isEmpty && collapsed.contains(section)
            rows.append(.header(section, count: items.count, collapsed: isCollapsed))
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
}

/// Small typed wrapper over UserDefaults for UI preferences.
enum Defaults {
    enum Key: String {
        case sort, collapsed, drafts, mergedThreshold
    }

    static func get<T: Decodable>(_ key: Key) -> T? {
        UserDefaults.standard.data(forKey: key.rawValue).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func set(_ value: some Encodable, for key: Key) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key.rawValue)
    }
}
