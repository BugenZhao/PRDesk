import Foundation
import GRDB

/// The local SQLite cache.
final class AppDatabase: Sendable {
    let writer: DatabasePool

    var reader: any DatabaseReader { writer }

    init(path: String) throws {
        writer = try DatabasePool(path: path)
        try Self.migrator.migrate(writer)
    }

    /// Opens `~/Library/Application Support/PR Desk/db.sqlite`.
    static func openDefault() throws -> AppDatabase {
        try AppDatabase(path: directory.appending(path: "db.sqlite").path(percentEncoded: false))
    }

    static var directory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "PR Desk", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.primaryKey("id", .text)
                t.column("number", .integer).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("url", .text).notNull()
                t.column("state", .text).notNull()
                t.column("isDraft", .boolean).notNull()
                t.column("author", .text)
                t.column("authorAvatarURL", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
                t.column("closedAt", .datetime)
                t.column("additions", .integer)
                t.column("deletions", .integer)
                t.column("reviewDecision", .text)
                t.column("mergeable", .text)
                t.column("ci", .jsonText)
                t.column("labels", .jsonText).notNull()
                t.column("reviews", .jsonText).notNull()
                t.column("reviewRequests", .jsonText).notNull()
                t.column("assignees", .jsonText).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "item") { t in
                t.add(column: "events", .jsonText).notNull().defaults(to: "[]")
            }
            try db.create(table: "itemState") { t in
                t.primaryKey("number", .integer)
                t.column("priority", .integer)
                t.column("pinnedAt", .datetime)
                t.column("focusDismissedAt", .datetime)
                t.column("viewedAt", .datetime)
                t.column("seenAt", .datetime)
                t.column("untrackedAt", .datetime)
                t.column("manual", .boolean).notNull().defaults(to: false)
            }
            // Events were not fetched before; force the next sync to start over.
            try db.execute(sql: "DELETE FROM meta WHERE key = 'lastSyncStartedAt'")
        }
        migrator.registerMigration("v3") { db in
            try db.create(table: "userInfo") { t in
                t.primaryKey("login", .text)
                t.column("company", .text)
                t.column("orgs", .jsonText).notNull()
                t.column("emailDomains", .jsonText).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "orgOverride") { t in
                t.column("login", .text).notNull()
                t.column("org", .text).notNull()
                t.column("include", .boolean).notNull()
                t.primaryKey(["login", "org"])
            }
        }
        migrator.registerMigration("v4") { db in
            try db.create(table: "detailCache") { t in
                t.primaryKey("number", .integer)
                t.column("json", .blob).notNull()
            }
        }
        migrator.registerMigration("v5") { db in
            // Comment bodies are now checked for "[AUTOMATED]"; refetch events and details.
            try db.execute(sql: "DELETE FROM meta WHERE key = 'lastSyncStartedAt'")
            try db.execute(sql: "DELETE FROM detailCache")
        }
        migrator.registerMigration("v6") { db in
            // Comments are no longer flagged by their text; refetch events and details flagged by v5.
            try db.execute(sql: "DELETE FROM meta WHERE key = 'lastSyncStartedAt'")
            try db.execute(sql: "DELETE FROM detailCache")
        }
        migrator.registerMigration("v7") { db in
            try db.create(table: "authorVote") { t in
                t.primaryKey("login", .text)
                t.column("vote", .integer).notNull()
                t.column("votedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v8") { db in
            // Cached timelines predate hiding "[AUTOMATED]" comments with the bots.
            try db.execute(sql: "DELETE FROM detailCache")
        }
        migrator.registerMigration("v9") { db in
            // Triage moved to the board; local priority, dismissals and untracking are gone.
            try db.alter(table: "itemState") { t in
                t.drop(column: "priority")
                t.drop(column: "focusDismissedAt")
                t.drop(column: "untrackedAt")
                t.drop(column: "manual")
            }
            try db.create(table: "boardItem") { t in
                t.primaryKey("number", .integer)
                t.column("itemID", .text).notNull()
                t.column("contentID", .text).notNull()
                t.column("status", .text)
                t.column("statusAt", .datetime)
                t.column("priority", .text)
                t.column("comment", .text)
                t.column("isArchived", .boolean).notNull()
            }
            // New `label:rust` search and mention events; fetch everything again.
            try db.execute(sql: "DELETE FROM meta WHERE key = 'lastSyncStartedAt'")
        }
        migrator.registerMigration("v10") { db in
            try db.alter(table: "userInfo") { t in
                t.add(column: "mergedCount", .integer)
                t.add(column: "mergedFetchedAt", .datetime)
            }
        }
        migrator.registerMigration("v11") { db in
            // Stored events and timelines renamed `isBot` to `isAutomated`, and more comments now count
            // as automated; fetch items and details again.
            try db.execute(sql: "DELETE FROM item")
            try db.execute(sql: "DELETE FROM detailCache")
            try db.execute(sql: "DELETE FROM meta WHERE key = 'lastSyncStartedAt'")
        }
        migrator.registerMigration("v12") { db in
            // Prefetching compares each cached detail's item time without decoding the JSON; rows from
            // before have none and count as stale.
            try db.alter(table: "detailCache") { t in
                t.add(column: "itemUpdatedAt", .datetime)
            }
        }
        migrator.registerMigration("v13") { db in
            try db.alter(table: "itemState") { t in
                t.add(column: "subscriptionBeforeQuiet", .text)
            }
        }
        migrator.registerMigration("v14") { db in
            // Parity staging PRs live on a fork, so numbers are no longer unique: local state and
            // details are keyed by node id, and items carry their repository (and head branch).
            try db.create(table: "newItemState") { t in
                t.primaryKey("itemID", .text)
                t.column("pinnedAt", .datetime)
                t.column("viewedAt", .datetime)
                t.column("seenAt", .datetime)
                t.column("subscriptionBeforeQuiet", .text)
            }
            try db.execute(sql: """
                INSERT INTO newItemState (itemID, pinnedAt, viewedAt, seenAt, subscriptionBeforeQuiet)
                SELECT item.id, s.pinnedAt, s.viewedAt, s.seenAt, s.subscriptionBeforeQuiet
                FROM itemState s JOIN item ON item.number = s.number
                """)
            try db.drop(table: "itemState")
            try db.rename(table: "newItemState", to: "itemState")

            try db.create(table: "newDetailCache") { t in
                t.primaryKey("itemID", .text)
                t.column("json", .blob).notNull()
                t.column("itemUpdatedAt", .datetime)
            }
            try db.execute(sql: """
                INSERT INTO newDetailCache (itemID, json, itemUpdatedAt)
                SELECT item.id, d.json, d.itemUpdatedAt FROM detailCache d JOIN item ON item.number = d.number
                """)
            try db.drop(table: "detailCache")
            try db.rename(table: "newDetailCache", to: "detailCache")

            try db.create(table: "newItem") { t in
                t.primaryKey("id", .text)
                t.column("repo", .text).notNull()
                t.column("number", .integer).notNull()
                t.column("headRef", .text)
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("url", .text).notNull()
                t.column("state", .text).notNull()
                t.column("isDraft", .boolean).notNull()
                t.column("author", .text)
                t.column("authorAvatarURL", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("closedAt", .datetime)
                t.column("additions", .integer)
                t.column("deletions", .integer)
                t.column("reviewDecision", .text)
                t.column("mergeable", .text)
                t.column("ci", .jsonText)
                t.column("labels", .jsonText).notNull()
                t.column("reviews", .jsonText).notNull()
                t.column("reviewRequests", .jsonText).notNull()
                t.column("assignees", .jsonText).notNull()
                t.column("events", .jsonText).notNull().defaults(to: "[]")
                t.column("fetchedAt", .datetime).notNull()
                t.uniqueKey(["repo", "number"])
            }
            let columns = "id, number, kind, title, url, state, isDraft, author, authorAvatarURL, createdAt, updatedAt, closedAt, additions, deletions, reviewDecision, mergeable, ci, labels, reviews, reviewRequests, assignees, events, fetchedAt"
            try db.execute(sql: "INSERT INTO newItem (repo, \(columns)) SELECT 'vllm-project/vllm', \(columns) FROM item")
            try db.drop(table: "item")
            try db.rename(table: "newItem", to: "item")
            try db.create(index: "item_on_updatedAt", on: "item", columns: ["updatedAt"])
            // Head branches weren't fetched before, and the fork's PRs not at all; start over.
            try db.execute(sql: "DELETE FROM meta WHERE key = 'lastSyncStartedAt'")
        }
        migrator.registerMigration("v15") { db in
            try db.alter(table: "itemState") { t in
                t.add(column: "investigateSentAt", .datetime)
                t.add(column: "trackSentAt", .datetime)
                t.add(column: "mergeSentAt", .datetime)
            }
        }
        migrator.registerMigration("v16") { db in
            try db.alter(table: "boardItem") { t in
                t.add(column: "session", .text)
            }
        }
        migrator.registerMigration("v17") { db in
            try db.alter(table: "itemState") { t in
                t.add(column: "investigateNote", .text)
                t.add(column: "trackNote", .text)
                t.add(column: "mergeNote", .text)
            }
        }
        migrator.registerMigration("v18") { db in
            try db.alter(table: "itemState") { t in
                t.add(column: "yabTabID", .text)
            }
        }
        return migrator
    }
}

// MARK: - Items

extension AppDatabase {
    func upsert(_ items: [Item]) async throws {
        guard !items.isEmpty else { return }
        try await writer.write { db in
            for item in items {
                try item.upsert(db)
            }
        }
    }

    /// States of all cached items by node id.
    func itemStates() async throws -> [String: Item.State] {
        try await reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, state FROM item")
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Item.State)? in
                guard let state = Item.State(rawValue: row["state"]) else { return nil }
                return (row["id"], state)
            })
        }
    }
}

