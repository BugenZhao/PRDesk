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
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
