import SwiftUI

/// The widths of a row's fixed columns, shared with the titles over them so both line up. They
/// grow with the text size.
struct RowColumns {
    static let spacing: CGFloat = 6
    static let trailingInset: CGFloat = 10

    let density: RowDensity
    let scale: CGFloat

    /// The unread dot, or the stack's rail (two lanes fit).
    var marker: CGFloat { StackRailShape.width + 6 }
    var number: CGFloat { 48 * scale }
    /// The picture, the login and marks of trust.
    var author: CGFloat { 150 * scale }
    var avatar: CGFloat { 18 * scale }
    /// In the Parity tab, the other end of the pair: its icon and number.
    var link: CGFloat { 62 * scale }
    var review: CGFloat { 16 * scale }
    var turn: CGFloat { 42 * scale }
    var ci: CGFloat { 12 * scale }
    /// Fits "+8888" and "−8888".
    var size: CGFloat { 86 * scale }
    var updated: CGFloat { 30 * scale }
    var height: CGFloat { (density.usesTwoLines ? 50 : 36) * scale }
}

/// A row of the list: the Mac's columns, as many as the width has room for (`RowDensity`). One
/// line on an iPad, beside the detail or at full width; on a phone the title gets its own line.
struct ItemRowView: View {
    @Environment(AppModel.self) private var model
    let row: ItemRow
    let density: RowDensity
    let isParity: Bool
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1

    private var item: Item { row.item }
    private var columns: RowColumns { RowColumns(density: density, scale: scale) }

    /// Closed items and drafts recede, as in the Mac list; the unread dot stays.
    private var fade: Double { !item.isOpen ? 0.55 : item.isDraft ? 0.6 : 1 }

    var body: some View {
        let columns = columns
        HStack(spacing: RowColumns.spacing) {
            marker.column(columns.marker)
            Group {
                if density.usesTwoLines {
                    twoLineCells(columns)
                } else {
                    lineCells(columns)
                }
            }
            .opacity(fade)
        }
        .padding(.trailing, RowColumns.trailingInset)
        .frame(minHeight: columns.height)
        .contentShape(Rectangle())
    }

    // MARK: Layouts

    @ViewBuilder
    private func lineCells(_ columns: RowColumns) -> some View {
        if density.showsNumber {
            Text(String(item.number))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondaryText)
                .frame(width: columns.number, alignment: .leading)
        }
        // The Comment and the latest event show only where the whole title fits beside them.
        ViewThatFits(in: .horizontal) {
            if density.showsNotes {
                HStack(spacing: 5) {
                    titleCell(showsEvent: true)
                    comment
                    Spacer(minLength: 8)
                    summary
                }
                HStack(spacing: 5) {
                    titleCell(showsEvent: true)
                    Spacer(minLength: 8)
                    summary
                }
            }
            HStack(spacing: 5) {
                titleCell(showsEvent: false)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isParity {
            link.column(density.showsAuthorName ? columns.author : columns.link, alignment: .leading)
        } else if density.showsAuthorName {
            author.column(columns.author, alignment: .leading)
        } else {
            AvatarView(login: item.author, size: columns.avatar)
        }
        review.column(columns.review)
        turn.column(columns.turn, alignment: .leading)
        ci.column(columns.ci)
        if density.showsSize { size.column(columns.size) }
        time(saysTurn: false).frame(width: columns.updated, alignment: .trailing)
    }

    /// `showsEvent`: the row shows the latest event too, which stands for the wake's tag when
    /// it is what woke the item (`ItemRow.wakeIsLatestEvent`).
    @ViewBuilder
    private func titleCell(showsEvent: Bool) -> some View {
        StateIconView(item: item, size: 15 * scale, isMerging: row.isMerging)
        title
        tags(showsWake: !(showsEvent && row.wakeIsLatestEvent))
    }

    /// The latest event's color: the wake's purple when it is what woke the item, as faint as
    /// the gray it takes the place of.
    private var eventStyle: AnyShapeStyle {
        row.wakeIsLatestEvent ? AnyShapeStyle(Color.purple.opacity(0.55)) : .tertiaryText
    }

    /// The title on the first line with the time, which also says whose turn it is; under it who
    /// and what happened, then the size and the marks, which keep their columns so they line up
    /// down the list.
    private func twoLineCells(_ columns: RowColumns) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                titleCell(showsEvent: secondLineIsEvent)
                if density.showsNotes { comment }
                Spacer(minLength: 0)
                time(saysTurn: true)
            }
            HStack(spacing: 5) {
                if density.showsNumber {
                    Text("#\(String(item.number))").monospacedDigit()
                }
                AvatarView(login: item.author, size: 15 * scale)
                Text(item.author ?? "ghost")
                    .lineLimit(1)
                    .layoutPriority(1)
                BadgeIcons(login: item.author, size: 12 * scale)
                if isParity { link }
                if let text = secondLineNote {
                    Text(text).foregroundStyle(secondLineIsEvent ? eventStyle : .tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                // The size at its own width, ahead of the two marks in their columns: a list
                // beside the detail or on a phone is never wide enough for the one-line rows'
                // Size column. No word for whose turn it is here (the time says it): words of
                // three widths kept the sizes from lining up.
                size.fixedSize().padding(.trailing, 4)
                review.column(columns.review)
                ci.column(columns.ci)
            }
            .font(.caption)
            .foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 6)
    }

