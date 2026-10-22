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
    /// Changes when badge data or avatars change, which the rows themselves don't reflect.
    var badgeVersion: Int
    var onAction: (ItemAction, Item.ID) -> Void
    var onSort: (ItemSort) -> Void
    var onToggleSection: (ListSection) -> Void
    var onFocusFilter: () -> Void
    var onFocusComposer: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ItemNSTableView()
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.floatsGroupRows = true
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
                    select(row)
                } else if let replacement = nearestItemRow(to: lastSelectedRow) {
                    // The selected item left its section (e.g. dismissed from Focus): select its neighbor.
                    select(replacement)
                    let id = rows[replacement].selectionID
                    DispatchQueue.main.async { self.parent.selection = id }
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

        private func select(_ row: Int) {
            guard let table else { return }
            lastSelectedRow = row
            if table.selectedRow != row {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        }

        private func nearestItemRow(to index: Int) -> Int? {
            guard index >= 0, !rows.isEmpty else { return nil }
            let start = min(index, rows.count - 1)
            return (start ..< rows.count).first { rows[$0].selectionID != nil }
                ?? (0 ..< start).reversed().first { rows[$0].selectionID != nil }
        }

        private var selectedItemID: Item.ID? {
            guard let table, rows.indices.contains(table.selectedRow) else { return nil }
            return rows[table.selectedRow].selectionID?.itemID
        }

        // MARK: Keyboard

        func handleKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers
            else { return false }
            switch key {
            case "j": move(by: 1)
            case "k": move(by: -1)
            case "/": parent.onFocusFilter()
            case "c": parent.onFocusComposer()
            default:
                let action: ItemAction? = switch key {
                case "1": .priority(.high)
                case "2": .priority(.medium)
                case "3": .priority(.low)
                case "0": .priority(nil)
                case "p": .togglePin
                case "d": .dismissFocus
                case "n": .markRead
                case "u": .toggleUntrack
                case "o", "\r": .openInBrowser
                default: nil
                }
                guard let action else { return false }
                if let id = selectedItemID { parent.onAction(action, id) }
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
            parent.onAction(.openInBrowser, id)
        }

        // MARK: Context menu

        private static let menuActions: [(String, ItemAction)] = [
            ("Open in Browser", .openInBrowser),
            ("High Priority", .priority(.high)),
            ("Medium Priority", .priority(.medium)),
            ("Low Priority", .priority(.low)),
            ("Clear Priority", .priority(nil)),
            ("Pin / Unpin", .togglePin),
            ("Remove from Focus", .dismissFocus),
            ("Mark as Read", .markRead),
            ("Untrack / Track", .toggleUntrack),
        ]

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            for (index, (title, _)) in Self.menuActions.enumerated() {
                let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.tag = index
                item.target = self
                menu.addItem(item)
                if index == 0 || index == 4 { menu.addItem(.separator()) }
            }
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            menu.delegate = self
            return menu
        }

        private var clickedItemID: Item.ID? {
            guard let table, rows.indices.contains(table.clickedRow) else { return nil }
            return rows[table.clickedRow].selectionID?.itemID
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            let enabled = clickedItemID != nil
            for item in menu.items { item.isHidden = !enabled }
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let id = clickedItemID else { return }
            parent.onAction(Self.menuActions[sender.tag].1, id)
        }

        @objc private func copyLink() {
            guard let table, rows.indices.contains(table.clickedRow), case let .item(_, row) = rows[table.clickedRow] else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.item.url, forType: .string)
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
                cell.runs = column.runs(for: itemRow, viewer: viewer, badges: parent.badges, now: Date())
                cell.alphaValue = itemRow.item.isOpen ? 1 : 0.55
                cell.toolTip = column == .author ? authorTooltip(itemRow.item.author) : nil
                return cell
            }
        }

        private func authorTooltip(_ author: String?) -> String? {
            guard let author else { return nil }
            let badges = parent.badges(author)
            guard !badges.isEmpty else { return author }
            return ([author] + badges.map { "\($0.org.displayName) — \($0.source)" }).joined(separator: "\n")
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
            if case let .item(_, itemRow) = rows[row] {
                view.tint = itemRow.state.priority?.rowTint
            } else {
                view.tint = nil
            }
            return view
        }

        func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard case let .header(section, _, _) = rows[row] else { return true }
            // Clicking a header toggles it; keyboard navigation just skips over it.
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

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
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
