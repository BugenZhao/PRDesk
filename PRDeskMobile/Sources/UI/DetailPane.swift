import SwiftUI

/// The selected item: its header, then Conversation / Commits / Files, as in the Mac's detail
/// pane. Beside the list or under it in a split view, pushed over it on a phone; either way it
/// shows the model's selection, and its pages belong to the desk, so a layout change keeps them.
///
/// The page gets the whole pane: the header lies over its top and scrolls away with it, under
/// the bar, whose title then names the item; the composer stays folded into a button in the bar
/// at the pane's foot until asked for.
struct DetailPane: View {
    @Environment(AppModel.self) private var model
    let pages: DetailPages
    /// The bar has room for the item's session and GitHub beside the menu (not a phone's, where
    /// they are at the menu's head).
    var showsLinks = true
    @AppStorage("showAutomated") private var showAutomated = false
    @State private var scrolls = PaneScrolls()
    /// How much of the pane the system's bars cover, which the pages reach under.
    @State private var bars = EdgeInsets()
    @State private var headerHeight: CGFloat = 0
    /// The composer is open over the conversation's foot, and how tall it is.
    @State private var isComposing = false
    @State private var composerHeight: CGFloat = 0
    /// The pane's height between the bars, and the keyboard when it is up.
    @State private var paneHeight: CGFloat = 0
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
                            // It goes with the page showing, up and away or down when pulled,
                            // and out of the composer's way.
                            .offset(y: -min(max(scroll.offset, headerLift), 3000))
                            .animation(.snappy(duration: 0.25), value: headerLift)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                    }
                    .onChange(of: item.id) {
                        if item.kind == .issue { model.detailTab = .conversation }
                        isComposing = false
                    }
                    // Asked for by key (c): the composer opens, in the conversation.
                    .onChange(of: model.composerFocusRequest) { compose(item) }
                    .toolbar { toolbar(item) }
                    .toolbarVisibility(isComposing ? .hidden : .automatic, for: .bottomBar)
                    // The page goes up with the header where it can, so the room the header
                    // leaves shows the conversation rather than the page's empty top.
                    .onChange(of: headerLift) { _, lift in
                        let scrollView = pages.timeline.webView.scrollView
                        let end = scrollView.contentSize.height - scrollView.bounds.height
                        let target = min(lift, end)
                        if scrollView.contentOffset.y < target {
                            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                        }
                    }
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        .navigationBarTitleDisplayMode(.inline)
    }

    /// How far the header moves up for the composer: all of itself where the pane, with the
    /// keyboard up, has no room for both (an iPad mini on its side), or the field being typed in
    /// would lie under it.
    private var headerLift: CGFloat {
        isComposing && paneHeight - headerHeight < composerHeight + 60 ? headerHeight : 0
    }

    /// Opens the composer, in the conversation.
    private func compose(_ item: Item) {
        guard !isComposing else { return }
        if item.kind == .pullRequest { model.detailTab = .conversation }
        withAnimation(.snappy(duration: 0.25)) { isComposing = true }
    }

    /// In the pane's bar: the item in two lines once the header's title has scrolled under the
    /// bar, the item elsewhere (its agent session, GitHub), and everything else about it. In the
    /// bar at the pane's foot, the composer's button while it is folded away.
    @ToolbarContentBuilder
    private func toolbar(_ item: Item) -> some ToolbarContent {
        // In the title's own place, which the system keeps between the bar's buttons.
        ToolbarItem(placement: .title) {
            ActivePage(scrolls: scrolls, item: item) { scroll in
                BarTitle(item: item, isShown: scroll.isChromeAway || headerLift > 0) { scrollToTop(item) }
            }
        }
        // One capsule for where else the item is, where the bar has the room; the menu in one
        // of its own.
        if showsLinks {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SessionButton(item: item) { Label("Open Agent Session", systemImage: "terminal") }
                Button("Open on GitHub", systemImage: "arrow.up.right") { model.perform(.openInBrowser, on: item.id) }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis") {
                ItemMenu(item: item, model: model) { renameText = item.title }
                Section("Conversation") {
                    Toggle("Show Automated", isOn: $showAutomated)
                    Button("Expand All", systemImage: "rectangle.expand.vertical") { pages.timeline.run("PRDesk.setAllCards(true)") }
                    Button("Collapse All", systemImage: "rectangle.compress.vertical") { pages.timeline.run("PRDesk.setAllCards(false)") }
                }
                Section {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.loadDetail(force: true) }
                    if model.canGoBack {
                        Button("Back to Previous Item", systemImage: "chevron.backward") { model.goBack() }
                    }
                }
            }
        }
        // Always there, and the bar hidden while the composer is open: taking the item out as
        // the keyboard came up left the pane laid out a hundred points too high.
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            ComposeButton(item: item) { compose(item) }
        }
    }

    /// Read when touched, not by the body.
    private func scrollToTop(_ item: Item) {
        let page = switch item.kind == .issue ? .conversation : model.detailTab {
        case .conversation: pages.timeline
        case .commits: pages.commits
        case .files: pages.files
        }
        page.run("scrollTo({ top: 0, behavior: 'smooth' })")
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

    /// The conversation, with the composer over its foot when open, which the page leaves room
    /// under its end for.
    private func conversation(_ item: Item, _ detail: ItemDetail) -> some View {
        Conversation(item: item, detail: detail, page: pages.timeline, showAutomated: showAutomated)
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

    /// Room under the last comment for the composer over the page's foot (the bar there is the
    /// system's, which the page keeps clear of already).
    private func setBottomRoom() {
        scrolls.conversation.bottomRoom = isComposing ? composerHeight + 12 : 0
    }

    /// The composer, open: the Mac's, on one card of glass floating over the page (and over the
    /// keyboard), its buttons the system's glass ones. One of them folds it away again; what is
    /// written stays as the item's draft.
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

/// The item in the pane's bar while its header is out of sight, from the bar's leading end: its
/// state and title, and under them its number, who wrote it (picture, name, marks of trust) and
/// how big it is, as a row of the list has them. It fades in and out; touching it goes back to
/// the top.
private struct BarTitle: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let isShown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    StateIconView(item: item, size: 13, isMerging: model.isMerging(item))
                    Text(itemTitle: item.title, shortenedTags: true, codeFont: .footnote.monospaced(), tagStyle: .secondaryText)
                }
                .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Text("#\(String(item.number))")
                    AvatarView(login: item.author, size: 14)
                    Text(item.author ?? "ghost")
                    BadgeIcons(login: item.author, size: 11)
                    if item.isDraft, item.isOpen { Text("· Draft") }
                    if let additions = item.additions, let deletions = item.deletions {
                        Text("·")
                        Text("+\(additions)").foregroundStyle(Color.diffAdded)
                        Text("−\(deletions)").foregroundStyle(Color.diffRemoved)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondaryText)
            }
            .lineLimit(1)
            // The bar centers its title at the width the title asks for. Asking for more than
            // any bar has, it is given all there is between the bar's buttons, and the text
            // goes to the leading end of that. (The system's own leading title, `.inlineLarge`,
            // is for a title of plain text, not a view.)
            .frame(idealWidth: 4000, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
        .accessibilityHint("Scrolls to the top")
        .animation(.easeInOut(duration: 0.2), value: isShown)
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
        // Come to rest, the page showing is the tab, whatever was asked for: a touch that stops
        // a slide half way leaves the position naming the page it was sliding to.
        .onScrollPhaseChange { _, phase, context in
            let width = context.geometry.containerSize.width
            guard phase == .idle, width > 0 else { return }
            let tabs: [AppModel.DetailTab] = [.conversation, .commits, .files]
            let index = Int((context.geometry.contentOffset.x / width).rounded())
            let tab = tabs[min(max(index, 0), tabs.count - 1)]
            if tab != model.detailTab { model.detailTab = tab }
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

/// The composer, folded away: a button in the bar at the pane's foot, which grows a word when a
/// draft waits behind it. A view of its own, so a draft being typed redraws only this.
private struct ComposeButton: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let action: () -> Void

    var body: some View {
        if model.draft(for: item.id).isEmpty {
            Button("Comment or Review", systemImage: "square.and.pencil", action: action)
        } else {
            Button(action: action) {
                Label("Draft", systemImage: "square.and.pencil").labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("Continue Draft")
        }
    }
}

/// The face of a menu in the header: what is set, on a glass capsule as tall as the round buttons.
private struct GlassMenuLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(.subheadline.weight(.medium))
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondaryText)
        }
        .padding(.horizontal, 13)
        .frame(height: RoundGlassIcon.size)
        .contentShape(Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
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
        let text = Text(
            itemTitle: item.title, shortenedTags: false, codeFont: .system(.title3, design: .monospaced).weight(.semibold),
            tagStyle: .secondaryText
        )
        return Text("\(Text("#\(String(item.number))").foregroundStyle(.secondaryText).monospacedDigit()) \(text)")
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .font(.title3.weight(.semibold))
    }

    private var people: some View {
        HStack(spacing: 6) {
            AvatarView(login: item.author, size: 18)
            LoginText(login: item.author)
                .lineLimit(1)
            BadgeIcons(login: item.author)
            StateIconView(item: item, isMerging: item.isOpen && model.board(for: item)?.triage == .merging)
            ItemStateChip(item: item)
            if let ci = item.ci {
                Button { model.checksShownFor = item.repoNumber } label: { CISummary(ci: ci).lineLimit(1) }
                    .buttonStyle(.plain)
                    .popover(isPresented: model.checksBinding(for: item)) {
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
            .foregroundStyle(.secondaryText)
            .accessibilityLabel(isExpanded ? "Show Less" : "Show More")
        }
        .font(.callout)
    }

    /// What folds away: dates and branches, the adoption, the stack, the labels and the board's
    /// Comment.
    @ViewBuilder private var more: some View {
        ItemDatesLine(item: item)

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
                .foregroundStyle(.secondaryText)
        }
    }

    // MARK: Controls

    /// Status and Priority on one row: as segments, one touch away, where they fit (an iPad);
    /// as two menus where they don't (a phone), each a glass capsule saying what is set.
    private var controls: some View {
        let onBoard = ItemMenu.isOnBoard(item, model: model)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if onBoard {
                    statusPicker(spelledOut: false).pickerStyle(.segmented).fixedSize()
                    priorityPicker(spelledOut: false).pickerStyle(.segmented).fixedSize()
                }
                Spacer(minLength: 0)
                buttons(onBoard: onBoard)
            }
            HStack(spacing: 8) {
                if onBoard {
                    Menu {
                        statusPicker(spelledOut: true).pickerStyle(.inline)
                    } label: {
                        GlassMenuLabel(text: (model.listedTriage(for: item)?.rawValue) ?? "Triage")
                    }
                    .accessibilityLabel("Status")
                    Menu {
                        priorityPicker(spelledOut: true).pickerStyle(.inline)
                    } label: {
                        GlassMenuLabel(text: model.board(for: item)?.priorityValue.map(Self.name) ?? "Priority")
                    }
                    .accessibilityLabel("Priority")
                }
                Spacer(minLength: 0)
                buttons(onBoard: onBoard)
            }
            .buttonStyle(.plain)
        }
    }

    private static func name(_ priority: Priority) -> String {
        switch priority {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    /// `spelledOut`: in a menu, where there is room for words and its title says what it sets.
    private func statusPicker(spelledOut: Bool) -> some View {
        let triage = model.triage(for: item)
        return Picker("Status", selection: model.statusBinding(for: item)) {
            Text("Triage").tag(TriageStatus?.none)
            ForEach(TriageStatus.settable, id: \.self) { status in
                if spelledOut {
                    Label(status.rawValue, systemImage: status.symbol).tag(Optional(status))
                } else {
                    Text(status.rawValue).tag(Optional(status))
                }
            }
            // Merging comes with 🚀 or from Merger; shown while the item has it, never offered.
            if triage == .merging {
                Text(TriageStatus.merging.rawValue).tag(Optional(TriageStatus.merging))
            }
        }
    }

    private func priorityPicker(spelledOut: Bool) -> some View {
        Picker("Priority", selection: model.priorityBinding(for: item)) {
            ForEach(Priority.allCases, id: \.self) { Text(spelledOut ? Self.name($0) : $0.letter).tag(Optional($0)) }
            Text(spelledOut ? "None" : "–").tag(Priority?.none)
        }
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
