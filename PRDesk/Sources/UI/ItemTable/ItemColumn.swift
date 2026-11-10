import AppKit

/// Columns of the item table and how each renders a row.
enum ItemColumn: String, CaseIterable {
    case stack, number, title, author, avatar, link, review, turn, ci, size, age, updated

    /// Shown in the Parity tab only, where it takes the place of Author (always the agent there).
    static let parityOnly: Set<ItemColumn> = [.link]
    /// Left out of the Parity tab.
    static let notInParity: Set<ItemColumn> = [.author, .avatar]
    /// Hidden one by one, in this order, while the title column would be narrower than
    /// `titleRoom`: the columns looked at least. Author gives way to `avatar`, its picture and
    /// marks without the name.
    static let givesWay: [ItemColumn] = [.turn, .ci, .author, .size, .age]
    static let titleRoom: CGFloat = 360

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

    var header: String {
        switch self {
        case .stack: ""
        case .number: "#"
        case .title: "Title"
        case .author: "Author"
        case .avatar: "Author"
        case .link: "Link"
        case .review: "✓"
        case .turn: "Turn"
        case .ci: "CI"
        case .size: "Size"
        case .age: "Age"
        case .updated: "Upd"
        }
    }

    /// The width a column starts with, and goes back to on Reset Columns.
    var width: CGFloat {
        switch self {
        case .stack: StackRailShape.width + 2 * RunsCellView.inset
        case .number: 42
        case .title: 520
        // Room for the picture, two marks and an 80-point login (three in four open items' authors);
        // with no marks, 115 points (nearly all). Longer logins truncate, whole in the tooltip.
        case .author: 140
        // The picture and up to two marks (see `runs`), with the spring between: its spacing
        // counts on both sides, or two marks overflow and one sits short of the edge.
        case .avatar: 3 * 13 + 3 * RunsCellView.spacing + 2 * RunsCellView.inset
        case .link: 64
        // One mark, no counts (the tooltip has the reviewers).
        case .review: Self.markSlot + 2 * RunsCellView.inset
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
        case .stack: nil
        case .number: .number
        case .title: .title
        case .author, .avatar: .author
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
        } else if self == .avatar || self == .review || self == .stack {
            // Fixed: a wider width saved before can't leave them with empty room.
            column.minWidth = width
            column.maxWidth = width
            column.resizingMask = []
        } else {
            column.minWidth = self == .size ? width : min(width, 16)
            column.resizingMask = .userResizingMask
        }
        return column
    }

