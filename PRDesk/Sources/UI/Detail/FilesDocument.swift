import CryptoKit
import Foundation

/// The changed files as the files page shows them.
enum FilesDocument {
    private struct Document: Encodable {
        var key: String
        var files: [File]
    }

    private struct File: Encodable {
        var name: String
        var previous: String?
        /// Classes of the status symbol.
        var symbol: String
        var additions: Int
        var deletions: Int
        var patch: String?
        var url: String
    }

    /// JSON for `PRDesk.renderFiles`; built off the main thread, as patches can run to megabytes.
    @concurrent
    static func payload(_ files: [PullFile], number: Int, pullURL: String) async -> String {
        let document = Document(key: String(number), files: files.map { file in
            File(
                name: file.filename, previous: file.previousFilename, symbol: symbol(for: file.status),
                additions: file.additions, deletions: file.deletions, patch: file.patch,
                url: "\(pullURL)/files#diff-\(anchor(file.filename))"
            )
        })
        return (try? String(decoding: JSONEncoder().encode(document), as: UTF8.self)) ?? "{}"
    }

    /// GitHub's anchor for a file in a PR's diff: the SHA-256 of its path.
    private static func anchor(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func symbol(for status: String) -> String {
        switch status {
        case "added": "s-plus-square c-green"
        case "removed": "s-minus-square c-red"
        case "renamed", "copied": "s-arrow-right-square c-blue"
        default: "s-square-and-pencil c-orange"
        }
    }
}
