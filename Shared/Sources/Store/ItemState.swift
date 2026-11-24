import Foundation
import GRDB

/// Local-only state for an item, keyed by its node id. Triage decisions and pins live on the board
/// instead.
struct ItemState: Codable, Hashable, Sendable {
    var itemID: Item.ID
    /// Last time the item was opened in the detail pane (for Recently viewed).
    var viewedAt: Date?
    /// Activity by others after this is unread. Opening an item or `n` moves it forward;
    /// `n` on a read item moves it back to just before the latest activity by others.
    var seenAt: Date?
    /// A PR's head commit when it was last opened, for "since you last looked" in Commits.
    var seenHeadOid: String?
    /// `n` on a read item: unread until seen after this.
    var markedUnreadAt: Date?
    /// When GitHub last saw the item's notification read, wherever it was read (the web, GitHub's
    /// apps, here); that counts as seeing the item.
    var notificationReadAt: Date?
    /// The viewer's subscription when the item went Shelf or Attic, put back when it leaves them.
    var subscriptionBeforeQuiet: String?
    /// The latest notification (a mention or review request) checked for having subscribed the
    /// viewer to an Attic item again (`SyncEngine.keepMutedQuiet`).
    var quietCheckedAt: Date?
    /// When the item was last sent to a Grok Bot for each request.
    var investigateSentAt: Date?
    var trackSentAt: Date?
    var adoptSentAt: Date?
    var mergeSentAt: Date?
    /// The viewer's note with the last send of each request.
    var investigateNote: String?
    var trackNote: String?
    var adoptNote: String?
    var mergeNote: String?

    init(itemID: Item.ID) {
        self.itemID = itemID
    }

    func sentAt(_ request: BotRequest) -> Date? {
        switch request {
        case .investigate: investigateSentAt
        case .track: trackSentAt
        case .adopt: adoptSentAt
        case .merge: mergeSentAt
        }
    }

    func note(_ request: BotRequest) -> String? {
        switch request {
        case .investigate: investigateNote
        case .track: trackNote
        case .adopt: adoptNote
        case .merge: mergeNote
        }
    }

    mutating func setSent(at date: Date?, note: String?, for request: BotRequest) {
        switch request {
        case .investigate: (investigateSentAt, investigateNote) = (date, note)
        case .track: (trackSentAt, trackNote) = (date, note)
        case .adopt: (adoptSentAt, adoptNote) = (date, note)
        case .merge: (mergeSentAt, mergeNote) = (date, note)
        }
    }
}

extension ItemState: FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemState"
}
