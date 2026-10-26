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

extension SyncEngine {
    /// Changed files of a PR (GitHub returns at most 3000).
    func fetchFiles(repo: String, number: Int) async throws -> [PullFile] {
        var files: [PullFile] = []
        for page in 1 ... 30 {
            let batch = try await client.rest(
                "GET", "/repos/\(repo)/pulls/\(number)/files",
                query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))],
                as: [PullFile].self
            )
            files += batch
            if batch.count < 100 { break }
        }
        return files
    }
}
