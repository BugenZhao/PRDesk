import Foundation
import GRDB

/// Local-only state for an item, keyed by its number.
struct ItemState: Codable, Hashable, Sendable {
    enum Priority: Int, Codable, Sendable, CaseIterable, Comparable {
        case high = 1, medium = 2, low = 3

        var letter: String {
            switch self {
            case .high: "H"
            case .medium: "M"
            case .low: "L"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var number: Int
    var priority: Priority?
    var pinnedAt: Date?
    /// Set by `d`; the item returns to Focus when someone else acts after this.
    var focusDismissedAt: Date?
    /// Last time the item was opened in the detail pane (for Recently viewed).
    var viewedAt: Date?
    /// Activity by others after this is unread. Opening an item or `n` moves it forward.
    var seenAt: Date?
    var untrackedAt: Date?
    /// Added by hand with + Add, rather than found by the tracking searches.
    var manual: Bool

    init(number: Int) {
        self.number = number
        manual = false
    }

    var isPinned: Bool { pinnedAt != nil }
}

extension ItemState: FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemState"
}
