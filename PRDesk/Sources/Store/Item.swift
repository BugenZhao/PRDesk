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

    /// A recent timeline event, kept for Turn, unread state and the title summary.
    struct Event: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case comment, approved, changesRequested, reviewed
            case commit, forcePush, merged, closed, reopened, readyForReview, reviewRequested
            /// `target` was @mentioned; the event has no actor.
            case mentioned
        }

        var kind: Kind
        var actor: String?
        /// By a bot or agent account; such events don't count as people's activity.
        var isAutomated: Bool
        var at: Date
        /// For `reviewRequested`: the requested user; for `mentioned`: the mentioned user.
        var target: String?

        /// Accounts that act for tools rather than people, besides GitHub's `[bot]` logins.
        private static let automationLogins: Set = [
            "mergify", "github-actions", "claude", "copilot-pull-request-reviewer", "dependabot", "vllm-agent",
        ]

        static func isAutomationLogin(_ login: String) -> Bool {
            login.hasSuffix("[bot]") || automationLogins.contains(login.lowercased())
        }

        /// Agents and bots people summon with a mention, as in "@codex review".
        private static let summonedAgents = ["codex", "claude", "gemini-code-assist", "copilot", "cursor", "coderabbitai", "mergify"]

        /// A comment that only drives tooling: "[AUTOMATED] …", or nothing but commands such as
        /// "@codex review", "@claude review" or "/ci run" (one per line, a few lines at most).
        static func isCommand(_ body: String) -> Bool {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[AUTOMATED]") { return true }
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !lines.isEmpty, lines.count <= 3 else { return false }
            return lines.allSatisfy { line in
                let lower = line.lowercased()
                // "/ci run", but not a path like "/path/to/file".
                if lower.wholeMatch(of: /\/[a-z][\w-]*(\s.*)?/) != nil { return true }
                return summonedAgents.contains { lower.hasPrefix("@\($0) ") || lower == "@\($0)" }
            }
        }
    }

    /// GraphQL node id.
    var id: String
    /// `owner/name`; numbers are only unique within a repository.
    var repo: String
    var number: Int
    /// A PR's head branch, which pairs parity staging PRs with the upstream PRs promoted from them.
    var headRef: String?
    /// A PR's base branch: a branch of another PR when stacked on it.
    var baseRef: String? = nil
    /// The GitHub stack a PR is in (numbered within its repository) and its place there, 1 being
    /// the closest to the base branch.
    var stackNumber: Int? = nil
    var stackPosition: Int? = nil
    /// A PR's first commit: PRs that share it may be stacked by commits (a stack from a fork, each
    /// based on the default branch; see `Stacks.commitParents`).
    var firstCommit: String? = nil
    /// A PR's head commit.
    var headCommit: String? = nil
    /// For a PR that shares its first commit with another, its commits (the first 100) as of the
    /// head `commitsHead`, which tell which of them it carries. Fetched apart from the list
    /// (`SyncEngine.fetchStackCommits`), and kept when the list stores the item again.
    var commitOids: [String]? = nil
    var commitsHead: String? = nil
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
    /// Most recent timeline events, oldest first.
    var events: [Event]
    var fetchedAt: Date
}

extension Item: FetchableRecord, PersistableRecord {
    static let databaseTableName = "item"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let number = Column(CodingKeys.number)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

/// Logins are case-insensitive on GitHub.
func sameLogin(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    // Logins are ASCII, so fold case byte by byte: `caseInsensitiveCompare` goes through NSString,
    // which made up much of each list rebuild (the Turn of every item compares logins).
    var lhs = a.utf8.makeIterator()
    var rhs = b.utf8.makeIterator()
    while true {
        switch (lhs.next(), rhs.next()) {
        case (nil, nil):
            return true
        case let (x?, y?):
            if x == y { continue }
            guard x < 0x80, y < 0x80 else { return a.caseInsensitiveCompare(b) == .orderedSame }
            if asciiLowercase(x) != asciiLowercase(y) { return false }
        default:
            return false
        }
    }
}

private func asciiLowercase(_ byte: UInt8) -> UInt8 {
    (0x41 ... 0x5A).contains(byte) ? byte | 0x20 : byte
}

extension Item {
    var isOpen: Bool { state == .open }

    /// In `vllm-project/vllm`, the repository the board and the dashboard are about.
    var isUpstream: Bool { repo.caseInsensitiveCompare(SyncEngine.repo) == .orderedSame }

    /// A staging PR of the parity agent on its fork (SPEC §3.2). The fork also holds Bugen's own PRs
    /// (stacks under an upstream PR, say), which come in through notifications and links: those
    /// are not the agent's and stay out of the Parity tab.
    var isParityStaging: Bool {
        repo.caseInsensitiveCompare(Parity.repo) == .orderedSame && kind == .pullRequest && Parity.isBot(author)
    }

    /// An upstream PR promoted from a staging PR (`bz/rust-parity-*`).
    var isParityUpstream: Bool { isUpstream && kind == .pullRequest && Parity.upstreamSlug(headRef) != nil }

    /// Listed in the Parity tab rather than on the dashboard.
    var isParity: Bool { isParityStaging || isParityUpstream }

    /// Repository and number, which name an item across repositories (as notifications do).
    var repoNumber: String { "\(repo.lowercased())#\(number)" }

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
