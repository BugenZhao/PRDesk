import AppKit
import SwiftUI

/// The dense, sectioned item list, backed by `NSTableView`.
struct ItemTableView: NSViewRepresentable {
    var rows: [TableRow]
    var viewer: String?
    @Binding var selection: TableSelection?
    var sort: ItemSort
    var focusRequest: Int
    var badges: (String) -> [Badge]
    var contribution: (String) -> Contribution?
    /// Changes when badge data or avatars change, which the rows themselves don't reflect.
    var badgeVersion: Int
    /// An action on the selected items (or the right-clicked one, if it is outside the selection).
    var onAction: (ItemAction, [Item.ID]) -> Void
    var onSort: (ItemSort) -> Void
    var onToggleSection: (ListSection) -> Void
    var onFocusFilter: () -> Void
    var onFocusComposer: () -> Void
    /// Selection made by the table itself (e.g. moving to a neighbor when the selected row goes
    /// away); unlike user selection it must not count as opening the item.
    var onAutoSelect: (TableSelection?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ItemNSTableView()
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.floatsGroupRows = true
        table.usesAlternatingRowBackgroundColors = true
        // The title column is sized manually to fill whatever the other columns leave.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for column in ItemColumn.allCases {
            table.addTableColumn(column.makeTableColumn())
        }
        table.autosaveName = "ItemTable"
        table.autosaveTableColumns = true
        table.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.openClickedItem)
        table.keyHandler = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }
        table.headerClickHandler = { [weak coordinator] row in coordinator?.toggleHeader(at: row) ?? false }
        table.menu = coordinator.makeContextMenu()
        coordinator.table = table
        coordinator.startClock()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.fitTitleColumn),
            name: NSView.frameDidChangeNotification, object: scroll.contentView
        )
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.fitTitleColumn),
            name: NSTableView.columnDidResizeNotification, object: table
        )
        return scroll
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    /// Take whatever space is offered. Without this SwiftUI uses the table's fitting size (the sum
    /// of its column widths) as a minimum, which can force the window wider than the screen.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSScrollView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: ItemNSTableView?
        private var parent: ItemTableView
        private var rows: [TableRow] = []
        private var viewer: String?
        private var badgeVersion = 0
        private var focusRequest = 0
        /// Set while the table is changed programmatically, so callbacks don't write back.
        private var isApplyingUpdate = false
        private var lastSelectedRow = -1
        private var clock: Task<Void, Never>?

        init(_ parent: ItemTableView) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        func update(_ parent: ItemTableView) {
            self.parent = parent
            guard let table else { return }
            isApplyingUpdate = true
            defer { isApplyingUpdate = false }

            // What is selected, by identity, before rows move around.
            let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].selectionID : nil })

            if parent.rows != rows || parent.viewer != viewer {
                rows = parent.rows
                viewer = parent.viewer
                badgeVersion = parent.badgeVersion
                table.reloadData()
            } else if parent.badgeVersion != badgeVersion {
                badgeVersion = parent.badgeVersion
                let author = table.column(withIdentifier: ItemColumn.author.identifier)
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< rows.count), columnIndexes: [author])
            }

            if let selection = parent.selection {
                if let row = index(of: selection) {
                    // Keep a multiple selection the primary item belongs to; otherwise select it alone.
                    let others = selected.contains(selection) ? selected.compactMap(index(of:)) : []
                    select(row, alongWith: others)
                } else if let replacement = nearestItemRow(to: lastSelectedRow) {
                    // The selected item left its section (e.g. triaged out of Triage): select its neighbor.
                    select(replacement)
                    let id = rows[replacement].selectionID
                    DispatchQueue.main.async { self.parent.onAutoSelect(id) }
                } else {
                    table.deselectAll(nil)
                }
            } else if table.selectedRow != -1 {
                table.deselectAll(nil)
            }

            if parent.focusRequest != focusRequest {
                focusRequest = parent.focusRequest
                table.window?.makeFirstResponder(table)
            }
        }

        private func index(of selection: TableSelection) -> Int? {
            rows.firstIndex { $0.selectionID == selection }
        }

        private func select(_ row: Int, alongWith others: [Int] = []) {
            guard let table else { return }
            lastSelectedRow = row
            let indexes = IndexSet(others).union([row])
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        }

        private func nearestItemRow(to index: Int) -> Int? {
            guard index >= 0, !rows.isEmpty else { return nil }
            let start = min(index, rows.count - 1)
            return (start ..< rows.count).first { rows[$0].selectionID != nil }
                ?? (0 ..< start).reversed().first { rows[$0].selectionID != nil }
        }

        /// Selected items, top to bottom, each once even if it shows in several sections.
        private var selectedItemIDs: [Item.ID] {
            guard let table else { return [] }
            return unique(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].selectionID?.itemID : nil })
        }

        private func unique(_ ids: [Item.ID]) -> [Item.ID] {
            var seen = Set<Item.ID>()
            return ids.filter { seen.insert($0).inserted }
        }

        // MARK: Keyboard

        func handleKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers
            else { return false }
            switch key {
            case "\u{1b}":
                // Escape clears the selection, returning the detail pane to its empty state.
                guard let table, table.selectedRow != -1 else { return false }
                table.deselectAll(nil)
            case "j": move(by: 1)
            case "k": move(by: -1)
            case "/": parent.onFocusFilter()
            case "c": parent.onFocusComposer()
            default:
                let action: ItemAction? = switch key {
                case "w": .triage(.working)
                case "b": .triage(.backlog)
                case "s": .triage(.skipped)
                case "m": .triage(.muted)
                case "1": .priority(.high)
                case "2": .priority(.medium)
                case "3": .priority(.low)
                case "0": .priority(nil)
                case "p": .togglePin
                case "n": .markRead
                case "+", "=": .voteAuthor(.up)
                case "-": .voteAuthor(.down)
                case "o", "\r": .openInBrowser
                default: nil
                }
                guard let action else { return false }
                let ids = selectedItemIDs
                if !ids.isEmpty { parent.onAction(action, ids) }
            }
            return true
        }

        private func move(by delta: Int) {
            guard let table else { return }
            var row = table.selectedRow
            repeat {
                row += delta
            } while rows.indices.contains(row) && rows[row].selectionID == nil
            guard rows.indices.contains(row) else { return }
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }

        // MARK: Layout

        /// Gives the title column all width not used by the other columns.
        @objc func fitTitleColumn() {
            guard let table,
                  let clip = table.enclosingScrollView?.contentView,
                  let title = table.tableColumn(withIdentifier: ItemColumn.title.identifier)
            else { return }
            let others = table.tableColumns.reduce(0) { $0 + ($1 === title || $1.isHidden ? 0 : $1.width) }
            let spacing = table.intercellSpacing.width * CGFloat(table.tableColumns.count)
            let target = max(title.minWidth, floor(clip.bounds.width - others - spacing))
            // Setting the width posts columnDidResize again, which then finds nothing to change.
            if abs(title.width - target) >= 1 {
                title.width = target
            }
        }

        /// Keeps the relative times fresh between syncs.
        func startClock() {
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self, let table else { return }
                    let visible = table.rows(in: table.visibleRect)
                    let columns = IndexSet([ItemColumn.title, .age, .updated].map { table.column(withIdentifier: $0.identifier) })
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.lowerBound ..< visible.upperBound), columnIndexes: columns)
                }
            }
        }

        @objc func openClickedItem() {
            guard let table, rows.indices.contains(table.clickedRow),
                  let id = rows[table.clickedRow].selectionID?.itemID
            else { return }
            parent.onAction(.openInBrowser, [id])
        }

        // MARK: Context menu

        private static let menuActions: [(String, ItemAction)] = [
            ("Open in Browser", .openInBrowser),
            ("Working", .triage(.working)),
            ("Backlog", .triage(.backlog)),
            ("Skipped", .triage(.skipped)),
            ("Muted", .triage(.muted)),
            ("High Priority", .priority(.high)),
            ("Medium Priority", .priority(.medium)),
            ("Low Priority", .priority(.low)),
            ("Clear Priority", .priority(nil)),
            ("Pin / Unpin", .togglePin),
            ("Mark as Read", .markRead),
            ("Upvote Author", .voteAuthor(.up)),
            ("Downvote Author", .voteAuthor(.down)),
        ]
        /// Indices of `menuActions` after which a separator goes.
        private static let menuSeparatorsAfter: Set = [0, 4, 8, 10]

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            for (index, (title, _)) in Self.menuActions.enumerated() {
                let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.tag = index
                item.target = self
                menu.addItem(item)
                if Self.menuSeparatorsAfter.contains(index) { menu.addItem(.separator()) }
            }
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            menu.delegate = self
            return menu
        }

        /// Rows a context-menu command applies to: the whole selection when the right-clicked row is
        /// part of it, as in Finder, otherwise just that row.
        private var menuTargets: [ItemRow] {
            guard let table, rows.indices.contains(table.clickedRow), rows[table.clickedRow].selectionID != nil else { return [] }
            let indexes = table.selectedRowIndexes.contains(table.clickedRow) ? Array(table.selectedRowIndexes) : [table.clickedRow]
            var seen = Set<Item.ID>()
            return indexes.compactMap { index in
                guard rows.indices.contains(index), case let .item(_, row) = rows[index], seen.insert(row.item.id).inserted else { return nil }
                return row
            }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            let targets = menuTargets
            for item in menu.items { item.isHidden = targets.isEmpty }
            // Check what all targets share; a dash when only some do.
            func state(_ matches: (ItemRow) -> Bool) -> NSControl.StateValue {
                let count = targets.count(where: matches)
                return count == 0 ? .off : count == targets.count ? .on : .mixed
            }
            for item in menu.items where item.action == #selector(performMenuAction(_:)) {
                item.state = switch Self.menuActions[item.tag].1 {
                case let .triage(status): state { $0.listedTriage == status }
                case let .priority(priority?): state { $0.priority == priority }
                case let .voteAuthor(vote): state { $0.authorVote == vote }
                default: .off
                }
            }
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            let ids = menuTargets.map(\.item.id)
            guard !ids.isEmpty else { return }
            parent.onAction(Self.menuActions[sender.tag].1, ids)
        }

        @objc private func copyLink() {
            let urls = menuTargets.map(\.item.url)
            guard !urls.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in _: NSTableView) -> Int {
            rows.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
            if case .header = rows[row] { true } else { false }
        }

        func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .header = rows[row] { 24 } else { 20 }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch rows[row] {
            case let .header(section, count, collapsed):
                let cell = reusableCell(tableView, id: "header")
                cell.alignment = .leading
                cell.runs = [
                    .symbol(collapsed ? "chevron.right" : "chevron.down", color: .secondaryLabelColor),
                    .text(section.title, font: CellFont.smallBold),
                    .text(String(count), color: .secondaryLabelColor, font: CellFont.digits),
                ]
                cell.alphaValue = 1
                return cell

            case let .item(_, itemRow):
                guard let tableColumn, let column = ItemColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
                let cell = reusableCell(tableView, id: column.rawValue)
                cell.alignment = column.alignment
                cell.runs = column.runs(for: itemRow, viewer: viewer, badges: parent.badges, contribution: parent.contribution, now: Date())
                cell.alphaValue = itemRow.item.isOpen ? 1 : 0.55
                cell.toolTip = switch column {
                case .author: authorTooltip(itemRow.item.author)
                case .ci: ItemColumn.ciTooltip(itemRow.item)
                default: nil
                }
                return cell
            }
        }

        private func authorTooltip(_ author: String?) -> String? {
            guard let author else { return nil }
            let lines = [author]
                + (parent.contribution(author).map { [$0.summary] } ?? [])
                + parent.badges(author).map { "\($0.org.displayName) — \($0.source)" }
            return lines.joined(separator: "\n")
        }

        private func reusableCell(_ tableView: NSTableView, id: String) -> RunsCellView {
            let identifier = NSUserInterfaceItemIdentifier(id)
            if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? RunsCellView { return cell }
            let cell = RunsCellView()
            cell.identifier = identifier
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: ItemRowView.identifier, owner: nil) as? ItemRowView ?? {
                let view = ItemRowView()
                view.identifier = ItemRowView.identifier
                return view
            }()
            switch rows[row] {
            case let .item(_, itemRow):
                view.tint = itemRow.priority?.rowTint
                view.toolTip = nil
            case let .header(section, _, _):
                view.tint = nil
                // On the row: a group row doesn't show its cell's tooltip.
                view.toolTip = section.help
            }
            return view
        }

        /// Toggles the section if `row` is a header; see `ItemNSTableView.mouseDown`.
        func toggleHeader(at row: Int) -> Bool {
            guard rows.indices.contains(row), case let .header(section, _, _) = rows[row] else { return false }
            parent.onToggleSection(section)
            return true
        }

        func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard case let .header(section, _, _) = rows[row] else { return true }
            // A click on the header floating at the top lands here (one in place is taken by
            // `ItemNSTableView.mouseDown`); keyboard navigation just skips over headers.
            if let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .leftMouseUp {
                DispatchQueue.main.async { self.parent.onToggleSection(section) }
            }
            return false
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            if row >= 0 { lastSelectedRow = row }
            parent.selection = rows.indices.contains(row) ? rows[row].selectionID : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(ItemSort.Key.init(rawValue:))
            else { return }
            parent.onSort(ItemSort(key: key, ascending: descriptor.ascending))
        }
    }
}

/// Routes single-key shortcuts to the coordinator before normal table handling.
final class ItemNSTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Returns whether the row was a section header and was toggled.
    var headerClickHandler: ((Int) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // The table never asks whether to select a header sitting in place, so `shouldSelectRow`
        // only sees clicks on the floating one; take the others here.
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, headerClickHandler?(row) == true { return }
        super.mouseDown(with: event)
    }
}

/// A row view that tints unselected rows, e.g. by priority.
final class ItemRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("itemRow")

    var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tint, !isGroupRowStyle else { return }
        tint.setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}
