import SwiftUI

/// The iPad and iPhone PR Desk. Its first interface was removed and the next isn't built yet, so
/// for now this only keeps `Shared/` and the platform parts here compiling for iOS: no model is
/// made, and nothing syncs.
@main
struct PRDeskMobileApp: App {
    var body: some Scene {
        WindowGroup {
            ContentUnavailableView(
                "PR Desk",
                systemImage: "hammer",
                description: Text("The interface for iPad is being rebuilt.")
            )
        }
    }
}
