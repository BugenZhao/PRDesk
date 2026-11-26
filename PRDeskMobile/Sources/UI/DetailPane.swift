import SwiftUI

/// The selected item: its header, then Conversation / Commits / Files, as in the Mac's detail
/// pane. Beside the list in a wide window, pushed over it in a narrow one (`isPushed`); either
/// way it shows the model's selection, and its pages belong to the desk, so a layout change keeps
/// them.
///
/// The page gets the whole pane: the header lies over its top and scrolls away with it
/// (`scrollsAway`), and the composer stays folded into a button until asked for.
struct DetailPane: View {
    @Environment(AppModel.self) private var model
    let pages: DetailPages
    let isPushed: Bool
    /// The list is put away: the pane has the window, and the bar over it only the desk's buttons.
    var isAlone = false
    @AppStorage("showAutomated") private var showAutomated = false
    @State private var scroll = PageScroll()
    /// The composer is open under the conversation.
    @State private var isComposing = false

    typealias Tab = AppModel.DetailTab

    /// The toolbar's row of buttons, which the bars over the pane end with.
    private static let barHeight: CGFloat = 62
    /// The desk's buttons at the bar's trailing end, which the title's line stops short of: the
    /// filter and the menu, or the menu alone while the list is away.
    private var trailingButtonsWidth: CGFloat { isAlone ? 64 : 124 }
    /// The button that brings the list back, at the bar's leading end while the list is away.
    private static let listButtonWidth: CGFloat = 60