// MARK: - Detail cache

extension AppDatabase {
    // Whole-detail JSON coding is heavy; keep it off the caller's actor (usually main).
    @concurrent
    func cachedDetail(itemID: Item.ID) async throws -> ItemDetail? {
        let data = try await reader.read { db in
            try Data.fetchOne(db, sql: "SELECT json FROM detailCache WHERE itemID = ?", arguments: [itemID])
        }
        return data.flatMap { try? JSONDecoder().decode(ItemDetail.self, from: $0) }
    }

    @concurrent
    func saveDetail(_ detail: ItemDetail) async throws {
        let data = try JSONEncoder().encode(detail)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO detailCache (itemID, json, itemUpdatedAt) VALUES (?, ?, ?)",
                arguments: [detail.id, data, detail.itemUpdatedAt]
            )
        }
    }

    /// When each cached detail's item was last updated, by item id.
    func cachedDetailTimes() async throws -> [Item.ID: Date] {
        try await reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT itemID, itemUpdatedAt FROM detailCache WHERE itemUpdatedAt IS NOT NULL")
            return Dictionary(rows.map { ($0["itemID"], $0["itemUpdatedAt"]) }, uniquingKeysWith: { a, _ in a })
        }
    }
}

// MARK: - Local state

extension AppDatabase {
    func state(_ itemID: Item.ID) async throws -> ItemState? {
        try await reader.read { db in try ItemState.fetchOne(db, key: itemID) }
    }

