import SwiftUI

/// The menu bar extra: what needs attention, without switching to the window.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private static let limit = 15

    var body: some View {
        let working = model.workingItems
        Section("Working · \(working.count)") {
            ForEach(working.prefix(Self.limit), id: \.item.id) { row in
                Button {
                    show { model.reveal(row.item.id) }
                } label: {
                    Text(label(row))
                }
            }
            if working.count > Self.limit {
                Text("and \(working.count - Self.limit) more").foregroundStyle(.secondary)
            }
        }
        Divider()
        Button(model.unreadInboxCount == 0 ? "Inbox" : "Inbox · \(model.unreadInboxCount) unread") {
            show { model.mode = .inbox }
        }
        Button("Sync Now") {
            Task { await model.sync() }
        }
        Divider()
        Button("Open PR Desk") { show {} }
        Button("Quit PR Desk") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(_ row: ItemRow) -> String {
        var parts: [String] = []
        if row.insight.isUnread { parts.append("●") }
        if row.insight.turn == .me { parts.append("→") }
        if let priority = row.priority { parts.append(priority.marks) }
        parts.append("#\(row.item.number) \(row.item.title)")
        return parts.joined(separator: " ")
    }

    private func show(_ action: () -> Void) {
        action()
        openWindow(id: "main")
        NSApp.activate()
    }
}
