import Foundation

/// What the viewer asks a Grok Bot to do with items, sent as the emoji the bots already know from
/// chat: Richard Loop looks into 👀, puts 🔥 on the Notion tracker (which also moves it to Desk on
/// the board) and has the parity agent vet 🫴 PRs for adoption (SPEC §3.2); Merger drives 🚀 PRs
/// through CI and merges them.
enum BotRequest: String, CaseIterable, Codable, Sendable {
    case investigate
    case track
    case adopt
    case merge

    var emoji: String {
        switch self {
        case .investigate: "👀"
        case .track: "🔥"
        case .adopt: "🫴"
        case .merge: "🚀"
        }
    }

    var title: String {
        switch self {
        case .investigate: "Investigate"
        case .track: "Track"
        case .adopt: "Adopt"
        case .merge: "Merge"
        }
    }

    /// Whether the request applies to `item`: adopting takes open PRs of the repository, and Merger
    /// only the approved ones (as in Good); staging PRs go through the parity agent.
    func applies(to item: Item) -> Bool {
        let upstreamPR = item.kind == .pullRequest && item.isOpen && item.isUpstream
        return switch self {
        case .investigate, .track: true
        case .adopt: upstreamPR
        case .merge: upstreamPR && item.reviewDecision == "APPROVED"
        }
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
