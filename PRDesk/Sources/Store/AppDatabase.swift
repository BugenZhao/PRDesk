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
        let dir = URL.applicationSupportDirectory.appending(path: "PR Desk", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try AppDatabase(path: dir.appending(path: "db.sqlite").path(percentEncoded: false))
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
        return migrator
    }
}

// MARK: - Writes

extension AppDatabase {
    func upsert(_ items: [Item]) async throws {
        guard !items.isEmpty else { return }
        try await writer.write { db in
            for item in items {
                try item.upsert(db)
            }
        }
    }

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

extension AppDatabase {
    /// All cached items, most recently updated first.
    func observeItems() -> AsyncValueObservation<[Item]> {
        ValueObservation
            .tracking { db in try Item.order(Item.Columns.updatedAt.desc).fetchAll(db) }
            .removeDuplicates()
            .values(in: reader)
    }
}
