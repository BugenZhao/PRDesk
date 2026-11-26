import SwiftUI

/// The menu bar on an iPad, and with it the Mac's keys for a keyboard attached to one (SPEC
/// §4.5): the list's single keys act on the selected item. They give way to typing wherever a
/// text field has the keyboard.
///
/// Like the Mac's, the commands read only the model's flags that flip (`hasSelection`,
/// `selectionIsPullRequest`), so moving the selection doesn't rebuild the menus.
struct DeskCommands: Commands {
    let model: AppModel
    /// The window's own doings: its layout is its to know.
    @FocusedValue(\.deskActions) private var desk
    /// The same setting as `DeskView`'s.
    @AppStorage(RowLines.key) private var rowLines = RowLines.two

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show or Hide the List") { desk?.toggleList() }
                .keyboardShortcut("b")
            Button("Full-Width List") { desk?.toggleTable() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button(rowLines == .two ? "Rows of One Line" : "Rows of Two Lines") {
                rowLines = rowLines == .two ? .one : .two
            }
            Divider()
            Button("Sync Now") { Task { await model.sync() } }
                .keyboardShortcut("r")
            Button("Filter") { model.requestFilterFocus() }
                .keyboardShortcut("/", modifiers: [])
            Divider()
            Button("Dashboard") { model.mode = .dashboard }
                .keyboardShortcut("1")
            Button("Parity") { model.mode = .parity }
                .keyboardShortcut("2")
            Button("Inbox") { model.mode = .inbox }
                .keyboardShortcut("3")
            Divider()
            Button("Conversation") { model.detailTab = .conversation }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(!model.selectionIsPullRequest)
            Button("Commits") { model.detailTab = .commits }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(!model.selectionIsPullRequest)
            Button("Files") { model.detailTab = .files }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(!model.selectionIsPullRequest)
        }

        CommandMenu("Go") {
            Button("Next Item") { model.moveSelection(by: 1) }
                .keyboardShortcut("j", modifiers: [])
            Button("Previous Item") { model.moveSelection(by: -1) }
                .keyboardShortcut("k", modifiers: [])
            Button("Deselect") { model.selection = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!model.hasSelection)
            Divider()
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Divider()
            item("Linked PR", "l", .openLinked)
            item("Agent Session", "t", .openSession)
        }

        CommandMenu("Item") {
            item("Open on GitHub", "o", .openInBrowser)
            item("Open Author's Profile", "u", .openAuthorProfile)
            Button("Copy Link") { perform(.copyLink) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.hasSelection)
            Button("Comment or Review") { model.requestComposerFocus() }
                .keyboardShortcut("c", modifiers: [])
                .disabled(!model.hasSelection)
            Divider()
            item("Mark Read or Unread", "n", .toggleRead)
            item("Pin or Unpin", "p", .togglePin)
            Divider()
            // The same key again clears the Status, as on the Mac.
            item("Desk", "w", .triage(.working))
            item("Tray", "b", .triage(.backlog))
            item("Shelf", "s", .triage(.skipped))
            item("Attic", "m", .triage(.muted))
            Divider()
            item("High Priority", "1", .priority(.high))
            item("Medium Priority", "2", .priority(.medium))
            item("Low Priority", "3", .priority(.low))
            item("No Priority", "0", .priority(nil))
            Divider()
            ForEach(BotRequest.allCases, id: \.self) { request in
                item("\(request.emoji) \(request.title)…", request.key, .sendToBot(request, withNote: true))
            }
        }
    }

    /// A command on the selected item, under a single key.
    private func item(_ title: String, _ key: KeyEquivalent, _ action: ItemAction) -> some View {
        Button(title) { perform(action) }
            .keyboardShortcut(key, modifiers: [])
            .disabled(!model.hasSelection)
    }

    private func perform(_ action: ItemAction) {
        guard let id = model.selectedItem?.id else { return }
        // No Priority clears whichever is set: setting the current one again does that.
        if case .priority(nil) = action {
            if let current = model.selectedItem.flatMap(model.board(for:))?.priorityValue {
                model.perform(.priority(current), on: id)
            }
        } else {
            model.perform(action, on: id)
        }
    }
}

extension BotRequest {
    /// The Mac's key for the request.
    var key: KeyEquivalent {
        switch self {
        case .investigate: "e"
        case .track: "f"
        case .adopt: "d"
        case .merge: "r"
        }
    }
}

extension AppModel {
    /// Selects the item after or before the selected one in the list as shown, which opens it:
    /// the first or the last with nothing selected.
    func moveSelection(by offset: Int) {
        let selections = rows.compactMap(\.selectionID)
        guard !selections.isEmpty else { return }
        guard let current = selection, let index = selections.firstIndex(of: current) else {
            selection = offset > 0 ? selections.first : selections.last
            return
        }
        let next = index + offset
        if selections.indices.contains(next) { selection = selections[next] }
    }
}
