import SwiftUI

/// The native timeline: comment and review cards plus compact event lines.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail
    /// Entries by others after this are highlighted as new.
    let previousSeenAt: Date?

    @AppStorage("showBots") private var showBots = false
    /// Per-card expansion chosen by the user, overriding the default.
    @State private var expanded: [String: Bool] = [:]
    @State private var expandAll: Bool?

    private static let descriptionID = "description"
    /// The newest this many cards start expanded; older ones show a one-line preview.
    private static let expandedTail = 5

    var body: some View {
        let blocks = makeBlocks()
        let cardIDs = blocks.compactMap { if case let .card(entry) = $0 { entry.id } else { nil } }
        let firstNew = blocks.first { isNew($0.lastEntry) }?.id

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    toolbar(cardCount: cardIDs.count)

                    if !detail.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.author != nil {
                        CommentCard(
                            id: Self.descriptionID,
                            login: item.author,
                            verb: "opened",
                            verbColor: .secondary,
                            at: item.createdAt,
                            url: item.url,
                            bodyHTML: detail.bodyHTML.isEmpty ? "<p><em>No description.</em></p>" : detail.bodyHTML,
                            bodyText: detail.bodyText,
                            reviewComments: [],
                            isNew: false,
                            expanded: binding(Self.descriptionID, default: true)
                        )
                        .id(Self.descriptionID)
                    }

                    ForEach(blocks) { block in
                        blockView(block, defaultExpanded: { id in
                            isNew(block.lastEntry) || cardIDs.suffix(Self.expandedTail).contains(id)
                        })
                        .id(block.id)
                    }
                }
                .padding(10)
            }
            .task(id: detail.number) {
                expanded = [:]
                expandAll = nil
                if let firstNew {
                    proxy.scrollTo(firstNew, anchor: .top)
                }
            }
        }
    }

    private func toolbar(cardCount: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("Show bots", isOn: $showBots)
                .toggleStyle(.checkbox)
            Text("\(cardCount) comment\(cardCount == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Expand all") {
                expanded = [:]
                expandAll = true
            }
            Button("Collapse all") {
                expanded = [:]
                expandAll = false
            }
        }
        .font(.caption)
        .controlSize(.small)
        .buttonStyle(.link)
    }

    @ViewBuilder
    private func blockView(_ block: Block, defaultExpanded: (String) -> Bool) -> some View {
        switch block {
        case let .card(entry):
            CommentCard(
                id: entry.id,
                login: entry.actor,
                verb: entry.verb,
                verbColor: entry.verbColor,
                at: entry.at,
                url: entry.url,
                bodyHTML: entry.bodyHTML ?? "",
                bodyText: entry.bodyText ?? "",
                reviewComments: entry.reviewComments,
                isNew: isNew(entry),
                expanded: binding(entry.id, default: defaultExpanded(entry.id))
            )
        case let .event(entry):
            EventRow(entry: entry, isNew: isNew(entry))
        case let .commits(entries):
            CommitsRow(entries: entries, isNew: entries.contains(where: isNew))
        }
    }

    private func binding(_ id: String, default value: Bool) -> Binding<Bool> {
        Binding(
            get: { expanded[id] ?? expandAll ?? value },
            set: { expanded[id] = $0 }
        )
    }

    private func isNew(_ entry: TimelineEntry?) -> Bool {
        guard let entry, let previousSeenAt else { return false }
        return entry.at > previousSeenAt && !sameLogin(entry.actor, model.viewer)
    }

    // MARK: Blocks

    enum Block: Identifiable {
        case card(TimelineEntry)
        case event(TimelineEntry)
        case commits([TimelineEntry])

        var id: String {
            switch self {
            case let .card(entry), let .event(entry): entry.id
            case let .commits(entries): "commits-\(entries[0].id)"
            }
        }

        var lastEntry: TimelineEntry? {
            switch self {
            case let .card(entry), let .event(entry): entry
            case let .commits(entries): entries.last
            }
        }
    }

    /// Groups consecutive commits by the same person, and drops bots unless shown.
    private func makeBlocks() -> [Block] {
        var blocks: [Block] = []
        for entry in detail.entries where showBots || !entry.isBot {
            if entry.kind == .commit {
                if case var .commits(group) = blocks.last, sameLogin(group[0].actor, entry.actor) {
                    group.append(entry)
                    blocks[blocks.count - 1] = .commits(group)
                } else {
                    blocks.append(.commits([entry]))
                }
            } else if entry.isCard {
                blocks.append(.card(entry))
            } else {
                blocks.append(.event(entry))
            }
        }
        return blocks
    }
}

// MARK: - Cards

