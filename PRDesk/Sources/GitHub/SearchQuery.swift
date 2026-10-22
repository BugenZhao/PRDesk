import Foundation

/// The issue/PR search used for syncing, and the response shapes it decodes into.
enum SearchQuery {
    static let pageSize = 50
    /// GitHub search never returns more than this many results for one query.
    static let resultCap = 1000

    static let text = """
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: \(pageSize), after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequest {
            id number title url state isDraft createdAt updatedAt closedAt
            author { login avatarUrl }
            additions deletions reviewDecision mergeable
            labels(first: 20) { nodes { name color } }
            reviewRequests(first: 30) {
              nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } }
            }
            latestOpinionatedReviews(first: 30) { nodes { author { login } state submittedAt } }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    state
                    contexts(first: 1) {
                      totalCount
                      checkRunCountsByState { state count }
                      statusContextCountsByState { state count }
                    }
                  }
                }
              }
            }
          }
          ... on Issue {
            id number title url state createdAt updatedAt closedAt
            author { login avatarUrl }
            labels(first: 20) { nodes { name color } }
            assignees(first: 10) { nodes { login } }
          }
        }
      }
    }
    """

    static let viewerText = "query { viewer { login } }"

    struct Variables: Encodable, Sendable {
        var q: String
        var after: String?
    }

    struct Response: Decodable, Sendable {
        let search: Connection
    }

    struct ViewerResponse: Decodable, Sendable {
        struct Viewer: Decodable, Sendable { let login: String }
        let viewer: Viewer
    }

    struct Connection: Decodable, Sendable {
        struct PageInfo: Decodable, Sendable {
            let hasNextPage: Bool
            let endCursor: String?
        }

        let issueCount: Int
        let pageInfo: PageInfo
        let nodes: [Node?]
    }

    enum Node: Decodable, Sendable {
        case pullRequest(PullRequest)
        case issue(Issue)
        case other

