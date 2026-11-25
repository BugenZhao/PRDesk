import SwiftUI

/// PR Desk on the iPad (and the iPhone): the Mac's model and sync over its own local cache, with
/// views of its own. One window: the model is one desk.
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
            DeskView()
                .environment(model)
                .task { model.start() }
        }
    }
}
