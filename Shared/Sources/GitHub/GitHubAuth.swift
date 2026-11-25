import Foundation
import Security

enum GitHubAuthError: LocalizedError {
    case noToken

    var errorDescription: String? {
        "No GitHub token found. Run `gh auth login`, or set a token in Settings."
    }
}

/// Resolves the GitHub token: a token saved in Settings wins, otherwise `gh auth token`.
enum GitHubAuth {
    static func resolveToken() async throws -> String {
        if let token = Keychain.readToken() { return token }
        if let token = await ghToken() { return token }
        throw GitHubAuthError.noToken
    }

    #if os(macOS)
        /// Runs `gh auth token`. GUI apps don't inherit the shell PATH, so try the
        /// usual install locations before falling back to a login shell.
        @concurrent
        static func ghToken() async -> String? {
            let fm = FileManager.default
            let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            if let gh = candidates.first(where: fm.isExecutableFile(atPath:)) {
                return run(gh, ["auth", "token"])
            }
            return run("/bin/zsh", ["-lc", "gh auth token"])
        }

        private static func run(_ executable: String, _ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
    #else
        /// The phone has no `gh`: debug builds may take a token from the environment (as a
        /// simulator launch passes it); otherwise it is the one saved in Settings.
        static func ghToken() async -> String? {
            #if DEBUG
                ProcessInfo.processInfo.environment["PRDESK_GITHUB_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
            #else
                nil
            #endif
        }
    #endif
}

/// Secrets kept as generic password items: the GitHub token and the bots' webhooks.
enum Keychain {
    private static let service = "com.bugenzhao.PRDesk"
    private static let tokenAccount = "github-token"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    @discardableResult
    static func save(_ value: String, as account: String) -> Bool {
        delete(account)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func readToken() -> String? { read(tokenAccount) }

    @discardableResult
    static func saveToken(_ token: String) -> Bool { save(token, as: tokenAccount) }

    @discardableResult
    static func deleteToken() -> Bool { delete(tokenAccount) }
}
