import AppKit

/// Columns of the item table and how each renders a row.
enum ItemColumn: String, CaseIterable {
    case unread, priority, number, title, author, link, review, turn, ci, size, age, updated

    /// Shown in the Parity tab only, where it takes the place of Author (always the agent there).
    static let parityOnly: Set<ItemColumn> = [.link]
    /// Left out of the Parity tab.
    static let notInParity: Set<ItemColumn> = [.author]

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

    var header: String {
        switch self {
        case .unread: ""
        case .priority: "P"
        case .number: "#"
        case .title: "Title"
        case .author: "Author"
        case .link: "Link"
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
        case .author: 168
        case .link: 64
        case .review: 40
        case .turn: 46
        case .ci: 22
        case .size: Self.sizeWidth
        case .age: 34
        case .updated: 34
        }
    }

    /// Fits "+8888 −8888" with just the cell's run spacing between, so four-digit sizes never
    /// truncate; also the column's minimum, which overrides a narrower width saved from before.
    private static let sizeWidth: CGFloat = {
        let texts = ["+8888", "−8888"].map { ceil($0.size(withAttributes: [.font: CellFont.digits]).width) }
        // The spring between the two runs adds a spacing on each side.
        return texts.reduce(0, +) + 2 * RunsCellView.spacing + 2 * RunsCellView.inset
    }()

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
        case .link: nil
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
            column.minWidth = self == .size ? width : min(width, 16)
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
            return [.symbol(priority.symbol, color: priority.color, pointSize: 11)]

        case .number:
            return [.text(String(item.number), color: .secondaryLabelColor, font: CellFont.digits)]

        case .title:
            return titleRuns(row, now: now)

        case .author:
            let vote: [CellRun] = row.authorVote.map { [.symbol($0.symbol, color: $0.nsColor)] } ?? []
            let orgBadges = item.author.map(badges) ?? []
            let contribution = item.author.flatMap(contribution)
            // An org badge already says the author is established.
            let seal: [CellRun] = contribution?.isRegular == true && orgBadges.isEmpty
                ? [.symbol("checkmark.seal", color: .systemGreen)] : []
            // A first-timer nothing vouches for is set in italics, a caution rather than a mark.
            let unvouched = contribution?.isUnvouched(badges: orgBadges) ?? false
            let name: CellRun = .text(item.author ?? "ghost", font: unvouched ? CellFont.regularItalic : CellFont.regular, flexible: true)
            let avatar: CellRun = .avatar(item.author.flatMap(AvatarCache.shared.image(for:)))
            // Marks of trust sit at the right edge, so they line up down the column.
            return [avatar, name] + vote + [.spring] + seal + orgBadges.map(\.cellRun)

        case .link:
            guard let paired = row.paired else { return [] }
            return [.icon(paired.stateIcon, color: paired.stateColor), .text("#\(paired.number)", color: .secondaryLabelColor, font: CellFont.digits)]

        case .review:
            return reviewRuns(row, viewer: viewer)

        case .turn:
            // A pending review request is the most common reason it's the viewer's move; name it.
            // The parity agent requests review on every staging PR, parked ones too.
            if item.isOpen, row.insight.isReviewRequestedFromMe, !item.isParityStaging || row.insight.turn == .me {
                return [.text("review", color: .systemOrange, font: CellFont.smallBold)]
            }
            return switch row.insight.turn {
            case .me: [.text("me", color: .systemOrange, font: CellFont.smallBold)]
            case .them: [.text("them", color: .tertiaryLabelColor, font: CellFont.small)]
            case nil: []
            }

        case .ci:
            return ciRuns(item)

        case .size:
            guard let additions = item.additions, let deletions = item.deletions else { return [] }
            // Additions to the left, deletions to the right, in deeper shades than the green and
            // red of Review and CI.
            return [
                .text("+\(additions)", color: .diffAdded, font: CellFont.digits),
                .spring,
                .text("−\(deletions)", color: .diffRemoved, font: CellFont.digits),
            ]

        case .age:
            return [.text(item.createdAt.compactAge(relativeTo: now), color: .secondaryLabelColor, font: CellFont.digits)]

