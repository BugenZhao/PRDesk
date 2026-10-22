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

    func items(numbers: [Int]) async throws -> [Item] {
        try await reader.read { db in
            try Item.filter(numbers.contains(Item.Columns.number)).fetchAll(db)
        }
    }
}

// MARK: - Local state

extension AppDatabase {
    /// Loads (or creates) the state for `number`, applies `change`, and saves it.
    func updateState(_ number: Int, _ change: @escaping @Sendable (inout ItemState) -> Void) async throws {
        try await writer.write { db in
            var state = try ItemState.fetchOne(db, key: number) ?? ItemState(number: number)
            change(&state)
            try state.save(db)
        }
    }

    func manualNumbers() async throws -> [Int] {
        try await reader.read { db in
            try Int.fetchAll(db, sql: "SELECT number FROM itemState WHERE manual AND untrackedAt IS NULL")
        }
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
    var states: [Int: ItemState] = [:]
    /// Unread before this moment is ignored, so a first sync doesn't mark everything unread.
    var baseline: Date?
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
                    states: Dictionary(uniqueKeysWithValues: ItemState.fetchAll(db).map { ($0.number, $0) }),
                    baseline: baseline
                )
            }
            .removeDuplicates()
            .values(in: reader)
    }
}