private struct CommentCard: View {
    let id: String
    let login: String?
    let verb: String
    let verbColor: Color
    let at: Date
    let url: String?
    let bodyHTML: String
    let bodyText: String
    let reviewComments: [ReviewComment]
    let isNew: Bool
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                if !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reviewComments.isEmpty {
                    HTMLBodyView(id: id, html: bodyHTML)
                }
                ForEach(reviewComments) { ReviewCommentView(comment: $0) }
            } else if let preview {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isNew ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isNew ? 1.5 : 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            AvatarView(login: login, size: 18)
            Text(login ?? "ghost").fontWeight(.semibold)
            BadgeIcons(login: login)
            Text(verb).foregroundStyle(verbColor)
            Text("\(at.compactAge()) ago")
                .foregroundStyle(.secondary)
                .help(at.formatted(date: .abbreviated, time: .shortened))
            if isNew {
                Chip(text: "new", color: .accentColor)
            }
            Spacer()
            if let url, let link = URL(string: url) {
                Link(destination: link) { Image(systemName: "arrow.up.right") }
                    .help("Open on GitHub")
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary)
                .frame(width: 12)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private var preview: String? {
        let text = bodyText.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? reviewComments.first.map { "\($0.path): …" }
        return text?.isEmpty == false ? text : nil
    }
}

private struct ReviewCommentView: View {
    let comment: ReviewComment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(comment.line.map { "\(comment.path):\($0)" } ?? comment.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                if comment.outdated { Chip(text: "outdated") }
                Spacer()
                if let url = URL(string: comment.url) {
                    Link(destination: url) { Image(systemName: "arrow.up.right") }
                        .font(.caption)
                }
            }
            DiffHunkView(hunk: comment.diffHunk)
            HTMLBodyView(id: comment.id, html: comment.bodyHTML)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The last few lines of a review comment's diff hunk.
private struct DiffHunkView: View {
    let hunk: String
    private static let lines = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunk.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.lines).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(line.hasPrefix("+") ? Color.green.opacity(0.15) : line.hasPrefix("-") ? Color.red.opacity(0.15) : .clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Events

private struct EventRow: View {
    let entry: TimelineEntry
    let isNew: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.symbol)
                .foregroundStyle(entry.verbColor)
                .frame(width: 16)
            AvatarView(login: entry.actor, size: 14)
            Text(entry.actor ?? "ghost").fontWeight(.medium)
            description
            Text("\(entry.at.compactAge()) ago").foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .overlay(alignment: .leading) {
            if isNew { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
    }

    @ViewBuilder
    private var description: some View {
        switch entry.kind {
        case .labeled, .unlabeled:
            Text(entry.kind == .labeled ? "added" : "removed").foregroundStyle(.secondary)
            LabelChip(name: entry.detail ?? "", hex: entry.color ?? "")
        case .crossReferenced:
            Text("mentioned this in").foregroundStyle(.secondary)
            if let url = entry.url.flatMap(URL.init(string:)) {
                Link(entry.detail ?? "", destination: url)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        default:
            Text(entry.eventText).foregroundStyle(.secondary).truncationMode(.tail)
        }
    }
}

private struct CommitsRow: View {
    let entries: [TimelineEntry]
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                AvatarView(login: entries[0].actor, size: 14)
                Text(entries[0].actor ?? "ghost").fontWeight(.medium)
                Text("pushed \(entries.count) commit\(entries.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Text("\(entries.last!.at.compactAge()) ago").foregroundStyle(.tertiary)
            }
            ForEach(entries.suffix(6)) { entry in
                Text(entry.detail ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 22)
            }
            if entries.count > 6 {
                Text("and \(entries.count - 6) earlier")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .overlay(alignment: .leading) {
            if isNew { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
    }
}

private extension TimelineEntry {
    var verb: String {
        switch kind {
        case .comment: "commented"
        case .approved: "approved"
        case .changesRequested: "requested changes"
        default: "reviewed"
        }
    }

    var verbColor: Color {
        switch kind {
        case .approved, .reopened: .green
        case .changesRequested, .closed: .red
        case .merged: .purple
        default: .secondary
        }
    }

    var symbol: String {
        switch kind {
        case .forcePush: "arrow.triangle.2.circlepath"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .reopened: "arrow.uturn.left.circle"
        case .readyForReview: "eye"
        case .convertToDraft: "pencil.circle"
        case .reviewRequested: "person.badge.plus"
        case .reviewDismissed: "xmark.seal"
        case .labeled, .unlabeled: "tag"
        case .crossReferenced: "link"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .renamed: "pencil"
        case .reviewed, .approved, .changesRequested: "eye.circle"
        case .comment, .commit: "circle"
        }
    }

    var eventText: String {
        switch kind {
        case .forcePush: "force-pushed\(detail.map { " to \($0)" } ?? "")"
        case .merged: "merged this"
        case .closed: "closed this"
        case .reopened: "reopened this"
        case .readyForReview: "marked this ready for review"
        case .convertToDraft: "converted this to draft"
        case .reviewRequested: "requested review from \(detail ?? "someone")"
        case .reviewDismissed: "dismissed a review"
        case .assigned: "assigned \(detail ?? "someone")"
        case .renamed: "changed the title to “\(detail ?? "")”"
        case .reviewed: "reviewed"
        default: ""
        }
    }
}
