import Foundation
import GRDB

/// The triage decision recorded on the board's Status field (SPEC §3.1).
enum TriageStatus: String, CaseIterable, Codable, Sendable {
    case working = "Working"
    case backlog = "Backlog"
    case skipped = "Skipped"
    case muted = "Muted"

    /// The GitHub subscription that goes with the status; nil leaves it alone. GitHub ignores
    /// `IGNORED` on issues and PRs, so Muted also mutes the notification thread (see `setTriage`).
    var subscription: String? {
        switch self {
        case .working, .backlog: nil
        case .skipped, .muted: "UNSUBSCRIBED"
        }
    }

    /// Statuses that changed the subscription, so leaving them restores it.
    var isQuiet: Bool { subscription != nil }
}

/// The board's Priority field.
enum Priority: Int, Codable, Sendable, CaseIterable, Comparable {
    case high = 1, medium = 2, low = 3

    var letter: String {
        switch self {
        case .high: "H"
        case .medium: "M"
        case .low: "L"
        }
    }

    /// The option name on the board.
    var optionName: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    /// Matches option names by their first letter, so "H" and "High" both work.
    init?(optionName: String) {
        guard let first = optionName.first?.uppercased() else { return nil }
        guard let match = Self.allCases.first(where: { $0.letter == first }) else { return nil }
        self = match
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An item on the triage board, as last synced (or as just written by the app).
struct BoardEntry: Codable, Hashable, Sendable {
    var number: Int
    /// Project item id.
    var itemID: String
    /// Node id of the PR or issue.
    var contentID: String
    /// Status option name as on the board.
    var status: String?
    /// When the Status field was last set.
    var statusAt: Date?
    var priority: String?
    var comment: String?
    var isArchived: Bool

    /// Another tracker shares the board; its items are left alone entirely.
    static let foreignStatuses: Set = ["Python Parity Backlog"]

    var isForeign: Bool { status.map(Self.foreignStatuses.contains) ?? false }

    /// The triage decision, folding legacy options into the current ones. Done and unknown
    /// options are no decision (an open item marked Done was reopened).
    var triage: TriageStatus? {
        guard !isArchived else { return nil }
        return switch status {
        case "Working", "Good", "Pending": .working
        case "Backlog", "Stale": .backlog
        case "Skipped": .skipped
        case "Muted": .muted
        default: nil
        }
    }

    var priorityValue: Priority? {
        guard !isArchived else { return nil }
        return priority.flatMap(Priority.init(optionName:))
    }
}

extension BoardEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "boardItem"
}
