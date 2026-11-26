import Foundation

/// Takes this device's secrets and settings from a file put into the app's Documents by the Mac
/// (`scripts/setup-device.sh`, over the cable with `devicectl`): the GitHub token and the bots'
/// webhooks go into the Keychain, the rest into the preferences, and the file is deleted. iOS has
/// no `gh` to ask and a release build reads no environment, so this is how a device is set up
/// without typing a token into it.
///
/// Only a trusted, paired Mac can write into the container; the app shares no folder with Files.
enum SetupImport {
    static let fileName = "setup.json"

    private struct Setup: Decodable {
        struct Hook: Decodable {
            var url: URL
            var secret: String
        }

        var token: String?
        /// By the bot's role (`BotRole`).
        var hooks: [String: Hook]?
        var settings: [String: String]?
    }

    /// The preferences a setup may carry.
    private static let settingKeys: Set<String> = [GrokBot.assistantBotKey, GrokBot.mergeBotKey, BadgeShare.repositoryKey]

    /// Before anything reads the token: at launch.
    static func run() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = documents.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file) else { return }
        // Whatever it holds, it doesn't stay.
        try? FileManager.default.removeItem(at: file)
        guard let setup = try? JSONDecoder().decode(Setup.self, from: data) else { return }
        if let token = setup.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            Keychain.saveToken(token)
        }
        for (name, hook) in setup.hooks ?? [:] {
            guard let role = BotRole(rawValue: name), hook.url.scheme == "https", !hook.secret.isEmpty else { continue }
            BotHook.save(BotHook(url: hook.url, secret: hook.secret), for: role)
        }
        for (key, value) in setup.settings ?? [:] where settingKeys.contains(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}
