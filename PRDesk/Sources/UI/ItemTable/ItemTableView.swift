import AppKit
import SwiftUI

/// The dense item list, backed by `NSTableView`.
struct ItemTableView: NSViewRepresentable {
    var items: [Item]
    var viewer: String?
    @Binding var selection: Item.ID?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        // The title column is sized manually to fill whatever the other columns leave.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for column in ItemColumn.allCases {
            table.addTableColumn(column.makeTableColumn())
        }
        table.autosaveName = "ItemTable"
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.openClickedItem)
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
        let coordinator = context.coordinator
        coordinator.selection = $selection
        coordinator.update(items: items, viewer: viewer, selectedID: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        var selection: Binding<Item.ID?>
        private var items: [Item] = []
        private var viewer: String?
        /// Set while the table is changed programmatically, so selection callbacks don't write back.
        private var isApplyingUpdate = false
        private var clock: Task<Void, Never>?

        init(selection: Binding<Item.ID?>) {
            self.selection = selection
        }

        func update(items: [Item], viewer: String?, selectedID: Item.ID?) {
            guard let table else { return }
            isApplyingUpdate = true
            defer { isApplyingUpdate = false }

            if items != self.items || viewer != self.viewer {
                self.items = items
                self.viewer = viewer
                table.reloadData()
            }
            let row = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
            if table.selectedRow != row {
                if row >= 0 {
                    table.selectRowIndexes([row], byExtendingSelection: false)
                    table.scrollRowToVisible(row)
                } else {
                    table.deselectAll(nil)
                }
            }
        }

        /// Keeps the relative-time columns fresh between syncs.
        func startClock() {
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self, let table else { return }
                    let visible = table.rows(in: table.visibleRect)
                    let columns = IndexSet([ItemColumn.age, .updated].map { table.column(withIdentifier: $0.identifier) })
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.lowerBound ..< visible.upperBound), columnIndexes: columns)
                }
            }
        }

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

        @objc func openClickedItem() {
            guard let table, items.indices.contains(table.clickedRow),
                  let url = URL(string: items[table.clickedRow].url)
            else { return }
            NSWorkspace.shared.open(url)
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in _: NSTableView) -> Int {
            items.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = ItemColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? RunsCellView ?? {
                let cell = RunsCellView()
                cell.identifier = column.identifier
                return cell
            }()
            let item = items[row]
            cell.alignment = column.alignment
            cell.runs = column.runs(for: item, viewer: viewer, now: Date())
            cell.alphaValue = item.isOpen ? 1 : 0.55
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, let table = notification.object as? NSTableView else { return }
            let row = table.selectedRow
            selection.wrappedValue = items.indices.contains(row) ? items[row].id : nil
        }
    }
}