    /// Loads (or creates) the state for `itemID`, applies `change`, and saves it.
    func updateState(_ itemID: Item.ID, _ change: @escaping @Sendable (inout ItemState) -> Void) async throws {
        try await writer.write { db in
            var state = try ItemState.fetchOne(db, key: itemID) ?? ItemState(itemID: itemID)
            change(&state)
            try state.save(db)
        }
    }

    /// Pins with no tab in Yab yet, and tabs in Yab whose pin is gone.
    func yabPinWork() async throws -> YabPins.Work {
        try await writer.read { db in
            let pinnedAt = Column("pinnedAt")
            let tab = Column("yabTabID")
            let unsynced = try ItemState.filter(pinnedAt != nil && tab == nil).order(pinnedAt).fetchAll(db)
            let items = try Item.fetchAll(db, keys: unsynced.map(\.itemID))
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let unpinned = try ItemState.filter(pinnedAt == nil && tab != nil).fetchAll(db)
            return YabPins.Work(
                add: unsynced.compactMap { state in
                    byID[state.itemID].map { YabPins.Work.Add(item: $0.id, url: $0.url, title: $0.title) }
                },
                close: unpinned.compactMap { state in
                    state.yabTabID.map { YabPins.Work.Close(item: state.itemID, tab: $0) }
                }
            )
        }
    }
}

