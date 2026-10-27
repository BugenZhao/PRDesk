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
    /// When the item was last sent to a Grok Bot for each request.
    var investigateSentAt: Date?
    var trackSentAt: Date?
    var mergeSentAt: Date?

    init(itemID: Item.ID) {
        self.itemID = itemID
    }

    var isPinned: Bool { pinnedAt != nil }

    func sentAt(_ request: BotRequest) -> Date? {
        switch request {
        case .investigate: investigateSentAt
        case .track: trackSentAt
        case .merge: mergeSentAt
        }
    }

    mutating func setSentAt(_ date: Date?, for request: BotRequest) {
        switch request {
        case .investigate: investigateSentAt = date
        case .track: trackSentAt = date
        case .merge: mergeSentAt = date
        }
    }

    /// The requests the item was sent with, in `BotRequest` order.
    var sentRequests: [BotRequest] { BotRequest.allCases.filter { sentAt($0) != nil } }
}

extension ItemState: FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemState"
}
