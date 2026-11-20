import Foundation
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// An agent session from the board's Session field: a link to any agent's session. Agents listed
/// in `known` get a name and, when their desktop app takes the link, open there; any other link
/// is named by its host (or, for an app's own link, its scheme) and opens as it is.
enum AgentSession {
    private struct Agent: Sendable {
        var name: String
        var scheme = "https"
        var host: String
        var pathPrefix = ""
        /// The link for the agent's desktop app, if it takes session links in another form.
        var appURL: (@Sendable (URL) -> URL?)? = nil

        func matches(_ url: URL) -> Bool {
            url.scheme == scheme && url.host() == host && url.path().hasPrefix(pathPrefix)
        }
    }

    private static let known = [
        // `https://claude.ai/code/session_…` opens in the Claude app as `claude://code/session_…`.
        Agent(name: "Claude Code", host: "claude.ai", pathPrefix: "/code/", appURL: { URL(string: "claude:/\($0.path())") }),
        // Deep links its desktop app (ChatGPT) takes: `codex://threads/<id>`.
        Agent(name: "Codex", scheme: "codex", host: "threads"),
        // Kimi Lite's links to Kimi Code sessions: `kimi-lite://sessions/session_…`.
        Agent(name: "Kimi Code", scheme: "kimi-lite", host: "sessions"),
        // `https://app.t3.codes/threads/<environment>/<thread>` opens in the T3 Code app as
        // `t3code://threads/<environment>/<thread>`; the app's own links are taken as they are.
        Agent(name: "T3 Code", host: "app.t3.codes", pathPrefix: "/threads/", appURL: { URL(string: "t3code:/\($0.path())") }),
        Agent(name: "T3 Code", scheme: "t3code", host: "threads"),
    ]

    /// The agent's name; for agents not listed, the link's host, or its scheme for an app's link.
    static func agentName(for url: URL) -> String {
        if let agent = known.first(where: { $0.matches(url) }) { return agent.name }
        if url.scheme == "https" || url.scheme == "http", let host = url.host() { return host }
        return url.scheme ?? url.absoluteString
    }

    /// Opens the session in the agent's app when one is installed to take the app link, else the
    /// link as it is (a web link still works without the app).
    @MainActor
    static func open(_ url: URL) {
        guard let appURL = known.first(where: { $0.matches(url) })?.appURL?(url) else {
            Platform.open(url)
            return
        }
        #if os(macOS)
            Platform.open(NSWorkspace.shared.urlForApplication(toOpen: appURL) == nil ? url : appURL)
        #else
            UIApplication.shared.open(appURL) { opened in
                if !opened { Platform.open(url) }
            }
        #endif
    }
}
