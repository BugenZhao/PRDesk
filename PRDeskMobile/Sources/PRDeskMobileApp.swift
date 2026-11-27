import SwiftUI

/// PR Desk on the iPad (and the iPhone): the Mac's model and sync over its own local cache, with
/// views of its own. One window: the model is one desk.
@main
struct PRDeskMobileApp: App {
    @State private var model: AppModel
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SetupImport.run()
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
                // A push that came while the app was suspended may have been dropped.
                .onChange(of: scenePhase) { if scenePhase == .active { model.fetchHints() } }
        }
        .commands { DeskCommands(model: model) }
    }
}
