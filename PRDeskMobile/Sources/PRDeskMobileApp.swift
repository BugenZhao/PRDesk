import SwiftUI

/// The phone's PR Desk: the Mac's model and sync over its own local cache, with views of its own.
@main
struct PRDeskMobileApp: App {
    @State private var model: AppModel

    init() {
        do {
            _model = State(initialValue: try AppModel(db: .openDefault()))
        } catch {
            fatalError("Failed to open the database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { model.start() }
        }
    }
}
