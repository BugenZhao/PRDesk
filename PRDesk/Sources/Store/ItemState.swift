import Foundation
import GRDB

/// Local-only state for an item, keyed by its node id. Triage decisions live on the board instead.
struct ItemState: Codable, Hashable, Sendable {
    var itemID: Item.ID
    var pinnedAt: Date?
    /// Last time the item was opened in the detail pane (for Recently viewed).
    var viewedAt: Date?
    /// Activity by others after this is unread. Opening an item or `n` moves it forward.
    var seenAt: Date?
    /// The viewer's subscription when the item went Skipped or Muted, put back when it leaves them.
    var subscriptionBeforeQuiet: String?

    init(itemID: Item.ID) {
        self.itemID = itemID
    }

    var isPinned: Bool { pinnedAt != nil }
}

extension ItemState: FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemState"
}
