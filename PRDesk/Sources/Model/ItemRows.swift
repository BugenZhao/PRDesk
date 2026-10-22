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
}

enum ListSection: String, CaseIterable, Codable, Sendable {
    case recent, pinned, working, good, triage, backlog, closed, skipped, muted, inbox

    var title: String {
        switch self {
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

    static let defaultCollapsed: Set<ListSection> = [.backlog, .closed, .skipped, .muted]

    /// The one triage section an item belongs to (besides Recently viewed and Pinned), or nil for
    /// items the app leaves alone.
    static func triageSection(of row: ItemRow) -> ListSection? {
        if row.board?.isForeign == true { return nil }
        guard row.item.isOpen else { return .closed }
        switch row.triage {
        case nil: return .triage
        case .working: return row.item.reviewDecision == "APPROVED" ? .good : .working
        case .backlog: return .backlog
        case .skipped: return row.wakeReason == nil ? .skipped : .triage
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
struct TableSelection: Hashable {
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
