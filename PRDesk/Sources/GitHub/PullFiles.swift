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

/// The viewer's mark on a changed file, GitHub's "Viewed" checkbox.
enum FileViewedState: String, Decodable, Sendable {
    case viewed = "VIEWED"
    case unviewed = "UNVIEWED"
    /// Marked viewed, then changed by a later push.
    case dismissed = "DISMISSED"
}

private struct ViewedStatesPage: Decodable, Sendable {
    struct Node: Decodable, Sendable { let files: Files? }
    struct Files: Decodable, Sendable { let pageInfo: PageInfo; let nodes: [File] }
    struct PageInfo: Decodable, Sendable { let hasNextPage: Bool; let endCursor: String? }
    struct File: Decodable, Sendable { let path: String; let viewerViewedState: String }

    let node: Node?
}

extension SyncEngine {
    /// The viewer's Viewed marks on a PR's changed files, by path.
    func fetchViewedStates(pullRequestID: String) async throws -> [String: FileViewedState] {
        struct Variables: Encodable, Sendable { let id: String; let after: String? }
        let query = """
        query($id: ID!, $after: String) { node(id: $id) { ... on PullRequest {
          files(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { path viewerViewedState } }
        } } }
        """
        var states: [String: FileViewedState] = [:]
        var after: String?
        for _ in 1 ... 30 {
            let page = try await client.query(query, variables: Variables(id: pullRequestID, after: after), as: ViewedStatesPage.self)
            guard let files = page.node?.files else { break }
            for file in files.nodes {
                states[file.path] = FileViewedState(rawValue: file.viewerViewedState) ?? .unviewed
            }
            guard files.pageInfo.hasNextPage, let cursor = files.pageInfo.endCursor else { break }
            after = cursor
        }
        return states
    }
}
