import SwiftUI

/// The selected item: its header, then Conversation / Commits / Files, as in the Mac's detail
/// pane. Beside the list in a wide window, pushed over it in a narrow one (`isPushed`); either
/// way it shows the model's selection, and its pages belong to the desk, so a layout change keeps
/// them.
struct DetailPane: View {
    @Environment(AppModel.self) private var model
    let pages: DetailPages
    let isPushed: Bool
    @AppStorage("showAutomated") private var showAutomated = false

    typealias Tab = AppModel.DetailTab

    var body: some View {
        @Bindable var model = model
        Group {
            if let item = model.selectedItem {
                VStack(spacing: 0) {
                    DetailHeader(item: item, pages: pages, showAutomated: $showAutomated)
                    if item.kind == .pullRequest {
                        Picker("View", selection: $model.detailTab) {
                            Text("Conversation").tag(Tab.conversation)
                            Text("Commits").tag(Tab.commits)
                            Text("Files").tag(Tab.files)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    Divider()
                    content(item)
                }
                .onChange(of: item.id) {
                    if item.kind == .issue { model.detailTab = .conversation }
                }
                .navigationTitle(isPushed ? "#\(String(item.number))" : "")
            } else {
                ContentUnavailableView("No Selection", systemImage: "rectangle.righthalf.inset.filled", description: Text("Select a PR or issue."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ item: Item) -> some View {
        if let detail = model.detail, detail.id == item.id {
            switch item.kind == .issue ? .conversation : model.detailTab {
            case .conversation:
                VStack(spacing: 0) {
                    Conversation(item: item, detail: detail, page: pages.timeline, showAutomated: showAutomated)
                    Divider()
                    ComposerView(item: item, detail: detail)
                }
            case .commits:
                // Its own per item, so the selection and the chosen range don't carry over.
                CommitsView(item: item, detail: detail, page: pages.commits)
                    .id(item.id)
            case .files:
                FilesView(item: item, page: pages.files)
            }
        } else if case let .failed(message) = model.detailState {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { model.loadDetail(force: true) }
            }
        } else {
            DelayedProgressView()
        }
    }
}

/// The timeline: comment and review cards plus compact event lines, in one web page
/// (`TimelineDocument`). Its options are in the header's menu.
private struct Conversation: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail
    let page: WebDocument
    let showAutomated: Bool

    var body: some View {
        let document = TimelineDocument(
            item: item, detail: detail, previousSeenAt: model.selectedItemPreviousSeenAt,
            showAutomated: showAutomated, people: model
        )
        WebDocumentView(document: page, key: item.id, payload: document.payload)
            // A link that pointed to a comment of this item scrolls to it.
            .onChange(of: model.linkedComment, initial: true) { _, link in
                if let link, let fragment = link.anchor, link.key == item.repoNumber {
                    page.reveal(fragment: fragment, key: item.id)
                }
            }
    }
}

/// Title, state, author and CI; the stack, labels and dates, which fold away; then the board's
/// controls and the ••• menu.
private struct DetailHeader: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let pages: DetailPages
    @Binding var showAutomated: Bool
    /// The stack, labels, dates and branches: shown until folded, to leave a short window (an
    /// iPad mini on its side) to the conversation.
    @AppStorage("detailHeaderExpanded") private var isExpanded = true
    @State private var renameText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
            people
            if isExpanded { more }
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .alert("Rename", isPresented: Binding(get: { renameText != nil }, set: { if !$0 { renameText = nil } })) {
            TextField("Title", text: Binding(get: { renameText ?? "" }, set: { renameText = $0 }))
            Button("Rename") {
                if let renameText { model.rename(item, to: renameText) }
                renameText = nil
            }
            Button("Cancel", role: .cancel) { renameText = nil }
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("#\(String(item.number))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            titleText
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .font(.title3.weight(.semibold))
    }

    /// The title with its leading tags ("[Core] ", "fix(x): ") dimmed and its inline code monospaced.
    private var titleText: Text {
        TitleMarkup.pieces(item.title).reduce(Text(verbatim: "")) { text, piece in
            var part = Text(verbatim: piece.text)
            if piece.isCode { part = part.font(.system(.title3, design: .monospaced).weight(.semibold)) }
            if piece.isPrefix { part = part.foregroundStyle(.secondary) }
            return Text("\(text)\(part)")
        }
    }

    private var people: some View {
        HStack(spacing: 6) {
            AvatarView(login: item.author, size: 18)
            LoginText(login: item.author)
                .lineLimit(1)
            BadgeIcons(login: item.author)
            StateIconView(item: item, isMerging: item.isOpen && model.board(for: item)?.triage == .merging)
            stateChip
            if let ci = item.ci {
                Button { model.checksShownFor = item.repoNumber } label: { CISummary(ci: ci).lineLimit(1) }
                    .buttonStyle(.plain)
                    .popover(isPresented: isShowingChecks) {
                        VStack(spacing: 0) {
                            ItemChecksView(item: item, maxHeight: 460)
                            Divider()
                            Button("Open on GitHub", systemImage: "arrow.up.right") {
                                if let url = URL(string: item.url + "/checks") { Platform.open(url) }
                            }
                            .font(.callout)
                            .padding(10)
                        }
                        .frame(minWidth: 360, idealWidth: 400)
                        .presentationDetents([.medium, .large])
                    }
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isExpanded ? "Show Less" : "Show More")
        }
        .font(.callout)
    }

    /// What folds away: dates and branches, the adoption, the stack, the labels and the board's
    /// Comment.
    @ViewBuilder private var more: some View {
        HStack(spacing: 6) {
            Text("opened \(item.createdAt.compactAge()) ago · updated \(item.updatedAt.compactAge()) ago")
                .lineLimit(1)
            if let detail = model.detail, detail.id == item.id, let head = detail.headRef, let base = detail.baseRef {
                Text("·")
                Text("\(head) → \(base)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        AdoptionNote(item: item)

        if let ladder = model.stackLadder, ladder.rungs.contains(where: { $0.entry.number == item.number }) {
            StackPanel(item: item, ladder: ladder)
        }

        if !item.labels.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(item.labels, id: \.name) { LabelChip(name: $0.name, hex: $0.color) }
            }
        }

        if let board = model.board(for: item), !board.isArchived, let comment = board.comment, !comment.isEmpty {
            Label(comment, systemImage: "text.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isShowingChecks: Binding<Bool> {
        Binding(
            get: { model.checksShownFor == item.repoNumber },
            set: { model.checksShownFor = $0 ? item.repoNumber : nil }
        )
    }

    private var stateChip: some View {
        switch (item.state, item.isDraft) {
        case (.open, true): Chip(text: "Draft")
        case (.open, false): Chip(text: "Open", color: .green)
        case (.merged, _): Chip(text: "Merged", color: .purple)
        case (.closed, _): Chip(text: "Closed", color: item.kind == .issue ? .purple : .red)
        }
    }

    // MARK: Controls

    /// Status and Priority one touch away, as segments; side by side where they fit, stacked on
    /// a phone.
    private var controls: some View {
        let onBoard = ItemMenu.isOnBoard(item, model: model)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if onBoard {
                    statusPicker.fixedSize()
                    priorityPicker.fixedSize()
                }
                Spacer(minLength: 0)
                buttons(onBoard: onBoard)
            }
            VStack(alignment: .leading, spacing: 8) {
                if onBoard { statusPicker }
                HStack(spacing: 8) {
                    if onBoard { priorityPicker.fixedSize() }
                    Spacer(minLength: 0)
                    buttons(onBoard: onBoard)
                }
            }
        }
    }

    private var statusPicker: some View {
        let triage = model.triage(for: item)
        return Picker("Status", selection: Binding(
            get: { model.listedTriage(for: item) },
            set: { status in
                if let status {
                    if status != triage { model.perform(.triage(status), on: item.id) }
                } else if let triage {
                    // Back to Triage: setting the current Status again clears it.
                    model.perform(.triage(triage), on: item.id)
                }
            }
        )) {
            Text("Triage").tag(TriageStatus?.none)
            ForEach(TriageStatus.settable, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            // Merging comes with 🚀 or from Merger; shown while the item has it, never offered.
            if triage == .merging {
                Text(TriageStatus.merging.rawValue).tag(Optional(TriageStatus.merging))
            }
        }
        .pickerStyle(.segmented)
    }

    private var priorityPicker: some View {
        Picker("Priority", selection: Binding(
            get: { model.board(for: item)?.priorityValue },
            set: { priority in
                // Setting the current Priority again clears it, so nil goes by the current one.
                let current = model.board(for: item)?.priorityValue
                if priority != current { model.perform(.priority(priority ?? current), on: item.id) }
            }
        )) {
            ForEach(Priority.allCases, id: \.self) { Text($0.letter).tag(Optional($0)) }
            Text("–").tag(Priority?.none)
        }
        .pickerStyle(.segmented)
    }

    private func buttons(onBoard: Bool) -> some View {
        HStack(spacing: 4) {
            if model.detailState == .loading {
                ProgressView().controlSize(.small).padding(.trailing, 4)
            }
            if onBoard {
                let isPinned = model.board(for: item)?.isPinned == true
                Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin") {
                    model.perform(.togglePin, on: item.id)
                }
                .foregroundStyle(isPinned ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
            }
            Button("Open on GitHub", systemImage: "arrow.up.right") { model.perform(.openInBrowser, on: item.id) }
            Menu("More", systemImage: "ellipsis") {
                ItemMenu(item: item, model: model)
                Section {
                    Button("Rename…", systemImage: "pencil") { renameText = item.title }
                    Button("Refresh", systemImage: "arrow.clockwise") { model.loadDetail(force: true) }
                    if model.canGoBack {
                        Button("Back to Previous Item", systemImage: "chevron.backward") { model.goBack() }
                    }
                }
                Section("Conversation") {
                    Toggle("Show Automated", isOn: $showAutomated)
                    Button("Expand All", systemImage: "rectangle.expand.vertical") { pages.timeline.run("PRDesk.setAllCards(true)") }
                    Button("Collapse All", systemImage: "rectangle.compress.vertical") { pages.timeline.run("PRDesk.setAllCards(false)") }
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.small)
    }
}
