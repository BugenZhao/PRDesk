import AppKit
import SwiftUI

/// The dense, sectioned item list, backed by `NSTableView`.
struct ItemTableView: NSViewRepresentable {
    var rows: [TableRow]
    /// Shows the Parity tab's columns rather than the others'.
    var isParity: Bool
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
    /// Undo for list actions, answering ⌘Z while the table has focus.
    var listUndoManager: UndoManager

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
        // A column added after the order was saved comes last; Link takes Author's place in the
        // Parity tab, so it goes beside it.
        let author = table.column(withIdentifier: ItemColumn.author.identifier)
        let link = table.column(withIdentifier: ItemColumn.link.identifier)
        if author >= 0, link >= 0, link != author + 1 {
            table.moveColumn(link, toColumn: link > author ? author + 1 : author)
        }
        table.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        // Rows drag out as links (to a browser, Notes, a chat). Only sideways: a vertical drag
        // still selects a run of rows.
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.verticalMotionCanBeginDrag = false
        table.doubleAction = #selector(Coordinator.openClickedItem)
        table.keyHandler = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }
        table.headerClickHandler = { [weak coordinator] row in coordinator?.toggleHeader(at: row) ?? false }
        table.copyLinksHandler = { [weak coordinator] in coordinator?.copySelectedLinks() ?? false }
        table.toolTipProvider = { [weak coordinator] row, column in coordinator?.toolTip(row: row, column: column) }
        table.listUndoManager = listUndoManager
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
        /// The selection the table last showed, to tell a new one (scrolled to) from the same one
        /// at a new index after rows came or went above it (left where it is).
        private var shownSelection: TableSelection?
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
                let old = rows
                let viewerChanged = parent.viewer != viewer
                rows = parent.rows
                viewer = parent.viewer
                badgeVersion = parent.badgeVersion
                table.resetToolTip()
                if viewerChanged || !animateChanges(from: old, in: table) {
                    table.reloadData()
                }
            } else if parent.badgeVersion != badgeVersion {
                badgeVersion = parent.badgeVersion
                let author = table.column(withIdentifier: ItemColumn.author.identifier)
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< rows.count), columnIndexes: [author])
            }

            if let selection = parent.selection {
                if let row = index(of: selection) {
                    // Keep a multiple selection the primary item belongs to; otherwise select it alone.
                    let others = selected.contains(selection) ? selected.compactMap(index(of:)) : []
                    select(row, alongWith: others, scroll: selection != shownSelection)
                } else if isCollapsed(selection.section) {
                    // Only hidden in a collapsed section: the item stays selected (and in the
                    // detail pane), and is highlighted again where it was once the section opens.
                    if table.selectedRow != -1 { table.deselectAll(nil) }
                } else if let replacement = nearestItemRow(to: lastSelectedRow) {
                    // The selected item left its section (e.g. triaged out of Triage): select its neighbor.
                    select(replacement, scroll: true)
                    let id = rows[replacement].selectionID
                    DispatchQueue.main.async { self.parent.onAutoSelect(id) }
                } else {
                    table.deselectAll(nil)
                    shownSelection = nil
                }
            } else {
                if table.selectedRow != -1 { table.deselectAll(nil) }
                shownSelection = nil
            }

            if parent.focusRequest != focusRequest {
                focusRequest = parent.focusRequest
                table.window?.makeFirstResponder(table)
            }
            showColumns(parity: parent.isParity, in: table)
        }

        private func showColumns(parity: Bool, in table: NSTableView) {
            var changed = false
            for column in ItemColumn.parityOnly.union(ItemColumn.notInParity) {
                guard let tableColumn = table.tableColumn(withIdentifier: column.identifier) else { continue }
                let hidden = ItemColumn.parityOnly.contains(column) != parity
                if tableColumn.isHidden != hidden {
                    tableColumn.isHidden = hidden
                    changed = true
                }
            }
            if changed { fitTitleColumn() }
        }

        private func index(of selection: TableSelection) -> Int? {
            rows.firstIndex { $0.selectionID == selection }
        }

        /// Selects `row`, scrolling to it only when asked: a selection that just moved because
        /// rows came or went above it (a section toggled) stays where the user scrolled.
        private func select(_ row: Int, alongWith others: [Int] = [], scroll: Bool) {
            guard let table else { return }
            lastSelectedRow = row
            shownSelection = rows[row].selectionID
            let indexes = IndexSet(others).union([row])
            if table.selectedRowIndexes != indexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
            if scroll { table.scrollRowToVisible(row) }
        }

        /// Moves, inserts and removes rows with animation instead of reloading, so an item given a
        /// new Status travels to its new section, one leaving the list fades out, and a section
        /// expands or collapses the same way whatever its size. Returns false when rows can't be
        /// matched up (duplicate identities), for the caller to reload.
        private func animateChanges(from old: [TableRow], in table: NSTableView) -> Bool {
            let oldKeys = old.map(\.animationKey)
            let newKeys = rows.map(\.animationKey)
            let oldSet = Set(oldKeys)
            let newSet = Set(newKeys)
            guard oldSet.count == oldKeys.count, newSet.count == newKeys.count else { return false }
            let removed = IndexSet(oldKeys.indices.filter { !newSet.contains(oldKeys[$0]) })

            // Changes in an update block apply one after another, each to the rows as the previous
            // one left them; `current` follows along.
            var current = oldKeys.indices.filter { !removed.contains($0) }.map { oldKeys[$0] }
            table.beginUpdates()
            table.removeRows(at: removed, withAnimation: [.effectFade, .slideUp])
            for (target, key) in newKeys.enumerated() {
                if current.indices.contains(target), current[target] == key { continue }
                // Everything before `target` already matches, so a row still to place sits after it.
                if let source = current[target...].firstIndex(of: key) {
                    table.moveRow(at: source, to: target)
                    current.insert(current.remove(at: source), at: target)
                } else {
                    table.insertRows(at: [target], withAnimation: [.effectFade, .slideDown])
                    current.insert(key, at: target)
                }
            }
            table.endUpdates()

            // Rows that stayed or moved may show something new: a header's count, an item's
            // section, Turn or priority tint.
            let oldRows = Dictionary(uniqueKeysWithValues: zip(oldKeys, old))
            let changed = IndexSet(rows.indices.filter { index in oldRows[newKeys[index]].map { $0 != rows[index] } ?? false })
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0 ..< table.numberOfColumns))
                for row in changed {
                    if let view = table.rowView(atRow: row, makeIfNecessary: false) as? ItemRowView { configure(view, for: row) }
                }
            }
            return true
        }

        private func isCollapsed(_ section: ListSection) -> Bool {
            rows.contains { if case .header(section, _, true, _) = $0 { true } else { false } }
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
                case "a": .addToDesk
                case "+", "=": .voteAuthor(.up)
                case "-": .voteAuthor(.down)
                case "o", "\r": .openInBrowser
                case "u": .openAuthorProfile
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

        private struct MenuAction {
            var title: String
            var action: ItemAction
            var symbol: String
            /// The list's single-key shortcut, shown beside the item.
            var key: String
        }

        private static let menuActions: [MenuAction] = [
            MenuAction(title: "Open in Browser", action: .openInBrowser, symbol: "safari", key: "o"),
            MenuAction(title: "Open Author's Profile", action: .openAuthorProfile, symbol: "person.crop.circle", key: "u"),
            MenuAction(title: "Working", action: .triage(.working), symbol: "hammer", key: "w"),
            MenuAction(title: "Backlog", action: .triage(.backlog), symbol: "tray", key: "b"),
            MenuAction(title: "Skipped", action: .triage(.skipped), symbol: "forward", key: "s"),
            MenuAction(title: "Muted", action: .triage(.muted), symbol: "bell.slash", key: "m"),
            MenuAction(title: "High Priority", action: .priority(.high), symbol: Priority.high.symbol, key: "1"),
            MenuAction(title: "Medium Priority", action: .priority(.medium), symbol: Priority.medium.symbol, key: "2"),
            MenuAction(title: "Low Priority", action: .priority(.low), symbol: Priority.low.symbol, key: "3"),
            MenuAction(title: "Clear Priority", action: .priority(nil), symbol: "xmark", key: "0"),
            MenuAction(title: "Pin / Unpin", action: .togglePin, symbol: "pin", key: "p"),
            MenuAction(title: "Mark as Read", action: .markRead, symbol: "envelope.open", key: "n"),
            MenuAction(title: "Upvote Author", action: .voteAuthor(.up), symbol: "hand.thumbsup", key: "+"),
            MenuAction(title: "Downvote Author", action: .voteAuthor(.down), symbol: "hand.thumbsdown", key: "-"),
        ]
        /// Indices of `menuActions` after which a separator goes.
        private static let menuSeparatorsAfter: Set = [1, 5, 9, 11]

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            for (index, entry) in Self.menuActions.enumerated() {
                let item = NSMenuItem(title: entry.title, action: #selector(performMenuAction(_:)), keyEquivalent: entry.key)
                item.keyEquivalentModifierMask = []
                item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
                item.tag = index
                item.target = self
                menu.addItem(item)
                if Self.menuSeparatorsAfter.contains(index) { menu.addItem(.separator()) }
            }
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy Link", action: #selector(copyClickedLinks), keyEquivalent: "c")
            copy.keyEquivalentModifierMask = [.command, .shift]
            copy.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
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
                item.state = switch Self.menuActions[item.tag].action {
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
            parent.onAction(Self.menuActions[sender.tag].action, ids)
        }

        @objc private func copyClickedLinks() {
            let ids = menuTargets.map(\.item.id)
            guard !ids.isEmpty else { return }
            parent.onAction(.copyLink, ids)
        }

        /// Edit > Copy Link while the table has focus: every selected item, not just the primary one.
        func copySelectedLinks() -> Bool {
            let ids = selectedItemIDs
            guard !ids.isEmpty else { return false }
            parent.onAction(.copyLink, ids)
            return true
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in _: NSTableView) -> Int {
            rows.count
        }

        func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard rows.indices.contains(row), case let .item(_, itemRow) = rows[row] else { return nil }
            let item = NSPasteboardItem()
            item.setString(itemRow.item.url, forType: .URL)
            item.setString(itemRow.item.url, forType: .string)
            // The link's title where the destination shows one, as Safari's links carry.
            item.setString("#\(itemRow.item.number) \(itemRow.item.title)", forType: NSPasteboard.PasteboardType("public.url-name"))
            return item
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
            case let .header(section, count, collapsed, inParity):
                let cell = reusableCell(tableView, id: "header")
                cell.alignment = .leading
                cell.runs = [
                    .symbol(collapsed ? "chevron.right" : "chevron.down", color: .secondaryLabelColor),
                    .text(section.title, font: CellFont.smallBold),
                    .text(String(count), color: .secondaryLabelColor, font: CellFont.digits),
                ] + (inParity == 0 ? [] : [.text("(+\(inParity) in Parity)", color: .tertiaryLabelColor, font: CellFont.small)])
                cell.opacity = 1
                return cell

            case let .item(_, itemRow):
                guard let tableColumn, let column = ItemColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
                let cell = reusableCell(tableView, id: column.rawValue)
                cell.alignment = column.alignment
                cell.runs = column.runs(for: itemRow, viewer: viewer, badges: parent.badges, contribution: parent.contribution, now: Date())
                cell.opacity = Self.opacity(of: itemRow.item, in: column)
                return cell
            }
        }

        /// Closed items fade, and drafts nearly as much (all but the unread dot, which still has
        /// to catch the eye), so the PRs ready for review stand out.
        private static func opacity(of item: Item, in column: ItemColumn) -> CGFloat {
            if !item.isOpen { return 0.55 }
            if item.isDraft, column != .unread { return 0.6 }
            return 1
        }

        /// The tooltip for a cell, worked out only when it is about to show; see
        /// `ItemNSTableView.toolTipProvider`.
        func toolTip(row: Int, column: Int) -> String? {
            guard let table, rows.indices.contains(row) else { return nil }
            switch rows[row] {
            case let .header(section, _, _, inParity):
                guard inParity > 0 else { return section.help }
                return "\(section.help)\n\n+\(inParity): parity PRs promoted upstream that would be here, listed in the Parity tab's Upstream section instead (⌘2)."
            case let .item(_, itemRow):
                guard table.tableColumns.indices.contains(column),
                      let itemColumn = ItemColumn(rawValue: table.tableColumns[column].identifier.rawValue)
                else { return nil }
                switch itemColumn {
                case .title: return (table.view(atColumn: column, row: row, makeIfNecessary: false) as? RunsCellView)?.truncatedText
                case .author: return authorTooltip(itemRow.item.author)
                case .link: return itemRow.paired.map { "\($0.repo)#\($0.number) \($0.title)" }
                case .ci: return ItemColumn.ciTooltip(itemRow.item)
                default: return nil
                }
            }
        }

        private func authorTooltip(_ author: String?) -> String? {
            guard let author else { return nil }
            let lines = [author]
                + (parent.contribution(author).map { [$0.summary] } ?? [])
                + parent.badges(author).map { "\($0.name) — \($0.source)" }
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
                // Cells draw into the row's layer rather than one backing store each, so a row
                // scrolling in is one layer to fill, not a dozen.
                view.canDrawSubviewsIntoLayer = true
                return view
            }()
            configure(view, for: row)
            return view
        }

        private func configure(_ view: ItemRowView, for row: Int) {
            switch rows[row] {
            case let .item(_, itemRow):
                view.tint = itemRow.priority?.rowTint
                view.drawsSeparator = false
            case .header:
                view.tint = nil
                // Divides each section from the one above.
                view.drawsSeparator = row > 0
            }
        }

        /// Toggles the section if `row` is a header; see `ItemNSTableView.mouseDown`.
        func toggleHeader(at row: Int) -> Bool {
            guard rows.indices.contains(row), case let .header(section, _, _, _) = rows[row] else { return false }
            parent.onToggleSection(section)
            return true
        }

        func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard case let .header(section, _, _, _) = rows[row] else { return true }
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
            shownSelection = rows.indices.contains(row) ? rows[row].selectionID : nil
            parent.selection = shownSelection
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(ItemSort.Key.init(rawValue:))
            else { return }
            parent.onSort(ItemSort(key: key, ascending: descriptor.ascending))
        }
    }
}

