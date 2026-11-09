import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showsDetail") private var showsDetail = true
    /// The window's content width, which caps the detail pane.
    @State private var width: CGFloat = 0

    private static let listMinWidth: CGFloat = 560
    private static let detailMinWidth: CGFloat = 360

    /// The widest the detail pane may get: what leaves the list its minimum. A fixed maximum lets a
    /// drag of the divider past the list's minimum widen the window instead.
    private var detailMaxWidth: CGFloat {
        guard width > 0 else { return 1000 }
        return min(1000, max(Self.detailMinWidth, width - Self.listMinWidth - 1))
    }

    var body: some View {
        // The status bar sits under the whole split view, so neither the list nor the detail pane
        // runs beneath it.
        VStack(spacing: 0) {
            content
            StatusBar()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var content: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            ItemTableView(
                rows: model.rows,
                isParity: model.mode == .parity,
                viewer: model.viewer,
                selection: $model.selection,
                sort: model.sort,
                focusRequest: model.tableFocusRequest,
                badges: { model.affiliations.badges(for: $0) },
                contribution: { model.contribution(for: $0) },
                affiliationMenu: { AffiliationMenu.make(for: $0, model: model) },
                badgeVersion: model.affiliationsVersion + AvatarCache.shared.version,
                onAction: { model.perform($0, on: $1) },
                onSort: { model.sort = $0 },
                onToggleSection: { model.toggleCollapsed($0) },
                onFocusFilter: { model.requestFilterFocus() },
                onFocusComposer: { model.requestComposerFocus() },
                onClearFilter: {
                    guard !model.filterText.isEmpty else { return false }
                    model.filterText = ""
                    return true
                },
                onAutoSelect: { model.autoSelect($0) },
                onOpenLink: { model.open($0) },
                listUndoManager: model.undoManager
            )
        }
        .frame(minWidth: Self.listMinWidth, maxHeight: .infinity)
        .inspector(isPresented: $showsDetail) {
            DetailView(isShown: showsDetail)
                .inspectorColumnWidth(min: Self.detailMinWidth, ideal: 480, max: detailMaxWidth)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.mode) {
                    Text("Dashboard").tag(AppModel.ListMode.dashboard)
                    Text(model.parityWaitingCount == 0 ? "Parity" : "Parity \(model.parityWaitingCount)").tag(AppModel.ListMode.parity)
                    Text(model.unreadInboxCount == 0 ? "Inbox" : "Inbox \(model.unreadInboxCount)").tag(AppModel.ListMode.inbox)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // The filter and the list's own action, at the right end of the list's part of the
            // toolbar rather than over the detail pane.
            ToolbarItem(placement: .primaryAction) {
                FilterField(
                    text: $model.filterText,
                    prompt: "Filter (/)",
                    focusRequest: model.filterFocusRequest,
                    onDone: { if !model.submitFilter() { model.requestTableFocus() } }
                )
            }
            // Its own capsule, so Sync doesn't read as part of the field.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Sync Now", systemImage: "arrow.clockwise") {
                    Task { await model.sync() }
                }
                .help("Sync now (⌘R)")
                .disabled(model.syncState == .syncing)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Detail", systemImage: "sidebar.right") {
                    showsDetail.toggle()
                }
                .help("Show or hide the detail pane (⌘B)")
            }
        }
        .alert(
            "GitHub not updated",
            isPresented: Binding(get: { model.writeError != nil }, set: { if !$0 { model.writeError = nil } }),
            actions: { Button("OK") {} },
            message: { Text(model.writeError ?? "") }
        )
        .alert(
            "Grok Bot not reached",
            isPresented: Binding(get: { model.botError != nil }, set: { if !$0 { model.botError = nil } }),
            actions: { Button("OK") {} },
            message: { Text(model.botError ?? "") }
        )
        .alert(
            "Not opened",
            isPresented: Binding(get: { model.linkError != nil }, set: { if !$0 { model.linkError = nil } }),
            actions: { Button("OK") {} },
            message: { Text(model.linkError ?? "") }
        )
        .sheet(item: Binding(get: { model.pendingBotSend }, set: { model.pendingBotSend = $0 })) { pending in
            BotSendSheet(pending: pending)
        }
        .task {
            #if DEBUG
                // `-PRDeskAppearance dark|light` forces an appearance, for checking both without
                // changing the system setting.
                if let name = UserDefaults.standard.string(forKey: "PRDeskAppearance") {
                    NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
                }
            #endif
            model.start()
        }
        .onAppear {
            // The window may be closed when the shortcut comes from Yab.
            model.showWindow = { [openWindow] in
                openWindow(id: "main")
                NSApp.activate()
            }
            GlobalHotKey.register(GlobalHotKey.showBrowserTab) { [model] in model.showBrowserTab() }
        }
    }
}

