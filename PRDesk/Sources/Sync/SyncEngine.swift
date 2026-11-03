import Foundation
import os

struct SyncResult: Sendable {
    var viewer: String
    var fetched: Int
    var finishedAt: Date
    var rateLimit: RateLimit?
}

enum SyncError: LocalizedError {
    case notFound(repo: String, number: Int)

    var errorDescription: String? {
        switch self {
        case let .notFound(repo, number): "#\(number) was not found in \(repo)."
        }
    }
}

/// Pulls tracked PRs and issues from GitHub into the local database.
///
/// The first sync looks back `initialLookback`; later syncs only ask for items
/// updated since the previous sync started (minus some slack for search index lag).
/// Items on the triage board are tracked too; those no search finds are refreshed by id.
actor SyncEngine {
    static let owner = "vllm-project"
    static let name = "vllm"
    static let repo = "\(owner)/\(name)"
    static let initialLookback: TimeInterval = 90 * 24 * 3600
    private static let indexSlack: TimeInterval = 5 * 60
    private static let boardRefreshInterval: TimeInterval = 5 * 60
    /// The board is read every few minutes rather than every round; the app's own writes show
    /// at once anyway, so this only delays edits made on the web.
    private static let boardSyncInterval: TimeInterval = 3 * 60
    private static let lastSyncKey = "lastSyncStartedAt"
    private static let viewerKey = "viewer"
    private static let windowLength: TimeInterval = 10 * 24 * 3600
    private static let maxConcurrentFetches = 6

    let client: GitHubClient
    let db: AppDatabase
    private let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "Sync")
    private var isSyncing = false
    private var boardRefreshedAt: Date?
    private var boardSyncedAt: Date?
    /// Ids needed to write to the board, from the latest board sync.
    var boardSchema: BoardQuery.Schema?
    /// When the app last wrote each board item, so a sync that read the board just before
    /// doesn't undo the write locally.
    var boardWrites: [Int: Date] = [:]

    init(client: GitHubClient, db: AppDatabase) {
        self.client = client
        self.db = db
    }

    /// Returns nil if a sync is already running. `includeBoard` reads the board even if it was read
    /// recently (for a sync the user asked for).
    func sync(includeBoard: Bool = false) async throws -> SyncResult? {
        guard !isSyncing else { return nil }
        isSyncing = true
        defer { isSyncing = false }

        let startedAt = Date()
        let viewer = try await viewer()
        let since: Date = if let last = try await db.meta(Self.lastSyncKey).flatMap(Self.parse) {
            last.addingTimeInterval(-Self.indexSlack)
        } else {
            startedAt.addingTimeInterval(-Self.initialLookback)
        }

        // One advanced search for everything tracked; `involves:` covers author, assignee, mentions
        // and commenters, but not review requests or reviews. The parity agent's staging PRs on the
        // fork are a second, small search.
        let queries = [
            "repo:\(Self.repo) (involves:\(viewer) OR review-requested:\(viewer) OR reviewed-by:\(viewer) OR label:rust)",
            "repo:\(Parity.repo) \(Parity.qualifier)",
        ]
        // Search pages are slow (GitHub computes mergeability and CI counts per PR), so long ranges
        // are cut into windows fetched in parallel; a short incremental range uses small pages.
        let windows = Self.windows(from: since, to: startedAt)
        let pageSize = windows.count > 1 ? ItemQuery.fullSyncPageSize : ItemQuery.incrementalPageSize
        let jobs = queries.flatMap { query in windows.map { (query: query, from: $0.from, to: $0.to) } }
        var fetched = try await withThrowingTaskGroup(of: Int.self) { group in
            var pending = jobs.makeIterator()
            var total = 0
            for _ in 0 ..< Self.maxConcurrentFetches {
                guard let job = pending.next() else { break }
                group.addTask { try await self.fetch(query: job.query, from: job.from, to: job.to, pageSize: pageSize) }
            }
            while let count = try await group.next() {
                total += count
                if let job = pending.next() {
                    group.addTask { try await self.fetch(query: job.query, from: job.from, to: job.to, pageSize: pageSize) }
                }
            }
            return total
        }
        if includeBoard || boardSyncedAt.map({ startedAt.timeIntervalSince($0) >= Self.boardSyncInterval }) ?? true {
            fetched += try await refreshBoardItems(syncBoard())
            boardSyncedAt = startedAt
        }

        try await db.setMeta(Self.lastSyncKey, Self.format(startedAt))
        if try await db.meta(AppDatabase.baselineKey) == nil {
            try await db.setMeta(AppDatabase.baselineKey, Self.format(startedAt))
        }
        logger.info("Synced \(fetched) items updated since \(since, privacy: .public)")
        return await SyncResult(viewer: viewer, fetched: fetched, finishedAt: Date(), rateLimit: client.rateLimit)
    }

    func viewer() async throws -> String {
        if let viewer = try await db.meta(Self.viewerKey) { return viewer }
        let response = try await client.query(ItemQuery.viewer, variables: [String: String](), as: ItemQuery.ViewerResponse.self)
        try await db.setMeta(Self.viewerKey, response.viewer.login)
        return response.viewer.login
    }

    /// Fetches one item by number, storing it unless `store` is false.
    func fetchItem(repo: String = SyncEngine.repo, number: Int, store: Bool = true) async throws -> Item {
        let (owner, name) = Self.split(repo)
        let response = try await client.query(
            ItemQuery.byNumber,
            variables: ItemQuery.NumberVariables(owner: owner, name: name, number: number),
            as: ItemQuery.NumberResponse.self
        )
        guard let item = response.repository?.issueOrPullRequest?.item(fetchedAt: Date()) else {
            throw SyncError.notFound(repo: repo, number: number)
        }
        if store { try await db.upsert([item]) }
        return item
    }

    /// Re-fetches the given items by node id, a few small batches at a time.
    func refresh(ids: [String]) async throws -> Int {
        let chunks = stride(from: 0, to: ids.count, by: ItemQuery.pageSize).map { Array(ids[$0 ..< min($0 + ItemQuery.pageSize, ids.count)]) }
        return try await withThrowingTaskGroup(of: Int.self) { group in
            var pending = chunks.makeIterator()
            var total = 0
            for _ in 0 ..< Self.maxConcurrentFetches {
                guard let chunk = pending.next() else { break }
                group.addTask { try await self.refreshChunk(chunk) }
            }
            while let count = try await group.next() {
                total += count
                if let chunk = pending.next() {
                    group.addTask { try await self.refreshChunk(chunk) }
                }
            }
            return total
        }
    }

    private func refreshChunk(_ ids: [String]) async throws -> Int {
        let response = try await client.query(ItemQuery.nodes, variables: ItemQuery.NodesVariables(ids: ids), as: ItemQuery.NodesResponse.self)
        let now = Date()
        let items = response.nodes.compactMap { $0?.item(fetchedAt: now) }
        try await db.upsert(items)
        return items.count
    }

    /// Fetches board items missing locally at once, and refreshes the open ones now and then, since
    /// the searches may not cover them. A failed refresh is retried next round rather than failing
    /// the sync, whose searches have landed by then.
    private func refreshBoardItems(_ contentIDs: [String]) async throws -> Int {
        let known = try await db.itemStates()
        var ids = contentIDs.filter { known[$0] == nil }
        let refreshOpen = boardRefreshedAt.map { Date().timeIntervalSince($0) >= Self.boardRefreshInterval } ?? true
        if refreshOpen {
            ids += contentIDs.filter { known[$0] == .open }
        }
        do {
            let count = try await refresh(ids: ids)
            if refreshOpen { boardRefreshedAt = Date() }
            return count
        } catch {
            logger.error("Board item refresh failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    /// Fetches every item matching `query` updated in `[from, to]`, writing each page as it arrives.
    /// Search caps results at 1000, so larger windows are split in half.
    private func fetch(query: String, from: Date, to: Date?, pageSize: Int) async throws -> Int {
        let range = if let to { "\(Self.format(from))..\(Self.format(to))" } else { ">=\(Self.format(from))" }
        let q = "\(query) updated:\(range)"
        var after: String?
        var count = 0
        repeat {
            let page = try await client.query(
                ItemQuery.search,
                variables: ItemQuery.SearchVariables(q: q, first: pageSize, after: after),
                as: ItemQuery.SearchResponse.self
            ).search
            if after == nil, page.issueCount > ItemQuery.resultCap {
                let end = to ?? Date()
                if end.timeIntervalSince(from) > 3600 {
                    let mid = from.addingTimeInterval(end.timeIntervalSince(from) / 2)
                    logger.info("\(page.issueCount) results for \(q, privacy: .public); splitting")
                    return try await fetch(query: query, from: from, to: mid, pageSize: pageSize)
                        + fetch(query: query, from: mid, to: to, pageSize: pageSize)
                }
            }
            let now = Date()
            let items = page.nodes.compactMap { $0?.item(fetchedAt: now) }
            try await db.upsert(items)
            count += items.count
            after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while after != nil
        return count
    }

    /// Splits `[from, to]` into consecutive windows; the last one is open-ended so nothing
    /// updated during the sync is missed.
    private static func windows(from: Date, to: Date) -> [(from: Date, to: Date?)] {
        var result: [(from: Date, to: Date?)] = []
        var start = from
        while to.timeIntervalSince(start) > windowLength {
            let end = start.addingTimeInterval(windowLength)
            result.append((start, end))
            start = end
        }
        result.append((start, nil))
        return result
    }

    /// `owner/name` as its two parts.
    static func split(_ repo: String) -> (owner: String, name: String) {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts.first ?? repo, parts.count > 1 ? parts[1] : "")
    }

    static func format(_ date: Date) -> String {
        // e.g. 2026-10-22T10:00:00Z, which search accepts in `updated:` ranges.
        date.formatted(.iso8601)
    }

    private static func parse(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}
