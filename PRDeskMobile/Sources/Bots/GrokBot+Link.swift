import UIKit

/// For a bot without a webhook the phone opens Grok Bot on the bot's chat with the message as a
/// draft (`grokbot://app/v1/prompt`); it goes out when the viewer sends it there.
extension GrokBot {
    /// The link takes at most this many characters of text.
    static let maxDraftLength = 1000

    /// `bot` is the bot's agent id (a UUID, as `grokbot agents` lists it), set in Settings: the
    /// link can't find a bot by name.
    @MainActor
    static func openDraft(_ text: String, to bot: String) async throws {
        guard UUID(uuidString: bot) != nil else {
            throw GrokBotError.failed("Set the id of \(bot) in Settings: Grok Bot opens a bot by its id.")
        }
        let draft = String(text.prefix(maxDraftLength))
        guard let url = draftURL(text: draft, bot: bot) else { throw GrokBotError.failed("Couldn't make the Grok Bot link.") }
        if isDryRun("open Grok Bot with a draft for \(bot): \(draft)") { return }
        guard await UIApplication.shared.open(url) else {
            throw GrokBotError.failed("Grok Bot didn't open. Is it installed?")
        }
    }

    static func draftURL(text: String, bot: String) -> URL? {
        // Only unreserved characters stay bare: `+` would read as a space and `&` end the text.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let id = bot.addingPercentEncoding(withAllowedCharacters: allowed),
              let text = text.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "grokbot://app/v1/prompt?id=\(id)&text=\(text)")
    }
}
