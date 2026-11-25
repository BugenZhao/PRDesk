import Foundation

/// A bot's webhook routine (SPEC §3.3): a POST with its secret wakes the routine, which takes the
/// message as the viewer's own, so the app needn't speak as the viewer through the grokbot CLI.
/// The same receivers the agents' `notify-bot` posts to (`scripts/notify-bot` in `richard`).
/// Kept in this device's Keychain, one item per bot.
struct BotHook: Codable, Equatable, Sendable {
    var url: URL
    var secret: String

    private static func account(_ role: BotRole) -> String { "grokbot-hook-\(role.rawValue)" }

    static func stored(for role: BotRole) -> BotHook? {
        Keychain.read(account(role)).flatMap { try? JSONDecoder().decode(BotHook.self, from: Data($0.utf8)) }
    }

    @discardableResult
    static func save(_ hook: BotHook, for role: BotRole) -> Bool {
        guard let data = try? JSONEncoder().encode(hook) else { return false }
        return Keychain.save(String(decoding: data, as: UTF8.self), as: account(role))
    }

    @discardableResult
    static func delete(for role: BotRole) -> Bool { Keychain.delete(account(role)) }

    /// The secret as pasted: bare, or the header line `notify-bot` keeps in `<bot>.hdr`
    /// (`Authorization: Bearer …`).
    static func secret(from text: String) -> String {
        var secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Authorization:", "Bearer "] where secret.lowercased().hasPrefix(prefix.lowercased()) {
            secret = String(secret.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return secret
    }

    /// A webhook URL as pasted, or nil when it isn't an https one.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// Posts `text` for `bot` (named in errors). The body has the same `message` field as
    /// `notify-bot`'s; the rest of its fields describe an agent session, which a send from the app
    /// has none of.
    @concurrent
    func post(_ text: String, bot: String) async throws {
        if isDryRun("post to \(bot)'s webhook: \(text)") {
            // About as long as a send takes, so the faint in-flight marks can be seen in tests.
            try? await Task.sleep(for: .seconds(1))
            return
        }
        struct Body: Encodable { let message: String; let source: String }
        #if os(macOS)
            let source = "PR Desk on the Mac"
        #else
            let source = "PR Desk on the phone"
        #endif
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(message: text, source: source))
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200 ..< 300: return
        case 401, 403: throw GrokBotError.failed("\(bot)'s webhook refused the secret (HTTP \(status)). Check it in Settings.")
        default: throw GrokBotError.failed("\(bot)'s webhook answered HTTP \(status).")
        }
    }
}

extension GrokBot {
    /// Whether a send for `request` goes out from here, rather than waiting as a draft in Grok Bot.
    static func sendsDirectly(_ request: BotRequest) -> Bool {
        sendsWithoutHook || BotHook.stored(for: request.role) != nil
    }

    /// Sends `text` for `request`, by the bot's webhook when one is set, otherwise the platform's
    /// way. Returns whether it went out (false: left as a draft in Grok Bot).
    static func deliver(_ text: String, for request: BotRequest) async throws -> Bool {
        if let hook = BotHook.stored(for: request.role) {
            try await hook.post(text, bot: request.botName)
            return true
        }
        try await send(text, to: request.bot)
        return sendsWithoutHook
    }
}
