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
    @State private var width: CGFloat = 0
    /// The list's own width, which as a sidebar the split view decides.
    @State private var listWidth: CGFloat = 0
    @State private var pages = DetailPages()
    @State private var showsSettings = false
    /// The menu a detail page asked for.
    @State private var pageMenu: PageMenu?

    var body: some View {
        let layout = DeskLayout(
            width: width, listWidth: listWidth, isCompact: sizeClass == .compact,
            prefersTable: width >= DeskLayout.wideMinWidth ? tableWhenWide : tableWhenNarrow,
            prefersTwoLines: rowLines == .two
        )
        Group {
            if layout.isMeasured {
                NavigationSplitView(columnVisibility: columnVisibility(layout), preferredCompactColumn: compactColumn(layout)) {
                    ListPane(density: layout.density, highlightsSelection: !layout.isListPage, showsSettings: $showsSettings)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
                        .navigationSplitViewColumnWidth(min: 400, ideal: 460, max: 480)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbar(layout) }
                } detail: {
                    DetailPane(pages: pages)
                }
                // The split view goes by the size class: told the width is compact, it is the
                // one column a phone has, with the list the whole window wide (the table).
                .environment(\.horizontalSizeClass, layout.isTable ? .compact : sizeClass)
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
        }
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
    }

    /// The split view's own button and gestures change it too.
    private func columnVisibility(_ layout: DeskLayout) -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isListShown(layout) ? .all : .detailOnly },
            // Only while the viewer is here: in the background the system lays the window out
            // at other sizes for its snapshots, and the split view, putting its sidebar away for
            // those, would write that back as if the viewer had.
            set: { if scenePhase == .active { setListShown($0 != .detailOnly, layout) } }
        )
    }

    /// The list as a table the whole window wide, or back as the detail's sidebar: kept for this
    /// kind of width. Either way the list was asked for and is there to see: as a table it is on
    /// top (the detail is pushed over it only for a selection), as a sidebar it is out.
    private func setTable(_ isTable: Bool, _ layout: DeskLayout) {
        guard !layout.isCompact else { return }
        if layout.isWide { tableWhenWide = isTable } else { tableWhenNarrow = isTable }
        if isTable {
            model.selection = nil
        } else {
            showsList = true
            showsFloatingList = true
        }
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
        ToolbarItem(placement: .topBarLeading) {
            Picker("View", selection: $model.mode) {
                Text("Dashboard").tag(AppModel.ListMode.dashboard)
                Text(model.parityWaitingCount == 0 ? "Parity" : "Parity \(model.parityWaitingCount)").tag(AppModel.ListMode.parity)
                Text(model.unreadInboxCount == 0 ? "Inbox" : "Inbox \(model.unreadInboxCount)").tag(AppModel.ListMode.inbox)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .bottomBar) { SyncStatusButton() }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            DeskMenu(
                rowLines: $rowLines, canChooseLines: layout.density.canUseOneLine,
                // Offered where the window isn't one column already.
                isTable: layout.isCompact ? nil : Binding(get: { layout.isTable }, set: { setTable($0, layout) }),
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
    /// The list as a table the whole window wide; nil where there is no such choice (a phone).
    let isTable: Binding<Bool>?
    @Binding var showsSettings: Bool

    private static let keys: [(ItemSort.Key, String)] = [
        (.updated, "Updated"), (.age, "Opened"), (.number, "Number"), (.title, "Title"), (.author, "Author"),
        (.priority, "Priority"), (.review, "Review"), (.turn, "Turn"), (.ci, "CI"), (.size, "Size"),
    ]

    var body: some View {
        @Bindable var model = model
        Menu("More", systemImage: "ellipsis") {
            if let isTable {
                Toggle("Full-Width List", systemImage: "tablecells", isOn: isTable)
            }
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
