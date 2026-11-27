import SwiftUI
import UIKit

/// Issues and PRs coming in from outside the app, as the Mac takes them from Yab's tab and
/// Handoff: the share sheet's "Open in PR Desk" (`prdesk://open?url=…`, from the
/// `PRDeskMobileOpen` extension), and a link on the clipboard when the app comes to the front,
/// offered in an alert.
///
/// The clipboard is looked at only when it may hold something new: once for each of its
/// changes (`changeCount`), never for what was copied while the app was in front (its own Copy
/// Link), and only past the checks that read nothing (`hasURLs`, `hasStrings`, the system's
/// pattern detection) does it read the text, which is what iOS asks permission for. A link
/// isn't offered again (the same text, even copied anew), nor when it is to the item showing.
struct ExternalLinks: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var offer: ItemLink?
    /// When a link last came in by URL: the clipboard isn't asked about right after.
    @State private var lastOpenedAt: Date?

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                lastOpenedAt = .now
                offer = nil
                open(url)
            }
            .onChange(of: scenePhase, initial: true) {
                switch scenePhase {
                case .active:
                    Task { await checkClipboard() }
                case .background:
                    // Copied while the app was in front: the app's own, not a link brought in.
                    // Not when inactive: coming back, the scene is inactive before it is active,
                    // and a link copied meanwhile was taken for seen.
                    ClipboardMemory.markSeen(UIPasteboard.general.changeCount)
                default:
                    break
                }
            }
            .alert(
                // Verbatim: a localized key writes the number with a grouping separator (#54,144).
                Text(verbatim: offer.map { "Open #\($0.number)?" } ?? ""),
                isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
                presenting: offer
            ) { link in
                Button("Open") { model.open(link) }
                Button("Not Now", role: .cancel) {}
            } message: { link in
                Text(verbatim: model.item(for: link).map { "\($0.title)\n\(link.repo)#\(link.number)" } ?? "\(link.repo)#\(link.number) is on the clipboard.")
            }
    }

    /// `prdesk://open?url=` and the link.
    private func open(_ url: URL) {
        guard url.scheme == "prdesk", url.host() == "open",
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value
        else { return }
        guard let link = ItemLink(text) else {
            model.linkError = "Not an issue or PR of \(ItemLink.repos.joined(separator: " or ")):\n\(text)"
            return
        }
        model.open(link)
    }

    private func checkClipboard() async {
        // After the scene has settled (a link opening the app arrives just after it is active,
        // and the selection from last time is put back), so neither is offered again.
        try? await Task.sleep(for: .milliseconds(600))
        guard scenePhase == .active, offer == nil else { return }
        if let lastOpenedAt, Date.now.timeIntervalSince(lastOpenedAt) < 3 { return }
        guard let link = await ClipboardMemory.newLink() else { return }
        guard scenePhase == .active, model.selectedItem?.repoNumber != link.key else { return }
        offer = link
    }
}

/// What of the clipboard has been looked at, kept across launches: its `changeCount` (which
/// counts every copy on the device, until it restarts) and the last link's text.
@MainActor
private enum ClipboardMemory {
    private static let changeCountKey = "clipboardSeenChangeCount"
    private static let textKey = "clipboardSeenLink"

    static func markSeen(_ changeCount: Int) {
        UserDefaults.standard.set(changeCount, forKey: changeCountKey)
    }

    /// An item's link copied since the clipboard was last looked at, or nil.
    static func newLink() async -> ItemLink? {
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        let defaults = UserDefaults.standard
        if defaults.object(forKey: changeCountKey) != nil, defaults.integer(forKey: changeCountKey) == changeCount { return nil }
        markSeen(changeCount)
        guard pasteboard.hasURLs || pasteboard.hasStrings else { return nil }
        // Without reading it: whether it looks like a web link at all.
        guard let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]),
              patterns.contains(\UIPasteboard.DetectedValues.probableWebURL),
              pasteboard.changeCount == changeCount
        else { return nil }
        guard let text = pasteboard.url?.absoluteString ?? pasteboard.string,
              text != defaults.string(forKey: textKey),
              let link = ItemLink(text)
        else { return nil }
        defaults.set(text, forKey: textKey)
        return link
    }
}
