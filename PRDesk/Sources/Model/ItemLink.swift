import Foundation

/// An issue or PR of a repository the app shows, as a browser tab, a pasted link or the filter
/// field names it: `https://github.com/<owner>/<repo>/(pull|issues)/<n>[/files][#issuecomment-…]`,
/// `<owner>/<repo>#<n>`, or `#<n>` for the main repository.
struct ItemLink: Equatable, Sendable {
    enum Page: Equatable, Sendable {
        case conversation, checks, files
    }

    /// `owner/name`, lowercased.
    var repo: String
    var number: Int
    /// The part of the PR the link shows.
    var page: Page = .conversation
    /// A comment or review it points to, as GitHub's fragment (`#issuecomment-…`), if any.
    var anchor: String?

    /// The item's `Item.repoNumber`.
    var key: String { "\(repo)#\(number)" }

    /// The repositories whose items open in the app: vllm and the parity agent's fork.
    static let repos = [SyncEngine.repo.lowercased(), Parity.repo.lowercased()]

    nonisolated(unsafe) private static let urlPattern = /^(?:https?:\/\/)?(?:www\.)?github\.com\/([^\/\s]+\/[^\/\s]+)\/(?:pull|issues)\/(\d+)(\/[^?#\s]*)?(?:\?[^#\s]*)?(#\S+)?$/.ignoresCase()
    nonisolated(unsafe) private static let shortPattern = /^(?:([^\/\s#]+\/[^\/\s#]+))?#(\d+)$/
    /// The tail of GitHub's page titles: `… · Pull Request #123 · owner/repo`.
    nonisolated(unsafe) private static let titlePattern = /·\s+(?:Pull Request|Issue)\s+#(\d+)\s+·\s+([^\/\s]+\/[^\/\s]+)\s*$/

    /// Reads a link or reference, or nil if it isn't one to an item of `repos`.
    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = try? Self.urlPattern.wholeMatch(in: text) {
            self.init(repo: String(match.1), number: String(match.2))
            switch match.3.map({ $0.lowercased() }) {
            case "/files"?, "/changes"?: page = .files
            case "/checks"?: page = .checks
            default: break
            }
            // Comments and reviews; not file or line fragments (`#diff-…`), which only the browser has.
            if let fragment = match.4, fragment.wholeMatch(of: /#(?:issuecomment|discussion_r|pullrequestreview)-?\d+/) != nil {
                anchor = String(fragment)
            }
        } else if let match = try? Self.shortPattern.wholeMatch(in: text) {
            self.init(repo: match.1.map(String.init) ?? SyncEngine.repo, number: String(match.2))
        } else {
            return nil
        }
    }

    /// Reads the item from a GitHub page's title, for a tab whose address isn't known.
    init?(pageTitle: String) {
        guard let match = try? Self.titlePattern.firstMatch(in: pageTitle) else { return nil }
        self.init(repo: String(match.2), number: String(match.1))
    }

    private init?(repo: String, number: String) {
        let repo = repo.lowercased()
        guard Self.repos.contains(repo), let number = Int(number) else { return nil }
        self.repo = repo
        self.number = number
    }
}
