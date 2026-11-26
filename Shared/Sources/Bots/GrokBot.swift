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

    /// Whether the request applies to `item`: adopting takes open PRs of the repository that are
    /// someone else's (not the viewer's own, nor the parity agent's, which there is nothing to
    /// adopt of), and Merger only the approved ones (as in Good); staging PRs go through the
    /// parity agent.
    func applies(to item: Item, viewer: String?) -> Bool {
        let upstreamPR = item.kind == .pullRequest && item.isOpen && item.isUpstream
        return switch self {
        case .investigate, .track: true
        case .adopt: upstreamPR && !sameLogin(item.author, viewer) && !Parity.isBot(item.author)
        case .merge: upstreamPR && item.reviewDecision == "APPROVED"
        }
    }

    /// The bot it goes to: Merger for 🚀, Richard Loop for the rest.
    var role: BotRole { self == .merge ? .merger : .assistant }

    var botName: String { role.botName }
    var bot: String { role.bot }
}

/// The two bots requests go to, each reached by the webhook of a routine that wakes it (`BotHook`).
/// The phone also takes each bot's id, for a draft when it has no webhook.
enum BotRole: String, CaseIterable, Sendable {
    case assistant
    case merger

    var emojis: String {
        BotRequest.allCases.filter { $0.role == self }.map(\.emoji).joined(separator: " ")
    }

    private var defaultBot: String { self == .merger ? GrokBot.defaultMergeBot : GrokBot.defaultAssistantBot }

    /// The bot by id (set on the phone, for drafts) or name.
    var bot: String {
        let key = self == .merger ? GrokBot.mergeBotKey : GrokBot.assistantBotKey
        let name = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? defaultBot : name
    }

    /// The bot's name to show: a bot set by id (as the phone's are) goes by its usual name.
    var botName: String { UUID(uuidString: bot) == nil ? bot : defaultBot }
}

enum GrokBotError: LocalizedError {
    case noHook(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .noHook(bot): "Set \(bot)'s webhook in Settings → Grok Bot."
        case let .failed(message): message
        }
    }
}

/// Messages to Grok Bots, posted to the bot's webhook (`BotHook`). Without one the phone opens
/// Grok Bot with them as a draft (`GrokBot+Link.swift`); the Mac can't send them.
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
