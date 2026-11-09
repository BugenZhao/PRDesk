import AppKit

/// Runs scripts in Yab through its CLI, `yab exec`, which needs no Automation permission.
enum Yab {
    static let bundleID = "dev.serafim.fast"

    enum Failure: LocalizedError {
        case notRunning
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: "Yab isn't open."
            case let .failed(message): message
            }
        }
    }

    /// Yab's binary, which acts as its CLI, if Yab is running. Checked first because `yab exec`
    /// would otherwise open a hidden Yab.
    static var runningExecutable: URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.executableURL
    }

    private struct ExecResult: Decodable {
        struct Content: Decodable { var text: String }
        var content: [Content]
    }

    /// Runs `script` (Yab's JavaScript with `__tool`) and returns what it returned. Blocks until
    /// the CLI exits, so call it off the main actor.
    static func exec(_ yab: URL, script: String, timeout: Int = 60) throws -> String {
        let process = Process()
        process.executableURL = yab
        process.arguments = ["exec", "-", "--json", "--timeout", String(timeout), "--output-limit", "32000"]
        // What Yab's own `yab` wrapper sets for its binary to act as the CLI.
        process.environment = ProcessInfo.processInfo.environment.merging(["YAB_CLI": "1"]) { $1 }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try stdin.fileHandleForWriting.close()
        // Both are short; read them before waiting so a full pipe can't stall the CLI.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let trimmed = { (data: Data) in String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            let message = [trimmed(err), trimmed(out)].first { !$0.isEmpty }
            throw Failure.failed(message ?? "yab exited with status \(process.terminationStatus).")
        }
        // The script's answer, then a line counting its steps.
        let text = try JSONDecoder().decode(ExecResult.self, from: out).content.first?.text ?? ""
        return text.range(of: "\n(", options: .backwards).map { String(text[..<$0.lowerBound]) } ?? text
    }
}

/// The tab in front in Yab, for showing the issue or PR it is on in the desk.
enum YabFrontTab {
    struct Tab: Decodable, Sendable {
        var url: String
        var title: String
    }

    /// Reads the address and title of the tab in front of Yab's window on screen. Only reads.
    @concurrent
    static func read() async throws -> Tab? {
        guard let yab = Yab.runningExecutable else { throw Yab.Failure.notRunning }
        let answer = try Yab.exec(yab, script: script, timeout: 15)
        return try JSONDecoder().decode(Optional<Tab>.self, from: Data(answer.utf8))
    }

    /// `native_context` names the tab in front but gives its address as an origin only; `tabs`
    /// lists full addresses by the first 8 characters of the id.
    private static let script = #"""
    const tab = JSON.parse(__tool('native_context', {section: 'summary', limit: 1})).activeTab;
    if (!tab) return 'null';
    const prefix = tab.id.slice(0, 8).toLowerCase();
    let url = tab.url || '';
    for (const line of __tool('tabs', {}).split('\n')) {
      const match = line.match(/^(\w+) \[user\].*, (\S+)$/);
      if (match && match[1].toLowerCase() === prefix) url = match[2];
    }
    return JSON.stringify({url, title: tab.title || ''});
    """#
}