    /// Under the title: the latest event, or the board's Comment where the first line has no
    /// room for it.
    private var secondLineNote: String? {
        if !density.showsNotes, let comment = row.comment { return comment }
        // Right after the author's name, what the author did needs no "author" before it.
        guard let summary = row.insight.summaryByAuthor ?? row.insight.summary else { return nil }
        return row.insight.summaryAt.map { "\(summary) \($0.compactAge())" } ?? summary
    }

    /// The second line's note is the latest event, not the Comment in its place.
    private var secondLineIsEvent: Bool {
        (density.showsNotes || row.comment == nil) && row.insight.summary != nil
    }

    // MARK: Cells

    /// The unread dot; on a stack's rail the node is the dot, gray when read (the title's icon
    /// already shows the state), hollow for a draft.
    @ViewBuilder private var marker: some View {
        let isUnread = row.showsUnread
        if let rail = row.rail {
            StackRailView(
                rail: rail, color: isUnread ? .accentColor : .secondaryText,
                hollow: !isUnread && item.isOpen && item.isDraft
            )
            .padding(.leading, 6)
        } else {
            Circle()
                .fill(Color.accentColor)
                .frame(width: StackRailShape.nodeSize, height: StackRailShape.nodeSize)
                .opacity(isUnread ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
        }
    }

    /// The title with its tags dimmed, shortened beside the detail and on a phone, where room is
    /// short.
    private var title: some View {
        Text(itemTitle: item.title, shortenedTags: !density.showsFullTags, codeFont: .footnote.monospaced(), tagStyle: .secondaryText)
            .font(.subheadline)
            .fontWeight(row.insight.isUnread ? .semibold : .regular)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    /// What marks the item beside its title: an agent session, an adoption, why it is in the
    /// Inbox, why a Shelf item woke.
    @ViewBuilder
    private func tags(showsWake: Bool) -> some View {
        if row.board?.sessionLinks.isEmpty == false {
            Image(systemName: "terminal").font(.caption2).foregroundStyle(.secondaryText)
        }
        if row.adoption != nil {
            Image(systemName: "link").font(.caption2).foregroundStyle(.secondaryText)
        }
        if let note = row.note {
            Chip(text: note.reasonLabel, color: .accentColor).fixedSize()
            if let triage = row.triage, density.showsNotes {
                Chip(text: triage.rawValue).fixedSize()
            }
        }
        if showsWake, let reason = row.wakeReason {
            Chip(text: reason, color: .purple).fixedSize()
        }
    }

    /// The board's Comment.
    @ViewBuilder private var comment: some View {
        if let comment = row.comment {
            Image(systemName: "text.bubble").font(.caption2).foregroundStyle(.tertiaryText)
            Text(comment)
                .font(.caption)
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize()
        }
    }

    /// The latest event, at the right edge of the title's column.
    @ViewBuilder private var summary: some View {
        if let summary = row.insight.summary, let at = row.insight.summaryAt {
            Text("\(summary) \(at.compactAge())")
                .font(.caption)
                .foregroundStyle(eventStyle)
                .lineLimit(1)
                .frame(maxWidth: 190, alignment: .trailing)
                .fixedSize()
        }
    }

    private var author: some View {
        let login = item.author
        let badges = login.map(model.affiliations.badges(for:)) ?? []
        let unvouched = model.contribution(for: login)?.isUnvouched(badges: badges) ?? false
        return HStack(spacing: 5) {
            AvatarView(login: login, size: columns.avatar)
            Text(login ?? "ghost")
                .font(.footnote)
                .italic(unvouched)
                .lineLimit(1)
            Spacer(minLength: 0)
            BadgeIcons(login: login, size: 13 * scale)
        }
    }

    /// In the Parity tab, the other end of the pair: the upstream PR promoted from a staging PR,
    /// or the staging PR of an upstream one.
    @ViewBuilder private var link: some View {
        if let paired = row.paired {
            HStack(spacing: 4) {
                StateIconView(item: paired, size: 13 * scale, isMerging: row.pairedIsMerging)
                Text("#\(String(paired.number))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    private var review: some View {
        // Always a view, so its column keeps its room without a mark.
        ZStack {
            if let mark = row.insight.reviewMark.symbol {
                Image(systemName: mark.name)
                    .font(.system(size: 11 * scale, weight: .bold))
                    .foregroundStyle(mark.tint.color)
            }
        }
    }

    @ViewBuilder private var turn: some View {
        if let mark = row.turnMark {
            Text(mark.text)
                .font(.caption)
                .fontWeight(mark.isMine ? .bold : .regular)
                // The label color itself: `.primary` would follow a dimmed container.
                .foregroundStyle(mark.isMine ? Color.primary : Color.tertiaryText)
                .lineLimit(1)
        }
    }

    /// Solid with the `ready` label, hollow without.
    private var ci: some View {
        // Always a view, so its column keeps its room without a dot.
        ZStack {
            if item.kind == .pullRequest, let tint = item.ciTint {
                let color: Color = tint == .gray ? .gray : tint.color
                if item.isMarkedReady {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(color, lineWidth: 1.5)
                }
            }
        }
        .frame(width: 9 * scale, height: 9 * scale)
    }

    @ViewBuilder private var size: some View {
        if let additions = item.additions, let deletions = item.deletions {
            HStack(spacing: 0) {
                Text("+\(additions)").foregroundStyle(Color.diffAdded)
                Spacer(minLength: 5)
                Text("−\(deletions)").foregroundStyle(Color.diffRemoved)
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
        }
    }

    /// The row's one time: when the item was last updated, or how long ago it was opened while
    /// the list is sorted by that (the Mac's Age and Upd columns in the room for one).
    ///
    /// `saysTurn`: in a two-line row it stands for the Turn column too, by its weight alone:
    /// the label color and a little heavier when the move is mine (a review asked of me
    /// included), gray when it is theirs, and fainter once theirs has been quiet for a week.
    private func time(saysTurn: Bool) -> some View {
        let mark = saysTurn ? row.turnMark : nil
        let isMine = mark?.isMine == true
        let showsAge = model.sort.key == .age
        let isQuiet = mark != nil && !isMine && !showsAge && Date().timeIntervalSince(item.updatedAt) >= 7 * 86400
        return Text((showsAge ? item.createdAt : item.updatedAt).compactAge())
            .font(.caption.monospacedDigit().weight(isMine ? .medium : .regular))
            // The label color itself: `.primary` would follow a dimmed container.
            .foregroundStyle(isMine ? AnyShapeStyle(Color.primary) : isQuiet ? .tertiaryText : .secondaryText)
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(2)
            .accessibilityValue(mark.map { $0.isMine ? "Your turn" : "Their turn" } ?? "")
    }
}

private extension View {
    /// A column of a row: its width whether or not the row has anything to put in it. A frame
    /// on a cell that is empty for this row (an issue has no size, no checks, no review) lays
    /// out nothing, and the columns after it would move over.
    func column(_ width: CGFloat, alignment: Alignment = .center) -> some View {
        ZStack { self }.frame(width: width, alignment: alignment)
    }
}
