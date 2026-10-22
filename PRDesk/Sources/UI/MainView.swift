import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showsDetail = true
    @State private var showsAdd = false
    @FocusState private var filterFocused: Bool

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            filterBar
            Divider()
            ItemTableView(
                rows: model.rows,
                viewer: model.viewer,
                selection: $model.selection,
                sort: model.sort,
                focusRequest: model.tableFocusRequest,
                badges: { model.affiliations.badges(for: $0) },
                contribution: { model.contribution(for: $0) },
                badgeVersion: model.affiliationsVersion + AvatarCache.shared.version,
                onAction: { model.perform($0, on: $1) },
                onSort: { model.sort = $0 },
                onToggleSection: { model.toggleCollapsed($0) },
                onFocusFilter: { model.requestFilterFocus() },
                onFocusComposer: { model.requestComposerFocus() },
                onAutoSelect: { model.autoSelect($0) }
            )
        }
        .frame(minWidth: 560, maxHeight: .infinity)
        .inspector(isPresented: $showsDetail) {
            DetailView()
                .inspectorColumnWidth(min: 360, ideal: 480, max: 1000)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.mode) {
                    Text("Dashboard").tag(AppModel.ListMode.dashboard)
                    Text(model.unreadInboxCount == 0 ? "Inbox" : "Inbox \(model.unreadInboxCount)").tag(AppModel.ListMode.inbox)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarItem(placement: .navigation) {
                Button("Add", systemImage: "plus") { showsAdd = true }
                    .help("Add a PR or issue to the board by number or URL")
                    .popover(isPresented: $showsAdd, arrowEdge: .bottom) {
                        AddItemView { showsAdd = false }
                    }
            }
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
                .help("Show or hide the detail pane")
            }
        }
        .onChange(of: model.filterFocusRequest) { filterFocused = true }
        .alert(
            "GitHub not updated",
            isPresented: Binding(get: { model.writeError != nil }, set: { if !$0 { model.writeError = nil } }),
            actions: { Button("OK") {} },
            message: { Text(model.writeError ?? "") }
        )
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
    }

    private var filterBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            TextField("Filter (/)", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 260)
                .focused($filterFocused)
                .onSubmit { model.requestTableFocus() }
                .onKeyPress(.escape) {
                    if model.filterText.isEmpty { model.requestTableFocus() } else { model.filterText = "" }
                    return .handled
                }
                .help("Text, or tokens like status:triage is:pr turn:me author:x label:x ci:fail p:h org:redhat vote:down merged:>=10 is:first")
            Spacer(minLength: 8)
            Text("j/k move · w/b/s/m working/backlog/skip/mute · 1/2/3 priority · p pin · n mark read · c comment · o open · +/- vote author")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct AddItemView: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void
    @State private var input = ""
    @State private var error: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Number or URL", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(add)
                .disabled(isAdding)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if isAdding { ProgressView().controlSize(.small) }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.isEmpty || isAdding)
            }
        }
        .padding(12)
    }

    private func add() {
        isAdding = true
        error = nil
        Task {
            do {
                try await model.addItem(input)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isAdding = false
        }
    }
}

/// The window's bottom bar, as in Finder: where the list comes from on the left, item count and
/// sync state on the right.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    private static let boardURL = URL(string: "https://github.com/orgs/\(BoardQuery.owner)/projects/\(BoardQuery.number)")!

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Text([model.viewer, SyncEngine.repo].compactMap(\.self).joined(separator: " · "))
                Text("·")
                Link("Board #\(BoardQuery.number)", destination: Self.boardURL)
                    .help("Open the triage board on GitHub")
                Spacer(minLength: 12)
                Text(model.visibleCount == 1 ? "1 item" : "\(model.visibleCount) items")
                Text("·")
                SyncStatus()
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
        }
        .background(.bar)
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
