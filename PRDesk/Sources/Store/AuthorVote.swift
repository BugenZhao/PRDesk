import Foundation
import GRDB

/// The viewer's opinion of a person. Downvoted authors' items sink to the bottom of Triage.
enum Vote: Int, Codable, Sendable {
    case up = 1
    case down = -1
}

/// A vote on a GitHub user, keyed by lowercased login.
struct AuthorVote: Codable, Hashable, Sendable {
    var login: String
    var vote: Vote
    var votedAt: Date
}

extension AuthorVote: FetchableRecord, PersistableRecord {
    static let databaseTableName = "authorVote"
}

extension AppDatabase {
    /// Sets or (with nil) clears the vote on `login`.
    func setVote(_ vote: Vote?, for login: String) async throws {
        let key = login.lowercased()
        try await writer.write { db in
            if let vote {
                try AuthorVote(login: key, vote: vote, votedAt: Date()).upsert(db)
            } else {
                _ = try AuthorVote.deleteOne(db, key: key)
            }
        }
    }
}
