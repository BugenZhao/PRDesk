import SwiftUI

/// The list side of the desk: the filter, column titles where the rows have columns, the rows in
/// their sections, and the status line underneath.
struct ListPane: View {
    @Environment(AppModel.self) private var model
    let density: RowDensity
    /// Side by side with the detail, the selected row stays marked.
    let highlightsSelection: Bool
    @Binding var showsSettings: Bool
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !density.usesTwoLines {
                ColumnTitles(density: density, isParity: model.mode == .parity, sort: $model.sort)
                Divider()
            }
            ItemListView(density: density, highlightsSelection: highlightsSelection)
                .overlay { emptyState }
                // Over the list's foot rather than under it, so the rows run to the window's edge.
                // On a phone it shows only with news: a write, or a sync that isn't idle.
                .overlay(alignment: .bottomLeading) {
                    if density.listWidth >= 450 || model.activity != nil || model.syncState != .idle {
                        StatusLine(isBrief: density.listWidth < 450)
                            .padding(.leading, 10)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    }
                }
        }
        .searchable(text: $model.filterText, prompt: "Filter")
        .searchFocused($isFilterFocused)
        .onChange(of: model.filterFocusRequest) { isFilterFocused = true }
        // Where the field would be a bar under the list (a phone), it is a button until used.
        .searchToolbarBehavior(.minimize)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    /// Why the list is empty, when it is: nothing synced yet, or no way to.
    @ViewBuilder private var emptyState: some View {
        if model.rows.isEmpty {
            switch model.syncState {
            case .syncing:
                ProgressView("Syncing…")
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn't Sync", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Settings") { showsSettings = true }
                    Button("Try Again") { Task { await model.sync() } }
                }
            default:
                EmptyView()
            }
        }
    }
}

/// The rows, grouped under headers that fold. A row selects its item, which opens it (viewed,
/// read): beside the list where there is room, pushed over it otherwise.
struct ItemListView: View {
    @Environment(AppModel.self) private var model
    let density: RowDensity
    let highlightsSelection: Bool
    /// The filter the rows were last laid out for.
    @State private var settledFilter = ""

    struct Group: Identifiable {
        let section: ListSection
        let count: Int
        let collapsed: Bool
        let inParity: Int
        var entries: [Entry] = []
        var id: ListSection { section }
    }

    /// An item in a section; the same item can be in several.
    struct Entry: Identifiable {
        let section: ListSection
        let row: ItemRow
        var id: String { "\(section.rawValue)/\(row.item.id)" }
        var selection: TableSelection { TableSelection(section: section, itemID: row.item.id) }
    }

    /// The model's flat rows (a header, then its items) as groups.
    private var groups: [Group] {
        var groups: [Group] = []
        for row in model.rows {
            switch row {
            case let .header(section, count, collapsed, inParity):
                groups.append(Group(section: section, count: count, collapsed: collapsed, inParity: inParity))
            case let .item(section, item):
                if !groups.isEmpty { groups[groups.count - 1].entries.append(Entry(section: section, row: item)) }
            }
        }
        return groups
    }

    var body: some View {
        let selection = highlightsSelection ? model.selection : nil
        let isParity = model.mode == .parity
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        ItemRowButton(
                            entry: entry, density: density, isParity: isParity,
                            isSelected: selection == entry.selection
                        )
                    }
                } header: {
                    SectionHeader(group: group)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 44, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .refreshable { await model.sync() }
        // Rows move to their new places (a Status set, a section folded), except while the
        // filter is typed: every keystroke would start another move over the last.
        .animation(model.filterText == settledFilter ? .snappy(duration: 0.25) : nil, value: model.rows)
        .onChange(of: model.filterText) { settledFilter = model.filterText }
    }
}

/// A section's title and count; tapping folds it. A band of glass from edge to edge: pinned at
/// the list's top, rows pass under it as they do under the bar above.
private struct SectionHeader: View {
    @Environment(AppModel.self) private var model
    let group: ItemListView.Group

