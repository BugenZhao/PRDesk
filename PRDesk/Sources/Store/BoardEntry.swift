import Foundation
import GRDB

/// The triage decision recorded on the board's Status field (SPEC §3.1).
enum TriageStatus: String, CaseIterable, Codable, Sendable {
    case working = "Working"
    case backlog = "Backlog"
    case skipped = "Skipped"
    case muted = "Muted"
    /// Merger has taken the PR on to merge it. Merger alone sets it (SPEC §3.3); the app only
    /// reads it, and moving the item to another Status takes it out.
    case merging = "Merging"

    /// The Statuses the app sets, in the order it offers them.
    static let settable: [TriageStatus] = [.working, .backlog, .skipped, .muted]

    /// The GitHub subscription that goes with the status; nil leaves it alone. GitHub can't
    /// ignore an issue or PR any more (neither `IGNORED` nor an ignored notification thread takes),
    /// so Muted only unsubscribes, like Skipped; the two differ only in the app.
    var subscription: String? {
        switch self {
        case .working, .backlog, .merging: nil
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

    /// SF Symbol shown for the priority: a minus for low, one or two exclamation marks above it.
    var symbol: String {
        switch self {
        case .high: "exclamationmark.2"
        case .medium: "exclamationmark"
        case .low: "minus"
        }
    }

    /// The same marks in plain text, for menus.
    var marks: String {
        switch self {
        case .high: "!!"
        case .medium: "!"
        case .low: "–"
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
    /// Links to the agent sessions opened for the item, oldest first, separated by spaces: written
    /// by the assistant bot after 👀 or 🔥 (SPEC §3.3), only read here.
    var session: String?
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
        case "Merging": .merging
        default: nil
        }
    }

    /// The Session field's links, oldest first.
    var sessionLinks: [URL] {
        guard !isArchived, let session else { return [] }
        return session.split(whereSeparator: \.isWhitespace).compactMap { URL(string: String($0)) }.filter { $0.scheme != nil }
    }

    var priorityValue: Priority? {
        guard !isArchived else { return nil }
        return priority.flatMap(Priority.init(optionName:))
    }
}

extension BoardEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "boardItem"
}
