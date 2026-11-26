import SwiftUI

/// The selected item: its header, then Conversation / Commits / Files, as in the Mac's detail
/// pane. Beside the list or under it in a split view, pushed over it on a phone; either way it
/// shows the model's selection, and its pages belong to the desk, so a layout change keeps them.
///
/// The page gets the whole pane: the header lies over its top and scrolls away with it, under
/// the bar, whose title then names the item; the composer stays folded into a button until asked
/// for.
struct DetailPane: View {
    @Environment(AppModel.self) private var model
    let pages: DetailPages
    @AppStorage("showAutomated") private var showAutomated = false
    @State private var scrolls = PaneScrolls()
    /// How much of the pane the system's bars cover, which the pages reach under.
    @State private var bars = EdgeInsets()
    @State private var headerHeight: CGFloat = 0
    /// The composer is open over the conversation's foot, and how tall it is.
    @State private var isComposing = false
    @State private var composerHeight: CGFloat = 0
    @State private var renameText: String?

    typealias Tab = AppModel.DetailTab

    // The body doesn't read the tab showing (the views that need it do): a change of tab then
    // leaves the bar's items alone, and the segments' own animation runs to its end.
    var body: some View {
        Group {
            if let item = model.selectedItem {
                content(item)
                    // Laid over the pages rather than inset above them: a scroll view of pages
                    // would start each below it, and every page leaves it room itself. Clipped
                    // at the bar's edge, so it leaves under the bar as a page's top does and
                    // never shows through the bar's buttons.
                    .overlay(alignment: .top) {
                        ActivePage(scrolls: scrolls, item: item) { scroll in
                            VStack(spacing: 0) {
                                DetailHeader(item: item) { scrolls.setTitleExtent($0) }
                                if item.kind == .pullRequest {
                                    DetailTabs().padding(.horizontal, 12).padding(.bottom, 8)
                                }
                                Divider()
                            }
                            .background(Color(uiColor: .systemBackground))
                            // Over every tab's page, each of which leaves it room at its top.
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                headerHeight = $0
                                scrolls.setHeader(height: $0)
                            }
                            // It goes with the page showing, up and away or down when pulled.
                            .offset(y: -min(scroll.offset, 3000))
                            // Once its title is gone the bar's says what this is, as a large
                            // title's does.
                            .navigationTitle(scroll.isChromeAway ? "#\(String(item.number)) \(item.title)" : "")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
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
                    .toolbar { toolbar(item) }
                    .alert("Rename", isPresented: Binding(get: { renameText != nil }, set: { if !$0 { renameText = nil } })) {
                        TextField("Title", text: Binding(get: { renameText ?? "" }, set: { renameText = $0 }))
                        Button("Rename") {
                            if let renameText { model.rename(item, to: renameText) }
                            renameText = nil
                        }
                        Button("Cancel", role: .cancel) { renameText = nil }
                    }
            } else {
                ContentUnavailableView("No Selection", systemImage: "rectangle.righthalf.inset.filled", description: Text("Select a PR or issue."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { bars = $0 }
        .navigationBarTitleDisplayMode(.inline)
    }

    /// In the pane's bar: the item on GitHub, and everything else about it.
    @ToolbarContentBuilder
    private func toolbar(_ item: Item) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Open on GitHub", systemImage: "arrow.up.right") { model.perform(.openInBrowser, on: item.id) }
        }
        ToolbarItem(placement: .topBarTrailing) {
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
    }

    @ViewBuilder
    private func content(_ item: Item) -> some View {
        if let detail = model.detail, detail.id == item.id {
            if item.kind == .issue {
                conversation(item, detail)
                    .environment(scrolls.conversation)
            } else {
                DetailPager(item: item, detail: detail, pages: pages, scrolls: scrolls, bars: bars, headerHeight: headerHeight) {
                    conversation(item, detail)
                }
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

    /// The conversation, with the composer over its foot: folded into a button over the corner,
    /// or open as a card of glass, which the page leaves room under its end for.
    private func conversation(_ item: Item, _ detail: ItemDetail) -> some View {
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
            .overlay(alignment: .bottom) {
                if isComposing {
                    composer(item, detail)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: isComposing, initial: true) { setBottomRoom() }
            .onChange(of: composerHeight) { setBottomRoom() }
            // A comment that went out leaves nothing to keep the composer open for.
            .onChange(of: detail.entries.count) {
                withAnimation(.snappy(duration: 0.25)) { isComposing = false }
            }
    }

    /// Room under the last comment for what lies over the page's foot.
    private func setBottomRoom() {
        scrolls.conversation.bottomRoom = isComposing ? composerHeight + 12 : ComposeButton.size + 8
    }

    /// The composer, open: the Mac's, on a card of glass floating over the page (and over the
    /// keyboard). Its own button folds it away again; what is written stays as the item's draft.
    private func composer(_ item: Item, _ detail: ItemDetail) -> some View {
        ComposerView(item: item, detail: detail) {
            withAnimation(.snappy(duration: 0.25)) { isComposing = false }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .onAppear { model.requestComposerFocus() }
    }
}

/// How far each tab's page has scrolled: they are side by side, and each keeps its own place.
@MainActor
private final class PaneScrolls {
    let conversation = PageScroll()
    let commits = PageScroll()
    let files = PageScroll()
    private let headerID = UUID()

    subscript(tab: AppModel.DetailTab) -> PageScroll {
        switch tab {
        case .conversation: conversation
        case .commits: commits
        case .files: files
        }
    }

    /// The pane's header lies over all of them.
    func setHeader(height: CGFloat) {
        for scroll in [conversation, commits, files] { scroll.setChrome(headerID, height: height) }
    }

    /// How far down the header its title ends: scrolled that far, the bar names the item.
    func setTitleExtent(_ extent: CGFloat) {
        for scroll in [conversation, commits, files] { scroll.setTitleExtent(extent) }
    }
}

/// Builds with the scroll of the page showing, so that only this view follows the tab.
private struct ActivePage<Content: View>: View {
    @Environment(AppModel.self) private var model
    let scrolls: PaneScrolls
    let item: Item
    @ViewBuilder let content: (PageScroll) -> Content

    var body: some View {
        let tab = item.kind == .issue ? .conversation : model.detailTab
        content(scrolls[tab])
            // Between tabs the header moves to where the other page has it.
            .animation(.snappy(duration: 0.25), value: tab)
    }
}

/// Conversation, Commits and Files as segments. Picking one slides to it.
private struct DetailTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("View", selection: Binding(
            get: { model.detailTab },
            set: { model.detailTab = $0 }
        )) {
            Text("Conversation").tag(AppModel.DetailTab.conversation)
            Text("Commits").tag(AppModel.DetailTab.commits)
            Text("Files").tag(AppModel.DetailTab.files)
        }
        .pickerStyle(.segmented)
    }
}

/// A pull request's three pages side by side, turned like pages: by a swipe, or by the tabs.
private struct DetailPager<Conversation: View>: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail
    let pages: DetailPages
    let scrolls: PaneScrolls
    let bars: EdgeInsets
    /// The pane's header, laid over the pages' tops.
    let headerHeight: CGFloat
    @ViewBuilder let conversation: Conversation
    /// The tabs shown for this item, or begun to be swiped to: the others load nothing yet.
    @State private var opened: Set<AppModel.DetailTab> = []
    @State private var position = ScrollPosition(idType: AppModel.DetailTab.self)

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                page(.conversation) { conversation }
                // Its own per item, so the selection and the chosen range don't carry over.
                page(.commits) { CommitsView(item: item, detail: detail, page: pages.commits).id(item.id) }
                page(.files) { FilesView(item: item, page: pages.files) }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        // A scroll view keeps its content clear of the bars; the pages reach under them
        // (`page`), so nothing is clipped there, only at the pane's sides.
        .scrollClipDisabled()
        .clipShape(SideClip())
        .onChange(of: item.id, initial: true) {
            opened = [model.detailTab]
            position.scrollTo(id: model.detailTab)
        }
        // A tab picked (a segment, a key): slide to its page.
        .onChange(of: model.detailTab) { _, tab in
            opened.insert(tab)
            if position.viewID(type: AppModel.DetailTab.self) != tab {
                withAnimation(.snappy(duration: 0.3)) { position.scrollTo(id: tab) }
            }
        }
        // A page swiped to: that is the tab now.
        .onChange(of: position.viewID(type: AppModel.DetailTab.self)) { _, tab in
            if let tab, tab != model.detailTab { model.detailTab = tab }
        }
    }

    private func page(_ tab: AppModel.DetailTab, @ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            if opened.contains(tab) { content() }
        }
        // The page fills the pane from the window's top to its foot. What it lays out by the
        // safe area (a tab's own bar, the composer) keeps clear of the bars and the header; its
        // web view ignores that and lies under them all.
        .safeAreaPadding(.top, bars.top + headerHeight)
        .safeAreaPadding(.bottom, bars.bottom)
        .frame(maxHeight: .infinity)
        .padding(.top, -bars.top)
        .padding(.bottom, -bars.bottom)
        .containerRelativeFrame(.horizontal)
        .environment(scrolls[tab])
        .onScrollVisibilityChange(threshold: 0.02) { if $0 { opened.insert(tab) } }
        .id(tab)
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
/// controls. GitHub and the ••• menu are in the pane's bar.
private struct DetailHeader: View {
    @Environment(AppModel.self) private var model
    let item: Item
    /// Told how far down the header the title ends.
    let onTitleExtent: (CGFloat) -> Void
    /// The stack, labels, dates and branches: shown until folded.
    @AppStorage("detailHeaderExpanded") private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .macTextStrength()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onTitleExtent($0 + 10) }
            people
            if isExpanded { more }
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        // Its buttons are plain (the CI status, the chevron), with no color of their own to lose.
        .macTextStrength()
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
        .foregroundStyle(Color.secondaryText)

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
                .foregroundStyle(Color.secondaryText)
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
        }
        .buttonStyle(.plain)
    }
}

/// As wide as the view and far taller: clips what leaves by its sides, not by its top or foot.
private struct SideClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -2000))
    }
}
