import SwiftUI

/// The detail's web pages, kept above the panes: a layout change rebuilds the detail, and the
/// pages (their web views, scroll positions and loaded diffs) must outlive it.
@MainActor
final class DetailPages {
    let timeline = WebDocument(kind: .timeline)
    let files = WebDocument(kind: .files)
    let commits = WebDocument(kind: .files)
    var all: [WebDocument] { [timeline, files, commits] }
}

/// The desk, always a split view: the list is the detail's sidebar, beside it or floating over
/// it, and on a phone a page the detail is pushed over (`DeskLayout`). The selection is
/// the model's, so every arrangement shows the same thing and nothing remembers which one came
/// before.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(DeskLayout.showsListKey) private var showsList = true
    @AppStorage(DeskLayout.tableWideKey) private var tableWhenWide = false
    @AppStorage(DeskLayout.tableNarrowKey) private var tableWhenNarrow = false
    @AppStorage(RowLines.key) private var rowLines = RowLines.two
    /// The sidebar floating over the detail is out. Kept with the scene, so it comes back as it
    /// was when the system has put the app away and starts it again.
    @SceneStorage("showsFloatingList") private var showsFloatingList = false
    @Environment(\.scenePhase) private var scenePhase
    /// What the split view shows of its columns. The system writes it too, when the window
    /// changes (it puts a sidebar away for a narrower window, or coming out of one column), and
    /// it does so before the desk sees the window change. So it is real state that both set; a
    /// write counts as the viewer's choice only if the window stays as it is for a moment after
    /// it (`columnVisibility`), and after a change the desk puts the viewer's choice back
    /// (`settle`).
    @State private var visibility = NavigationSplitViewVisibility.all
    /// Counts the window's rearrangements, to tell whether one came after a write.
    @State private var rearrangements = 0
    /// The list switcher shows the lists' names; nil until first laid out. Its own state, behind
    /// the layout's: going to full width the switcher is first as it was, then opens out, so
    /// the bar's head is the same across the change (`wantsNames`).
    @State private var switcherShowsNames: Bool?
    @Environment(\.dynamicTypeSize) private var textSize
    /// Set for a moment to have the split view take the compact width again (`settle`).
    @State private var renewsCompact = false
    /// The detail's column is on screen.
    @State private var detailHasAppeared = false
    @State private var width: CGFloat = 0
    /// The list's own width, which as a sidebar the split view decides.
    @State private var listWidth: CGFloat = 0
    @State private var pages = DetailPages()
    @State private var showsSettings = false
    /// The menu a detail page asked for.
    @State private var pageMenu: PageMenu?

    private var layout: DeskLayout {
        DeskLayout(
            width: width, listWidth: listWidth, isCompact: sizeClass == .compact,
            prefersTable: width >= DeskLayout.wideMinWidth ? tableWhenWide : tableWhenNarrow,
            prefersTwoLines: rowLines == .two
        )
    }

    /// The ways the desk is arranged, between which the system rearranges the split view.
    private enum Arrangement: Hashable {
        case page, floating, beside
    }

    private var arrangement: Arrangement {
        let layout = layout
        return layout.isListPage ? .page : layout.listFloats ? .floating : .beside
    }

    var body: some View {
        let layout = layout
        Group {
            if layout.isMeasured {
                NavigationSplitView(columnVisibility: columnVisibility, preferredCompactColumn: compactColumn(layout)) {
                    ListPane(density: layout.density, highlightsSelection: !layout.isListPage, showsSettings: $showsSettings)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
                        .navigationSplitViewColumnWidth(min: 400, ideal: 460, max: 480)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbar(layout) }
                } detail: {
                    DetailPane(pages: pages)
                        .onAppear { detailHasAppeared = true }
                        .onDisappear { detailHasAppeared = false }
                }
                // The split view goes by the size class: told the width is compact, it is the
                // one column a phone has, with the list the whole window wide (the table).
                .environment(\.horizontalSizeClass, layout.isTable && !renewsCompact ? .compact : sizeClass)
            } else {
                Color.clear
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .popover(item: $pageMenu, attachmentAnchor: .rect(.rect(pageMenu?.anchor ?? .zero))) { menu in
            PageMenuView(menu: menu).environment(model)
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .modifier(ModelAlerts())
        // The filter is the list's: asked for by key while the list is away, it comes back.
        .onChange(of: model.filterFocusRequest) {
            withAnimation { setListShown(true, layout) }
        }
        // An item picked from the list floating over the detail: the list has done its part.
        .onChange(of: model.selection) {
            if layout.listFloats, model.selection != nil { showsFloatingList = false }
            showChosenColumns()
        }
        // The window is arranged another way (turned, resized), or the app is back in front:
        // the system has had its say about the columns, and the viewer's choice goes back in.
        .onChange(of: arrangement, initial: true) { settle() }
        .task(id: [layout.isMeasured, wantsNames(layout)]) {
            let wanted = wantsNames(layout)
            guard layout.isMeasured else { return }
            // Names go at once (the bar they were in may be gone), and at first there is
            // nothing to come from. They come once the window has changed its layout.
            guard wanted, switcherShowsNames != nil else { return switcherShowsNames = wanted }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            switcherShowsNames = true
        }
        .onChange(of: scenePhase) { if scenePhase == .active { settle() } }
        .focusedSceneValue(\.deskActions, DeskActions(
            toggleList: { withAnimation { setListShown(!isListShown(layout), layout) } },
            toggleTable: { setTable(!layout.isTable, layout) }
        ))
        .onAppear {
            // Start WebKit ahead of the first selection, and open the repository's own links here.
            _ = pages.timeline.webView
            for page in pages.all {
                page.openItem = { [model] repo, number in model.openItem(repo: repo, number: number) }
                page.menuHandler = { request, point in
                    pageMenu = PageMenu(request: request, point: point, page: page)
                }
            }
            pages.timeline.toggleReaction = { [model] content, subject in model.toggleReaction(content, on: subject) }
        }
    }

    // MARK: The list as a sidebar

    /// Beside the detail the sidebar stays as the viewer left it; floating over it, it is out
    /// while asked for, and while there is nothing selected to look at instead.
    private func isListShown(_ layout: DeskLayout) -> Bool {
        layout.listFloats ? showsFloatingList || model.selection == nil : showsList
    }

    private func setListShown(_ shown: Bool, _ layout: DeskLayout) {
        guard !layout.isListPage else { return }
        if layout.listFloats { showsFloatingList = shown } else { showsList = shown }
        showChosenColumns()
    }

    /// Puts the columns as the viewer chose them.
    private func showChosenColumns() {
        let layout = layout
        guard !layout.isListPage else { return }
        let chosen: NavigationSplitViewVisibility = isListShown(layout) ? .all : .detailOnly
        if visibility != chosen { visibility = chosen }
    }

    /// The split view's own button and gestures change it, and that is the viewer's choice:
    /// kept, unless the window is rearranged right after (the write was the system's, making
    /// ready for that) or the app isn't in front (the system lays the window out at other sizes
    /// for its snapshots).
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { visibility },
            set: { shown in
                visibility = shown
                let before = rearrangements
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    let layout = layout
                    guard rearrangements == before, scenePhase == .active, visibility == shown, !layout.isListPage else { return }
                    if layout.listFloats { showsFloatingList = shown != .detailOnly } else { showsList = shown != .detailOnly }
                }
            }
        )
    }

    /// After the window was rearranged (turned, resized, back in front): once the split view
    /// has come to rest, the columns go back to what the viewer chose.
    ///
    /// As a page with nothing selected, the list should be what shows. Where the detail shows
    /// instead, the split view has lost the compact width the page asks for (seen on a device
    /// turned upright, where UIKit seems to hand the window's own width class down again): the
    /// width is taken away for a moment and given again.
    private func settle() {
        rearrangements += 1
        showChosenColumns()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            showChosenColumns()
            if layout.isTable, model.selection == nil, detailHasAppeared {
                renewsCompact = true
                try? await Task.sleep(for: .milliseconds(60))
                renewsCompact = false
            }
        }
    }

    /// The lists by name in the bar: where the list has the window, and the window the room (a
    /// phone has it at ordinary text sizes).
    private func wantsNames(_ layout: DeskLayout) -> Bool {
        layout.isListPage && (layout.width >= 600 || textSize <= .large)
    }

    /// The list as a table the whole window wide, or back as the detail's sidebar: kept for this
    /// kind of width. Either way the list was asked for and is there to see: as a table it is on
    /// top (the detail is pushed over it only for a selection), as a sidebar it is out.
    private func setTable(_ isTable: Bool, _ layout: DeskLayout) {
        guard !layout.isCompact else { return }
        // The bar's head stays as it is across the change: going to the sidebar, whose bar has
        // no room for names, the switcher folds its names away first (it opens them, going
        // the other way, once the change is made).
        guard isTable || switcherShowsNames != true else {
            switcherShowsNames = false
            Task { @MainActor in
                // A moment for the bar to lay the shorter switcher out.
                try? await Task.sleep(for: .milliseconds(80))
                setTable(isTable, self.layout)
            }
            return
        }
        dissolveWindow()
        if layout.isWide { tableWhenWide = isTable } else { tableWhenNarrow = isTable }
        if isTable {
            model.selection = nil
        } else {
            showsList = true
            showsFloatingList = true
        }
    }

    /// The split view goes from one column to two and back at once, whatever animation the
    /// change is made with (it is UIKit's, rebuilding its columns). So the window dissolves from
    /// how it looked to how it looks: a transition on its layer, which takes in whatever this
    /// turn of the run loop changes.
    private func dissolveWindow() {
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
        guard let window = windows.first, !UIAccessibility.isReduceMotionEnabled else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.28
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        window.layer.add(transition, forKey: "deskLayout")
    }

    /// In one column, the detail is on top while there is a selection; going back drops it.
    /// Only there: as a sidebar the list isn't a column to go back to, and what the split view
    /// writes then (it does, after having been one column) must not cost the selection.
    private func compactColumn(_ layout: DeskLayout) -> Binding<NavigationSplitViewColumn> {
        Binding(
            get: { model.selection == nil ? .sidebar : .detail },
            set: { if $0 == .sidebar, layout.isListPage { model.selection = nil } }
        )
    }

    /// Around the list: which list it is at its head (beside the split view's own button for
    /// putting it away), and at its foot how things stand with GitHub (a button), the filter and
    /// the desk's menu.
    @ToolbarContentBuilder
    private func toolbar(_ layout: DeskLayout) -> some ToolbarContent {
        @Bindable var model = model
        // The segments are glass themselves: no second sheet of it behind them.
        // One item, so one capsule of the bar's glass around the three lists.
        ToolbarItem(placement: .topBarLeading) {
            let names = switcherShowsNames ?? wantsNames(layout)
            ListTabBar(
                selection: $model.mode, parityCount: model.parityWaitingCount, inboxCount: model.unreadInboxCount,
                showsNames: names
            )
        }
        .sharedBackgroundVisibility(.hidden)
        // Where the window isn't one column already: the filter, then the list the whole window
        // wide or back beside the detail, next to the split view's own button for the sidebar
        // (the two are about where the list is). The filter is placed here by name, with a
        // spacer: left to the system it joins whatever is at the bar's end.
        if !layout.isCompact {
            DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    layout.isTable ? "List Beside the Detail" : "Full-Width List",
                    systemImage: layout.isTable ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                ) { setTable(!layout.isTable, layout) }
            }
        }
        ToolbarItem(placement: .bottomBar) { SyncStatusButton() }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if layout.isCompact {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            DeskMenu(
                rowLines: $rowLines, canChooseLines: layout.density.canUseOneLine,
                showsSettings: $showsSettings
            )
        }
    }
}

