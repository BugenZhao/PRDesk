import Foundation
import GRDB

/// A tracked pull request or issue, as last fetched from GitHub.
struct Item: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case pullRequest = "pr"
        case issue
    }

    enum State: String, Codable, Sendable {
        case open, closed, merged
    }

    struct Label: Codable, Hashable, Sendable {
        var name: String
        /// Hex color without the leading `#`.
        var color: String
    }

    struct Review: Codable, Hashable, Sendable {
        var login: String
        /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`.
        var state: String
        var submittedAt: Date?
    }

    struct CIStatus: Codable, Hashable, Sendable {
        /// Rollup state: `SUCCESS`, `FAILURE`, `ERROR`, `PENDING`, `EXPECTED`.
        var state: String
        var total: Int
        var failed: Int
        var pending: Int
    }

    /// GraphQL node id.
    var id: String
    var number: Int
    var kind: Kind
    var title: String
    var url: String
    var state: State
    var isDraft: Bool
    var author: String?
    var authorAvatarURL: String?
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    var additions: Int?
    var deletions: Int?
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`.
    var reviewDecision: String?
    /// `MERGEABLE`, `CONFLICTING`, `UNKNOWN`.
    var mergeable: String?
    var ci: CIStatus?
    var labels: [Label]
    /// Latest opinionated review per reviewer.
    var reviews: [Review]
    /// Pending review requests: user logins, or `team:<slug>`.
    var reviewRequests: [String]
    var assignees: [String]
    var fetchedAt: Date
}

extension Item: FetchableRecord, PersistableRecord {
    static let databaseTableName = "item"

    enum Columns {
        static let number = Column(CodingKeys.number)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

extension Item {
    var isOpen: Bool { state == .open }

    func review(by login: String) -> Review? {
        reviews.first { $0.login.caseInsensitiveCompare(login) == .orderedSame }
    }

    var approvalCount: Int {
        reviews.count { $0.state == "APPROVED" }
    }

    func isReviewRequested(from login: String) -> Bool {
        reviewRequests.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }
}
