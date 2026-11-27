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
    @State private var isSearching = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !density.usesTwoLines {
                ColumnTitles(density: density, isParity: model.mode == .parity, sort: $model.sort)
                Divider()
            }
            ItemListView(density: density, highlightsSelection: highlightsSelection)
                .overlay { emptyState }
        }
        .searchable(text: $model.filterText, isPresented: $isSearching, prompt: "Filter")
        .searchFocused($isFilterFocused)
        // Return on a link, or on a `#n` nothing listed matches, opens the item (as the Mac's
        // field does) and puts the field away; on a filter it only puts the keyboard away.
        .onSubmit(of: .search) {
            if model.submitFilter() { isSearching = false }
        }
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
        // The desk's own ground rather than a sidebar's gray: the rows' tints are read against it.
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .listSectionSpacing(0)
        .contentMargins(.top, 0, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .refreshable { await model.sync() }
        // Rows move to their new places (a Status set, a section folded), except while the
        // filter is typed: every keystroke would start another move over the last.
        .animation(model.filterText == settledFilter ? .snappy(duration: 0.25) : nil, value: model.rows)
        .onChange(of: model.filterText) { settledFilter = model.filterText }
    }
}

/// A section's title and count; tapping folds it. A band of plain material from edge to edge
/// (glass glints as rows pass, which tires the eye): pinned at the list's top, rows show dimly
/// under it.
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
                    .foregroundStyle(.tertiaryText)
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .frame(width: 14)
                Text(group.section.title)
                    .foregroundStyle(Color.primary)
                Text(String(group.count))
                    .foregroundStyle(.secondaryText)
                    .monospacedDigit()
                if group.inParity > 0 {
                    Text("+\(group.inParity) in Parity").foregroundStyle(.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.semibold))
            .textCase(nil)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(.regularMaterial)
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
        // One thing a side, done by swiping all the way: read or unread, and the item's next
        // place on the board. The rest (Tray, Attic, the pin) is in the row's menu and the detail.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(row.showsUnread ? "Read" : "Unread", systemImage: row.showsUnread ? "envelope.open" : "envelope.badge") {
                model.perform(.toggleRead, on: row.item.id)
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if ItemMenu.isOnBoard(row.item, model: model) {
                // By the Status the item has, not the section the row is in (an item is in
                // several): onto the Desk, or off it to the Shelf. Triage is where the choice
                // between the two is made, so there the Shelf is beside the Desk.
                ForEach(Self.swipeStatuses(from: row.listedTriage), id: \.self) { status in
                    Button(status.rawValue, systemImage: status.symbol) {
                        model.perform(.triage(status), on: row.item.id)
                    }
                    .tint(status.swipeTint)
                }
            }
        }
        .contextMenu { ItemMenu(item: row.item, model: model) }
    }

    /// Where a swipe sends an item with this Status, the full swipe's first.
    static func swipeStatuses(from status: TriageStatus?) -> [TriageStatus] {
        switch status {
        case .working: [.skipped]
        case nil: [.working, .skipped]
        case .backlog, .skipped, .muted: [.working]
        // Merger has it: a swipe would take it back from Merger.
        case .merging: []
        }
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
            // The Mac's two where both fit; else one for both: Age while sorted by it, Upd
            // otherwise.
            if density.showsAge {
                title("Age", .age, width: widths.updated, alignment: .trailing)
                title("Upd", .updated, width: widths.updated, alignment: .trailing)
            } else if sort.key == .age {
                title("Age", .age, width: widths.updated, alignment: .trailing)
            } else {
                title("Upd", .updated, width: widths.updated, alignment: .trailing)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondaryText)
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

/// How things stand with GitHub, as one button in the bar at the list's foot: it says it at a
/// glance (the system's spinner while a sync or a write is on its way; a symbol for a write just
/// done, a failure, the budget used up), and its menu says it in words, with Sync Now.
struct SyncStatusButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section {
                if model.requestsStopped {
                    Button("Resume GitHub Requests", systemImage: "play") { model.resumeRequests() }
                } else {
                    Button("Sync Now", systemImage: "arrow.clockwise") {
                        Task { await model.sync() }
                    }
                    .disabled(model.syncState == .syncing)
                }
            }
            // Read when the menu opens: plain lines, nothing to touch.
            Section {
                if let activity = model.activity {
                    Label(activity.text, systemImage: activity.isDone ? "checkmark.circle" : "arrow.up.circle")
                }
                Label(syncLine, systemImage: glyph.name)
                if case let .failed(message) = model.syncState {
                    Text(message)
                }
                Label(model.visibleCount == 1 ? "1 item" : "\(model.visibleCount) items", systemImage: "list.bullet")
                if let rate = model.rateLimit {
                    Label(
                        "\(rate.remaining.formatted()) of \(rate.limit.formatted()) requests left, until \(rate.resetAt.formatted(date: .omitted, time: .shortened))",
                        systemImage: "gauge.with.dots.needle.33percent"
                    )
                }
            }
            .disabled(true)
        } label: {
            // The system's spinner while something is on its way (a sync, a write), which is
            // quieter in the corner of the eye than a symbol turning, and can't be left
            // turning on the symbol that comes next (a write done during a sync had its green
            // check spin).
            if isBusy {
                ProgressView()
            } else {
                Image(systemName: glyph.name)
                    .foregroundStyle(glyph.color ?? Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityLabel("Sync Status")
        .accessibilityValue(model.activity?.text ?? syncLine)
    }

    private var isWriting: Bool { model.activity.map { !$0.isDone } ?? false }

    /// A write on its way, or a sync with no write just done to show first.
    private var isBusy: Bool { isWriting || model.activity == nil && model.syncState == .syncing }

    /// A write first (it is what the viewer just did), then the sync.
    private var glyph: (name: String, color: Color?) {
        if let activity = model.activity {
            return activity.isDone ? ("checkmark.circle.fill", .green) : ("arrow.up.circle", nil)
        }
        if model.requestsStopped { return ("hand.raised.fill", .red) }
        switch model.syncState {
        case .syncing: return ("arrow.triangle.2.circlepath", nil)
        case .failed: return ("exclamationmark.arrow.triangle.2.circlepath", .red)
        case .rateLimited: return ("hourglass", .orange)
        case .idle:
            // The budget nearly spent shows before it is.
            let isLow = model.rateLimit.map { $0.remaining < 500 } ?? false
            return ("arrow.triangle.2.circlepath", isLow ? .orange : nil)
        }
    }

    private var syncLine: String { model.syncLine() ?? "Not synced yet" }
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
