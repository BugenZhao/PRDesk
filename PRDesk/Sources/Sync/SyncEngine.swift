import Foundation
import os

struct SyncResult: Sendable {
    var viewer: String
    var fetched: Int
    var finishedAt: Date
    var rateLimit: RateLimit?
}

/// Pulls tracked PRs and issues from GitHub search into the local database.
///
/// The first sync looks back `initialLookback`; later syncs only ask for items
/// updated since the previous sync started (minus some slack for search index lag).
actor SyncEngine {
    static let repo = "vllm-project/vllm"
    static let initialLookback: TimeInterval = 90 * 24 * 3600
    private static let indexSlack: TimeInterval = 5 * 60
    private static let lastSyncKey = "lastSyncStartedAt"
    private static let viewerKey = "viewer"
    private static let windowLength: TimeInterval = 10 * 24 * 3600
    private static let maxConcurrentFetches = 6

    private let client: GraphQLClient
    private let db: AppDatabase
    private let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "Sync")
    private var isSyncing = false

    init(client: GraphQLClient, db: AppDatabase) {
        self.client = client
        self.db = db
    }

    /// Returns nil if a sync is already running.
    func sync() async throws -> SyncResult? {
        guard !isSyncing else { return nil }
        isSyncing = true
        defer { isSyncing = false }

        let startedAt = Date()
        let viewer = try await resolveViewer()
        let since: Date = if let last = try await db.meta(Self.lastSyncKey).flatMap(Self.parse) {
            last.addingTimeInterval(-Self.indexSlack)
        } else {
            startedAt.addingTimeInterval(-Self.initialLookback)
        }

        // `involves:` covers author, assignee, mentions and commenters, but not review requests or reviews.
        let qualifiers = ["involves:\(viewer)", "review-requested:\(viewer)", "reviewed-by:\(viewer)"]
        // Search pages are slow (GitHub computes mergeability and CI counts per PR), so long ranges
        // are cut into windows fetched in parallel.
        let windows = Self.windows(from: since, to: startedAt)
        let jobs = qualifiers.flatMap { qualifier in windows.map { (qualifier, $0.from, $0.to) } }
        let fetched = try await withThrowingTaskGroup(of: Int.self) { group in
            var pending = jobs.makeIterator()
            var total = 0
            for _ in 0 ..< Self.maxConcurrentFetches {
                guard let (qualifier, from, to) = pending.next() else { break }
                group.addTask { try await self.fetch(qualifier: qualifier, from: from, to: to) }
            }
            while let count = try await group.next() {
                total += count
                if let (qualifier, from, to) = pending.next() {
                    group.addTask { try await self.fetch(qualifier: qualifier, from: from, to: to) }
                }
            }
            return total
        }

        try await db.setMeta(Self.lastSyncKey, Self.format(startedAt))
        logger.info("Synced \(fetched) items updated since \(since, privacy: .public)")
        return await SyncResult(viewer: viewer, fetched: fetched, finishedAt: Date(), rateLimit: client.rateLimit)
    }

    private func resolveViewer() async throws -> String {
        if let viewer = try await db.meta(Self.viewerKey) { return viewer }
        let response = try await client.query(SearchQuery.viewerText, variables: [String: String](), as: SearchQuery.ViewerResponse.self)
        try await db.setMeta(Self.viewerKey, response.viewer.login)
        return response.viewer.login
    }

    /// Fetches every item matching `qualifier` updated in `[from, to]`, writing each page as it arrives.
    /// Search caps results at 1000, so larger windows are split in half.
    private func fetch(qualifier: String, from: Date, to: Date?) async throws -> Int {
        let range = if let to { "\(Self.format(from))..\(Self.format(to))" } else { ">=\(Self.format(from))" }
        let q = "repo:\(Self.repo) \(qualifier) updated:\(range)"
        var after: String?
        var count = 0
        repeat {
            let page = try await client.query(SearchQuery.text, variables: SearchQuery.Variables(q: q, after: after), as: SearchQuery.Response.self).search
            if after == nil, page.issueCount > SearchQuery.resultCap {
                let end = to ?? Date()
                if end.timeIntervalSince(from) > 3600 {
                    let mid = from.addingTimeInterval(end.timeIntervalSince(from) / 2)
                    logger.info("\(page.issueCount) results for \(q, privacy: .public); splitting")
                    return try await fetch(qualifier: qualifier, from: from, to: mid)
                        + fetch(qualifier: qualifier, from: mid, to: to)
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

    private static func format(_ date: Date) -> String {
        // e.g. 2026-10-22T10:00:00Z, which search accepts in `updated:` ranges.
        date.formatted(.iso8601)
    }

    private static func parse(_ string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}
