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
/// or pushed over it where it isn't (`DeskLayout`). The selection is the model's, so the two
/// arrangements show the same thing and nothing remembers which one came before.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("prefersSplit") private var prefersSplit = true
    @State private var width: CGFloat = 0
    @State private var pages = DetailPages()
    @State private var showsSettings = false

    var body: some View {
        let layout = DeskLayout(width: width, prefersSplit: prefersSplit)
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
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .modifier(ModelAlerts())
        .onAppear {
            // Start WebKit ahead of the first selection, and open the repository's own links here.
            _ = pages.timeline.webView
            for page in pages.all {
                page.openItem = { [model] repo, number in model.openItem(repo: repo, number: number) }
            }
            pages.timeline.toggleReaction = { [model] content, subject in model.toggleReaction(content, on: subject) }
        }
    }

    private func panes(_ layout: DeskLayout) -> some View {
        HStack(spacing: 0) {
            ListPane(density: layout.density, highlightsSelection: layout.isSplit, showsSettings: $showsSettings)
                .frame(width: layout.isSplit ? layout.listWidth : nil)
            if layout.isSplit {
                Divider().ignoresSafeArea()
                DetailPane(pages: pages, isPushed: false)
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
        // Over the list, whichever way the window is laid out.
        ToolbarItem(placement: .topBarLeading) {
            Picker("View", selection: $model.mode) {
                Text("Dashboard").tag(AppModel.ListMode.dashboard)
                Text(model.parityWaitingCount == 0 ? "Parity" : "Parity \(model.parityWaitingCount)").tag(AppModel.ListMode.parity)
                Text(model.unreadInboxCount == 0 ? "Inbox" : "Inbox \(model.unreadInboxCount)").tag(AppModel.ListMode.inbox)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        if layout.canSplit {
            ToolbarItem(placement: .topBarTrailing) {
                Button(prefersSplit ? "Hide Detail" : "Show Detail", systemImage: "sidebar.right") {
                    prefersSplit.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)
            }
            .visibilityPriority(.high)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Sync Now", systemImage: "arrow.clockwise") {
                Task { await model.sync() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.syncState == .syncing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { showsSettings = true }
        }
        .visibilityPriority(.low)
    }
}
