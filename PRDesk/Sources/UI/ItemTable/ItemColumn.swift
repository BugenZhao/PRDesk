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

    /// Fits "+8888 −8888" with a little room to spare, so four-digit sizes never truncate; also
    /// the column's minimum, which overrides a narrower width saved from before.
    private static let sizeWidth: CGFloat = {
        let texts = ["+8888", "−8888"].map { ceil($0.size(withAttributes: [.font: CellFont.digits]).width) }
        return texts.reduce(0, +) + 2 * RunsCellView.spacing + 2 * RunsCellView.inset
    }()

    /// The deletions' slot in the Size column: "−888" (the digits are all one width).
    private static let deletionSlot: CGFloat = ceil("−888".size(withAttributes: [.font: CellFont.digits]).width)

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
                // Room for two marks; the tooltip names the rest. At the right edge, as in Author.
                return [avatar, .spring] + (seal + orgBadges.map(\.cellRun)).prefix(2)
            }
            return [avatar, name, .spring] + seal + orgBadges.map(\.cellRun)

        case .link:
            guard let paired = row.paired else { return [] }
            let runs: [CellRun] = [.icon(paired.stateIcon, color: paired.stateColor(isMerging: row.pairedIsMerging)), .text("#\(paired.number)", color: .secondaryLabelColor, font: CellFont.digits)]
            // Link stands in for Author: someone other than the agent or the viewer is worth a face.
            guard let author = Self.outsideAuthor(row, viewer: viewer) else { return runs }
            return runs + [.spring, .avatar(AvatarCache.shared.image(for: author))]

        case .review:
            return reviewRuns(row)

        case .turn:
            // The viewer's move stands out by weight alone; color is left to priority.
            guard let mark = row.turnMark else { return [] }
            return [.text(mark.text, color: mark.isMine ? .labelColor : .tertiaryLabelColor, font: mark.isMine ? CellFont.smallBold : CellFont.small)]

        case .ci:
            return ciRuns(item)

        case .size:
            guard let additions = item.additions, let deletions = item.deletions else { return [] }
            // Deletions right-aligned in a slot as wide as "−888", additions just before them, so
            // the minus signs of sizes up to three digits line up down the list (the iPad's and
            // iPhone's rows do the same). In deeper shades than the green and red of Review and CI.
            let removed = "−\(deletions)"
            let slot = deletions < 1000 ? Self.deletionSlot : ceil(removed.size(withAttributes: [.font: CellFont.digits]).width)
            return [
                .text("+\(additions)", color: .diffAdded, font: CellFont.digits),
                .slot(.text(removed, color: .diffRemoved, font: CellFont.digits), width: slot, trailing: true),
            ]

        case .age:
            return [.text(item.createdAt.compactAge(relativeTo: now), color: .secondaryLabelColor, font: CellFont.digits)]

        case .updated:
            return [.text(item.updatedAt.compactAge(relativeTo: now), color: .secondaryLabelColor, font: CellFont.digits)]
        }
    }

    /// In the Parity tab, whose PR a row's pair is when it is neither the agent's nor the viewer's:
    /// an adopted PR's author, on its row or its staging PR's.
    static func outsideAuthor(_ row: ItemRow, viewer: String?) -> String? {
        [row.item.author, row.paired?.author].compactMap(\.self).first { !Parity.isBot($0) && !sameLogin($0, viewer) }
    }

    /// Marks an upstream PR the parity agent is adopting (or adopted), so in Landed too it stands
    /// apart from the viewer's own.
    static func showsAdoption(_ row: ItemRow) -> Bool {
        row.adoption != nil
    }

    @MainActor private func titleRuns(_ row: ItemRow, now: Date, abbreviatesTags: Bool) -> [CellRun] {
        let item = row.item
        var runs: [CellRun] = [
            .icon(item.stateIcon, color: item.stateColor(isMerging: row.isMerging)),
            titleRun(item.title, bold: row.insight.isUnread, abbreviatesTags: abbreviatesTags),
        ]
        if row.board?.sessionLinks.isEmpty == false {
            runs.append(.symbol("terminal", color: .secondaryLabelColor, pointSize: 10))
        }
        if Self.showsAdoption(row) {
            runs.append(.symbol("link", color: .secondaryLabelColor, pointSize: 10))
        }
        if let note = row.note {
            runs.append(.chip(note.reasonLabel, color: .controlAccentColor))
            // The Inbox has no triage sections, so say where the item stands.
            if let triage = row.triage {
                runs.append(.chip(triage.rawValue, color: .secondaryLabelColor))
            }
        }
        // The latest event, at the cell's end, says why when it is what woke the item.
        let eventIsWake = row.wakeIsLatestEvent && row.insight.summary != nil
        if let reason = row.wakeReason, !eventIsWake {
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
            // The reason's purple, as faint as the gray it takes the place of.
            let wakeColor = NSColor.systemPurple.withAlphaComponent(0.55)
            let age = CellRun.text(at.compactAge(relativeTo: now), color: eventIsWake ? wakeColor : .tertiaryLabelColor, font: CellFont.small)
            if eventIsWake {
                // In the reason's color and in its stead: it goes after the comment, and its age
                // stays whatever the room, as the tag did.
                runs.append(.optional(.text(summary, color: wakeColor, font: CellFont.small, flexible: true, maxWidth: 150), priority: 2, minWidth: 44))
                runs.append(age)
            } else {
                runs.append(.optional(.text(summary, color: .tertiaryLabelColor, font: CellFont.small, flexible: true, maxWidth: 150), priority: 0, minWidth: 44))
                runs.append(.optional(age, priority: 0))
            }
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
        let mark = row.insight.reviewMark.symbol
        return mark.map { [.symbol($0.name, color: $0.tint.nsColor, pointSize: Self.markPointSize)] } ?? []
    }

    /// A dot for the CI state (green passed, red failed, yellow running, gray cancelled), filled
    /// when the PR has the `ready` label and hollow otherwise. Counts are in the tooltip.
    private func ciRuns(_ item: Item) -> [CellRun] {
        guard let tint = item.ciTint else { return [] }
        // Gray here is the system gray, not the label gray of a draft's icon.
        let color: NSColor = tint == .gray ? .systemGray : tint.nsColor
        let isReady = item.isMarkedReady
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

extension StateTint {
    var nsColor: NSColor {
        switch self {
        case .green: .systemGreen
        case .gray: .secondaryLabelColor
        case .yellow: .systemYellow
        case .purple: .systemPurple
        case .red: .systemRed
        }
    }
}

extension Item {
    func stateColor(isMerging: Bool) -> NSColor {
        stateTint(isMerging: isMerging).nsColor
    }

    var stateColor: NSColor { stateTint.nsColor }
}
