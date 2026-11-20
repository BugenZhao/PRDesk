import Foundation
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// What the viewer asks a Grok Bot to do with items, sent as the emoji the bots already know from
/// chat: Richard Loop looks into 👀 and puts 🔥 on the Notion tracker (which also moves it to
/// Working on the board); Merger drives 🚀 PRs through CI and merges them.
enum BotRequest: String, CaseIterable, Codable, Sendable {
    case investigate
    case track
    case merge

    var emoji: String {
        switch self {
        case .investigate: "👀"
        case .track: "🔥"
        case .merge: "🚀"
        }
    }

    var title: String {
        switch self {
        case .investigate: "Investigate"
        case .track: "Track"
        case .merge: "Merge"
        }
    }

    /// Whether the request applies to `item`: Merger only takes open, approved PRs of the
    /// repository (as in Good); staging PRs go through the parity agent.
    func applies(to item: Item) -> Bool {
        self != .merge || item.kind == .pullRequest && item.isOpen && item.isUpstream && item.reviewDecision == "APPROVED"
    }

    /// The bot's name to show: a bot set by id (as the phone's are) goes by the request's usual bot.
    var botName: String {
        UUID(uuidString: bot) == nil ? bot : (self == .merge ? GrokBot.defaultMergeBot : GrokBot.defaultAssistantBot)
    }

    /// The bot it goes to, by name (or a unique prefix of one), set in Settings.
    var bot: String {
        let key = self == .merge ? GrokBot.mergeBotKey : GrokBot.assistantBotKey
        let name = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? (self == .merge ? GrokBot.defaultMergeBot : GrokBot.defaultAssistantBot) : name
    }
}

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

enum GrokBotError: LocalizedError {
    case missingCLI
    case notSignedIn
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI: "The grokbot CLI isn't in the app bundle."
        case .notSignedIn: "grokbot isn't signed in. Run `grokbot login` in Terminal."
        case let .failed(message): message
        }
    }
}

/// Messages to Grok Bots. How they go out is the platform's: the Mac sends them through the
/// bundled grokbot CLI (`GrokBot+CLI.swift`), the phone opens Grok Bot with them as a draft.
enum GrokBot {
    static let assistantBotKey = "grokBotAssistant"
    static let mergeBotKey = "grokBotMerger"
    static let defaultAssistantBot = "Richard Loop"
    static let defaultMergeBot = "Merger"

    /// The message for `request` on `items`: the emoji, then one line per item with its link and
    /// title, as the viewer would paste them into the chat; the viewer's note last, after a blank line.
    static func message(_ request: BotRequest, items: [Item], note: String? = nil) -> String {
        let lines = items.map { "\($0.url) \($0.title)" }
        let body = lines.count == 1 ? " \(lines[0])" : "\n" + lines.map { "- \($0)" }.joined(separator: "\n")
        return "[Sent from PR Desk] \(request.emoji)\(body)" + (note.map { "\n\n\($0)" } ?? "")
    }
}
