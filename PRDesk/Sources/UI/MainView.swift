import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showsDetail = true

    var body: some View {
        @Bindable var model = model
        let items = model.visibleItems

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter", text: $model.filterText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
                Text("\(items.count) items")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()
            ItemTableView(items: items, viewer: model.viewer, selection: $model.selection)
        }
        .frame(minWidth: 640, maxHeight: .infinity)
        .inspector(isPresented: $showsDetail) {
            DetailView(item: model.selectedItem)
                .inspectorColumnWidth(min: 360, ideal: 520, max: 1000)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SyncStatusView()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Detail", systemImage: "sidebar.right") {
                    showsDetail.toggle()
                }
                .help("Show or hide the detail pane")
            }
        }
        .task { model.start() }
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
                Text("api \(rateLimit.remaining)")
                    .foregroundStyle(rateLimit.remaining < 500 ? .orange : .secondary)
                    .help("GraphQL rate limit resets \(rateLimit.resetAt.formatted(.relative(presentation: .named)))")
            }
            Button("Sync Now", systemImage: "arrow.clockwise") {
                Task { await model.sync() }
            }
            .labelStyle(.iconOnly)
            .disabled(model.syncState == .syncing)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 6)
    }
}
