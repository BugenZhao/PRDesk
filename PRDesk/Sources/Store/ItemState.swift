import Foundation
import GRDB

/// Local-only state for an item, keyed by its number. Triage decisions live on the board instead.
struct ItemState: Codable, Hashable, Sendable {
    var number: Int
    var pinnedAt: Date?
    /// Last time the item was opened in the detail pane (for Recently viewed).
    var viewedAt: Date?
    /// Activity by others after this is unread. Opening an item or `n` moves it forward.
    var seenAt: Date?
    /// The viewer's subscription when the item went Skipped or Muted, put back when it leaves them.
    var subscriptionBeforeQuiet: String?

    init(number: Int) {
        self.number = number
    }

    var isPinned: Bool { pinnedAt != nil }
}

extension ItemState: FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemState"
}
