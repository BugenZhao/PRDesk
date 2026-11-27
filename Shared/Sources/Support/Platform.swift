#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The few things the shared code asks of the platform it runs on.
@MainActor
enum Platform {
    /// Opens a link in the app that handles it (the browser for web links).
    static func open(_ url: URL) {
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #else
            UIApplication.shared.open(url)
        #endif
    }

    /// Puts `text` on the pasteboard; `url` too, for apps that take a link (Mail, Notes).
    static func copy(_ text: String, url: String? = nil) {
        #if os(macOS)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if let url { pasteboard.setString(url, forType: .URL) }
        #else
            if let url, let link = URL(string: url) {
                UIPasteboard.general.setItems([[UTType.plainText.identifier: text, UTType.url.identifier: link]])
            } else {
                UIPasteboard.general.string = text
            }
        #endif
    }

    /// The unread inbox count on the app's icon: the Dock tile on the Mac. The phone shows it in
    /// the app only, since it would need notification permission for the icon.
    static func setBadgeCount(_ count: Int) {
        #if os(macOS)
            NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        #endif
    }

    /// Asks for the silent pushes CloudKit sends when another device wrote a hint
    /// (`CloudHints`); they need no permission, being shown to nobody.
    static func registerForRemoteNotifications() {
        #if os(macOS)
            NSApplication.shared.registerForRemoteNotifications()
        #else
            UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
}

#if !os(macOS)
    import UniformTypeIdentifiers
#endif