    var body: some View {
        Button {
            model.toggleCollapsed(group.section)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .frame(width: 14)
                Text(group.section.title)
                    .foregroundStyle(Color.primary)
                Text(String(group.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if group.inParity > 0 {
                    Text("+\(group.inParity) in Parity").foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.semibold))
            .textCase(nil)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .glassEffect(.regular, in: .rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .accessibilityHint(group.section.help)
    }
}

/// A row as the list places it: its background (priority, selection), the swipes and the menu.
private struct ItemRowButton: View {
    @Environment(AppModel.self) private var model
    let entry: ItemListView.Entry
    let density: RowDensity
    let isParity: Bool
    let isSelected: Bool

    var body: some View {
        let row = entry.row
        Button {
            model.selection = entry.selection
        } label: {
            ItemRowView(row: row, density: density, isParity: isParity)
        }
        .buttonStyle(RowButtonStyle())
        .listRowInsets(EdgeInsets())
        .listRowBackground(background)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(row.showsUnread ? "Read" : "Unread", systemImage: row.showsUnread ? "envelope.open" : "envelope.badge") {
                model.perform(.toggleRead, on: row.item.id)
            }
            .tint(.blue)
            if ItemMenu.isOnBoard(row.item, model: model) {
                Button(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin") {
                    model.perform(.togglePin, on: row.item.id)
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if ItemMenu.isOnBoard(row.item, model: model) {
                // Nearest the edge first: Desk, then further away from it. Not the Status the
                // item has: setting that again would clear it, a surprise under a swipe.
                ForEach(TriageStatus.settable.filter { $0 != row.listedTriage }, id: \.self) { status in
                    Button(status.rawValue, systemImage: status.symbol) {
                        model.perform(.triage(status), on: row.item.id)
                    }
                    .tint(status.swipeTint)
                }
            }
        }
        .contextMenu { ItemMenu(item: row.item, model: model) }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        return entry.row.priority?.rowTint ?? Color.clear
    }
}

/// Rows answer the touch at once, as a pressed cell does.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
    }
}

/// The columns' names over the rows, as on the Mac; tapping one sorts by it, again reverses.
private struct ColumnTitles: View {
    let density: RowDensity
    let isParity: Bool
    @Binding var sort: ItemSort
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        let widths = RowColumns(density: density, scale: scale)
        HStack(spacing: RowColumns.spacing) {
            Color.clear.frame(width: widths.marker, height: 1)
            if density.showsNumber { title("#", .number, width: widths.number, alignment: .leading) }
            title("Title", .title, width: nil, alignment: .leading)
            if isParity {
                title("Link", nil, width: density.showsAuthorName ? widths.author : widths.link, alignment: .leading)
            } else if density.showsAuthorName {
                title("Author", .author, width: widths.author, alignment: .leading)
            } else {
                Color.clear.frame(width: widths.avatar, height: 1)
            }
            title("✓", .review, width: widths.review, alignment: .center)
            title("Turn", .turn, width: widths.turn, alignment: .leading)
            title("CI", .ci, width: widths.ci, alignment: .center)
            if density.showsSize { title("Size", .size, width: widths.size, alignment: .trailing) }
            title("Upd", .updated, width: widths.updated, alignment: .trailing)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.trailing, RowColumns.trailingInset)
        .frame(height: 24)
        .background(.bar)
    }

    private func title(_ text: String, _ key: ItemSort.Key?, width: CGFloat?, alignment: Alignment) -> some View {
        Button {
            guard let key else { return }
            sort = ItemSort(key: key, ascending: sort.key == key ? !sort.ascending : false)
        } label: {
            Text(text)
                .lineLimit(1)
                .fixedSize()
                // The arrow hangs beside the name, so a narrow column's name stays whole.
                .overlay(alignment: alignment == .trailing ? .leading : .trailing) {
                    if let key, sort.key == key {
                        Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .offset(x: alignment == .trailing ? -9 : 9)
                    }
                }
                .frame(width: width, alignment: alignment)
                .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(key == nil)
    }
}

/// A capsule of glass over the list's foot: the write under way (or just done), otherwise how
/// many items, then when the desk last synced and what is left of GitHub's hourly budget.
private struct StatusLine: View {
    @Environment(AppModel.self) private var model
    /// On a phone: the write or the sync alone.
    let isBrief: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if let activity = model.activity {
                    HStack(spacing: 5) {
                        ZStack {
                            if activity.isDone {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .frame(width: 14)
                        Text(activity.text)
                            .foregroundStyle(Color.primary)
                            .opacity(activity.isDone ? 0.6 : 1)
                    }
                    .id(activity.id)
                    .transition(.opacity)
                } else if !isBrief {
                    Text(model.visibleCount == 1 ? "1 item" : "\(model.visibleCount) items")
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.activity)
            if !isBrief || model.activity == nil {
                if !isBrief { Text("·") }
                sync
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder private var sync: some View {
        switch model.syncState {
        case .syncing:
            ProgressView().controlSize(.mini)
            Text("Syncing…")
        case .failed:
            Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
        case let .rateLimited(until):
            Label("Rate limited until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "hourglass")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
        case .idle:
            if let last = model.lastSyncedAt {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let age = last.compactAge(relativeTo: context.date)
                    Text(age == "now" ? "Synced just now" : "Synced \(age) ago")
                }
            } else {
                Text("Not synced yet")
            }
        }
        if !isBrief, let rateLimit = model.rateLimit, !model.syncState.isRateLimited {
            Text("·")
            Text("\(rateLimit.remaining.formatted()) left")
                .foregroundStyle(rateLimit.remaining < 500 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }
}

extension Priority {
    /// The row's background, as the Mac list tints by priority: H light orange, M light yellow.
    var rowTint: Color? {
        switch self {
        case .high: Color.orange.opacity(0.16)
        case .medium: Color.yellow.opacity(0.16)
        case .low: nil
        }
    }
}

extension TriageStatus {
    /// For a swipe's button and the menus.
    var symbol: String {
        switch self {
        case .working: "studentdesk"
        case .backlog: "tray"
        case .skipped: "books.vertical"
        case .muted: "archivebox"
        case .merging: "arrow.triangle.merge"
        }
    }

    var swipeTint: Color {
        switch self {
        case .working: .green
        case .backlog: .teal
        case .skipped: .indigo
        case .muted, .merging: .gray
        }
    }
}
