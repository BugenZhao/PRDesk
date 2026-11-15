import Foundation
import os

/// Sends messages to Grok Bots through the grokbot CLI (github.com/BugenZhao/grokbot-cli),
/// built into the app as `Contents/Helpers/grokbot` by `scripts/embed-grokbot.sh`.
extension GrokBot {
    static var cliPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/grokbot").path(percentEncoded: false)
    }

    /// Sends `text` to `bot` without waiting for the reply, which arrives in the Grok Bot app.
    @concurrent
    static func send(_ text: String, to bot: String) async throws {
        if isDryRun("send to \(bot): \(text)") {
            // About as long as the CLI takes, so the faint in-flight marks can be seen in tests.
            try? await Task.sleep(for: .seconds(2))
            return
        }
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