    @MainActor
    /// `abbreviatesTags` shortens the title's tags ("[RF][Fix] "); the table turns it on for all
    /// rows at once.
    func runs(for row: ItemRow, viewer: String?, badges: (String) -> [Badge], contribution: (String) -> Contribution?, now: Date, abbreviatesTags: Bool = false) -> [CellRun] {
        let item = row.item
        switch self {
        case .stack:
            // The unread dot; on a stack's rail the node is the dot, gray when read (the title's
            // icon already shows the state), hollow for a draft.
            let unreadNote = row.note.map { !$0.isRead } ?? false
            let isUnread = row.insight.isUnread || unreadNote
            guard let rail = row.rail else { return isUnread ? [.dot(.controlAccentColor)] : [] }
            return [.rail(rail, node: isUnread ? .controlAccentColor : .secondaryLabelColor, hollow: !isUnread && item.isOpen && item.isDraft)]

        case .number:
            return [.text(String(item.number), color: .secondaryLabelColor, font: CellFont.digits)]

        case .title:
            return titleRuns(row, now: now, abbreviatesTags: abbreviatesTags)

        case .author, .avatar:
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
            if self == .avatar {
                // Room for two marks, the vote first; the tooltip names the rest. At the right edge,
                // as in Author.
                return [avatar, .spring] + (vote + seal + orgBadges.map(\.cellRun)).prefix(2)
            }
            return [avatar, name] + vote + [.spring] + seal + orgBadges.map(\.cellRun)

        case .link:
            guard let paired = row.paired else { return [] }
            return [.icon(paired.stateIcon, color: paired.stateColor), .text("#\(paired.number)", color: .secondaryLabelColor, font: CellFont.digits)]

        case .review:
            return reviewRuns(row)

        case .turn:
            // The viewer's move stands out by weight alone; color is left to priority.
            // A pending review request is the most common reason it's the viewer's move; name it.
            // The parity agent requests review on every staging PR, parked ones too.
            if item.isOpen, row.insight.isReviewRequestedFromMe, !item.isParityStaging || row.insight.turn == .me {
                return [.text("review", color: .labelColor, font: CellFont.smallBold)]
            }
            return switch row.insight.turn {
            case .me: [.text("me", color: .labelColor, font: CellFont.smallBold)]
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

    @MainActor private func titleRuns(_ row: ItemRow, now: Date, abbreviatesTags: Bool) -> [CellRun] {
        let item = row.item
        var runs: [CellRun] = [
            .icon(item.stateIcon, color: item.stateColor),
            titleRun(item.title, bold: row.insight.isUnread, abbreviatesTags: abbreviatesTags),
        ]
        // What the item was sent to a Grok Bot for; faint while the send is under way.
        for request in row.state.sentRequests {
            let mark: CellRun = .text(request.emoji, font: CellFont.small)
            runs.append(row.sending.contains(request) ? .faded(mark, opacity: 0.35) : mark)
        }
        if row.board?.sessionLinks.isEmpty == false {
            runs.append(.symbol("terminal", color: .secondaryLabelColor, pointSize: 10))
        }
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
        // The board comment and the latest event make room for the title: they shrink, then go,
        // the event first.
        if let comment = row.comment {
            runs.append(.optional(.symbol("text.bubble", color: .tertiaryLabelColor), priority: 1))
            runs.append(.optional(.text(comment, color: .secondaryLabelColor, font: CellFont.small, flexible: true, maxWidth: 320), priority: 1, minWidth: 40))
        }
        // The latest event sits at the right edge, so it lines up down the column. Its age stays
        // whole while the words before it shrink.
        if let summary = row.insight.summary, let at = row.insight.summaryAt {
            runs.append(.spring)
            runs.append(.optional(.text(summary, color: .tertiaryLabelColor, font: CellFont.small, flexible: true, maxWidth: 150), priority: 0, minWidth: 44))
            runs.append(.optional(.text(at.compactAge(relativeTo: now), color: .tertiaryLabelColor, font: CellFont.small), priority: 0))
        }
        return runs
    }

    /// The title with its leading tags ("[Core] ", "fix(x): ") dimmed, shortened ("[RF][Fix] ")
    /// when `abbreviatesTags`, and its inline code monospaced.
    @MainActor private func titleRun(_ title: String, bold: Bool, abbreviatesTags: Bool) -> CellRun {
        let parsed = Self.parsedTitle(title)
        let font = bold ? CellFont.regularBold : CellFont.regular
        let segments: [TextSegment] = if abbreviatesTags, let short = parsed.shortPrefix {
            [TextSegment(text: short, color: .secondaryLabelColor, font: nil)] + parsed.pieces.filter { !$0.isPrefix }.map { segment($0, bold: bold) }
        } else {
            parsed.pieces.map { segment($0, bold: bold) }
        }
        return .segments(segments, font: font, flexible: true)
    }

    private func segment(_ piece: TitlePiece, bold: Bool) -> TextSegment {
        TextSegment(
            text: piece.text,
            color: piece.isPrefix ? .secondaryLabelColor : .labelColor,
            font: piece.isCode ? (bold ? CellFont.codeBold : CellFont.code) : nil
        )
    }

    /// `TitleMarkup.pieces` and the shortened prefix, remembered: the prefix regexes are slow next
    /// to everything else a row scrolling in costs.
    @MainActor private static var titleSplits: [String: (pieces: [TitlePiece], shortPrefix: String?)] = [:]

    /// The title as drawn with its tags shortened, when shortening changes it.
    @MainActor static func shortenedTitle(_ title: String) -> String? {
        let parsed = parsedTitle(title)
        guard let short = parsed.shortPrefix else { return nil }
        return short + parsed.pieces.filter { !$0.isPrefix }.map(\.text).joined()
    }

    @MainActor private static func parsedTitle(_ title: String) -> (pieces: [TitlePiece], shortPrefix: String?) {
        if let parsed = titleSplits[title] { return parsed }
        let parsed = (TitleMarkup.pieces(title), TitlePrefix.abbreviate(TitlePrefix.split(title).prefix))
        if titleSplits.count > 5000 { titleSplits.removeAll() }
        titleSplits[title] = parsed
        return parsed
    }

    /// A review mark's width.
    private static let markSlot: CGFloat = 13
    /// One size for the review check and the CI dot, so they match.
    private static let markPointSize: CGFloat = 10

    /// `ReviewMark`: crosses for change requests, checks for approvals; colored when it concerns
    /// the viewer, gray when only others think so.
    private func reviewRuns(_ row: ItemRow) -> [CellRun] {
        let mark: (symbol: String, color: NSColor)? = switch row.insight.reviewMark {
        case .none: nil
        case .approvedByOthers: ("checkmark", .secondaryLabelColor)
        case .approved: ("checkmark", .systemGreen)
        case .changesRequestedByOthers: ("xmark", .secondaryLabelColor)
        case .changesRequested: ("xmark", .systemRed)
        }
        return mark.map { [.symbol($0.symbol, color: $0.color, pointSize: Self.markPointSize)] } ?? []
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

    /// E.g. "Approved by alice, bob" and "Changes requested by carol", one per line.
    static func reviewTooltip(_ item: Item) -> String? {
        let lines = [("APPROVED", "Approved by"), ("CHANGES_REQUESTED", "Changes requested by")].compactMap { state, label in
            let logins = item.reviews.filter { $0.state == state }.map(\.login)
            return logins.isEmpty ? nil : "\(label) \(logins.joined(separator: ", "))"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
    /// A template image in the asset catalog: the PR state glyphs (GitHub Octicons).
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
