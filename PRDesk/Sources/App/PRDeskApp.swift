import SwiftUI

@main
struct PRDeskApp: App {
    @State private var model: AppModel

    init() {
        // Tooltips carry details the dense list leaves out, so show them almost at once (AppKit's
        // default waits about a second). A registered default, so `defaults write` still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 100])
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
        .commands {
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
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            if model.unreadInboxCount == 0 {
                Image(systemName: "tray")
            } else {
                Image(systemName: "tray.full")
                Text(String(model.unreadInboxCount))
            }
        }
    }
}
