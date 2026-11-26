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

/// The desk: the list as the sidebar of a split view, and the selected item's detail beside it
/// where the window is wide enough or pushed over it where it isn't (`DeskLayout`). Beside the
/// detail the list can be put away, as any sidebar. The selection is the model's, so every
/// arrangement shows the same thing and nothing remembers which one came before.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DeskLayout.showsListKey) private var showsList = true
    @AppStorage(RowLines.key) private var rowLines = RowLines.two
    @State private var width: CGFloat = 0
    /// The list's own width, which the split view decides beside the detail.
    @State private var listWidth: CGFloat = 0
    @State private var pages = DetailPages()
    @State private var showsSettings = false
    /// The menu a detail page asked for.
    @State private var pageMenu: PageMenu?

    var body: some View {
        let layout = DeskLayout(width: width, listWidth: listWidth, showsList: showsList, prefersTwoLines: rowLines == .two)
        Group {
            if layout.isMeasured {
                NavigationSplitView(columnVisibility: columnVisibility, preferredCompactColumn: compactColumn) {
                    ListPane(density: layout.density, highlightsSelection: layout.isSplit, showsSettings: $showsSettings)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
                        .navigationSplitViewColumnWidth(min: 400, ideal: 460, max: 480)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbar(layout) }
                } detail: {
                    DetailPane(pages: pages, isPushed: !layout.isSplit)
                }
                .navigationSplitViewStyle(.balanced)
                // The split view goes by the size class: narrower than the desk splits at, it is
                // to be one column whatever the device calls the width (an iPad mini upright).
                .environment(\.horizontalSizeClass, layout.isSplit ? .regular : .compact)
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
            if !showsList { withAnimation { showsList = true } }
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

    /// The list beside the detail, or put away: the viewer's choice, which the split view's own
    /// button and gestures change too.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { showsList ? .all : .detailOnly },
            set: { showsList = $0 != .detailOnly }
        )
    }

    /// In one column, the detail is on top while there is a selection; going back drops it.
    private var compactColumn: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { model.selection == nil ? .sidebar : .detail },
            set: { if $0 == .sidebar { model.selection = nil } }
        )
    }

    /// Around the list: which list it is at its head (beside the split view's own button for
    /// putting it away), and at its foot how things stand, the filter and the desk's menu.
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
        // On a phone the status shows only with news: a write, or a sync that isn't idle.
        let isBrief = !layout.density.canUseOneLine
        if !isBrief || model.activity != nil || model.syncState != .idle {
            ToolbarItem(placement: .status) { StatusLine(isBrief: isBrief) }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            DeskMenu(rowLines: $rowLines, canChooseLines: layout.density.canUseOneLine, showsSettings: $showsSettings)
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
                Button("Sync Now", systemImage: "arrow.clockwise") {
                    Task { await model.sync() }
                }
                .disabled(model.syncState == .syncing)
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
    }
}
