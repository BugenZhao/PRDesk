import Foundation

/// GraphQL queries that fetch list-level item data, and the response shapes they decode into.
enum ItemQuery {
    static let pageSize = 50
    /// GitHub search never returns more than this many results for one query.
    static let resultCap = 1000

    private static let actor = "{ __typename login }"

    /// Recent events used for Turn, unread state and the summary next to the title.
    private static let prEvents = """
    timelineItems(last: 12, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT, REVIEW_REQUESTED_EVENT]) {
      nodes {
        __typename
        ... on IssueComment { author \(actor) createdAt }
        ... on PullRequestReview { author \(actor) state submittedAt createdAt }
        ... on PullRequestCommit { commit { committedDate author { user { login } } } }
        ... on HeadRefForcePushedEvent { actor \(actor) createdAt }
        ... on MergedEvent { actor \(actor) createdAt }
        ... on ClosedEvent { actor \(actor) createdAt }
        ... on ReopenedEvent { actor \(actor) createdAt }
        ... on ReadyForReviewEvent { actor \(actor) createdAt }
        ... on ReviewRequestedEvent { actor \(actor) createdAt requestedReviewer { ... on User { login } } }
      }
    }
    """

    private static let issueEvents = """
    timelineItems(last: 12, itemTypes: [ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT]) {
      nodes {
        __typename
        ... on IssueComment { author \(actor) createdAt }
        ... on ClosedEvent { actor \(actor) createdAt }
        ... on ReopenedEvent { actor \(actor) createdAt }
      }
    }
    """

    static let fragments = """
    fragment PRFields on PullRequest {
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
      \(prEvents)
    }
    fragment IssueFields on Issue {
      id number title url state createdAt updatedAt closedAt
      author { login avatarUrl }
      labels(first: 20) { nodes { name color } }
      assignees(first: 10) { nodes { login } }
      \(issueEvents)
    }
    """

    static let search = """
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: \(pageSize), after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes { __typename ...PRFields ...IssueFields }
      }
    }
    \(fragments)
    """

    static let nodes = """
    query($ids: [ID!]!) {
      nodes(ids: $ids) { __typename ...PRFields ...IssueFields }
    }
    \(fragments)
    """

    static let byNumber = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issueOrPullRequest(number: $number) { __typename ...PRFields ...IssueFields }
      }
    }
    \(fragments)
    """

    static let viewer = "query { viewer { login } }"

    // MARK: Variables and responses

    struct SearchVariables: Encodable, Sendable {
        var q: String
        var after: String?
    }

    struct NodesVariables: Encodable, Sendable {
        var ids: [String]
    }

    struct NumberVariables: Encodable, Sendable {
        var owner: String
        var name: String
        var number: Int
    }

    struct SearchResponse: Decodable, Sendable {
        let search: Connection
    }

    struct NodesResponse: Decodable, Sendable {
        let nodes: [Node?]
    }

    struct NumberResponse: Decodable, Sendable {
        struct Repository: Decodable, Sendable {
            let issueOrPullRequest: Node?
        }

        let repository: Repository?
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

    /// An event actor; `__typename` tells bots apart.
    struct TypedActor: Decodable, Sendable {
        let typename: String?
        let login: String

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case login
        }

        var isBot: Bool { typename == "Bot" || Item.Event.isBotLogin(login) }
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

    /// One timeline node; which fields are present depends on `__typename`.
    struct TimelineNode: Decodable, Sendable {
        struct CommitInfo: Decodable, Sendable {
            struct Author: Decodable, Sendable { let user: Login? }
            let committedDate: Date
            let author: Author?
        }

        let typename: String
        let author: TypedActor?
        let actor: TypedActor?
        let createdAt: Date?
        let submittedAt: Date?
        let state: String?
        let commit: CommitInfo?
        /// Empty for team requests.
        let requestedReviewer: ReviewRequest.Reviewer?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case author, actor, createdAt, submittedAt, state, commit, requestedReviewer
        }

        var event: Item.Event? {
            let who = author ?? actor
            func make(_ kind: Item.Event.Kind, at date: Date?, target: String? = nil) -> Item.Event? {
                date.map { Item.Event(kind: kind, actor: who?.login, isBot: who?.isBot ?? false, at: $0, target: target) }
            }
            switch typename {
            case "IssueComment":
                return make(.comment, at: createdAt)
            case "PullRequestReview":
                // A pending review is the viewer's unsubmitted draft.
                guard state != "PENDING" else { return nil }
                let kind: Item.Event.Kind = switch state {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                default: .reviewed
                }
                return make(kind, at: submittedAt ?? createdAt)
            case "PullRequestCommit":
                guard let commit else { return nil }
                let login = commit.author?.user?.login
                return Item.Event(kind: .commit, actor: login, isBot: login.map(Item.Event.isBotLogin) ?? false, at: commit.committedDate, target: nil)
            case "HeadRefForcePushedEvent": return make(.forcePush, at: createdAt)
            case "MergedEvent": return make(.merged, at: createdAt)
            case "ClosedEvent": return make(.closed, at: createdAt)
            case "ReopenedEvent": return make(.reopened, at: createdAt)
            case "ReadyForReviewEvent": return make(.readyForReview, at: createdAt)
            case "ReviewRequestedEvent": return make(.reviewRequested, at: createdAt, target: requestedReviewer?.login)
            default: return nil
            }
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
        let timelineItems: Nodes<TimelineNode>

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
                events: timelineItems.values.compactMap(\.event),
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
        let timelineItems: Nodes<TimelineNode>

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
                events: timelineItems.values.compactMap(\.event),
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
