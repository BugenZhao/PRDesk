import Foundation

/// One changed file of a PR, with its unified-diff patch.
struct PullFile: Decodable, Equatable, Identifiable, Sendable {
    let filename: String
    /// `added`, `removed`, `modified`, `renamed`, `copied`, `changed`, `unchanged`.
    let status: String
    let additions: Int
    let deletions: Int
    /// Missing for binary files and very large diffs.
    let patch: String?
    let previousFilename: String?

    var id: String { filename }

    private enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }
}

/// A rendered diff line with old/new line numbers.
struct DiffLine: Equatable, Identifiable, Sendable {
    enum Kind: Sendable { case context, added, removed, hunk }

    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?

    /// Parses a unified-diff patch, numbering lines from each `@@ -a,b +c,d @@` header.
    static func parse(_ patch: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var old = 0
        var new = 0
        for (index, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let match = line.firstMatch(of: /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
                    old = Int(match.1) ?? 0
                    new = Int(match.2) ?? 0
                }
                lines.append(DiffLine(id: index, kind: .hunk, text: line, oldNumber: nil, newNumber: nil))
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(id: index, kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: new))
                new += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(id: index, kind: .removed, text: String(line.dropFirst()), oldNumber: old, newNumber: nil))
                old += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file"
                continue
            } else {
                lines.append(DiffLine(id: index, kind: .context, text: String(line.dropFirst()), oldNumber: old, newNumber: new))
                old += 1
                new += 1
            }
        }
        return lines
    }
}

extension SyncEngine {
    /// Changed files of a PR (GitHub returns at most 3000).
    func fetchFiles(number: Int) async throws -> [PullFile] {
        var files: [PullFile] = []
        for page in 1 ... 30 {
            let batch = try await client.rest(
                "GET", "/repos/\(Self.repo)/pulls/\(number)/files",
                query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))],
                as: [PullFile].self
            )
            files += batch
            if batch.count < 100 { break }
        }
        return files
    }
}
