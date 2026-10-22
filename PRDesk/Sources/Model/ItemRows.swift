import Foundation

/// An item with everything the list needs to show it.
struct ItemRow: Hashable, Sendable {
    var item: Item
    var state: ItemState
    var insight: ItemInsight
    /// The notification that brought the item to the Inbox.
    var note: InboxNote?
    /// The viewer's vote on the item's author.
    var authorVote: Vote?
    /// The item's entry on the triage board, if it is on it.
    var board: BoardEntry?

    var triage: TriageStatus? { board?.triage }
    var priority: Priority? { board?.priorityValue }
    var comment: String? { board?.isArchived == false ? board?.comment : nil }

    /// Why a Skipped item is back in Triage: someone asked the viewer directly after it was skipped.
    var wakeReason: String? {
        guard triage == .skipped, let ask = insight.directAsk, ask.at > board?.statusAt ?? .distantPast else { return nil }
        return ask.reason
    }

    /// The Status as the list treats it: none for a woken Skipped item, which is back in Triage,
    /// and Working for the viewer's own items without one, which have nothing to triage. The
    /// default is never written to the board.
    var listedTriage: TriageStatus? {
        if wakeReason != nil { return nil }
        return triage ?? (insight.isMine ? .working : nil)
    }
}

enum ListSection: String, CaseIterable, Codable, Sendable {
    case opened, recent, pinned, working, good, triage, backlog, closed, skipped, muted, inbox

    var title: String {
        switch self {
        case .opened: "Opened from links"
        case .recent: "Recently viewed"
        case .pinned: "Pinned"
        case .working: "Working"
        case .good: "Good"
        case .triage: "Triage"
        case .backlog: "Backlog"
        case .closed: "Recently closed"
        case .skipped: "Skipped"
        case .muted: "Muted"
        case .inbox: "Inbox"
        }
    }

    /// What the section holds and how it relates to the board (Status on vllm-project #56).
    var help: String {
        switch self {
        case .opened:
            "Issues and PRs opened from links in the detail pane that aren't on the desk. Kept until you quit; add one (a) or give it a Status to keep it."
        case .recent:
            "The last \(Self.recentLimit) items you opened. Not tied to the board; they also stay in their own section."
        case .pinned:
            "Items you pinned (p). Kept on this Mac, not on the board; they also stay in their own section."
        case .working:
            "Status Working on the board (old Good and Pending count too), except approved PRs, and your own items without a Status. Your own items go first, then those waiting on you. The subscription is left alone."
        case .good:
            "Status Working and approved: waiting to be merged. Your own items go first."
        case .triage:
            "No Status yet: not on the board, on it without a Status, or Done but open again. Also Skipped items someone asked you about since, with the reason. Your own items count as Working instead. Downvoted authors go last."
        case .backlog:
            "Status Backlog: worth caring about, but later. Your own items go first. The subscription is left alone."
        case .closed:
            "Merged or closed in the last \(Int(Self.closedRetention / 86400)) days, whatever the Status. The board's own workflow sets Done."
        case .skipped:
            "Status Skipped: ignored for now. Unsubscribed, so GitHub only notifies on mentions or when you take part. Back in Triage when someone asks you directly; s skips it again."
        case .muted:
            "Status Muted: dropped for good. Never back in Triage, and the Inbox and unread counts leave it out. Unsubscribed like Skipped: GitHub can't ignore an item, so it still notifies on mentions and review requests."
        case .inbox:
            "GitHub notifications for this repository where you take part. Not tied to the board."
        }
    }

    static let defaultCollapsed: Set<ListSection> = [.backlog, .closed, .skipped, .muted]
    /// Closed or merged items stay visible this long after closing.
    static let closedRetention: TimeInterval = 14 * 24 * 3600
    static let recentLimit = 8

    /// The one triage section an item belongs to (besides Recently viewed and Pinned), or nil for
    /// items the app leaves alone.
    static func triageSection(of row: ItemRow) -> ListSection? {
        if row.board?.isForeign == true { return nil }
        guard row.item.isOpen else { return .closed }
        switch row.listedTriage {
        case nil: return .triage
        case .working: return row.item.reviewDecision == "APPROVED" ? .good : .working
        case .backlog: return .backlog
        case .skipped: return .skipped
        case .muted: return .muted
        }
    }
}

/// A row of the table: a section header or an item within a section.
enum TableRow: Hashable {
    case header(ListSection, count: Int, collapsed: Bool)
    case item(ListSection, ItemRow)

    var selectionID: TableSelection? {
        if case let .item(section, row) = self { TableSelection(section: section, itemID: row.item.id) } else { nil }
    }
}

/// The same item can appear in several sections, so a selection names both.
struct TableSelection: Hashable, Codable {
    var section: ListSection
    var itemID: Item.ID
}

/// Column-based ordering of rows within a section.
struct ItemSort: Equatable, Codable {
    enum Key: String, Codable {
        case priority, number, title, author, review, turn, ci, size, age, updated
    }

    var key: Key = .updated
    var ascending = false

    func areInIncreasingOrder(_ a: ItemRow, _ b: ItemRow) -> Bool {
        let result: ComparisonResult = switch key {
        case .priority: compare(a.priority?.rawValue ?? 9, b.priority?.rawValue ?? 9, reversed: true)
        case .number: compare(a.item.number, b.item.number)
        case .title: a.item.title.localizedCaseInsensitiveCompare(b.item.title)
        case .author: (a.item.author ?? "").localizedCaseInsensitiveCompare(b.item.author ?? "")
        case .review: compare(a.item.approvalCount, b.item.approvalCount)
        case .turn: compare(a.insight.turn == .me ? 1 : 0, b.insight.turn == .me ? 1 : 0)
        case .ci: compare(a.item.ci?.failed ?? -1, b.item.ci?.failed ?? -1)
        case .size: compare((a.item.additions ?? 0) + (a.item.deletions ?? 0), (b.item.additions ?? 0) + (b.item.deletions ?? 0))
        case .age: compare(a.item.createdAt, b.item.createdAt)
        case .updated: compare(a.item.updatedAt, b.item.updatedAt)
        }
        if result == .orderedSame { return a.item.number > b.item.number }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    /// For priority, "larger" means more important, so descending puts H first.
    private func compare<T: Comparable>(_ a: T, _ b: T, reversed: Bool = false) -> ComparisonResult {
        if a == b { return .orderedSame }
        return (a < b) != reversed ? .orderedAscending : .orderedDescending
    }
}
