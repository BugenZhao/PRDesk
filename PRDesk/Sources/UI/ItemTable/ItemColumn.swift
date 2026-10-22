import AppKit

/// Columns of the item table and how each renders a row.
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
        case .author: 150
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

    var sortKey: ItemSort.Key? {
        switch self {
        case .unread: nil
        case .priority: .priority
        case .number: .number
        case .title: .title
        case .author: .author
        case .review: .review
        case .turn: .turn
        case .ci: .ci
        case .size: .size
        case .age: .age
        case .updated: .updated
        }
    }

    @MainActor
    func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = header
        column.width = width
        column.headerCell.alignment = alignment == .trailing ? .right : .left
        if let sortKey {
            column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey.rawValue, ascending: false)
        }
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
    func runs(for row: ItemRow, viewer: String?, badges: (String) -> [Badge], contribution: (String) -> Contribution?, now: Date) -> [CellRun] {
        let item = row.item
        switch self {
        case .unread:
            let unreadNote = row.note.map { !$0.isRead } ?? false
            return row.insight.isUnread || unreadNote ? [.dot(.controlAccentColor)] : []

        case .priority:
            guard let priority = row.priority else { return [] }
            return [.chip(priority.letter, color: priority.color)]

        case .number:
            return [.text(String(item.number), color: .secondaryLabelColor, font: CellFont.digits)]

        case .title:
            return titleRuns(row, now: now)

        case .author:
            let name: CellRun = .text(item.author ?? "ghost", flexible: true)
            let vote: [CellRun] = row.authorVote.map { [.symbol($0.symbol, color: $0.nsColor)] } ?? []
            var mark: [CellRun] = []
            if let contribution = item.author.flatMap(contribution) {
                if contribution.isRegular {
                    mark = [.symbol("checkmark.seal", color: .systemBlue)]
                } else if contribution.isFirstTime {
                    mark = [.chip("1st", color: .secondaryLabelColor)]
                }
            }
            return [name] + vote + mark + (item.author.map(badges) ?? []).map(\.cellRun)

        case .review:
            return reviewRuns(row, viewer: viewer)

        case .turn:
            return switch row.insight.turn {
            case .me: [.text("me", color: .systemOrange, font: CellFont.smallBold)]
            case .them: [.text("them", color: .tertiaryLabelColor, font: CellFont.small)]
            case nil: []
            }

        case .ci:
            return ciRuns(item)

        case .size:
            guard let additions = item.additions, let deletions = item.deletions else { return [] }
            return [
                .text("+\(additions)", color: .systemGreen, font: CellFont.digits),
                .text("−\(deletions)", color: .systemRed, font: CellFont.digits),
            ]

        case .age:
            return [.text(item.createdAt.compactAge(relativeTo: now), color: .secondaryLabelColor, font: CellFont.digits)]

        case .updated:
            return [.text(item.updatedAt.compactAge(relativeTo: now), color: .secondaryLabelColor, font: CellFont.digits)]
        }
    }

    private func titleRuns(_ row: ItemRow, now: Date) -> [CellRun] {
        let item = row.item
        var runs: [CellRun] = [
            .icon(item.stateIcon, color: item.stateColor),
            titleRun(item.title, bold: row.insight.isUnread),
        ]
        if let note = row.note {
            runs.append(.chip(note.reasonLabel, color: .controlAccentColor))
            // The Inbox has no triage sections, so say where the item stands.
            if let triage = row.triage {
                runs.append(.chip(triage.rawValue.lowercased(), color: .secondaryLabelColor))
            }
        }
        if let reason = row.wakeReason {
            runs.append(.chip(reason, color: .systemPurple))
        }
        if let summary = row.insight.summary, let at = row.insight.summaryAt {
            runs.append(.text("\(summary) \(at.compactAge(relativeTo: now))", color: .tertiaryLabelColor, font: CellFont.small, maxWidth: 180))
        }
        if let comment = row.comment {
            runs.append(.symbol("text.bubble", color: .tertiaryLabelColor))
            runs.append(.text(comment, color: .secondaryLabelColor, font: CellFont.small, maxWidth: 320))
        }
        return runs
    }

    /// The title with its leading tags ("[Core] ", "fix(x): ") dimmed.
    private func titleRun(_ title: String, bold: Bool) -> CellRun {
        let (prefix, rest) = TitlePrefix.split(title)
        var parts: [(text: String, color: NSColor)] = []
        if !prefix.isEmpty { parts.append((String(prefix), .secondaryLabelColor)) }
        parts.append((String(rest), .labelColor))
        return .segments(parts, font: bold ? CellFont.regularBold : CellFont.regular, flexible: true)
    }

    private func reviewRuns(_ row: ItemRow, viewer: String?) -> [CellRun] {
        let item = row.item
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
        if item.isOpen, row.insight.isReviewRequestedFromMe {
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

extension Vote {
    var symbol: String {
        switch self {
        case .up: "hand.thumbsup.fill"
        case .down: "hand.thumbsdown.fill"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .up: .systemGreen
        case .down: .systemRed
        }
    }
}

extension Badge {
    @MainActor
    var cellRun: CellRun {
        if let image = AvatarCache.shared.image(for: org.avatarLogin) { .image(image) } else { .chip(org.shortLabel, color: .secondaryLabelColor) }
    }
}

extension Priority {
    var color: NSColor {
        switch self {
        case .high: .systemRed
        case .medium: .systemOrange
        case .low: .secondaryLabelColor
        }
    }

    /// Row background tint, or nil for none.
    var rowTint: NSColor? {
        switch self {
        case .high: .systemOrange.withAlphaComponent(0.16)
        case .medium: .systemYellow.withAlphaComponent(0.16)
        case .low: nil
        }
    }
}

/// The icon for an item's kind and state.
enum StateIcon: Hashable {
    /// A template image in the asset catalog: the PR state glyphs from the Claude app's
    /// anthropicons font.
    case asset(String)
    case symbol(String)
}

extension Item {
    var hasConflicts: Bool { isOpen && mergeable == "CONFLICTING" }

    /// Each PR state has its own glyph; draft wins over conflicts. Issues use SF Symbols.
    var stateIcon: StateIcon {
        switch (kind, state) {
        case (.pullRequest, .open): .asset(isDraft ? "pr-draft" : hasConflicts ? "pr-conflict" : "pr-open")
        case (.pullRequest, .merged): .asset("pr-merged")
        case (.pullRequest, .closed): .asset("pr-closed")
        case (.issue, .open): .symbol("circle.circle")
        case (.issue, _): .symbol("checkmark.circle")
        }
    }

    var stateDescription: String {
        switch (kind, state) {
        case (.pullRequest, .open): isDraft ? "Draft" : hasConflicts ? "Open, merge conflicts" : "Open"
        case (_, .merged): "Merged"
        case (_, .closed): "Closed"
        case (.issue, .open): "Open"
        }
    }

    /// GitHub's state colors: open green, draft gray, merged/completed purple, closed PR red;
    /// an open, ready PR with merge conflicts is yellow.
    var stateColor: NSColor {
        switch (kind, state) {
        case (.pullRequest, .open): isDraft ? .secondaryLabelColor : hasConflicts ? .systemYellow : .systemGreen
        case (.pullRequest, .merged): .systemPurple
        case (.pullRequest, .closed): .systemRed
        case (.issue, .open): .systemGreen
        case (.issue, _): .systemPurple
        }
    }
}