// MARK: - Board

extension AppDatabase {
    /// Replaces the cached board with `entries`, except for `keeping`: numbers the app has just
    /// written, whose local value is newer than what the sync read. Returns the entries it replaced.
    func replaceBoard(_ entries: [BoardEntry], keeping: Set<Int>) async throws -> [Int: BoardEntry] {
        try await writer.write { db in
            let previous = try Dictionary(uniqueKeysWithValues: BoardEntry.fetchAll(db).map { ($0.number, $0) })
            try BoardEntry.deleteAll(db)
            for var entry in entries where !keeping.contains(entry.number) {
                // Setting the same option again (renewing a skip) may leave GitHub's time alone.
                if let old = previous[entry.number], old.status == entry.status,
                   let at = old.statusAt, at > entry.statusAt ?? .distantPast {
                    entry.statusAt = at
                }
                try entry.insert(db)
            }
            for number in keeping {
                try previous[number]?.insert(db)
            }
            return previous
        }
    }

    func boardEntry(number: Int) async throws -> BoardEntry? {
        try await reader.read { db in try BoardEntry.fetchOne(db, key: number) }
    }

    func saveBoardEntry(_ entry: BoardEntry) async throws {
        try await writer.write { db in try entry.save(db) }
    }
}

// MARK: - Meta

extension AppDatabase {
    func meta(_ key: String) async throws -> String? {
        try await reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    func setMeta(_ key: String, _ value: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }
}

// MARK: - Observation

/// Everything the list needs from the database, observed as one value.
struct Snapshot: Equatable, Sendable {
    var items: [Item] = []
    var states: [Item.ID: ItemState] = [:]
    /// Unread before this moment is ignored, so a first sync doesn't mark everything unread.
    var baseline: Date?
    /// Votes by lowercased login.
    var votes: [String: Vote] = [:]
    /// The triage board, by item number.
    var board: [Int: BoardEntry] = [:]
}

extension AppDatabase {
    static let baselineKey = "unreadBaseline"

    func observeSnapshot() -> AsyncValueObservation<Snapshot> {
        ValueObservation
            .tracking { db in
                let baseline = try String
                    .fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.baselineKey])
                    .flatMap { try? Date($0, strategy: .iso8601) }
                return try Snapshot(
                    items: Item.order(Item.Columns.updatedAt.desc).fetchAll(db),
                    states: Dictionary(uniqueKeysWithValues: ItemState.fetchAll(db).map { ($0.itemID, $0) }),
                    baseline: baseline,
                    votes: Dictionary(uniqueKeysWithValues: AuthorVote.fetchAll(db).map { ($0.login, $0.vote) }),
                    board: Dictionary(uniqueKeysWithValues: BoardEntry.fetchAll(db).map { ($0.number, $0) })
                )
            }
            .removeDuplicates()
            .values(in: reader)
    }
}
