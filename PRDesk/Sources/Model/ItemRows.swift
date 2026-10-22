import Foundation

/// An item with everything the list needs to show it.
struct ItemRow: Hashable, Sendable {
    var item: Item
    var state: ItemState
    var insight: ItemInsight
    /// The notification that brought the item to the Inbox.
    var note: InboxNote?
}

enum ListSection: String, CaseIterable, Codable, Sendable {
    case recent, pinned, focus, requests, all, inbox

    var title: String {
        switch self {
        case .recent: "Recently viewed"
        case .pinned: "Pinned"
        case .focus: "Focus"
        case .requests: "Review requests"
        case .all: "All tracked"
        case .inbox: "Inbox"
        }
    }

    static let dashboard: [ListSection] = [.recent, .pinned, .focus, .requests, .all]
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
        case .priority: compare(a.state.priority?.rawValue ?? 9, b.state.priority?.rawValue ?? 9, reversed: true)
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