/// What the menu bar's commands ask of the desk's window, whose layout only it knows.
struct DeskActions {
    /// Shows the list as a sidebar, or puts it away.
    var toggleList: () -> Void
    /// The list as a table the whole window wide, or back as the sidebar.
    var toggleTable: () -> Void
}

extension FocusedValues {
    @Entry var deskActions: DeskActions?
}

/// Whether a row takes one line, as on the Mac, or two.
enum RowLines: Int {
    case one = 1, two = 2
    static let key = "rowLines"
}

/// The desk's own menu: how the list is shown (the rows' lines, and the order within a section,
/// which the column titles also set where rows have them), and the settings.
private struct DeskMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var rowLines: RowLines
    /// The list is wide enough for rows of one line; a phone's never is, and isn't offered them.
    let canChooseLines: Bool
    @Binding var showsSettings: Bool

    private static let keys: [(ItemSort.Key, String)] = [
        (.updated, "Updated"), (.age, "Opened"), (.number, "Number"), (.title, "Title"), (.author, "Author"),
        (.priority, "Priority"), (.review, "Review"), (.turn, "Turn"), (.ci, "CI"), (.size, "Size"),
    ]

    var body: some View {
        @Bindable var model = model
        Menu("More", systemImage: "ellipsis") {
            if canChooseLines {
                Picker("Rows", selection: $rowLines) {
                    Label("Two Lines", systemImage: "rectangle.grid.1x2").tag(RowLines.two)
                    Label("One Line", systemImage: "list.dash").tag(RowLines.one)
                }
            }
            Picker("Sort By", selection: $model.sort.key) {
                ForEach(Self.keys, id: \.0) { key, name in Text(name).tag(key) }
            }
            .pickerStyle(.menu)
            Picker("Order", selection: $model.sort.ascending) {
                Label("Descending", systemImage: "arrow.down").tag(false)
                Label("Ascending", systemImage: "arrow.up").tag(true)
            }
            Section {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
    }
}
