import AppKit
import os

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

    /// The bot it goes to, by name (or a unique prefix of one), set in Settings.
    var bot: String {
        let key = self == .merge ? GrokBot.mergeBotKey : GrokBot.assistantBotKey
        let name = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? (self == .merge ? GrokBot.defaultMergeBot : GrokBot.defaultAssistantBot) : name
    }
}

/// An agent session from the board's Session field.
enum AgentSession {
    /// Claude Code sessions open in the Claude app rather than the browser:
    /// `https://claude.ai/code/session_…` becomes `claude://code/session_…`. Others open as they are.
    static func open(_ url: URL) {
        let appURL = url.host() == "claude.ai" && url.path().hasPrefix("/code/")
            ? URL(string: "claude:/\(url.path())") : nil
        NSWorkspace.shared.open(appURL ?? url)
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

/// Sends messages to Grok Bots through the grokbot CLI (github.com/BugenZhao/grokbot-cli),
/// built into the app as `Contents/Helpers/grokbot` by `scripts/embed-grokbot.sh`.
enum GrokBot {
    static let assistantBotKey = "grokBotAssistant"
    static let mergeBotKey = "grokBotMerger"
    static let defaultAssistantBot = "Richard Loop"
    static let defaultMergeBot = "Merger"

    static var cliPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/grokbot").path(percentEncoded: false)
    }

    /// The message for `request` on `items`: the emoji, then one line per item with its link and
    /// title, as the viewer would paste them into the chat; the viewer's note last, after a blank line.
    static func message(_ request: BotRequest, items: [Item], note: String? = nil) -> String {
        let lines = items.map { "\($0.url) \($0.title)" }
        let body = lines.count == 1 ? " \(lines[0])" : "\n" + lines.map { "- \($0)" }.joined(separator: "\n")
        return "[Sent from PR Desk] \(request.emoji)\(body)" + (note.map { "\n\n\($0)" } ?? "")
    }

    /// Sends `text` to `bot` without waiting for the reply, which arrives in the Grok Bot app.
    @concurrent
    static func send(_ text: String, to bot: String) async throws {
        if isDryRun("send to \(bot): \(text)") { return }
        let output = try await run(["ask", "--no-wait", "-q", "-a", bot, text])
        Logger(subsystem: "com.bugenzhao.PRDesk", category: "GrokBot")
            .notice("Sent to \(bot, privacy: .public) as message \(output, privacy: .public)")
    }

    /// The signed-in account's email, or nil when signed out.
    @concurrent
    static func whoami() async throws -> String? {
        do {
            // The email, then `name:` and `session:` lines.
            return try await run(["whoami", "-q"]).split(separator: "\n").first.map(String.init)
        } catch GrokBotError.notSignedIn {
            return nil
        }
    }

    @concurrent
    private static func run(_ arguments: [String]) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { throw GrokBotError.missingCLI }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Both are short; read them before waiting so a full pipe can't stall the CLI.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let trimmed = { (data: Data) in String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        switch process.terminationStatus {
        case 0: return trimmed(out)
        // The CLI's exit code for a missing or expired session.
        case 3: throw GrokBotError.notSignedIn
        default:
            let message = trimmed(err)
            throw GrokBotError.failed(message.isEmpty ? "grokbot exited with status \(process.terminationStatus)." : message)
        }
    }
}
