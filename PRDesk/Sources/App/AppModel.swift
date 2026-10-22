import AppKit
import Foundation
import Observation
import os

enum ItemAction {
    case priority(ItemState.Priority?)
    case togglePin
    case dismissFocus
    case markRead
    case toggleUntrack
    case openInBrowser
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
    private(set) var inbox: [InboxNote] = []

    /// Bumped to move keyboard focus to the filter field or back to the table.
    private(set) var filterFocusRequest = 0
    private(set) var tableFocusRequest = 0
    private(set) var composerFocusRequest = 0

    private(set) var affiliations = Affiliations()
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
        collapsed = Defaults.get(.collapsed) ?? [.all]
    }

    var selectedItem: Item? {
        selection.flatMap { itemsByID[$0.itemID] }
    }

    func state(for item: Item) -> ItemState {
        snapshot.states[item.number] ?? ItemState(number: item.number)
    }

    // MARK: Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self, db] in
            do {
                for try await snapshot in db.observeSnapshot() {
                    guard let self else { return }
                    self.snapshot = snapshot
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
                    if filterText.contains("org:") { rebuild() }
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
        guard let note = inbox.first(where: { $0.number == number }) else { return }
        inbox.removeAll { $0.threadID == note.threadID }
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

    func setDraft(_ text: String, for number: Int) {
        drafts[number] = text.isEmpty ? nil : text
        Defaults.set(drafts, for: .drafts)
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

    // MARK: Actions

    func perform(_ action: ItemAction, on itemID: Item.ID) {
        guard let item = itemsByID[itemID] else { return }
        let now = Date()
        switch action {
        case let .priority(priority):
            let current = state(for: item).priority
            updateState(item) { $0.priority = priority == current ? nil : priority }
        case .togglePin:
            updateState(item) { $0.pinnedAt = $0.pinnedAt == nil ? now : nil }
        case .dismissFocus:
            updateState(item) { $0.focusDismissedAt = now }
        case .markRead:
            updateState(item) { $0.seenAt = now }
            markNotificationRead(number: item.number)
        case .toggleUntrack:
            updateState(item) { $0.untrackedAt = $0.untrackedAt == nil ? now : nil }
        case .openInBrowser:
            if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
        }
    }

    /// Fetches an item by number or URL and tracks it by hand.
    func addItem(_ input: String) async throws {
        let digits = input.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
        guard let number = digits else { throw SyncError.notFound(0) }
        let item = try await engine.fetchItem(number: number)
        try await db.updateState(number) { state in
            state.manual = true
            state.untrackedAt = nil
            state.pinnedAt = state.pinnedAt ?? Date()
        }
        selection = TableSelection(section: .pinned, itemID: item.id)
    }

    /// Updates affiliation data for everyone who appears in the list.
    func refreshAffiliations(force: Bool = false) async {
        let logins = Set(snapshot.items.compactMap(\.author) + snapshot.items.flatMap { $0.events.compactMap(\.actor) })
        do {
            try await affiliationEngine.refresh(logins: logins, force: force)
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

    private func selectionChanged(from old: TableSelection?) {
        guard selection?.itemID != old?.itemID else { return }
        dwellTask?.cancel()
        loadDetail()
        guard let item = selectedItem else {
            selectedItemPreviousSeenAt = nil
            return
        }
        selectedItemPreviousSeenAt = [state(for: item).seenAt, snapshot.baseline].compactMap(\.self).max()
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

    private func rebuild() {
        itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        let cutoff = Date().addingTimeInterval(-Self.closedRetention)
        let filter = ItemFilter(filterText)
        let affiliations = affiliations
        let orgs = { (login: String) in affiliations.badges(for: login).map(\.org) }

        let visible: [ItemRow] = snapshot.items.compactMap { item in
            let state = state(for: item)
            let insight = ItemInsight(item: item, state: state, viewer: viewer, baseline: snapshot.baseline)
            let row = ItemRow(item: item, state: state, insight: insight)
            if !insight.isTracked, !filter.showsUntracked { return nil }
            if !item.isOpen, (item.closedAt ?? item.updatedAt) < cutoff, !state.isPinned { return nil }
            return filter.matches(row, orgs: orgs) ? row : nil
        }
        visibleCount = visible.count

        if mode == .inbox {
            let byNumber = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.number, $0) })
            let rows: [ItemRow] = inbox.compactMap { note in
                guard let item = byNumber[note.number] else { return nil }
                let state = state(for: item)
                var row = ItemRow(item: item, state: state, insight: ItemInsight(item: item, state: state, viewer: viewer, baseline: snapshot.baseline))
                row.note = note
                return filter.matches(row, orgs: orgs) ? row : nil
            }
            visibleCount = rows.count
            self.rows = [.header(.inbox, count: rows.count, collapsed: false)] + rows.map { .item(.inbox, $0) }
            return
        }

        let ordered = visible.sorted(by: sort.areInIncreasingOrder)
        let recent = visible
            .filter { $0.state.viewedAt != nil }
            .sorted { $0.state.viewedAt! > $1.state.viewedAt! }
            .prefix(Self.recentLimit)
        let pinned = ordered.filter(\.state.isPinned)
        let focus = ordered.filter(Self.isFocus)
        let rest = ordered.filter { !$0.state.isPinned && !Self.isFocus($0) }

        var rows: [TableRow] = []
        for (section, members) in [(ListSection.recent, Array(recent)), (.pinned, pinned), (.focus, focus), (.all, rest)] {
            guard !members.isEmpty || section == .focus else { continue }
            // While filtering, show every match rather than hiding some in collapsed sections.
            let isCollapsed = filter.isEmpty && collapsed.contains(section)
            rows.append(.header(section, count: members.count, collapsed: isCollapsed))
            if !isCollapsed {
                rows += members.map { .item(section, $0) }
            }
        }
        self.rows = rows
    }

    private static func isFocus(_ row: ItemRow) -> Bool {
        guard row.item.isOpen, row.insight.isTracked else { return false }
        // Review requests on drafts (often automatic, via CODEOWNERS) wait until the PR is ready.
        let requested = row.insight.isReviewRequestedFromMe && !row.item.isDraft
        let wanted = row.insight.turn == .me || row.state.priority == .high || requested
        guard wanted else { return false }
        if let dismissed = row.state.focusDismissedAt {
            return (row.insight.othersActivityAt ?? .distantPast) > dismissed
        }
        return true
    }
}

/// Small typed wrapper over UserDefaults for UI preferences.
enum Defaults {
    enum Key: String {
        case sort, collapsed, drafts
    }

    static func get<T: Decodable>(_ key: Key) -> T? {
        UserDefaults.standard.data(forKey: key.rawValue).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func set(_ value: some Encodable, for key: Key) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key.rawValue)
    }
}
