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

/// The desk: the list, and the selected item's detail beside it where the window is wide enough
/// or pushed over it where it isn't (`DeskLayout`). Beside the detail the list can be put away,
/// as a sidebar is. The selection is the model's, so every arrangement shows the same thing and
/// nothing remembers which one came before.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DeskLayout.showsListKey) private var showsList = true
    @AppStorage(RowLines.key) private var rowLines = RowLines.two
    @State private var width: CGFloat = 0
    @State private var pages = DetailPages()
    @State private var showsSettings = false
    /// The menu a detail page asked for.
    @State private var pageMenu: PageMenu?

    var body: some View {
        let layout = DeskLayout(width: width, showsList: showsList, prefersTwoLines: rowLines == .two)
        NavigationStack {
            Group {
                if layout.isMeasured {
                    panes(layout)
                } else {
                    Color.clear
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: pushed(layout)) { _ in
                DetailPane(pages: pages, isPushed: true)
            }
            .toolbar { toolbar(layout) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .popover(item: $pageMenu, attachmentAnchor: .rect(.rect(pageMenu?.anchor ?? .zero))) { menu in
            PageMenuView(menu: menu).environment(model)
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .modifier(ModelAlerts())
        // The filter is the list's: asked for by key while the list is away, it comes back.
        .onChange(of: model.filterFocusRequest) {
            if !showsList { withAnimation(.snappy(duration: 0.3)) { showsList = true } }
        }
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

    private func panes(_ layout: DeskLayout) -> some View {
        HStack(spacing: 0) {
            if !layout.isListHidden {
                ListPane(density: layout.density, highlightsSelection: layout.isSplit, showsSettings: $showsSettings)
                    .frame(width: layout.isSplit ? layout.listWidth : nil)
                    .transition(.move(edge: .leading))
            }
            if layout.isSplit {
                if !layout.isListHidden { Divider().ignoresSafeArea() }
                DetailPane(pages: pages, isPushed: false, isAlone: layout.isListHidden)
            }
        }
    }

    /// The pushed detail, only where the layout pushes: side by side there is nothing to pop.
    private func pushed(_ layout: DeskLayout) -> Binding<TableSelection?> {
        Binding(
            get: { layout.isMeasured && !layout.isSplit ? model.selection : nil },
            set: { if $0 == nil, layout.isMeasured, !layout.isSplit { model.selection = nil } }
        )
    }

    @ToolbarContentBuilder
    private func toolbar(_ layout: DeskLayout) -> some ToolbarContent {
        @Bindable var model = model
        // The list's end of the bar: the way to put it away, and which list it is.
        if layout.isSplit {
            ToolbarItem(placement: .topBarLeading) {
                Button(showsList ? "Hide List" : "Show List", systemImage: "sidebar.leading") {
                    withAnimation(.snappy(duration: 0.3)) { showsList.toggle() }
                }
            }
        }
        if !layout.isListHidden {
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
        }
        if !layout.isListHidden, layout.showsFilterInBar {
            // The filter, apart from the menu.
            DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            DeskMenu(rowLines: $rowLines, showsSettings: $showsSettings)
        }
    }
}

/// Whether a row takes one line, as on the Mac, or two.
enum RowLines: Int {
    case one = 1, two = 2
    static let key = "rowLines"
}

/// The desk's own menu: how the list is shown (the rows' lines, and the order within a section,
/// which the column titles also set where rows have them), syncing, and the settings. Pulling the
/// list down syncs too.
private struct DeskMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var rowLines: RowLines
    @Binding var showsSettings: Bool

    private static let keys: [(ItemSort.Key, String)] = [
        (.updated, "Updated"), (.age, "Opened"), (.number, "Number"), (.title, "Title"), (.author, "Author"),
        (.priority, "Priority"), (.review, "Review"), (.turn, "Turn"), (.ci, "CI"), (.size, "Size"),
    ]

    var body: some View {
        @Bindable var model = model
        Menu("More", systemImage: "ellipsis") {
            Picker("Rows", selection: $rowLines) {
                Label("Two Lines", systemImage: "rectangle.grid.1x2").tag(RowLines.two)
                Label("One Line", systemImage: "list.dash").tag(RowLines.one)
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
                Button("Sync Now", systemImage: "arrow.clockwise") {
                    Task { await model.sync() }
                }
                .disabled(model.syncState == .syncing)
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
    }
}