/// The window's bottom bar, as in Finder: where the list comes from on the left, item count and
/// sync state on the right.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    static let height: CGFloat = 22

    private static let shortcuts = "j/k move · w/b/s/m working/backlog/skip/mute · 1/2/3 priority · p pin · n read/unread · a add · c comment · o open · u author profile · +/- vote author · e 👀 investigate · f 🔥 track · r 🚀 merge · t open session"
    private static let filterHelp = "Filter with text, or tokens like status:triage is:pr turn:me author:x label:x ci:fail p:h org:redhat vote:down merged:>=10 is:first"

    private static let boardURL = URL(string: "https://github.com/orgs/\(BoardQuery.owner)/projects/\(BoardQuery.number)")!

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                // The latest write while it is under way and just after; otherwise the shortcuts,
                // which give way first when the window is narrow.
                ZStack(alignment: .leading) {
                    if let activity = model.activity {
                        ActivityLine(activity: activity)
                            .id(activity.id)
                            .transition(.opacity)
                    } else {
                        Text(Self.shortcuts)
                            .foregroundStyle(.tertiary)
                            .truncationMode(.tail)
                            .help(Self.filterHelp)
                            .transition(.opacity)
                    }
                }
                .layoutPriority(-1)
                .animation(.easeInOut(duration: 0.25), value: model.activity)
                Spacer(minLength: 12)
                Text([model.viewer, model.mode == .parity ? "\(Parity.repo) → \(SyncEngine.repo)" : SyncEngine.repo].compactMap(\.self).joined(separator: " · "))
                Text("·")
                Link("Board #\(BoardQuery.number)", destination: Self.boardURL)
                    .help("Open the triage board on GitHub")
                Text("·")
                Text(model.visibleCount == 1 ? "1 item" : "\(model.visibleCount) items")
                Text("·")
                SyncStatus()
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: Self.height)
        }
        .background(.bar)
    }
}

/// A write in the status bar: a spinner while it is under way, a check once it is done.
private struct ActivityLine: View {
    let activity: AppModel.Activity

    var body: some View {
        HStack(spacing: 5) {
            // Spinner and check share one slot and cross-fade.
            ZStack {
                if activity.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.mini)
                        .transition(.opacity)
                }
            }
            .frame(width: 12)
            // Dimmed by opacity rather than .secondary: hierarchical styles switch without animating.
            Text(activity.text)
                .foregroundStyle(.primary)
                .opacity(activity.isDone ? 0.6 : 1)
                .truncationMode(.tail)
        }
    }
}

private struct SyncStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.syncState {
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case let .failed(message):
                Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
                    .help(message)
            case .idle:
                if let last = model.lastSyncedAt {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let age = last.compactAge(relativeTo: context.date)
                        Text(age == "now" ? "Synced just now" : "Synced \(age) ago")
                    }
                }
            }
            if let rateLimit = model.rateLimit {
                Text("·")
                Text("API quota \(rateLimit.remaining.formatted()) left")
                    .foregroundStyle(rateLimit.remaining < 500 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help("GitHub GraphQL points left this hour; resets \(rateLimit.resetAt.formatted(.relative(presentation: .named))). Below 500, syncing slows down.")
            }
        }
    }
}
