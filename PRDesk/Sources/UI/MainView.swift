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
                    .help("Track a PR or issue by number or URL")
                    .popover(isPresented: $showsAdd, arrowEdge: .bottom) {
                        AddItemView { showsAdd = false }
                    }
            }
            // Status is information, not a control, so it sits without the glass capsule.
            ToolbarItem(placement: .primaryAction) {
                SyncStatusView()
            }
            .sharedBackgroundVisibility(.hidden)
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
                .help("Text, or tokens like is:pr turn:me author:x label:x ci:fail p:h org:redhat is:untracked")
            Text("\(model.visibleCount) items")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("j/k move · 1/2/3 priority · p pin · d drop from focus · n mark read · c comment · o open · u untrack · +/- vote author")
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

private struct SyncStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text([model.viewer, SyncEngine.repo].compactMap(\.self).joined(separator: " · "))
                .foregroundStyle(.secondary)
            switch model.syncState {
            case .syncing:
                Text("syncing…").foregroundStyle(.secondary)
            case let .failed(message):
                Label("sync failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
                    .help(message)
            case .idle:
                if let last = model.lastSyncedAt {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        Text("synced \(last.compactAge(relativeTo: context.date))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let rateLimit = model.rateLimit {
                Text("api \(String(rateLimit.remaining))")
                    .foregroundStyle(rateLimit.remaining < 500 ? .orange : .secondary)
                    .help("GraphQL rate limit resets \(rateLimit.resetAt.formatted(.relative(presentation: .named)))")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 6)
    }
}