        private enum TypeKey: String, CodingKey { case typename = "__typename" }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: TypeKey.self)
            switch try container.decode(String.self, forKey: .typename) {
            case "PullRequest": self = try .pullRequest(PullRequest(from: decoder))
            case "Issue": self = try .issue(Issue(from: decoder))
            default: self = .other
            }
        }

        func item(fetchedAt: Date) -> Item? {
            switch self {
            case let .pullRequest(pr): pr.item(fetchedAt: fetchedAt)
            case let .issue(issue): issue.item(fetchedAt: fetchedAt)
            case .other: nil
            }
        }
    }

    // MARK: Node shapes

    struct Nodes<T: Decodable & Sendable>: Decodable, Sendable {
        let nodes: [T?]?

        var values: [T] { nodes?.compactMap(\.self) ?? [] }
    }

    struct Actor: Decodable, Sendable {
        let login: String
        let avatarUrl: String?
    }

    struct Label: Decodable, Sendable {
        let name: String
        let color: String
    }

    struct Login: Decodable, Sendable {
        let login: String
    }

    struct ReviewRequest: Decodable, Sendable {
        struct Reviewer: Decodable, Sendable {
            let login: String?
            let slug: String?
        }

        let requestedReviewer: Reviewer?
    }

    struct Review: Decodable, Sendable {
        let author: Login?
        let state: String
        let submittedAt: Date?
    }

    struct Commit: Decodable, Sendable {
        struct Inner: Decodable, Sendable {
            let statusCheckRollup: Rollup?
        }

        let commit: Inner
    }

    struct Rollup: Decodable, Sendable {
        struct StateCount: Decodable, Sendable {
            let state: String
            let count: Int
        }

        struct Contexts: Decodable, Sendable {
            let totalCount: Int
            let checkRunCountsByState: [StateCount]?
            let statusContextCountsByState: [StateCount]?
        }

        let state: String
        let contexts: Contexts

        private static let failedCheckRuns: Set = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"]
        private static let pendingCheckRuns: Set = ["IN_PROGRESS", "PENDING", "QUEUED", "WAITING", "REQUESTED"]
        private static let failedStatuses: Set = ["FAILURE", "ERROR"]
        private static let pendingStatuses: Set = ["PENDING", "EXPECTED"]

        var status: Item.CIStatus {
            func sum(_ counts: [StateCount]?, _ states: Set<String>) -> Int {
                (counts ?? []).filter { states.contains($0.state) }.reduce(0) { $0 + $1.count }
            }
            return Item.CIStatus(
                state: state,
                total: contexts.totalCount,
                failed: sum(contexts.checkRunCountsByState, Self.failedCheckRuns)
                    + sum(contexts.statusContextCountsByState, Self.failedStatuses),
                pending: sum(contexts.checkRunCountsByState, Self.pendingCheckRuns)
                    + sum(contexts.statusContextCountsByState, Self.pendingStatuses)
            )
        }
    }

    struct PullRequest: Decodable, Sendable {
        let id: String
        let number: Int
        let title: String
        let url: String
        let state: String
        let isDraft: Bool
        let createdAt: Date
        let updatedAt: Date
        let closedAt: Date?
        let author: Actor?
        let additions: Int
        let deletions: Int
        let reviewDecision: String?
        let mergeable: String?
        let labels: Nodes<Label>
        let reviewRequests: Nodes<ReviewRequest>
        let latestOpinionatedReviews: Nodes<Review>
        let commits: Nodes<Commit>

        func item(fetchedAt: Date) -> Item {
            Item(
                id: id,
                number: number,
                kind: .pullRequest,
                title: title,
                url: url,
                state: Item.State(graphQL: state),
                isDraft: isDraft,
                author: author?.login,
                authorAvatarURL: author?.avatarUrl,
                createdAt: createdAt,
                updatedAt: updatedAt,
                closedAt: closedAt,
                additions: additions,
                deletions: deletions,
                reviewDecision: reviewDecision,
                mergeable: mergeable,
                ci: commits.values.last?.commit.statusCheckRollup?.status,
                labels: labels.values.map { Item.Label(name: $0.name, color: $0.color) },
                reviews: latestOpinionatedReviews.values.compactMap { review in
                    review.author.map { Item.Review(login: $0.login, state: review.state, submittedAt: review.submittedAt) }
                },
                reviewRequests: reviewRequests.values.compactMap { request in
                    guard let reviewer = request.requestedReviewer else { return nil }
                    return reviewer.login ?? reviewer.slug.map { "team:\($0)" }
                },
                assignees: [],
                fetchedAt: fetchedAt
            )
        }
    }

    struct Issue: Decodable, Sendable {
        let id: String
        let number: Int
        let title: String
        let url: String
        let state: String
        let createdAt: Date
        let updatedAt: Date
        let closedAt: Date?
        let author: Actor?
        let labels: Nodes<Label>
        let assignees: Nodes<Login>

        func item(fetchedAt: Date) -> Item {
            Item(
                id: id,
                number: number,
                kind: .issue,
                title: title,
                url: url,
                state: Item.State(graphQL: state),
                isDraft: false,
                author: author?.login,
                authorAvatarURL: author?.avatarUrl,
                createdAt: createdAt,
                updatedAt: updatedAt,
                closedAt: closedAt,
                additions: nil,
                deletions: nil,
                reviewDecision: nil,
                mergeable: nil,
                ci: nil,
                labels: labels.values.map { Item.Label(name: $0.name, color: $0.color) },
                reviews: [],
                reviewRequests: [],
                assignees: assignees.values.map(\.login),
                fetchedAt: fetchedAt
            )
        }
    }
}

private extension Item.State {
    init(graphQL state: String) {
        switch state {
        case "MERGED": self = .merged
        case "CLOSED": self = .closed
        default: self = .open
        }
    }
}
