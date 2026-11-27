import Foundation
import Observation
import os
#if !os(macOS)
    import UIKit
#endif

enum ItemAction {
    /// Sets the board Status; choosing the current one again clears it (back to Triage).
    case triage(TriageStatus)
    /// Sets the board Priority; choosing the current one again clears it.
    case priority(Priority?)
    case togglePin
    /// Marks the items read; if all are read already, makes each unread again from its latest
    /// activity by others. Only local: GitHub can't mark a notification unread.
    case toggleRead
    case openInBrowser
    /// Opens the GitHub profiles of the items' authors.
    case openAuthorProfile
    /// Copies the items' GitHub links, one per line.
    case copyLink
    /// Brings an item opened from a link onto the desk.
    case addToDesk
    /// Sends the items to a Grok Bot with the request's emoji; `withNote` (⌥) opens the send sheet
    /// first to add a note for the bot.
    case sendToBot(BotRequest, withNote: Bool = false)
    /// Opens the latest agent session of each item, from the board's Session field.
    case openSession
    /// Goes to the PR at the other end of the first item's parity pair (`AppModel.linkedPR`).
    case openLinked
}

/// A send to a Grok Bot waiting in the send sheet: every merge, any request the items were
/// already sent with, and any the viewer asked to add a note to.
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
        /// GitHub refused for its budget; the timer waits until then, while ⌘R and what the user
        /// does are still tried.
        case rateLimited(until: Date)

        var isRateLimited: Bool {
            if case .rateLimited = self { true } else { false }
        }
    }

    /// Seconds between automatic syncs, set in the Mac's Settings. Each round costs a few GraphQL
    /// points. iOS has no setting: it syncs only in front, every five minutes, whatever an older
    /// build stored.
    #if os(macOS)
        var syncInterval: Int = Defaults.get(.syncInterval) ?? 300 {
            didSet { Defaults.set(syncInterval, for: .syncInterval) }
        }
    #else
        let syncInterval = 300
    #endif

    static let syncIntervals = [60, 120, 300, 600, 900]
    /// Rounds are timed from the last attempt, so a failing sync isn't retried every tick.
    @ObservationIgnored private var lastSyncAttemptAt: Date?
    /// Failed rounds in a row; after a failure the next round comes sooner than the interval
    /// (1, 2, 4… minutes), since GitHub's 502s and 504s usually pass within minutes.
    @ObservationIgnored private var syncFailures = 0
    /// How often the poll loop checks whether a sync is due, so a new interval applies promptly.
    private static let pollTick: Duration = .seconds(15)

    private(set) var viewer: String?
    private(set) var syncState: SyncState = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var rateLimit: RateLimit?
    /// What the guard against loops last stopped (`RequestGuard`), for an alert; nil once seen.
    var requestTrip: RequestGuard.Trip?
    /// The guard stopped every request to GitHub, until the viewer resumes.
    private(set) var requestsStopped = false

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
            updateStackLadder()
        }
    }

    /// Whether anything is selected. Observed apart from `selection`, so views that only care
    /// about this (the menu commands) aren't rebuilt each time the selection moves.
    private(set) var hasSelection = false
    /// Whether the selection is a PR, which has the Commits tab; observed apart from it
    /// for the same reason.
    private(set) var selectionIsPullRequest = false

    enum DetailTab: Hashable {
        case conversation, commits
    }

    /// The detail pane's tab. Here rather than in the pane, for the View menu's commands.
    var detailTab: DetailTab = .conversation
    /// The item (`Item.repoNumber`) whose checks show, in a popover from its CI status (a sheet on
    /// the phone); cleared when the selection moves to another item.
    var checksShownFor: String?

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
    @ObservationIgnored private var restoredSelection: TableSelection? = Defaults.get(.selection) {
        didSet { if restoredSelection == nil, awaitsRestoredSelection { awaitsRestoredSelection = false } }
    }
    /// The selection from last time is about to be put back: nothing is selected yet, but
    /// there will be. The iPad's sidebar floating over the detail stays put away for it, rather
    /// than coming out for the empty selection and going away again as the app starts.
    private(set) var awaitsRestoredSelection = (Defaults.get(.selection) as TableSelection?) != nil
    /// The stored items have been read once.
    @ObservationIgnored private var hasSnapshot = false
    /// A link asked for before that (Handoff or the hot key starting the app), opened once they
    /// have: opened at once it found nothing here yet, fetched the item and listed it as opened
    /// from a link, on whichever tab the app last showed.
    @ObservationIgnored private var pendingLink: ItemLink?
    /// Unread notifications for issues and PRs in the repository, newest first.
    private(set) var inbox: [InboxNote] = [] {
        didSet { updateBadge() }
    }

    /// Attic items' notifications don't count; GitHub can't always be stopped from sending them.
    var unreadInboxCount: Int { inbox.count { !$0.isRead && !isMuted($0) } }

    private func isMuted(_ note: InboxNote) -> Bool {
        note.isUpstream && board[note.number]?.triage == .muted
    }

    /// What waits on the viewer in the Parity tab, for the tab's count: staging PRs to review, and
    /// upstream PRs (the viewer's own or adopted) whose Turn is the viewer's.
    private(set) var parityWaitingCount = 0
    /// Where each item of the Parity tab is listed, as of the last rebuild.
    @ObservationIgnored private var paritySections: [Item.ID: ListSection] = [:]
    /// The upstream PR promoted from each parity staging PR that has one, by the staging PR's id.
    @ObservationIgnored private var stagingUpstream: [Item.ID: Item] = [:]
    /// The parity agent's adoptions of other people's upstream PRs, as of the last rebuild.
    @ObservationIgnored private var adoptions = Parity.Adoptions()

    /// The staging PR of each upstream PR promoted from one, by the upstream PR's id.
    @ObservationIgnored private var upstreamStaging: [Item.ID: Item] = [:]

    /// The adoption a staging PR makes, or an upstream PR is the subject of.
    func adoption(of item: Item) -> Parity.Adoption? { adoptions.of(item) }

    /// The PR at the other end of an item's parity pair, as repository and number (it may not be
    /// stored): an adoption's adopted PR or staging PR, a staging PR's promoted upstream PR, or an
    /// upstream PR's staging PR.
    func linkedPR(of item: Item) -> (repo: String, number: Int)? {
        if let adoption = adoptions.of(item) {
            if adoption.staging.id != item.id { return (adoption.staging.repo, adoption.staging.number) }
            return Parity.adoptedNumber(item.headRef).map { (SyncEngine.repo, $0) }
        }
        return (stagingUpstream[item.id] ?? upstreamStaging[item.id]).map { ($0.repo, $0.number) }
    }

    private func updateBadge() {
        Platform.setBadgeCount(unreadInboxCount)
    }
    /// Desk and Good items regardless of the filter, the viewer's move first (for the menu bar).
    private(set) var workingItems: [ItemRow] = []

    /// The last write to the board that failed, shown until dismissed.
    var writeError: String?
    /// The last send to a Grok Bot that failed, shown until dismissed.
    var botError: String?
    /// Why a link or Yab's tab in front didn't open, for an alert.
    var linkError: String?

    /// A write the status bar reports: under way, then done for a few seconds. Failures clear it
    /// and are reported on their own.
    struct Activity: Equatable {
        let id: UUID
        var text: String
        var isDone = false
    }

    private(set) var activity: Activity?

    /// Runs `work` while the status bar shows `text`, then shows it done (unless a newer write
    /// took the status bar meanwhile).
    func withActivity<T>(_ text: String, _ work: () async throws -> T) async rethrows -> T {
        let id = UUID()
        activity = Activity(id: id, text: text)
        do {
            let result = try await work()
            if activity?.id == id {
                activity?.isDone = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if activity?.id == id { activity = nil }
                }
            }
            return result
        } catch {
            if activity?.id == id { activity = nil }
            throw error
        }
    }

    /// Grok Bot sends shown on rows before the database has them: under way (drawn faint), or sent
    /// and waiting for the stored state to catch up. Nothing is stored until the send succeeds,
    /// so a failure only drops the entry.
    private struct BotSendOverlay {
        var at: Date
        var note: String?
        var isSent = false
    }

    @ObservationIgnored private var botSends: [Item.ID: [BotRequest: BotSendOverlay]] = [:]
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
        didSet {
            if let detail { rememberDetail(detail) }
            if detail?.stack != oldValue?.stack || detail?.id != oldValue?.id { updateStackLadder() }
        }
    }

    /// The stack the selected PR is in, for the detail header.
    private(set) var stackLadder: StackLadder?

    private func updateStackLadder() {
        let ladder = selectedItem.flatMap { item in
            StackLadder.of(
                item, stack: detail?.id == item.id ? detail?.stack : nil, items: snapshot.items,
                upstreamOf: { [stagingUpstream] in stagingUpstream[$0.id] }
            )
        }
        if ladder != stackLadder { stackLadder = ladder }
    }

    /// Moves the selection to the next PR along the selected one's stack: `offset` -1 toward the
    /// base, 1 away from it.
    /// False when the selected PR isn't in a stack.
    @discardableResult
    func stepInStack(_ offset: Int) -> Bool {
        guard let item = selectedItem, let ladder = stackLadder else { return false }
        if let number = ladder.neighbor(of: item.number, offset: offset) {
            openItem(repo: ladder.repo, number: number)
        }
        return true
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
    /// The selected PR's head when it was opened before, for Commits' "since you last looked".
    private(set) var selectedItemPreviousSeenHead: String?
    /// The selected item, if the user opened it (rather than the table selecting it); its head is
    /// stored as seen as its detail comes in.
    @ObservationIgnored private var openedItemID: Item.ID?

    @ObservationIgnored private var snapshot = Snapshot()
    @ObservationIgnored private var itemsByID: [Item.ID: Item] = [:]
    @ObservationIgnored let db: AppDatabase
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let affiliationEngine: AffiliationEngine
    @ObservationIgnored private let badgeShare: BadgeShare
    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    /// The item `detailTask` is fetching from GitHub, while it is.
    @ObservationIgnored private var fetchingDetailID: Item.ID?
    /// The item and its update the last detail fetch started for. The stored items changing asks
    /// for the shown detail again only for an update it hasn't started for: a fetch that failed,
    /// or brought a detail still older than the item, isn't started again at each change.
    @ObservationIgnored private var detailFetchedFor: (id: Item.ID, updatedAt: Date)?
    /// Cached details older than this are refreshed when shown, even if the item looks unchanged.
    private static let detailMaxAge: TimeInterval = 120
    @ObservationIgnored let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "App")

    init(db: AppDatabase) {
        self.db = db
        let client = GitHubClient()
        self.client = client
        engine = SyncEngine(client: client, db: db)
        affiliationEngine = AffiliationEngine(client: client, db: db)
        badgeShare = BadgeShare(client: client, db: db)
        sort = Defaults.get(.sort) ?? ItemSort()
        collapsed = Self.loadCollapsed()
        hints = CloudHints.make(directory: AppDatabase.directory) { [weak self] hints in
            await self?.receive(hints)
        } report: { [weak self] error in
            await MainActor.run { if self?.hintsStatus.lastError != error { self?.hintsStatus.lastError = error } }
        }
        hintsStatus.isOn = hints != nil
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
        _ = selectedItemRevision
        return selection.flatMap { itemsByID[$0.itemID] }
    }

    /// Bumped when the stored selected item changes, so the detail pane follows changes that don't
    /// reload its detail (e.g. a rename, which leaves `updatedAt` until the next fetch).
    private var selectedItemRevision = 0

    func state(for item: Item) -> ItemState {
        snapshot.states[item.id] ?? ItemState(itemID: item.id)
    }

    /// The triage board by item number; observed (unlike `snapshot`) so the detail pane follows it.
    private(set) var board: [Int: BoardEntry] = [:]

    /// Only upstream items are on the board; its numbers are upstream ones.
    func board(for item: Item) -> BoardEntry? {
        item.isUpstream ? board[item.number] : nil
    }

    /// Merger is merging the PR (Status Merging on the board), for its icon's color.
    func isMerging(_ item: Item) -> Bool {
        item.isOpen && board(for: item)?.triage == .merging
    }

    /// The same for a PR known only by number, such as a stack's member.
    func isMerging(repo: String, number: Int) -> Bool {
        repo.caseInsensitiveCompare(SyncEngine.repo) == .orderedSame && board[number]?.triage == .merging
    }

    /// The item's Status on the board as the list treats it: none for a Shelf item that was
    /// woken. What toggles act on, so the default Desk of the viewer's own items is left out.
    func triage(for item: Item) -> TriageStatus? {
        board(for: item)?.triage == nil ? nil : row(for: item).listedTriage
    }

    /// The Status the list shows, the default Desk of the viewer's own items included.
    func listedTriage(for item: Item) -> TriageStatus? {
        row(for: item).listedTriage
    }

    /// Whether the item has activity the viewer hasn't seen, as its row's dot shows.
    func isUnread(_ item: Item) -> Bool {
        row(for: item).insight.isUnread
    }

    private func row(for item: Item) -> ItemRow {
        var state = state(for: item)
        for (request, send) in botSends[item.id] ?? [:] {
            state.setSent(at: send.at, note: send.note, for: request)
        }
        let board = board(for: item)
        var insight = insight(for: item, state: state)
        // Merger works a Merging PR through conflicts and CI itself; it needs the viewer only once
        // the approval is gone.
        if item.isOpen, board?.triage == .merging {
            insight.turn = item.reviewDecision == "APPROVED" ? .them : .me
        }
        return ItemRow(
            item: item, state: state,
            insight: insight,
            board: board,
            adoption: adoptions.byUpstream[item.id].flatMap { $0.isActive ? $0 : nil }
        )
    }

    private struct InsightInputs: Equatable {
        var item: Item
        var state: ItemState
        var viewer: String?
        var baseline: Date?
        var adoptedSince: Date?
    }

    /// Insights by item, reused while what they are worked out from stays the same: every
    /// rebuild (each keystroke in the filter) makes rows for all items.
    @ObservationIgnored private var insights: [Item.ID: (inputs: InsightInputs, insight: ItemInsight)] = [:]

    private func insight(for item: Item, state: ItemState) -> ItemInsight {
        let adoption = adoptions.byUpstream[item.id]
        let adoptedSince = adoption?.isPromoted == true ? adoption?.since : nil
        let inputs = InsightInputs(item: item, state: state, viewer: viewer, baseline: snapshot.baseline, adoptedSince: adoptedSince)
        if let cached = insights[item.id], cached.inputs == inputs { return cached.insight }
        let insight = ItemInsight(item: item, state: state, viewer: viewer, baseline: snapshot.baseline, adoptedSince: adoptedSince)
        insights[item.id] = (inputs, insight)
        return insight
    }

    // MARK: Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self, client] in
            for await trip in client.trips {
                guard let self else { return }
                requestTrip = trip
                if trip.isPause { requestsStopped = true }
            }
        })
        #if os(macOS)
            installMouseMonitor()
        #endif
        if let hints {
            // CloudKit's silent pushes say when another device wrote a hint.
            PushDelegate.handler = { [weak self] in await self?.pushEvent($0) }
            Platform.registerForRemoteNotifications()
            tasks.append(Task { await hints.start() })
            #if os(macOS)
                // CloudKit's pushes are low priority, which Apple's servers hold for a Mac until its
                // push connection next shows activity: 40 s to 20 minutes, the app in front or
                // not. The Mac also looks itself, every 10 s while it is in front and every 30 s
                // otherwise: one small CloudKit request, nothing of GitHub's quota.
                tasks.append(Task {
                    var lastPoll = ContinuousClock.now
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.hintsPollInFront)
                        let interval = Platform.isFrontmost ? Self.hintsPollInFront : Self.hintsPollBehind
                        guard ContinuousClock.now - lastPoll >= interval - .seconds(1) else { continue }
                        lastPoll = .now
                        await hints.poll()
                    }
                })
            #endif
        }
        tasks.append(Task { [weak self, db] in
            do {
                for try await snapshot in db.observeSnapshot() {
                    guard let self else { return }
                    self.snapshot = snapshot
                    migrateDrafts()
                    for item in snapshot.items {
                        if let author = item.author, let url = item.authorAvatarURL { AvatarStore.remember(url, for: author) }
                    }
                    if board != snapshot.board {
                        board = snapshot.board
                        updateBadge()
                    }
                    rebuild()
                    if !hasSnapshot {
                        hasSnapshot = true
                        if let link = pendingLink {
                            pendingLink = nil
                            // It is what was asked for, not what was selected last time.
                            restoredSelection = nil
                            open(link)
                        }
                    }
                    restoreSelection()
                    if awaitsRestoredSelection { stopAwaitingRestoredSelection() }
                    if let item = selectedItem, let detail, detail.id == item.id, detail.itemUpdatedAt < item.updatedAt,
                       detailFetchedFor.map({ $0.id != item.id || $0.updatedAt != item.updatedAt }) ?? true
                    {
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
            // Debug builds launched with `-PRDeskNoSync YES` (test copies) don't sync on their own:
            // no searches, board, inbox or prefetched details, only what is opened (and ⌘R). A
            // copy that syncs is a second client spending the same hourly GraphQL quota.
            #if DEBUG
                if UserDefaults.standard.bool(forKey: "PRDeskNoSync") {
                    // A test's badges file is local: sharing it is no request.
                    if BadgeShare.isLocal { await self?.shareBadges(soon: true) }
                    return
                }
            #endif
            while !Task.isCancelled {
                guard let self else { return }
                if isSyncDue {
                    await sync(includeBoard: false)
                }
                try? await Task.sleep(for: Self.pollTick)
            }
        })
    }

    private var isSyncDue: Bool {
        // Right when GitHub's limit lifts, not an interval after.
        if case let .rateLimited(until) = syncState { return Date() >= until }
        return lastSyncAttemptAt.map { Date().timeIntervalSince($0) >= nextSyncDelay } ?? true
    }

    private var nextSyncDelay: TimeInterval {
        guard syncFailures > 0 else { return TimeInterval(syncInterval) }
        return min(60 * pow(2, Double(syncFailures - 1)), TimeInterval(syncInterval))
    }

    /// Lets requests to GitHub go again after the guard stopped them all, and syncs.
    func resumeRequests() {
        requestsStopped = false
        Task {
            await client.resumeRequests()
            await sync()
        }
    }

    /// Syncs now. Unless it is the timer's round, this also reads the board.
    func sync(includeBoard: Bool = true) async {
        // Nothing would be sent; the status says why.
        guard syncState != .syncing, !requestsStopped else { return }
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
            syncFailures = 0
            await syncInbox()
            Task { await refreshAffiliations() }
            prefetchDetails()
        } catch let GraphQLClientError.rateLimited(until) {
            logger.error("Sync rate limited until \(until, privacy: .public)")
            syncState = .rateLimited(until: until)
        } catch {
            logger.error("Sync failed: \(String(describing: error), privacy: .public)")
            syncState = .failed(error.localizedDescription)
            syncFailures += 1
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
            let threads = await recentThreads()
            await followNotificationReads(threads)
            // Read ones too: a mention read on the web has subscribed the viewer all the same.
            if DeviceRole.current.runsRules { await engine.keepMutedQuiet(notes + threads) }
            inbox = notes.sorted { $0.updatedAt > $1.updatedAt }
            rebuild()
            restoreSelection()
        } catch {
            logger.error("Inbox sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Notification threads updated lately, read ones too; none if they can't be read.
    private func recentThreads() async -> [InboxNote] {
        do {
            return try await engine.fetchRecentThreads()
        } catch {
            logger.error("Reading recent notification threads failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Reading a notification anywhere (the web, GitHub's apps, here) counts as seeing its item:
    /// records when each recent thread was last read.
    private func followNotificationReads(_ threads: [InboxNote]) async {
        do {
            let ids = Dictionary(snapshot.items.map { ($0.repoNumber, $0.id) }, uniquingKeysWith: { a, _ in a })
            var readAt: [Item.ID: Date] = [:]
            for thread in threads {
                guard let id = ids[thread.repoNumber], let at = thread.lastReadAt else { continue }
                readAt[id] = max(readAt[id] ?? at, at)
            }
            let changed = readAt.filter { snapshot.states[$0.key]?.notificationReadAt != $0.value }
            if !changed.isEmpty { try await db.setNotificationReadTimes(changed) }
        } catch {
            logger.error("Recording notification read times failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Marks the item's notification thread read on GitHub, if it has one.
    private func markNotificationRead(_ item: Item) {
        guard let index = inbox.firstIndex(where: { $0.repoNumber == item.repoNumber && !$0.isRead }) else { return }
        let note = inbox[index]
        // Keep the row in place so the selection doesn't jump; the next sync drops it.
        inbox[index].isRead = true
        rebuild()
        Task { [weak self, engine, logger] in
            do {
                try await engine.markThreadRead(note.threadID)
                self?.hint(.inbox, [item.id])
            } catch {
                logger.error("Failed to mark thread read: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Other devices

    /// Hints to and from the viewer's other devices (`CloudHints`); nil in a copy not signed for
    /// iCloud.
    @ObservationIgnored private var hints: CloudHints?

    /// How hints between the devices go, for Settings.
    struct HintsStatus: Equatable {
        var isOn = false
        var lastSent: Date?
        var lastReceived: Date?
        /// The kind of device the last hint came from ("iPad").
        var lastSender: String?
        /// Why the last send or fetch failed, until one goes through.
        var lastError: String?
    }

    private(set) var hintsStatus = HintsStatus()

    #if os(macOS)
        private static let hintsPollInFront: Duration = .seconds(10)
        private static let hintsPollBehind: Duration = .seconds(30)
    #endif

    /// What this device is called in the others' Settings.
    private static var deviceKind: String {
        #if os(macOS)
            "Mac"
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// Tells the other devices that a write to GitHub went through, so that they fetch these
    /// items' `parts` again now rather than at their next sync.
    private func hint(_ parts: ChangeHint.Parts, _ itemIDs: [Item.ID]) {
        guard let hints, !itemIDs.isEmpty else { return }
        let hint = ChangeHint(itemIDs: itemIDs, parts: parts, device: CloudHints.deviceID, deviceKind: Self.deviceKind, at: Date())
        hintsStatus.lastSent = hint.at
        Task { await hints.send(hint) }
    }

    /// Fetches the others' hints now, for an app back in front.
    func fetchHints() {
        guard let hints else { return }
        Task { await hints.fetchNow() }
    }

    /// What the app's delegate was told about pushes: one came (CloudKit's, saying another
    /// device wrote a hint), or registering for them went through or failed.
    func pushEvent(_ event: PushDelegate.Event) async {
        guard let hints else { return }
        switch event {
        case .push: await hints.pushed()
        case .registered: await hints.noted("registered for pushes")
        case let .failed(reason): await hints.noted("registering for pushes failed: \(reason)")
        }
    }

    /// Fetches again what other devices changed: the stored items (and items another device put
    /// on the board, as a sync would), their board entries, the inbox, the shown detail and its
    /// files' marks. Left to the next sync while GitHub refuses for its budget.
    private func receive(_ hints: [ChangeHint]) async {
        if let last = hints.max(by: { $0.at < $1.at }) {
            hintsStatus.lastReceived = Date()
            hintsStatus.lastSender = last.deviceKind
        }
        guard !syncState.isRateLimited else { return }
        func ids(_ part: ChangeHint.Parts) -> Set<Item.ID> {
            Set(hints.filter { $0.parts.contains(part) }.flatMap(\.itemIDs))
        }
        let all = Set(hints.flatMap(\.itemIDs))
        let stored = Set(snapshot.items.map(\.id))
        let board = ids(.board)
        // Only what is stored: an item opened from a link isn't on the desk, unless it went on the board.
        let refresh = all.filter { stored.contains($0) || board.contains($0) }
        do {
            if !board.isEmpty { try await engine.refreshBoardEntries(contentIDs: Array(board)) }
            if !refresh.isEmpty { _ = try await engine.refresh(ids: Array(refresh)) }
        } catch {
            logger.error("Following another device's change failed: \(String(describing: error), privacy: .public)")
        }
        if !ids(.inbox).isEmpty { await syncInbox() }
        if let item = selectedItem, all.contains(item.id) {
            if ids(.timeline).contains(item.id) { loadDetail(force: true) }
            if ids(.files).contains(item.id), viewedFiles[item.id] != nil { await loadViewedFiles(for: item) }
        }
        prefetchDetails()
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
        let verb = switch submission {
        case .comment: "Comment on"
        case .approve: "Approve"
        case .requestChanges: "Request changes on"
        }
        try await withActivity("\(verb) #\(item.number)") {
            try await engine.submit(submission, body: body, subjectID: detail.id)
        }
        setDraft("", for: item.id)
        hint([.item, .timeline], [item.id])
        if DeviceRole.current.runsRules, submission == .approve, item.kind == .pullRequest, item.isUpstream, item.isOpen,
           board(for: item).map({ $0.isArchived && !$0.isForeign }) ?? true {
            writeBoard("add #\(item.number) to the board as Good", activity: "#\(item.number) → Good", items: [item]) { engine in
                try await engine.addApproved(number: item.number, contentID: item.id)
            }
        }
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
                self?.hint(.timeline, [changed.id])
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
        try await withActivity(comment.isEmpty ? "Close #\(item.number)" : "Comment on and close #\(item.number)") {
            if !comment.isEmpty {
                try await engine.submit(.comment, body: comment, subjectID: detail.id)
                setDraft("", for: item.id)
            }
            try await engine.close(subjectID: detail.id, isPullRequest: item.kind == .pullRequest, reason: reason)
        }
        hint([.item, .timeline], [item.id])
        updateState(item) { $0.seenAt = Date() }
        _ = try? await engine.refresh(ids: [item.id])
        loadDetail(force: true)
    }

    /// Flips an open PR between draft and ready for review (`Item.draftToggle`); a failure shows
    /// in the write alert.
    func toggleDraft(_ item: Item) async {
        guard let toggle = item.draftToggle else { return }
        let activity = item.isParityStaging ? "\(toggle.title) #\(item.number)" : "#\(item.number) → \(toggle.makesDraft ? "Draft" : "Ready")"
        do {
            try await withActivity(activity) {
                try await engine.setDraft(toggle.makesDraft, pullRequestID: item.id)
            }
        } catch {
            writeError = "Couldn't \(toggle.verb) #\(item.number): \(error.localizedDescription)"
            return
        }
        hint([.item, .timeline], [item.id])
        updateState(item) { $0.seenAt = Date() }
        _ = try? await engine.refresh(ids: [item.id])
        loadDetail(force: true)
    }

    /// Renames the item: the list and detail show the new title at once, and get the old one back
    /// if GitHub refuses. An empty or unchanged title does nothing; line breaks become spaces.
    func rename(_ item: Item, to newTitle: String) {
        let title = newTitle.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let old = item.title
        guard !title.isEmpty, title != old else { return }
        Task {
            do {
                try await db.setTitle(title, id: item.id)
            } catch {
                logger.error("Storing the new title of #\(item.number) failed: \(String(describing: error), privacy: .public)")
            }
            do {
                try await withActivity("Rename #\(item.number)") {
                    try await engine.setTitle(title, subjectID: item.id, isPullRequest: item.kind == .pullRequest)
                }
                hint([.item, .timeline], [item.id])
            } catch {
                try? await db.setTitle(old, id: item.id, expected: title)
                writeError = "Couldn't rename #\(item.number): \(error.localizedDescription)"
            }
        }
    }

    func renderMarkdown(_ text: String, in item: Item) async throws -> String {
        try await engine.renderMarkdown(text, repo: item.repo)
    }

    func requestComposerFocus() { composerFocusRequest += 1 }

    /// An adopted PR whose promote is done, before the viewer has posted the comment the agent drafted.
    func awaitsDraftedComment(_ item: Item) -> Bool {
        row(for: item).insight.awaitsDraftedComment
    }

    /// The comment the parity agent drafted, in an adoption's staging PR, for the viewer to post
    /// on the adopted PR; nil if the body has none.
    func draftedComment(for adoption: Parity.Adoption) async throws -> String? {
        let body = try await engine.fetchBody(repo: adoption.staging.repo, number: adoption.staging.number)
        return Parity.draftedComment(inBody: body)
    }

    @ObservationIgnored private var filesCache: [Item.ID: (updatedAt: Date?, files: [PullFile])] = [:]

    /// Changed files of a PR, cached until the PR is updated.
    func files(for item: Item) async throws -> [PullFile] {
        let updatedAt = itemsByID[item.id]?.updatedAt ?? item.updatedAt
        if let cached = filesCache[item.id], cached.updatedAt == updatedAt { return cached.files }
        let files = try await engine.fetchFiles(repo: item.repo, number: item.number)
        filesCache[item.id] = (updatedAt, files)
        return files
    }

    @ObservationIgnored private var rangeFilesCache: [String: [PullFile]] = [:]

    /// The files a range of a PR's commits changed. A commit's never change, so they are kept for
    /// the run (a hundred ranges at most).
    func files(for item: Item, in range: CommitRange) async throws -> [PullFile] {
        if range == .all { return try await files(for: item) }
        let key = "\(item.repo)@\(range.key)"
        if let cached = rangeFilesCache[key] { return cached }
        let files = switch range {
        case .all: try await files(for: item)
        case let .commit(sha): try await engine.fetchCommitFiles(repo: item.repo, sha: sha)
        case let .compare(base, head): try await engine.fetchCompareFiles(repo: item.repo, base: base, head: head)
        }
        if rangeFilesCache.count >= 100 { rangeFilesCache.removeAll() }
        rangeFilesCache[key] = files
        return files
    }

    /// The viewer's "Viewed" marks on PRs' files, by PR and path; missing until fetched.
    private(set) var viewedFiles: [Item.ID: [String: FileViewedState]] = [:]

    /// Fetches the viewer's "Viewed" marks on a PR's files; on failure the page offers none.
    func loadViewedFiles(for item: Item) async {
        do {
            viewedFiles[item.id] = try await engine.fetchViewedStates(pullRequestID: item.id)
        } catch {
            logger.error("Loading viewed files of #\(item.number) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Ticks or clears a file's "Viewed" mark at once, and puts it back if GitHub refuses.
    func setFileViewed(_ viewed: Bool, path: String, in itemID: Item.ID) {
        guard let before = viewedFiles[itemID]?[path] else { return }
        let after: FileViewedState = viewed ? .viewed : .unviewed
        guard before != after else { return }
        viewedFiles[itemID]?[path] = after
        Task { [weak self, engine] in
            do {
                try await engine.setFileViewed(viewed, path: path, pullRequestID: itemID)
                self?.hint(.files, [itemID])
            } catch {
                guard let self else { return }
                logger.error("Marking \(path, privacy: .public) viewed failed: \(String(describing: error), privacy: .public)")
                if viewedFiles[itemID]?[path] == after { viewedFiles[itemID]?[path] = before }
            }
        }
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

    /// Opens the item a link names (a browser tab, a pasted or dropped link, the filter field), on
    /// the tab the link shows (with the checks showing for `/checks`), scrolled to the comment it
    /// points to.
    func open(_ link: ItemLink) {
        guard hasSnapshot else {
            pendingLink = link
            return
        }
        switch link.page {
        case .conversation: detailTab = .conversation
        case .commits, .files: detailTab = .commits
        case .checks: detailTab = .conversation
        }
        checksShownFor = link.page == .checks ? link.key : nil
        linkedCommit = [.commits, .files].contains(link.page) ? link : nil
        linkedComment = link.anchor == nil ? nil : link
        openItem(repo: link.repo, number: link.number)
        requestTableFocus()
    }

    /// Return in the filter field: a link, or a `#n` that nothing listed matches, opens its item and
    /// clears the filter. Returns false to leave the field as Return otherwise does.
    func submitFilter() -> Bool {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        guard let link = ItemLink(text) else { return false }
        if text.hasPrefix("#"), rows.contains(where: { $0.selectionID != nil }) { return false }
        filterText = ""
        open(link)
        return true
    }

    /// The last opened link that points to a comment, until the selection moves to another item;
    /// the conversation scrolls to it once it shows the comment.
    private(set) var linkedComment: ItemLink?
    /// The last opened link to a PR's commits or files, until the selection moves to another item;
    /// the Commits tab selects the commit it names, or shows all changes.
    private(set) var linkedCommit: ItemLink?

    /// Brings up the window, set by the views that can open it.
    @ObservationIgnored var showWindow: (() -> Void)?

    private func showOpened(_ item: Item) {
        openedItems.removeAll { $0.id == item.id }
        openedItems.insert(item, at: 0)
        if openedItems.count > Self.openedLimit { openedItems.removeLast() }
        collapsed.remove(.opened)
        // Among its own kind: a parity item not listed here (too new, or long closed) shows at
        // the head of the Parity tab, as a listed one is gone to there.
        if item.isParity, mode != .parity {
            mode = .parity
        } else {
            rebuild()
        }
        selection = TableSelection(section: .opened, itemID: item.id)
    }

    /// The item a link names, if it is here: stored, or opened from a link before.
    func item(for link: ItemLink) -> Item? {
        snapshot.items.first { $0.repoNumber == link.key } ?? openedItems.first { $0.repoNumber == link.key }
    }

    /// Whether the item is only in Opened: fetched from a link and not stored, so not on the desk.
    func isOpenedOnly(_ item: Item) -> Bool {
        !snapshot.items.contains { $0.id == item.id }
    }

    /// Whether the request can go to its bot for this item (`BotRequest.applies`).
    func canSend(_ request: BotRequest, for item: Item) -> Bool {
        request.applies(to: item, viewer: viewer)
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
        return item.isOpen || (item.closedAt ?? item.updatedAt) >= cutoff || row.isPinned
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
    #if os(macOS)
        @ObservationIgnored var mouseMonitor: Any?
    #endif
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
    /// has the status, priority or pin, it is cleared from all; otherwise all get it.
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
            // Pins are on the board, so as for Status; Pinned is a dashboard section, which
            // staging PRs stay out of.
            items = items.filter { $0.isUpstream && !$0.isParity && board(for: $0)?.isForeign != true }
            addToDesk(items)
        case .addToDesk:
            addToDesk(items.filter(canAddToDesk))
        case let .sendToBot(request, _):
            items = items.filter { canSend(request, for: $0) }
        default:
            break
        }
        guard !items.isEmpty else { return }
        switch action {
        case let .triage(status):
            // A woken Shelf item is back in Triage, so skipping it again renews the skip.
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
            let pin = !items.allSatisfy { board(for: $0)?.isPinned == true }
            setPins(items.filter { board(for: $0)?.isPinned != pin }.map { ($0, pin) })
        case .toggleRead:
            let rows = items.map { ($0, insight(for: $0, state: state(for: $0))) }
            if rows.contains(where: { $0.1.isUnread }) {
                for item in items {
                    updateState(item) { $0.seenAt = now }
                    markNotificationRead(item)
                }
            } else {
                // Unread until seen again, even where GitHub says its notification was read. GitHub
                // times are whole seconds: a second before the latest activity by others makes
                // just that new when the item is next opened.
                for (item, insight) in rows {
                    let seenAt = insight.othersActivityAt?.addingTimeInterval(-1)
                    updateState(item) { state in
                        state.markedUnreadAt = now
                        if let seenAt { state.seenAt = seenAt }
                    }
                }
            }
        case .openInBrowser:
            // Opening dozens of tabs is never what a stray keypress meant.
            for item in items.prefix(Self.maxTabsAtOnce) {
                if let url = URL(string: item.url) { Platform.open(url) }
            }
        case .openLinked:
            if let linked = items.lazy.compactMap(linkedPR).first {
                openItem(repo: linked.repo, number: linked.number)
            }
        case .openSession:
            let links = items.compactMap { board(for: $0)?.sessionLinks.last }
            for link in links.prefix(Self.maxTabsAtOnce) {
                AgentSession.open(link)
            }
        case .openAuthorProfile:
            var seen = Set<String>()
            let authors = items.compactMap(\.author).filter { seen.insert($0.lowercased()).inserted }
            for author in authors.prefix(Self.maxTabsAtOnce) {
                Self.openProfile(author)
            }
        case .copyLink:
            // A single link also goes as a URL, so apps that take one (Mail, Notes) make it a link.
            Platform.copy(items.map(\.url).joined(separator: "\n"), url: items.count == 1 ? items[0].url : nil)
        case .addToDesk:
            break
        case let .sendToBot(request, withNote):
            let resends = items.count { state(for: $0).sentAt(request) != nil || botSends[$0.id]?[request] != nil }
            if withNote || request == .merge || resends > 0 {
                pendingBotSend = PendingBotSend(request: request, items: items, resends: resends)
            } else {
                sendToBot(request, items: items)
            }
        }
    }

    /// Sends `items` to the request's bot in one message, with the viewer's note if any. The marks
    /// show at once, faint until the send is through; they are stored only then, and dropped if
    /// it fails.
    func sendToBot(_ request: BotRequest, items: [Item], note: String? = nil) {
        let note = note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let text = GrokBot.message(request, items: items, note: note)
        let bot = request.botName
        let now = Date()
        for item in items {
            botSends[item.id, default: [:]][request] = BotSendOverlay(at: now, note: note)
        }
        rebuild()
        let what = items.count == 1 ? "#\(items[0].number)" : "\(items.count) items"
        Task {
            let sent: Bool
            do {
                sent = try await withActivity("\(request.emoji) \(what) → \(bot)") {
                    try await GrokBot.deliver(text, for: request)
                }
            } catch {
                logger.error("Failed to send to \(bot, privacy: .public): \(String(describing: error), privacy: .public)")
                for item in items { botSends[item.id]?[request] = nil }
                rebuild()
                botError = "Couldn't send \(request.emoji) to \(bot): \(error.localizedDescription)"
                return
            }
            for item in items { botSends[item.id]?[request]?.isSent = true }
            rebuild()
            // Merger has the PR only once the message is out, not while it waits as a draft.
            if request == .merge, sent { setMerging(items) }
            for item in items {
                do {
                    try await db.updateState(item.id) { $0.setSent(at: now, note: note, for: request) }
                } catch {
                    logger.error("Failed to store the send of #\(item.number): \(error)")
                }
            }
        }
    }

    private static let maxTabsAtOnce = 10

    static func profileURL(for login: String) -> URL? {
        URL(string: "https://github.com/\(login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login)")
    }

    /// Opens a person's GitHub profile in the browser.
    static func openProfile(_ login: String) {
        if let url = profileURL(for: login) { Platform.open(url) }
    }

    /// Runs a board write, reporting failure in `writeError`.
    // MARK: Undo

    /// Undo for list actions: Status, Priority and pins. The table answers ⌘Z with
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
        let statuses = Set(changes.map(\.status))
        let to = statuses.count == 1 ? (statuses.first!?.rawValue ?? "Triage") : "Status"
        writeBoard("set the status of \(what)", activity: "\(what) → \(to)", items: changes.map(\.item)) { engine in
            for change in changes {
                try await engine.setTriage(change.status, number: change.item.number, contentID: change.item.id)
            }
        }
    }

    /// Marks PRs just sent with 🚀 as Merging on the board, without waiting for Merger to (SPEC
    /// §3.3). Not undoable, like the send itself.
    private func setMerging(_ items: [Item]) {
        let items = items.filter { board(for: $0)?.isForeign != true && board(for: $0)?.triage != .merging }
        guard !items.isEmpty else { return }
        let what = items.count == 1 ? "#\(items[0].number)" : "\(items.count) items"
        writeBoard("set \(what) to Merging", activity: "\(what) → Merging", items: items) { engine in
            for item in items {
                try await engine.setMerging(number: item.number, contentID: item.id)
            }
        }
    }

    private func setPriority(_ changes: [(item: Item, priority: Priority?)]) {
        guard !changes.isEmpty else { return }
        let previous = changes.map { (item: $0.item, priority: board(for: $0.item)?.priorityValue) }
        registerUndo("Set Priority") { $0.setPriority(previous) }
        let what = changes.count == 1 ? "#\(changes[0].item.number)" : "\(changes.count) items"
        let priorities = Set(changes.map(\.priority))
        let to = priorities.count == 1 ? (priorities.first!.map { "\($0.optionName) priority" } ?? "no priority") : "Priority"
        writeBoard("set the priority of \(what)", activity: "\(what) → \(to)", items: changes.map(\.item)) { engine in
            for change in changes {
                try await engine.setPriority(change.priority, number: change.item.number, contentID: change.item.id)
            }
        }
    }

    private func setPins(_ changes: [(item: Item, pinned: Bool)]) {
        guard !changes.isEmpty else { return }
        let previous = changes.map { (item: $0.item, pinned: board(for: $0.item)?.isPinned == true) }
        let pins = changes.contains(where: \.pinned)
        registerUndo(pins ? "Pin" : "Unpin") { $0.setPins(previous) }
        let what = changes.count == 1 ? "#\(changes[0].item.number)" : "\(changes.count) items"
        let verb = Set(changes.map(\.pinned)).count > 1 ? "pin / unpin" : pins ? "pin" : "unpin"
        writeBoard("\(verb) \(what)", activity: "\(verb.capitalized) \(what)", items: changes.map(\.item)) { engine in
            for change in changes {
                try await engine.setPinned(change.pinned, number: change.item.number, contentID: change.item.id)
            }
        }
    }

    /// The latest board write for each item. A write waits for those of its items before it, so an
    /// undo never reaches GitHub ahead of what it undoes; other items' writes don't wait.
    @ObservationIgnored private var pendingBoardWrites: [Int: Task<Void, Never>] = [:]

    /// `activity` is what the status bar says meanwhile.
    private func writeBoard(_ what: String, activity: String, items: [Item], _ write: @escaping @Sendable (SyncEngine) async throws -> Void) {
        let numbers = items.map(\.number)
        let earlier = numbers.compactMap { pendingBoardWrites[$0] }
        let task = Task { [engine, logger] in
            for task in earlier { await task.value }
            do {
                try await withActivity(activity) { try await write(engine) }
                hint(.board, items.map(\.id))
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

    /// How sharing badges between the devices last went (`BadgeShare`), for Settings.
    enum BadgeShareState: Equatable {
        case none
        case done(Date)
        case failed(String)
    }

    private(set) var badgeShareState = BadgeShareState.none

    /// Badges are set by hand here: on the Mac, and on a device that doesn't read the Mac's
    /// (whose next file would put its own entries in their place).
    var canEditAffiliations: Bool { DeviceRole.current.computesAffiliations || BadgeShare.place == nil }

    /// The Mac publishes what its badges come from where that changed; the iPad reads it.
    func shareBadges(soon: Bool = false) async {
        do {
            let outcome = if DeviceRole.current.computesAffiliations {
                try await badgeShare.publish(mergedThreshold: mergedThreshold, soon: soon)
            } else {
                try await badgeShare.read(force: soon)
            }
            switch outcome {
            case .published:
                badgeShareState = .done(Date())
            case let .read(threshold):
                if let threshold, threshold != mergedThreshold { mergedThreshold = threshold }
                badgeShareState = .done(Date())
            case .waiting, nil:
                break
            }
        } catch {
            logger.error("Sharing badges failed: \(String(describing: error), privacy: .public)")
            badgeShareState = .failed(error.localizedDescription)
        }
    }

    /// Updates affiliation data for everyone who appears in the list.
    func refreshAffiliations(force: Bool = false) async {
        guard DeviceRole.current.computesAffiliations else { return await shareBadges(soon: force) }
        let authors = Set(snapshot.items.compactMap(\.author))
        let logins = authors.union(snapshot.items.flatMap { $0.events.compactMap(\.actor) })
        do {
            try await affiliationEngine.refresh(logins: logins, authors: authors, force: force)
        } catch {
            logger.error("Affiliation refresh failed: \(String(describing: error), privacy: .public)")
        }
        await shareBadges(soon: force)
    }

    func setOverride(_ override: OrgOverride) {
        updateOverrides(saving: [override], deleting: [])
    }

    func removeOverride(_ override: OrgOverride) {
        updateOverrides(saving: [], deleting: [override])
    }

    /// Gives `logins` the org's badge, or takes it away when they all have it (SPEC §5).
    func toggleAffiliation(_ org: Org, for logins: [String]) {
        let (save, delete) = affiliations.toggling(org, for: logins)
        updateOverrides(saving: save, deleting: delete)
    }

    /// Drops every manual affiliation of `logins`, back to what is detected.
    func clearManualAffiliations(for logins: [String]) {
        let keys = Set(logins.map { $0.lowercased() })
        updateOverrides(saving: [], deleting: affiliations.overrides.filter { keys.contains($0.login) })
    }

    private func updateOverrides(saving: [OrgOverride], deleting: [OrgOverride]) {
        guard !saving.isEmpty || !deleting.isEmpty else { return }
        Task {
            do {
                try await db.update(saving: saving, deleting: deleting)
            } catch {
                logger.error("Failed to set affiliations: \(error)")
            }
            // A badge set by hand reaches the other devices without waiting its turn.
            await shareBadges(soon: true)
        }
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
        // A fetch of this item is under way: let it finish. The fetch stores the item before it
        // ends, and the stored items changing asks for the detail again while the one shown is
        // older than the item: restarting here cancelled it each time, and it started over for
        // good, spending the quota at every turn.
        if !force, let fetching = fetchingDetailID, fetching == selectedItem?.id { return }
        detailTask?.cancel()
        fetchingDetailID = nil
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
            self?.recordSeenHead()
            if !force, let current = self?.detail,
               current.itemUpdatedAt >= item.updatedAt,
               Date().timeIntervalSince(current.fetchedAt) < Self.detailMaxAge
            {
                return
            }
            guard !Task.isCancelled else { return }
            self?.detailState = .loading
            self?.fetchingDetailID = item.id
            self?.detailFetchedFor = (item.id, item.updatedAt)
            do {
                let (fresh, freshItem) = try await engine.fetchDetail(of: item)
                try? await db.saveDetail(fresh)
                guard !Task.isCancelled, let self else { return }
                fetchingDetailID = nil
                detail = fresh
                // A stored item's row follows from the database; one only opened from a link is here.
                if let freshItem, let index = openedItems.firstIndex(where: { $0.id == freshItem.id }), isOpenedOnly(freshItem) {
                    openedItems[index] = freshItem
                    rebuild()
                }
                detailState = .idle
                recordSeenHead()
                // Merged counts too, for what hovering a login in the conversation shows. A companion
                // imports the badges instead, so it doesn't spend the quota on who these people are.
                if DeviceRole.current.computesAffiliations {
                    let actors = Set(fresh.entries.compactMap(\.actor))
                    Task { try? await self.affiliationEngine.refresh(logins: actors, authors: actors) }
                }
                // The item moved on while this was on its way: once more, for that update.
                if let current = selectedItem, current.id == item.id, current.updatedAt > item.updatedAt,
                   fresh.itemUpdatedAt < current.updatedAt
                {
                    loadDetail()
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.fetchingDetailID = nil
                self?.logger.error("Detail of #\(item.number) failed: \(String(describing: error), privacy: .public)")
                self?.detailState = .failed(error.localizedDescription)
            }
        }
    }

    /// Stores the head of a PR the user opened as seen, once its detail is in.
    private func recordSeenHead() {
        guard let item = selectedItem, item.id == openedItemID, let detail, detail.id == item.id,
              let head = detail.commits?.last?.oid, state(for: item).seenHeadOid != head else { return }
        updateState(item) { $0.seenHeadOid = head }
    }

    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// Items whose prefetch failed, with the update it failed at: not tried again until the item
    /// moves on, or one that always fails (gone, transferred) would be fetched at every sync.
    @ObservationIgnored private var prefetchFailed: [Item.ID: Date] = [:]

    private enum PrefetchOutcome: Sendable {
        case fetched(actors: Set<String>)
        case failed(Item.ID, at: Date)
        case rateLimited
    }
    private static let prefetchConcurrency = 2

    /// Fetches ahead the details of items likely to be opened (Desk, Good, Triage, the Inbox,
    /// Pinned, Recently viewed and the open parity staging PRs) whose cache is missing or older than
    /// the item, so opening one shows its cache at once. A round still running skips the next; the
    /// sync after picks it up.
    private func prefetchDetails() {
        guard DeviceRole.current.prefetchesDetails, prefetchTask == nil else { return }
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
            return row.isPinned || inboxItems.contains(item.repoNumber) || recent.contains(item.id)
        }
        prefetchTask = Task { [weak self, db, engine, logger] in
            defer { self?.prefetchTask = nil }
            let cached = (try? await db.cachedDetailTimes()) ?? [:]
            let failed = self?.prefetchFailed ?? [:]
            let stale = candidates.filter { item in
                failed[item.id] != item.updatedAt && (cached[item.id].map { $0 < item.updatedAt } ?? true)
            }
            guard !stale.isEmpty else { return }
            logger.info("Prefetching \(stale.count) details")
            var actors: Set<String> = []
            // Refused by GitHub for its budget, the rest wait for the sync after the limit.
            await withTaskGroup(of: PrefetchOutcome.self) { group in
                var queue = stale.makeIterator()
                var isRateLimited = false
                let fetch = { @Sendable (item: Item) async -> PrefetchOutcome in
                    do {
                        let detail = try await engine.fetchDetail(of: item).detail
                        try await db.saveDetail(detail)
                        return .fetched(actors: Set(detail.entries.compactMap(\.actor)))
                    } catch GraphQLClientError.rateLimited {
                        return .rateLimited
                    } catch {
                        logger.error("Prefetching the detail of #\(item.number) failed: \(String(describing: error), privacy: .public)")
                        return .failed(item.id, at: item.updatedAt)
                    }
                }
                for _ in 0 ..< Self.prefetchConcurrency {
                    if let item = queue.next() { group.addTask { await fetch(item) } }
                }
                for await outcome in group {
                    switch outcome {
                    case let .fetched(found): actors.formUnion(found)
                    case let .failed(id, updatedAt): self?.prefetchFailed[id] = updatedAt
                    case .rateLimited: isRateLimited = true
                    }
                    if !isRateLimited, let item = queue.next() { group.addTask { await fetch(item) } }
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

    /// The stored items are read and the selection from last time isn't back: it won't be soon.
    /// One of the Inbox comes back once the Inbox is synced, so that is waited for a little.
    private func stopAwaitingRestoredSelection() {
        guard restoredSelection?.section == .inbox, !rows.isEmpty else {
            awaitsRestoredSelection = false
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.awaitsRestoredSelection = false
        }
    }

    func autoSelect(_ selection: TableSelection?) {
        isAutoSelecting = true
        defer { isAutoSelecting = false }
        self.selection = selection
    }

    private func selectionChanged(from old: TableSelection?) {
        guard selection?.itemID != old?.itemID else { return }
        recordHistory(from: old)
        if let linkedComment, selectedItem?.repoNumber != linkedComment.key { self.linkedComment = nil }
        if let checksShownFor, selectedItem?.repoNumber != checksShownFor { self.checksShownFor = nil }
        if let linkedCommit, selectedItem?.repoNumber != linkedCommit.key { self.linkedCommit = nil }
        openedItemID = nil
        if let item = selectedItem { selectedItemPreviousSeenHead = state(for: item).seenHeadOid }
        loadDetail()
        guard let item = selectedItem else {
            selectedItemPreviousSeenAt = nil
            selectedItemPreviousSeenHead = nil
            return
        }
        selectedItemPreviousSeenAt = state(for: item).seenAt ?? snapshot.baseline
        // Opening counts at once; only the user's own selections open anything.
        guard !isAutoSelecting else { return }
        openedItemID = item.id
        recordSeenHead()
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

    private static let dashboardSections: [ListSection] = [.recent, .pinned, .good, .working, .triage, .backlog, .closed, .skipped, .muted]

    private func rebuild() {
        let selectedBefore = selection.flatMap { itemsByID[$0.itemID] }
        itemsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        if let selection, itemsByID[selection.itemID] != selectedBefore { selectedItemRevision += 1 }
        // Sent marks the database now has need no overlay. Stored dates keep milliseconds only.
        for (id, sends) in botSends {
            let stored = snapshot.states[id]
            let left = sends.filter { request, send in
                !(send.isSent && stored?.sentAt(request).map { abs($0.timeIntervalSince(send.at)) < 0.01 } == true)
            }
            botSends[id] = left.isEmpty ? nil : left
        }
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

        adoptions = Parity.adoptions(in: snapshot.items, viewer: viewer)
        let all: [ItemRow] = snapshot.items.compactMap { item in
            let row = row(for: item)
            // Items of the other tracker sharing the board are none of the app's business.
            if row.board?.isForeign == true { return nil }
            if !item.isOpen, (item.closedAt ?? item.updatedAt) < cutoff, !row.isPinned { return nil }
            return row
        }
        // Staging PRs and the upstream PRs promoted from them show in the Parity tab, not the
        // dashboard; adopted PRs show in both once promoted.
        let candidates = all.filter { $0.item.isUpstream && !$0.item.isParity }
        var parity = Parity.sections(of: all, adoptions: adoptions)
        for (section, rows) in parity {
            parity[section] = rows.map { row in
                var row = row
                row.pairedIsMerging = row.paired.map(isMerging) ?? false
                return row
            }
        }
        paritySections = [:]
        stagingUpstream = [:]
        upstreamStaging = [:]
        for (section, rows) in parity {
            for row in rows {
                paritySections[row.item.id] = section
                if row.item.isUpstream, let staging = row.paired {
                    stagingUpstream[staging.id] = row.item
                    upstreamStaging[row.item.id] = staging
                }
            }
        }
        updateStackLadder()
        let waiting = (parity[.parityReview]?.count ?? 0)
            + (parity[.parityUpstream] ?? []).count { $0.insight.turn == .me }
            + (parity[.parityAdopted] ?? []).count { $0.insight.turn == .me }
        if parityWaitingCount != waiting { parityWaitingCount = waiting }

        workingItems = Self.mineFirst(candidates
            .filter { [.working, .good].contains(ListSection.triageSection(of: $0)) }
            .sorted { $0.item.updatedAt > $1.item.updatedAt })
        let visible = filter.isEmpty ? candidates : candidates.filter { filter.matches($0, badges: badges, contribution: contribution) }

        visibleCount = visible.count

        if mode == .parity {
            var rows = openedRows
            var count = 0
            // Stack members in other sections (or filtered out) show as stubs.
            let pool = parity.values.flatMap { $0.map(\.item) }
            for section in Parity.sections {
                let members = (parity[section] ?? [])
                    .filter { filter.isEmpty || filter.matches($0, badges: badges, contribution: contribution) }
                    .sorted(by: sort.areInIncreasingOrder)
                count += members.count
                let isCollapsed = filter.isEmpty && collapsed.contains(section)
                rows.append(.header(section, count: members.count, collapsed: isCollapsed))
                if !isCollapsed {
                    rows += Stacks.grouped(Self.yourMoveFirst(members), among: pool).map { .item(section, $0) }
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
        members[.pinned] = ordered.filter(\.isPinned)
        for row in ordered {
            if let section = ListSection.triageSection(of: row) { members[section, default: []].append(row) }
        }
        for section in [ListSection.working, .good, .backlog] {
            members[section] = Self.mineFirst(members[section] ?? [])
        }
        // What waits for 🚀 comes before what Merger is already merging.
        let good = members[.good] ?? []
        members[.good] = good.filter { !$0.isMerging } + good.filter(\.isMerging)
        // Stacks stay together, where their base sorts; Recently viewed keeps its order (by when
        // each item was opened). Pinned sorts like the rest, so its stacks group too.
        // Members in other sections (or filtered out) show as stubs on the rail.
        let pool = candidates.map(\.item)
        for section in Self.dashboardSections where section != .recent {
            if let rows = members[section] { members[section] = Stacks.grouped(rows, among: pool) }
        }

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