    var body: some View {
        Group {
            if let item = model.selectedItem {
                content(item)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            DetailHeader(item: item, pages: pages, showAutomated: $showAutomated)
                            // Pushed, the tabs are in the navigation bar, beside the way back.
                            if item.kind == .pullRequest, !isPushed {
                                tabs.padding(.horizontal, 12).padding(.bottom, 8)
                            }
                            Divider()
                        }
                        .scrollsAway()
                    }
                    // Once the header has left with the page, a line of glass says what this is;
                    // touching it goes back to the top.
                    .overlay(alignment: isPushed ? .top : .topLeading) {
                        CompactTitle(item: item, isShown: scroll.isChromeAway) {
                            activePage(item).run("scrollTo({ top: 0, behavior: 'smooth' })")
                        }
                        // Beside the list the bar over this pane is empty up to the window's
                        // buttons: the line goes there, level with them. Pushed, the bar holds
                        // the way back and the tabs, and the line sits under it.
                        .padding(.leading, isAlone ? Self.listButtonWidth : 0)
                        .padding(.trailing, isPushed ? 0 : trailingButtonsWidth)
                        .offset(y: isPushed ? 6 : -(Self.barHeight + CompactTitle.height) / 2)
                    }
                    .onChange(of: item.id) {
                        if item.kind == .issue { model.detailTab = .conversation }
                        isComposing = false
                    }
                    // Asked for by key (c): the composer opens, in the conversation.
                    .onChange(of: model.composerFocusRequest) {
                        guard !isComposing else { return }
                        if item.kind == .pullRequest { model.detailTab = .conversation }
                        withAnimation(.snappy(duration: 0.25)) { isComposing = true }
                    }
                    .toolbar {
                        if isPushed, item.kind == .pullRequest {
                            // The segments are glass themselves: no second sheet of it behind.
                            ToolbarItem(placement: .principal) { tabs.frame(maxWidth: 420) }
                                .sharedBackgroundVisibility(.hidden)
                        }
                    }
            } else {
                ContentUnavailableView("No Selection", systemImage: "rectangle.righthalf.inset.filled", description: Text("Select a PR or issue."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(scroll)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The page of the tab showing.
    private func activePage(_ item: Item) -> WebDocument {
        switch item.kind == .issue ? .conversation : model.detailTab {
        case .conversation: pages.timeline
        case .commits: pages.commits
        case .files: pages.files
        }
    }

    private var tabs: some View {
        @Bindable var model = model
        return Picker("View", selection: $model.detailTab) {
            Text("Conversation").tag(Tab.conversation)
            Text("Commits").tag(Tab.commits)
            Text("Files").tag(Tab.files)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func content(_ item: Item) -> some View {
        if let detail = model.detail, detail.id == item.id {
            switch item.kind == .issue ? .conversation : model.detailTab {
            case .conversation:
                // The composer under the conversation rather than over it, so the page ends
                // where the composer begins; folded, the page runs to the window's foot.
                VStack(spacing: 0) {
                    Conversation(item: item, detail: detail, page: pages.timeline, showAutomated: showAutomated)
                        .overlay(alignment: .bottomTrailing) {
                            if !isComposing {
                                ComposeButton(hasDraft: !model.draft(for: item.id).isEmpty) {
                                    withAnimation(.snappy(duration: 0.25)) { isComposing = true }
                                }
                                .padding(.trailing, 16)
                                .padding(.bottom, 12)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                    if isComposing {
                        composer(item, detail)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // Room under the last comment for the button over the corner.
                .onChange(of: isComposing, initial: true) { scroll.bottomRoom = isComposing ? 0 : ComposeButton.size + 8 }
                .onDisappear { scroll.bottomRoom = 0 }
                // A comment that went out leaves nothing to keep the composer open for.
                .onChange(of: detail.entries.count) {
                    withAnimation(.snappy(duration: 0.25)) { isComposing = false }
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

    /// The composer, open: the Mac's, under a handle that folds it away again. What is written
    /// stays as the item's draft.
    private func composer(_ item: Item, _ detail: ItemDetail) -> some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.snappy(duration: 0.25)) { isComposing = false }
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Composer")
            ComposerView(item: item, detail: detail)
        }
        .background(.bar)
        .onAppear { model.requestComposerFocus() }
    }
}

/// The item in one line of glass over the page's top, while the header is scrolled away.
private struct CompactTitle: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let isShown: Bool
    let action: () -> Void

    static let height: CGFloat = 36

    var body: some View {
        ZStack {
            if isShown {
                Button(action: action) {
                    HStack(spacing: 6) {
                        StateIconView(item: item, size: 14, isMerging: model.isMerging(item))
                        Text("#\(String(item.number))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(itemTitle: item.title, shortenedTags: true, codeFont: .footnote.monospaced())
                            .lineLimit(1)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(height: Self.height)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .offset(y: -8)))
                .accessibilityHint("Scrolls to the top")
            }
        }
        .animation(.snappy(duration: 0.25), value: isShown)
    }
}

/// The composer, folded away: a round glass button over the conversation's corner, which grows
/// a word when a draft waits behind it.
private struct ComposeButton: View {
    let hasDraft: Bool
    let action: () -> Void

    static let size: CGFloat = 48

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                if hasDraft { Text("Draft") }
            }
            .font(.system(size: 18, weight: .medium))
            .padding(.horizontal, hasDraft ? 16 : 0)
            .frame(minWidth: Self.size)
            .frame(height: Self.size)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasDraft ? "Continue Draft" : "Comment or Review")
    }
}

/// The face of a round glass button in the header: one size whatever the symbol, and the same
/// for a button and a menu.
private struct RoundGlassIcon: View {
    let systemName: String
    var tint: Color = .primary

    static let size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
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
    /// The stack, labels, dates and branches: shown until folded.
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
        // One text, so a title that wraps continues under its number.
        Text("\(Text("#\(String(item.number))").foregroundStyle(.secondary).monospacedDigit()) \(titleText)")
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
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
        HStack(spacing: 8) {
            if model.detailState == .loading {
                ProgressView().controlSize(.small)
            }
            if onBoard {
                let isPinned = model.board(for: item)?.isPinned == true
                Button {
                    model.perform(.togglePin, on: item.id)
                } label: {
                    RoundGlassIcon(systemName: isPinned ? "pin.fill" : "pin", tint: isPinned ? .orange : .primary)
                }
                .accessibilityLabel(isPinned ? "Unpin" : "Pin")
            }
            Button {
                model.perform(.openInBrowser, on: item.id)
            } label: {
                RoundGlassIcon(systemName: "arrow.up.right")
            }
            .accessibilityLabel("Open on GitHub")
            Menu {
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
            } label: {
                RoundGlassIcon(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
        .buttonStyle(.plain)
    }
}
