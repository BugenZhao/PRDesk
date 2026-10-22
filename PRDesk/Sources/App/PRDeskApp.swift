import SwiftUI

@main
struct PRDeskApp: App {
    @State private var model: AppModel

    init() {
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
        .defaultSize(width: 1500, height: 900)
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
            if model.inbox.isEmpty {
                Image(systemName: "tray")
            } else {
                Image(systemName: "tray.full")
                Text(String(model.inbox.count))
            }
        }
    }
}