        case .updated:
            return [.text(item.updatedAt.compactAge(relativeTo: now), color: .secondaryLabelColor, font: CellFont.digits)]
        }
    }

    @MainActor private func titleRuns(_ row: ItemRow, now: Date) -> [CellRun] {
        let item = row.item
        var runs: [CellRun] = [
            .icon(item.stateIcon, color: item.stateColor),
            titleRun(item.title, bold: row.insight.isUnread),
        ]
        if let note = row.note {
            runs.append(.chip(note.reasonLabel, color: .controlAccentColor))
            // The Inbox has no triage sections, so say where the item stands.
            if let triage = row.triage {
                runs.append(.chip(triage.rawValue, color: .secondaryLabelColor))
            }
        }
        if let reason = row.wakeReason {
            runs.append(.chip(reason, color: .systemPurple))
        }
        if let comment = row.comment {
            runs.append(.symbol("text.bubble", color: .tertiaryLabelColor))
            runs.append(.text(comment, color: .secondaryLabelColor, font: CellFont.small, flexible: true, maxWidth: 320))
        }
        // The latest event sits at the right edge, so it lines up down the column.
        if let summary = row.insight.summary, let at = row.insight.summaryAt {
            runs.append(.spring)
            runs.append(.text("\(summary) \(at.compactAge(relativeTo: now))", color: .tertiaryLabelColor, font: CellFont.small, maxWidth: 180))
        }
        return runs
    }

    /// The title with its leading tags ("[Core] ", "fix(x): ") dimmed.
    @MainActor private func titleRun(_ title: String, bold: Bool) -> CellRun {
        let (prefix, rest) = Self.splitTitle(title)
        var parts: [(text: String, color: NSColor)] = []
        if !prefix.isEmpty { parts.append((prefix, .secondaryLabelColor)) }
        parts.append((rest, .labelColor))
        return .segments(parts, font: bold ? CellFont.regularBold : CellFont.regular, flexible: true)
    }

    /// `TitlePrefix.split`, remembered: its regexes are slow next to everything else a row
    /// scrolling in costs.
    @MainActor private static var titleSplits: [String: (prefix: String, rest: String)] = [:]

    @MainActor private static func splitTitle(_ title: String) -> (prefix: String, rest: String) {
        if let split = titleSplits[title] { return split }
        let (prefix, rest) = TitlePrefix.split(title)
        let split = (String(prefix), String(rest))
        if titleSplits.count > 5000 { titleSplits.removeAll() }
        titleSplits[title] = split
        return split
    }

    /// Review and CI share one shape: a small mark, then a count, in the same fixed slots.
    private static let markSlot: CGFloat = 13
    private static let countSlot: CGFloat = 16
    /// One size for the review check and the CI dot, both SF Symbol circles, so they match.
    private static let markPointSize: CGFloat = 10

    /// Approvals as a bare check and a count: green when the viewer approved, gray when only others
    /// did. A red cross after them when the viewer requested changes.
    private func reviewRuns(_ row: ItemRow, viewer: String?) -> [CellRun] {
        let item = row.item
        guard item.kind == .pullRequest else { return [] }
        let mine = viewer.flatMap(item.review(by:))?.state
        let count = item.approvalCount
        let color: NSColor = mine == "APPROVED" ? .systemGreen : .secondaryLabelColor
        let check: CellRun? = count > 0 ? .symbol("checkmark", color: color, pointSize: Self.markPointSize) : nil
        let approvals: CellRun? = count > 0 ? .text(String(count), color: color, font: CellFont.digits) : nil
        var runs: [CellRun] = [.slot(check, width: Self.markSlot), .slot(approvals, width: Self.countSlot)]
        if mine == "CHANGES_REQUESTED" {
            runs.append(.symbol("xmark", color: .systemRed, pointSize: Self.markPointSize))
        }
        return runs
    }

    /// A dot for the CI state (green passed, red failed, yellow running, gray cancelled), filled
    /// when the PR has the `ready` label and hollow otherwise. Counts are in the tooltip.
    private func ciRuns(_ item: Item) -> [CellRun] {
        guard let ci = item.ci else { return [] }
        let color: NSColor = if ci.failed > 0 {
            .systemRed
        } else if ci.pending > 0 || ci.state == "PENDING" || ci.state == "EXPECTED" {
            .systemYellow
        } else if ci.state == "SUCCESS" {
            .systemGreen
        } else {
            // A failed rollup with no failed checks: they were cancelled.
            .systemGray
        }
        let isReady = item.labels.contains { $0.name == "ready" }
        return [.symbol(isReady ? "circle.fill" : "circle", color: color, pointSize: Self.markPointSize)]
    }

    /// E.g. "CI: 2 failed, 1 pending of 14 · ready".
    static func ciTooltip(_ item: Item) -> String? {
        guard let ci = item.ci else { return nil }
        var parts: [String] = []
        if ci.failed > 0 { parts.append("\(ci.failed) failed") }
        if ci.pending > 0 { parts.append("\(ci.pending) pending") }
        var text = if !parts.isEmpty {
            "CI: \(parts.joined(separator: ", ")) of \(ci.total)"
        } else {
            switch ci.state {
            case "SUCCESS": "CI passed"
            case "FAILURE", "ERROR": "CI cancelled"
            default: "CI \(ci.state.lowercased())"
            }
        }
        if item.labels.contains(where: { $0.name == "ready" }) { text += " · ready" }
        return text
    }
}

extension NSColor {
    /// Diff stat colors, a shade deeper than the system green and red (GitHub's diff palette).
    static let diffAdded = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.18, green: 0.63, blue: 0.26, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1)
    }

    static let diffRemoved = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.85, green: 0.21, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.81, green: 0.13, blue: 0.18, alpha: 1)
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
        if let image { .image(image) } else { .tile(org.shortLabel, color: .tertiaryLabelColor) }
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