private extension TableRow {
    /// Identity across updates, for animating them. An item in the triage sections keeps one
    /// identity whatever its section, so a new Status moves it; Recently viewed, Pinned and the
    /// Inbox show copies, which keep their own.
    enum AnimationKey: Hashable {
        case header(ListSection)
        case item(ListSection?, Item.ID)
    }

    var animationKey: AnimationKey {
        switch self {
        case let .header(section, _, _, _): .header(section)
        case let .item(section, row): .item([.recent, .pinned, .inbox].contains(section) ? section : nil, row.item.id)
        }
    }
}

/// Routes single-key shortcuts to the coordinator before normal table handling, and ⌘Z to the
/// list's own undo.
final class ItemNSTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    /// Returns whether the row was a section header and was toggled.
    var headerClickHandler: ((Int) -> Bool)?
    weak var listUndoManager: UndoManager?
    /// Copies the selected items' links; returns whether anything was selected.
    var copyLinksHandler: (() -> Bool)?
    /// The tooltip for the cell at a row and column.
    var toolTipProvider: ((Int, Int) -> String?)?

    @objc func undo(_: Any?) { listUndoManager?.undo() }
    @objc func redo(_: Any?) { listUndoManager?.redo() }

    /// Sent by Edit > Copy Link down the responder chain; see `PRDeskApp`.
    @objc func copyItemLinks(_: Any?) {
        if copyLinksHandler?() != true { NSSound.beep() }
    }

    /// Edit > Copy (⌘C) in the list copies the selected items' links too.
    @objc func copy(_ sender: Any?) {
        copyItemLinks(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let manager = listUndoManager else { return super.validateUserInterfaceItem(item) }
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = manager.undoMenuItemTitle
            return manager.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = manager.redoMenuItemTitle
            return manager.canRedo
        case #selector(copy(_:)):
            return selectedRow != -1
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: Tooltips

    // One tooltip area, over the cell under the mouse, instead of one per cell: cells don't
    // work out tooltips while being set up, and scrolling has no tooltip areas to move.
    private var toolTipCell: (row: Int, column: Int)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateToolTipCell(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        resetToolTip()
    }

    /// Forgets the hovered cell, e.g. after rows changed under it.
    func resetToolTip() {
        guard toolTipCell != nil else { return }
        toolTipCell = nil
        removeAllToolTips()
    }

    private func updateToolTipCell(at point: NSPoint) {
        let row = row(at: point)
        let column = column(at: point)
        guard row >= 0, column >= 0 else { return resetToolTip() }
        if let toolTipCell, toolTipCell == (row, column) { return }
        removeAllToolTips()
        toolTipCell = (row, column)
        // A header spans the whole row.
        let rect = delegate?.tableView?(self, isGroupRow: row) == true ? rect(ofRow: row) : frameOfCell(atColumn: column, row: row)
        addToolTip(rect, owner: self, userData: nil)
    }

    override func mouseDown(with event: NSEvent) {
        // The table never asks whether to select a header sitting in place, so `shouldSelectRow`
        // only sees clicks on the floating one; take the others here.
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, headerClickHandler?(row) == true { return }
        super.mouseDown(with: event)
    }
}

extension ItemNSTableView: NSViewToolTipOwner {
    nonisolated func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point _: NSPoint, userData _: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated {
            guard let toolTipCell else { return "" }
            return toolTipProvider?(toolTipCell.row, toolTipCell.column) ?? ""
        }
    }
}

/// A row view that tints unselected rows, e.g. by priority.
final class ItemRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("itemRow")

    var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    /// A hairline along the top, for section headers.
    var drawsSeparator = false {
        didSet { needsDisplay = true }
    }

    /// No crossfade of the alternating stripe when a row slides to the other parity: the cells
    /// draw into the row's layer, so each frame of the fade would redraw the whole row.
    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "backgroundColor" ? nil : super.defaultAnimation(forKey: key)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if drawsSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 2)).fill()
        }
        guard let tint, !isGroupRowStyle else { return }
        tint.setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}
