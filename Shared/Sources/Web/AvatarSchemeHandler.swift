import WebKit

/// Serves `prdesk-avatar://avatar/<login>` from `AvatarStore`, so pages show avatars already on
/// disk at once, and `prdesk-avatar://badge/<org>` drawn for the page's appearance.
@MainActor
final class AvatarSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = AvatarSchemeHandler()
    static let scheme = "prdesk-avatar"

    static func url(for login: String) -> String {
        "\(scheme)://avatar/\(login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login)"
    }

    static func url(for badge: Badge) -> String {
        "\(scheme)://badge/\(badge.org.rawValue)\(badge.isSecondary ? "-secondary" : "")"
    }

    private var running: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running.insert(id)
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent
        let isDark = WebImages.isDark(webView)
        Task {
            let data = if url.host == "badge" { Self.badgeData(name, isDark: isDark) } else { await AvatarStore.data(for: name) }
            guard running.remove(id) != nil else { return }
            guard let data else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": Self.mimeType(of: data), "Cache-Control": "max-age=86400"]
            )!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// The badge's image (a bundled logo or brand tile), drawn for the page's appearance.
    private static func badgeData(_ name: String, isDark: Bool) -> Data? {
        let isSecondary = name.hasSuffix("-secondary")
        guard let org = Org(rawValue: isSecondary ? String(name.dropLast("-secondary".count)) : name) else { return nil }
        return WebImages.badgePNG(Badge(org: org, source: "", secondaryName: isSecondary ? "" : nil), side: 26, isDark: isDark)
    }

    private static func mimeType(of data: Data) -> String {
        switch data.first {
        case 0xFF: "image/jpeg"
        case 0x47: "image/gif"
        default: "image/png"
        }
    }
}
