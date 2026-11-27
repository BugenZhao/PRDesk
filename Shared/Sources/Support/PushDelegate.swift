#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The app's delegate, for the one thing SwiftUI doesn't hand on: silent pushes, CloudKit's
/// saying another device wrote a hint (`CloudHints`). `CKSyncEngine` notices them too, but only
/// schedules its fetch, which the system may leave waiting; the app fetches at once.
@MainActor
final class PushDelegate: NSObject {
    enum Event: Sendable {
        case push
        case registered
        case failed(String)
    }

    /// Set by the app once its model is there.
    static var handler: (@MainActor (Event) async -> Void)?
}

#if os(macOS)
    extension PushDelegate: NSApplicationDelegate {
        func application(_: NSApplication, didReceiveRemoteNotification _: [String: Any]) {
            Task { await Self.handler?(.push) }
        }

        func application(_: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken _: Data) {
            Task { await Self.handler?(.registered) }
        }

        func application(_: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
            Task { await Self.handler?(.failed(error.localizedDescription)) }
        }
    }
#else
    extension PushDelegate: UIApplicationDelegate {
        func application(_: UIApplication, didReceiveRemoteNotification _: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
            await Self.handler?(.push)
            return .newData
        }

        func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken _: Data) {
            Task { await Self.handler?(.registered) }
        }

        func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
            Task { await Self.handler?(.failed(error.localizedDescription)) }
        }
    }
#endif
