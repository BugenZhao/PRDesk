import SwiftUI

/// One tab's list: the model's sections for `mode`, as on the Mac, with headers that fold.
/// Tapping a row selects it, which opens it (viewed, read) and pushes its detail.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    let mode: AppModel.ListMode
    @State private var showsSettings = false

    private struct SectionRows: Identifiable {
        let section: ListSection
        let count: Int
        let collapsed: Bool
        let inParity: Int
        var rows: [ItemRow] = []
        var id: ListSection { section }
    }

    /// The model's flat rows (headers, then their items) as sections.
    private var sections: [SectionRows] {
        var sections: [SectionRows] = []
        for row in model.rows {
            switch row {
            case let .header(section, count, collapsed, inParity):
                sections.append(SectionRows(section: section, count: count, collapsed: collapsed, inParity: inParity))
            case let .item(_, item):
                if !sections.isEmpty { sections[sections.count - 1].rows.append(item) }
            }
        }
        return sections
    }

    /// Pushes the detail while this tab's own list has the selection; the tabs share the model's.
    private var selection: Binding<TableSelection?> {
        Binding(
            get: { model.mode == mode ? model.selection : nil },
            set: { if $0 == nil, model.mode == mode { model.selection = nil } }
        )
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                ForEach(sections) { group in
                    Section {
                        if !group.collapsed {
                            ForEach(group.rows, id: \.item.id) { row in
                                Button {
                                    model.selection = TableSelection(section: group.section, itemID: row.item.id)
                                } label: {
                                    ItemRowView(row: row)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(row.priority.map { $0.rowTint } ?? Color(uiColor: .secondarySystemGroupedBackground))
                                .swipeActions(edge: .leading) {
                                    Button(row.insight.isUnread ? "Read" : "Unread", systemImage: row.insight.isUnread ? "envelope.open" : "envelope.badge") {
                                        model.perform(.toggleRead, on: row.item.id)
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin") {
                                        model.perform(.togglePin, on: row.item.id)
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                    } header: {
                        Button {
                            model.toggleCollapsed(group.section)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                                Text(group.section.title)
                                Text(String(group.count)).foregroundStyle(.secondary)
                                if group.inParity > 0 {
                                    Text("(+\(group.inParity) in Parity)").foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.filterText, prompt: "Filter")
            .refreshable { await model.sync() }
            .navigationDestination(item: selection) { _ in
                ItemDetailScreen()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SyncStatus()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsScreen() }
            .overlay {
                if model.rows.isEmpty, model.syncState == .syncing {
                    ProgressView("Syncing…")
                }
            }
        }
    }
}

/// When the last sync finished, or that one is running or failed.
private struct SyncStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.syncState {
            case .syncing:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .idle:
                if let at = model.lastSyncedAt {
                    Text(at.compactAge()).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }
}

extension AppModel.ListMode {
    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .parity: "Parity"
        case .inbox: "Inbox"
        }
    }
}

extension Priority {
    /// The row's background, as the Mac list tints by priority: H light orange, M light yellow.
    var rowTint: Color {
        switch self {
        case .high: Color.orange.opacity(0.16)
        case .medium: Color.yellow.opacity(0.16)
        case .low: Color(uiColor: .secondarySystemGroupedBackground)
        }
    }
}
