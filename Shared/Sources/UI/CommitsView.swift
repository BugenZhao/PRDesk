import SwiftUI

/// A PR's changes: everything (with GitHub's Viewed boxes), since the viewer's last review, since
/// they last looked, one commit, a stretch of commits, or a force push, picked from the commits
/// listed above the diff (folded away unless asked for).
struct CommitsView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail
    let page: WebDocument

    /// Selected rows; empty means the preset.
    @State private var selection: Set<String> = []
    /// The chosen preset; nil for the default.
    @State private var preset: CommitHistory.Preset?
    @State private var loaded: Loaded?
    @State private var error: String?
    /// Merges whose diff the user asked for anyway.
    @State private var shownMerges: Set<String> = []
    /// The commit list's width, for whether titles' tags are shortened.
    @State private var listWidth: CGFloat = 0
    @AppStorage("wrapDiffLines") private var wrapLines = true
    /// Whether the commits are listed over the diff; folded, the bar alone says what it shows.
    @AppStorage("showsCommitList") private var showsList = false

    private struct Loaded {
        var range: CommitRange
        var files: [PullFile]
        var payload: String
    }

    /// Small diffs (a commit or two) start with their files expanded.
    private static let expandedLimit = (files: 10, lines: 600)

    private var history: CommitHistory {
        CommitHistory(
            detail: detail, viewer: model.viewer,
            previousHead: model.selectedItemPreviousSeenHead, previousSeenAt: model.selectedItemPreviousSeenAt
        )
    }

    var body: some View {
        let history = history
        let range = range(in: history)
        let merge = skippedMerge(history, range: range)
        Group {
            if detail.commits?.contains(where: { $0.parentCount == nil }) != false {
                // Cached before details had commits, or merges told apart: fetch it again.
                DelayedProgressView()
                    .task { model.loadDetail(force: true) }
            } else if history.commits.isEmpty {
                ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                Group {
                    if let merge {
                        mergeNote(merge)
                    } else {
                        diff(range)
                    }
                }
                .pageBar {
                    // The bar on top, so the chevron stays where it was when the list opens.
                    toolbar(history, range: range)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    if showsList {
                        Divider()
                        list(history)
                            .frame(height: min(CGFloat(listRowCount(history)) * RowMetrics.commitRowHeight + 10, 200))
                    }
                }
            }
        }
        .task(id: [range.key, merge?.oid]) {
            if merge == nil { await load(range) }
        }
        // The marks come on their own, so the diff doesn't wait for them; again after each push.
        .task(id: "\(item.id)-\(item.updatedAt.timeIntervalSince1970)") { await model.loadViewedFiles(for: item) }
        .onChange(of: wrapLines, initial: true) { page.setting("wrap", "PRDesk.setWrap(\(wrapLines))") }
        .onChange(of: model.viewedFiles[item.id], initial: true) { sendViewed() }
        .onChange(of: item.id, initial: true) {
            page.setFileViewed = { [model, itemID = item.id] path, viewed in model.setFileViewed(viewed, path: path, in: itemID) }
        }
        .onChange(of: model.linkedCommit, initial: true) { selectLinkedCommit(history) }
    }

    /// The page's key for the whole PR's diff, the one the Viewed boxes go on: GitHub keeps them
    /// for the PR's files as a whole, which a commit's or a stretch's diff isn't.
    private var allKey: String { "\(item.id)#\(CommitRange.all.key)" }

    /// The item's Viewed marks, for the page to show on the files' headers of the whole diff.
    private func sendViewed() {
        let states = model.viewedFiles[item.id]?.mapValues(\.rawValue)
        let key = WebDocument.jsonLiteral(allKey) ?? "null"
        let json = states.flatMap { WebDocument.jsonLiteral($0) } ?? "null"
        page.setting("viewed", "PRDesk.setViewedFiles(\(key), \(json))")
    }

    /// A merge selected alone, whose diff (everything it brought in, often thousands of files)
    /// isn't loaded unless asked for.
    private func skippedMerge(_ history: CommitHistory, range: CommitRange) -> PRCommit? {
        guard case let .commit(sha) = range, let commit = history.commit(matching: sha),
              commit.isMerge, !shownMerges.contains(commit.oid) else { return nil }
        return commit
    }

    private func mergeNote(_ commit: PRCommit) -> some View {
        ContentUnavailableView {
            Label("Merge Commit", systemImage: "arrow.triangle.merge")
        } description: {
            Text("It brings in another branch, usually the base, so its diff can run to thousands of files. It isn't loaded.")
        } actions: {
            Button("Show Diff Anyway") { shownMerges.insert(commit.oid) }
            Button("Open on GitHub") {
                if let url = URL(string: "\(item.url)/commits/\(commit.oid)") { Platform.open(url) }
            }
        }
    }

    private func range(in history: CommitHistory) -> CommitRange {
        if !selection.isEmpty, let range = history.range(selecting: selection) { return range }
        return history.range(preset ?? .all) ?? .all
    }

    /// A link to one of the PR's commits selects it; one to its changes as a whole goes back to
    /// everything.
    private func selectLinkedCommit(_ history: CommitHistory) {
        guard let link = model.linkedCommit, link.key == item.repoNumber else { return }
        guard let sha = link.commit else {
            selection = []
            preset = nil
            return
        }
        guard let commit = history.commit(matching: sha) else { return }
        selection = [commit.oid]
    }

    // MARK: List

    private func list(_ history: CommitHistory) -> some View {
        #if os(macOS)
            List(selection: $selection) {
                ForEach(history.rows) { row in
                    rowView(row)
                        .selectionDisabled(!isSelectable(row))
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 22)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        #else
            // No selection without edit mode here: a tap picks one commit (again to go back to the
            // preset), and its menu extends the selection to it or picks a force push folded
            // into it. The menu shows the commit's whole message above it, what the pointer's
            // tooltip shows on the Mac.
            List {
                ForEach(history.compactRows) { row in
                    compactRowView(row)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let commit = row.commit else { return }
                            selection = selection == [commit.oid] ? [] : [commit.oid]
                        }
                        .listRowBackground(rowBackground(row))
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, RowMetrics.commitRowHeight)
            // The pager lets its pages draw past their edges, which would reach this list too:
            // its rows, scrolled, drew over the bar above it.
            .scrollClipDisabled(false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        #endif
    }

    private func listRowCount(_ history: CommitHistory) -> Int {
        #if os(macOS)
            history.rows.count
        #else
            history.compactRows.count
        #endif
    }

    #if os(macOS)
        @ViewBuilder
        private func rowView(_ row: CommitHistory.Row) -> some View {
            switch row {
            case let .commit(commit, isNew):
                CommitRow(commit: commit, isNew: isNew, shortensTags: shortensTags, pullURL: item.url)
            case let .push(push):
                PushRow(push: push)
            }
        }
    #endif

    #if os(iOS)
        @ViewBuilder
        private func compactRowView(_ row: CommitHistory.CompactRow) -> some View {
            let selectPush: (CommitHistory.Push) -> Void = { selection = [CommitHistory.Row.pushPrefix + $0.id] }
            if let commit = row.commit {
                let canExtend = !selection.isEmpty && !selection.contains(commit.oid)
                    && !selection.contains { $0.hasPrefix(CommitHistory.Row.pushPrefix) }
                CommitRow(
                    commit: commit, isNew: row.isNew, shortensTags: shortensTags, pullURL: item.url,
                    pushes: row.pushes, selectPush: selectPush,
                    extend: canExtend ? { selection.insert(commit.oid) } : nil
                )
            } else {
                EarlierPushesRow(pushes: row.pushes, select: selectPush)
            }
        }

        /// A chosen commit in the accent's tint; a row holding the chosen force push in orange.
        private func rowBackground(_ row: CommitHistory.CompactRow) -> Color {
            if let commit = row.commit, selection.contains(commit.oid) { return Color.accentColor.opacity(0.18) }
            if row.pushes.contains(where: { selection.contains(CommitHistory.Row.pushPrefix + $0.id) }) {
                return Color.orange.opacity(0.15)
            }
            return .clear
        }
    #endif

    /// A force push whose ends aren't known has nothing to compare.
    private func isSelectable(_ row: CommitHistory.Row) -> Bool {
        if case let .push(push) = row { return push.before != nil && push.after != nil }
        return true
    }

    /// Whether every headline's tags are shortened: when any row's wouldn't fit with them in full,
    /// as the stack does, so a tag reads the same in every row.
    private var shortensTags: Bool {
        guard listWidth > 0 else { return false }
        let body = PlatformFont.preferredFont(forTextStyle: CommitRow.textStyle)
        let mono = PlatformFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        let caption = PlatformFont.preferredFont(forTextStyle: CommitRow.badgeStyle)
        let digits = PlatformFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
        func measure(_ text: String, _ font: PlatformFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        func needed(_ commit: PRCommit, isNew: Bool, pushes: Int) -> CGFloat {
            // The row's insets, then CI dot, avatar, sha, headline, "new", pushes and age with
            // their gaps.
            var needed = 2 * 12 + 7 + 6 + 16 + 6 + measure(commit.shortOid, mono) + 6
                + measure(commit.headline, body) + 4 + measure(commit.committedAt.compactAge(), digits)
            if isNew { needed += measure("new", caption) + 10 + 6 }
            if pushes > 0 { needed += measure(pushes > 1 ? "\(pushes)" : "", caption) + body.pointSize + 6 }
            return needed
        }
        #if os(macOS)
            return history.rows.contains { row in
                guard case let .commit(commit, isNew) = row else { return false }
                return needed(commit, isNew: isNew, pushes: 0) > listWidth
            }
        #else
            return history.compactRows.contains { row in
                guard let commit = row.commit else { return false }
                return needed(commit, isNew: row.isNew, pushes: row.pushes.count) > listWidth
            }
        #endif
    }

    // MARK: Toolbar

    private func toolbar(_ history: CommitHistory, range: CommitRange) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsList.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showsList ? 90 : 0))
                    Text("\(history.commits.count) commit\(history.commits.count == 1 ? "" : "s")")
                        .fixedSize()
                }
                .foregroundStyle(.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsList ? "Hide the commits" : "Show the commits")
            Menu {
                ForEach(CommitHistory.Preset.allCases, id: \.self) { option in
                    Button(option.title) {
                        selection = []
                        preset = option
                    }
                    .disabled(history.range(option) == nil)
                }
            } label: {
                Text(title(history, range: range))
            }
            #if os(macOS)
                .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            if history.isRewritten(range) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Force-pushed since: a rebase onto the base branch shows up here too")
            }
            if skippedMerge(history, range: range) == nil, let loaded, loaded.range == range {
                Text("\(loaded.files.count) file\(loaded.files.count == 1 ? "" : "s")")
                    .padding(.leading, 4)
                Text("+\(loaded.files.reduce(0) { $0 + $1.additions })").foregroundStyle(.green)
                Text("−\(loaded.files.reduce(0) { $0 + $1.deletions })").foregroundStyle(.red)
                if range == .all, let viewed = model.viewedFiles[item.id] {
                    let count = loaded.files.count { viewed[$0.filename] == .viewed }
                    Text("\(count) / \(loaded.files.count) viewed")
                        .fixedSize()
                        .foregroundStyle(.secondaryText)
                        .padding(.leading, 4)
                }
            }
            Spacer(minLength: 0)
            DiffOptions(wrapLines: $wrapLines, page: page)
        }
        .lineLimit(1)
        .font(.caption.monospacedDigit())
        .controlSize(.small)
    }

    /// What the diff shows: the preset, or what the selection covers.
    private func title(_ history: CommitHistory, range: CommitRange) -> String {
        guard !selection.isEmpty else { return (preset ?? .all).title }
        switch range {
        case let .commit(sha):
            return "Commit \(history.commit(matching: sha)?.shortOid ?? String(sha.prefix(7)))"
        case let .compare(base, head):
            let indices = history.commits.indices.filter { selection.contains(history.commits[$0].oid) }
            if let low = indices.first, let high = indices.last {
                return "\(high - low + 1) commits"
            }
            return "Force push \(base.prefix(7)) → \(head.prefix(7))"
        case .all:
            return CommitHistory.Preset.all.title
        }
    }

    // MARK: Diff

    @ViewBuilder
    private func diff(_ range: CommitRange) -> some View {
        if let loaded, loaded.range == range {
            if loaded.files.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "doc")
            } else {
                WebDocumentView(document: page, key: "\(item.id)#\(range.key)", payload: loaded.payload)
            }
        } else if let error {
            ContentUnavailableView {
                Label("Couldn't load changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await load(range) } }
            }
        } else {
            DelayedProgressView()
        }
    }

    private func load(_ range: CommitRange) async {
        error = nil
        let item = item
        do {
            let files = try await model.files(for: item, in: range)
            let lines = files.reduce(0) { $0 + $1.additions + $1.deletions }
            let isSmall = files.count <= Self.expandedLimit.files && lines <= Self.expandedLimit.lines
            let filesURL: String? = switch range {
            case .all: nil
            case let .commit(sha): "\(item.url)/commits/\(sha)"
            case let .compare(base, head): "\(item.url)/files/\(base)..\(head)"
            }
            let payload = await FilesDocument.payload(
                files, key: "\(item.id)#\(range.key)", pullURL: item.url, filesURL: filesURL,
                expanded: range != .all && isSmall ? true : nil
            )
            guard !Task.isCancelled else { return }
            loaded = Loaded(range: range, files: files, payload: payload)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct CommitRow: View {
    let commit: PRCommit
    let isNew: Bool
    let shortensTags: Bool
    let pullURL: String
    /// The force pushes folded into the row (iOS lists them in the commit's menu, not as rows).
    var pushes: [CommitHistory.Push] = []
    var selectPush: ((CommitHistory.Push) -> Void)?
    var extend: (() -> Void)?

    /// A size under the page's text on iOS, as the diff's file headers below are; the Mac's
    /// rows are a size up from those, as its list rows are.
    #if os(macOS)
        static let font = Font.callout
        static let textStyle = PlatformFont.TextStyle.callout
        static let badgeFont = Font.caption
        static let badgeStyle = PlatformFont.TextStyle.caption1
    #else
        static let font = Font.footnote
        static let textStyle = PlatformFont.TextStyle.footnote
        static let badgeFont = Font.caption2
        static let badgeStyle = PlatformFont.TextStyle.caption2
    #endif

    var body: some View {
        #if os(macOS)
            line
                .help("\(commit.tooltipMessage())\n\n\(byline)")
                .contextMenu { menu }
        #else
            line
                .contextMenu { menu } preview: {
                    CommitMessageCard(commit: commit)
                }
        #endif
    }

    #if os(macOS)
        /// Who made it and how big it is, under the message in the tooltip.
        private var byline: String {
            "\(commit.shortOid) · \(commit.authorName ?? commit.author ?? "Unknown") · +\(commit.additions) −\(commit.deletions)"
        }
    #endif

    @ViewBuilder
    private var menu: some View {
        if let extend { Button("Extend Selection to Here", systemImage: "arrow.up.and.down", action: extend) }
        if let selectPush, !pushes.isEmpty {
            Section { PushButtons(pushes: pushes, select: selectPush) }
        }
        Button("Open on GitHub", systemImage: "safari") {
            if let url = URL(string: "\(pullURL)/commits/\(commit.oid)") { Platform.open(url) }
        }
        Button("Copy SHA", systemImage: "doc.on.doc") { Platform.copy(commit.oid) }
        if commit.message != nil {
            Button("Copy Message", systemImage: "text.quote") { Platform.copy(commit.message ?? "") }
        }
    }

    private var line: some View {
        HStack(spacing: 6) {
            if commit.isMerge {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondaryText)
                    .frame(width: 7, height: 7)
            } else {
                Circle()
                    .fill(ciColor)
                    .frame(width: 7, height: 7)
            }
            AvatarView(login: commit.author, size: 16)
            Text(commit.shortOid)
                .font(Self.font.monospaced())
                .foregroundStyle(.secondaryText)
            // Merges in gray: they are rarely what a review is about.
            Text(itemTitle: commit.headline, shortenedTags: shortensTags)
                .foregroundStyle(commit.isMerge ? .secondaryText : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !pushes.isEmpty {
                HStack(spacing: 1) {
                    Image(systemName: "arrow.triangle.branch")
                    if pushes.count > 1 { Text("\(pushes.count)").font(Self.badgeFont.monospacedDigit()) }
                }
                .foregroundStyle(.orange)
                .accessibilityLabel(pushes.count == 1 ? "Force-pushed" : "Force-pushed \(pushes.count) times")
            }
            if isNew {
                Text("new")
                    .font(Self.badgeFont)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 5)
                    .background(.tint.opacity(0.15), in: .capsule)
            }
            Text(commit.committedAt.compactAge())
                .foregroundStyle(.secondaryText)
                .monospacedDigit()
        }
        .font(Self.font)
    }

    private var ciColor: Color {
        switch commit.ciState {
        case "SUCCESS": .green
        case "FAILURE", "ERROR": .red
        case "PENDING", "EXPECTED": .yellow
        default: .clear
        }
    }
}

/// A button for each force push whose ends are known, to see what it changed.
private struct PushButtons: View {
    let pushes: [CommitHistory.Push]
    let select: (CommitHistory.Push) -> Void

    var body: some View {
        ForEach(pushes) { push in
            if let before = push.before, let after = push.after {
                Button { select(push) } label: {
                    Label("Force Push \(before.prefix(7)) → \(after.prefix(7))", systemImage: "arrow.triangle.branch")
                    Text("\(push.actor ?? "Someone"), \(push.at.compactAge())")
                }
            }
        }
    }
}

#if os(iOS)
    /// The force pushes older than every commit listed (heads a rebase has rewritten since), as one
    /// row whose menu picks one.
    private struct EarlierPushesRow: View {
        let pushes: [CommitHistory.Push]
        let select: (CommitHistory.Push) -> Void

        var body: some View {
            Menu {
                PushButtons(pushes: pushes, select: select)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .frame(width: 7 + 6 + 16)
                    Text(pushes.count == 1 ? "1 earlier force push" : "\(pushes.count) earlier force pushes")
                    Spacer(minLength: 4)
                    if let last = pushes.last, let first = pushes.first {
                        Text(first.at.compactAge() == last.at.compactAge()
                            ? first.at.compactAge() : "\(first.at.compactAge())–\(last.at.compactAge())")
                            .monospacedDigit()
                    }
                }
                .font(CommitRow.font)
                .foregroundStyle(.orange)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// A commit's whole message, over its row's menu: who made it, the headline, and the body
    /// (its paragraphs reflowed), cut short where the room ends.
    private struct CommitMessageCard: View {
        let commit: PRCommit

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                // The name gives way to the numbers, which a long bot's name cut off.
                HStack(spacing: 6) {
                    AvatarView(login: commit.author, size: 20)
                    Text(commit.shortOid).monospaced()
                    Text("·")
                    Text(commit.authorName ?? commit.author ?? "Unknown")
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                    Text("·")
                    Text("+\(commit.additions) −\(commit.deletions)")
                    Spacer(minLength: 4)
                    Text(commit.committedAt.compactAge())
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondaryText)
                .lineLimit(1)
                // Its tags in gray, as the rows show them.
                Text(itemTitle: commit.messageTitle, shortenedTags: false)
                    .font(.headline)
                    .lineLimit(4)
                    .layoutPriority(1)
                let body = commit.reflowedBody
                if !body.isEmpty {
                    Text(body)
                        .font(.subheadline)
                        .lineLimit(18)
                }
            }
            .padding(16)
            // The system measures the preview with no width proposed, where text is one line a
            // paragraph: the ideal width makes it wrap, so the card asks for the height it needs.
            // It is about the width the system then gives a preview (342 pt on an iPad mini):
            // measured wider, the text took more lines than it had asked room for and the last
            // ones were dropped. At most 18 lines of body, or the system shrinks a tall card to
            // fit, narrower too (it keeps the card's proportions). Flexible below that: given less
            // room than it asked for, it wraps narrower and cuts the body short rather than
            // being clipped.
            .frame(idealWidth: 340, maxWidth: 400, maxHeight: .infinity, alignment: .topLeading)
        }
    }
#endif

#if os(macOS)
    /// A force push as a row of its own: the Mac's list is close enough to spare it one.
    private struct PushRow: View {
        let push: CommitHistory.Push

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .frame(width: 7 + 6 + 16)
                Text("\(push.actor ?? "Someone") force-pushed")
                if let before = push.before, let after = push.after {
                    Text("\(before.prefix(7)) → \(after.prefix(7))")
                        .font(.callout.monospaced())
                }
                Spacer(minLength: 4)
                Text(push.at.compactAge())
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.orange)
            .help(push.before == nil || push.after == nil ? "" : "Select to see what the push changed")
        }
    }
#endif
