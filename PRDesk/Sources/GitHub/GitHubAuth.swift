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
}

/// Stores a personal access token as a generic password item.
enum Keychain {
    private static let service = "com.bugenzhao.PRDesk"
    private static let account = "github-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        deleteToken()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteToken() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
