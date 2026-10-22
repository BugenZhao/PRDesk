import AppKit

/// Columns of the item table and how each renders an item.
enum ItemColumn: String, CaseIterable {
    case unread, priority, number, title, author, review, turn, ci, size, age, updated

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

    var header: String {
        switch self {
        case .unread: ""
        case .priority: "P"
        case .number: "#"
        case .title: "Title"
        case .author: "Author"
        case .review: "Review"
        case .turn: "Turn"
        case .ci: "CI"
        case .size: "Size"
        case .age: "Age"
        case .updated: "Upd"
        }
    }

    private var width: CGFloat {
        switch self {
        case .unread: 8
        case .priority: 16
        case .number: 42
        case .title: 520
        case .author: 120
        case .review: 64
        case .turn: 40
        case .ci: 54
        case .size: 84
        case .age: 34
        case .updated: 34
        }
    }

    var alignment: RunsCellView.Alignment {
        switch self {
        case .size, .age, .updated: .trailing
        default: .leading
        }
    }

    func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = header
        column.width = width
        column.headerCell.alignment = alignment == .trailing ? .right : .left
        if self == .title {
            // Sized by the table to fill the remaining width; see `Coordinator.fitTitleColumn`.
            column.minWidth = 160
            column.resizingMask = []
        } else {
            column.minWidth = min(width, 16)
            column.resizingMask = .userResizingMask
        }
        return column
    }

    @MainActor
    func runs(for item: Item, viewer: String?, now: Date) -> [CellRun] {
        switch self {
        case .unread, .priority, .turn:
            // Local state and turn tracking arrive in milestone 2.
            []

        case .number:
            [.text(String(item.number), color: .secondaryLabelColor, font: CellFont.digits)]

        case .title:
            titleRuns(item)

        case .author:
            [.text(item.author ?? "ghost", flexible: true)]

        case .review:
            reviewRuns(item, viewer: viewer)

        case .ci:
            ciRuns(item)

        case .size:
            if let additions = item.additions, let deletions = item.deletions {
                [
                    .text("+\(additions)", color: .systemGreen, font: CellFont.digits),
                    .text("−\(deletions)", color: .systemRed, font: CellFont.digits),
                ]
            } else {
                []
            }

        case .age:
            [.text(item.createdAt.compactAge(relativeTo: now), color: .secondaryLabelColor, font: CellFont.digits)]

        case .updated:
            [.text(item.updatedAt.compactAge(relativeTo: now), color: .secondaryLabelColor, font: CellFont.digits)]
        }
    }

    private func titleRuns(_ item: Item) -> [CellRun] {
        var runs: [CellRun] = [.symbol(item.kindSymbol, color: item.stateColor), .text(item.title, flexible: true)]
        if item.isDraft, item.isOpen { runs.append(.chip("draft", color: .secondaryLabelColor)) }
        switch item.state {
        case .merged: runs.append(.chip("merged", color: .systemPurple))
        case .closed: runs.append(.chip("closed", color: .systemRed))
        case .open: if item.mergeable == "CONFLICTING" { runs.append(.chip("conflicts", color: .systemRed)) }
        }
        return runs
    }

    private func reviewRuns(_ item: Item, viewer: String?) -> [CellRun] {
        guard item.kind == .pullRequest else { return [] }
        var runs: [CellRun] = []
        switch viewer.flatMap(item.review(by:))?.state {
        case "APPROVED": runs.append(.text("✓ you", color: .systemGreen, font: CellFont.small))
        case "CHANGES_REQUESTED": runs.append(.text("× you", color: .systemRed, font: CellFont.small))
        default:
            if item.approvalCount > 0 {
                runs.append(.text("✓\(item.approvalCount)", color: .systemGreen, font: CellFont.small))
            }
        }
        if let viewer, item.isOpen, item.isReviewRequested(from: viewer) {
            runs.append(.chip("req", color: .systemOrange))
        }
        return runs
    }

    private func ciRuns(_ item: Item) -> [CellRun] {
        var runs: [CellRun] = []
        if let ci = item.ci {
            if ci.failed > 0 {
                runs += [.dot(.systemRed), .text(String(ci.failed), color: .systemRed, font: CellFont.digits)]
            } else if ci.pending > 0 || ci.state == "PENDING" || ci.state == "EXPECTED" {
                runs.append(.dot(.systemYellow))
            } else if ci.state == "SUCCESS" {
                runs.append(.dot(.systemGreen))
            } else {
                runs.append(.dot(.systemRed))
            }
        }
        if item.labels.contains(where: { $0.name == "ready" }) {
            runs.append(.chip("rdy", color: .systemGreen))
        }
        return runs
    }
}

extension Item {
    var kindSymbol: String {
        switch kind {
        case .pullRequest: "arrow.triangle.pull"
        case .issue: state == .open ? "circle.circle" : "checkmark.circle"
        }
    }

    /// GitHub's state colors: open green, draft gray, merged/completed purple, closed PR red.
    var stateColor: NSColor {
        switch (kind, state) {
        case (.pullRequest, .open): isDraft ? .secondaryLabelColor : .systemGreen
        case (.pullRequest, .merged): .systemPurple
        case (.pullRequest, .closed): .systemRed
        case (.issue, .open): .systemGreen
        case (.issue, _): .systemPurple
        }
    }
}
