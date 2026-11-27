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
        .background(ItemHandoff())
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
                hasLinkedPR: { model.linkedPR(of: $0) != nil },
                canSendToBot: { model.canSend($0, for: $1) },
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
                onStepInStack: { model.stepInStack($0) },
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
        .modifier(ModelAlerts())
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

    private static let shortcuts = "j/k move · w/b/s/m desk/tray/shelf/attic · 1/2/3 priority · p pin · n read/unread · a add · c comment · o open · u author profile · e 👀 investigate · f 🔥 track · r 🚀 merge · t open session"
    private static let filterHelp = "Filter with text, or tokens like status:triage is:pr turn:me author:x label:x ci:fail p:h org:redhat merged:>=10 is:first"

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
            if model.requestsStopped {
                Label(model.syncLine() ?? "", systemImage: "hand.raised.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
                    .help("GitHub's budget fell fast while PR Desk sent many requests, as a loop would: nothing is sent until you resume.")
                Button("Resume") { model.resumeRequests() }
                    .buttonStyle(.link)
            } else {
                switch model.syncState {
                case .syncing:
                    ProgressView().controlSize(.mini)
                    Text(model.syncLine() ?? "")
                case let .failed(message):
                    Label(model.syncLine() ?? "", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                        .help(message)
                case .rateLimited:
                    Label(model.syncLine() ?? "", systemImage: "hourglass")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                        .help("GitHub refused a sync for its GraphQL budget. The next one waits until then; ⌘R and what you do are still tried.")
                case .idle:
                    if model.lastSyncedAt != nil {
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            Text(model.syncLine(at: context.date) ?? "")
                        }
                    }
                }
            }
            if let rateLimit = model.rateLimit, !model.syncState.isRateLimited, !model.requestsStopped {
                Text("·")
                Text("API quota \(rateLimit.remaining.formatted()) left")
                    .foregroundStyle(rateLimit.remaining < 500 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help("GitHub GraphQL points left this hour; resets \(rateLimit.resetAt.formatted(.relative(presentation: .named))). Below 500, syncing slows down.")
            }
        }
    }
}
