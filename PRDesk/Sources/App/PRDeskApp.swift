import SwiftUI

@main
struct PRDeskApp: App {
    @State private var model: AppModel

    init() {
        // Tooltips carry details the dense list leaves out, so show them almost at once (AppKit's
        // default waits about a second). A registered default, so `defaults write` still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 300])
        do {
            _model = State(initialValue: try AppModel(db: .openDefault()))
        } catch {
            fatalError("Failed to open the database: \(error)")
        }
    }

    var body: some Scene {
        Window("PR Desk", id: "main") {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1360, height: 860)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

/// The menu bar extra's icon and unread count. A view of its own, so a new count redraws just
/// the label rather than re-evaluating every scene.
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if model.unreadInboxCount == 0 {
            Image(systemName: "tray")
        } else {
            Image(systemName: "tray.full")
            Text(String(model.unreadInboxCount))
        }
    }
}

/// The app's menu commands. Kept apart from the scenes and reading only what their enabled states
/// need, so moving the selection doesn't rebuild the menus.
private struct AppCommands: Commands {
    let model: AppModel
    @FocusedBinding(\.detailTab) private var detailTab

    var body: some Commands {
        // View > Show / Hide Inspector (⌃⌘I) for the detail pane.
        InspectorCommands()
        CommandGroup(after: .toolbar) {
            Button("Sync Now") {
                Task { await model.sync() }
            }
            .keyboardShortcut("r")
            Divider()
            Button("Dashboard") { model.mode = .dashboard }
                .keyboardShortcut("1")
            Button("Inbox") { model.mode = .inbox }
                .keyboardShortcut("2")
            Divider()
            // The detail pane's tabs, as Xcode numbers its inspectors.
            Button("Conversation") { detailTab = .conversation }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(detailTab == nil)
            Button("Checks") { detailTab = .checks }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(detailTab == nil)
            Button("Files") { detailTab = .files }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(detailTab == nil)
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            // The list answers with all its selected rows; elsewhere (e.g. reading the
            // conversation) it is the item in the detail pane.
            Button("Copy Link") {
                if !NSApp.sendAction(#selector(ItemNSTableView.copyItemLinks(_:)), to: nil, from: nil),
                   let id = model.selectedItem?.id {
                    model.perform(.copyLink, on: id)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!model.hasSelection)
        }
        // In the conversation or files of the detail pane, wherever focus is.
        CommandGroup(after: .textEditing) {
            Button("Find…") { WebDocument.performFind(.showFindInterface) }
                .keyboardShortcut("f")
            Button("Find Next") { WebDocument.performFind(.nextMatch) }
                .keyboardShortcut("g")
            Button("Find Previous") { WebDocument.performFind(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        // Works wherever focus is; `o` in the list does the same for the selected rows.
        CommandGroup(after: .newItem) {
            Button("Open on GitHub") {
                if let id = model.selectedItem?.id { model.perform(.openInBrowser, on: id) }
            }
            .keyboardShortcut("o")
            .disabled(!model.hasSelection)
        }
    }
}
