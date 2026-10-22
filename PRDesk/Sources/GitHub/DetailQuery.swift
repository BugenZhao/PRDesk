import Foundation

/// The query behind the detail pane: body, full timeline and checks of one item.
enum DetailQuery {
    private static let actor = "{ __typename login }"

    private static let timelineFragment = """
    fragment TimelineFields on PullRequestTimelineItems {
      __typename
      ... on IssueComment { id author \(actor) createdAt bodyHTML bodyText url }
      ... on PullRequestReview {
        id author \(actor) state submittedAt createdAt bodyHTML bodyText url
        comments(first: 50) { nodes { id path line originalLine diffHunk bodyHTML outdated url } }
      }
      ... on PullRequestCommit { id url commit { abbreviatedOid messageHeadline committedDate author { user { login } name } } }
      ... on HeadRefForcePushedEvent { id actor \(actor) createdAt afterCommit { abbreviatedOid } }
      ... on MergedEvent { id actor \(actor) createdAt }
      ... on ClosedEvent { id actor \(actor) createdAt }
      ... on ReopenedEvent { id actor \(actor) createdAt }
      ... on ReadyForReviewEvent { id actor \(actor) createdAt }
      ... on ConvertToDraftEvent { id actor \(actor) createdAt }
      ... on ReviewRequestedEvent { id actor \(actor) createdAt requestedReviewer { ... on User { login } ... on Team { name } } }
      ... on ReviewDismissedEvent { id actor \(actor) createdAt }
      ... on LabeledEvent { id actor \(actor) createdAt label { name color } }
      ... on UnlabeledEvent { id actor \(actor) createdAt label { name color } }
      ... on CrossReferencedEvent {
        id actor \(actor) createdAt
        source { __typename ... on PullRequest { number title url } ... on Issue { number title url } }
      }
      ... on AssignedEvent { id actor \(actor) createdAt assignee { ... on User { login } } }
      ... on RenamedTitleEvent { id actor \(actor) createdAt currentTitle }
    }
    """

    private static let prTypes = "[ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, REVIEW_REQUESTED_EVENT, REVIEW_DISMISSED_EVENT, LABELED_EVENT, UNLABELED_EVENT, CROSS_REFERENCED_EVENT, ASSIGNED_EVENT, RENAMED_TITLE_EVENT]"
    private static let issueTypes = "[ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT, LABELED_EVENT, UNLABELED_EVENT, CROSS_REFERENCED_EVENT, ASSIGNED_EVENT, RENAMED_TITLE_EVENT]"

    static let text = """
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        issueOrPullRequest(number: $number) {
          __typename
          ... on PullRequest {
            id bodyHTML bodyText headRefName baseRefName updatedAt
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: 100) {
                      pageInfo { hasNextPage endCursor }
                      nodes { ...ContextFields }
                    }
                  }
                }
              }
            }
            timelineItems(first: 100, after: $after, itemTypes: \(prTypes)) {
              pageInfo { hasNextPage endCursor }
              nodes { ...TimelineFields }
            }
          }
          ... on Issue {
            id bodyHTML bodyText updatedAt
            timelineItems(first: 100, after: $after, itemTypes: \(issueTypes)) {
              pageInfo { hasNextPage endCursor }
              nodes { ...TimelineFields }
            }
          }
        }
      }
    }
    \(timelineFragment)
    \(contextFragment)
    """

    private static let contextFragment = """
    fragment ContextFields on StatusCheckRollupContext {
      __typename
      ... on CheckRun { name status conclusion detailsUrl startedAt completedAt title checkSuite { app { name } } }
      ... on StatusContext { context state targetUrl description createdAt }
    }
    """

    /// Further pages of checks, for PRs with more than 100.
    static let moreChecks = """
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  contexts(first: 100, after: $after) {
                    pageInfo { hasNextPage endCursor }
                    nodes { ...ContextFields }
                  }
                }
              }
            }
          }
        }
      }
    }
    \(contextFragment)
    """

    struct MoreChecksResponse: Decodable, Sendable {
        struct Repository: Decodable, Sendable {
            struct PullRequest: Decodable, Sendable { let commits: Nodes<Subject.Commit> }
            let pullRequest: PullRequest?
        }

        let repository: Repository?
    }

    struct Variables: Encodable, Sendable {
        var owner: String
        var name: String
        var number: Int
        var after: String?
    }

    struct Response: Decodable, Sendable {
        struct Repository: Decodable, Sendable {
            let issueOrPullRequest: Subject?
        }

        let repository: Repository?
    }

    typealias Nodes = ItemQuery.Nodes
    typealias TypedActor = ItemQuery.TypedActor

    struct Subject: Decodable, Sendable {
        struct Timeline: Decodable, Sendable {
            let pageInfo: ItemQuery.Connection.PageInfo
            let nodes: [Node?]
        }

        struct Commit: Decodable, Sendable {
            struct Inner: Decodable, Sendable {
                struct Rollup: Decodable, Sendable { let contexts: Contexts }
                let statusCheckRollup: Rollup?
            }

            let commit: Inner
        }

        let id: String
        let bodyHTML: String
        let bodyText: String
        let headRefName: String?
        let baseRefName: String?
        let updatedAt: Date
        let commits: Nodes<Commit>?
        let timelineItems: Timeline

        var contexts: Contexts? {
            commits?.values.last?.commit.statusCheckRollup?.contexts
        }
    }

    struct Contexts: Decodable, Sendable {
        let pageInfo: ItemQuery.Connection.PageInfo
        let nodes: [Context?]

        var checks: [Check] { nodes.compactMap { $0?.check } }
    }

    struct Context: Decodable, Sendable {
        struct Suite: Decodable, Sendable {
            struct App: Decodable, Sendable { let name: String }
            let app: App?
        }

        let typename: String
        // CheckRun
        let name: String?
        let status: String?
        let conclusion: String?
        let detailsUrl: String?
        let startedAt: Date?
        let completedAt: Date?
        let title: String?
        let checkSuite: Suite?
        // StatusContext
        let context: String?
        let state: String?
        let targetUrl: String?
        let description: String?
        let createdAt: Date?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case name, status, conclusion, detailsUrl, startedAt, completedAt, title, checkSuite
            case context, state, targetUrl, description, createdAt
        }

        var check: Check? {
            switch typename {
            case "CheckRun":
                guard let name else { return nil }
                let state: Check.State = switch (status, conclusion) {
                case (_, "SUCCESS"), (_, "NEUTRAL"): .passed
                case (_, "SKIPPED"): .skipped
                case (_, "FAILURE"), (_, "TIMED_OUT"), (_, "STARTUP_FAILURE"), (_, "ACTION_REQUIRED"): .failed
                case (_, "CANCELLED"), (_, "STALE"): .skipped
                default: .pending
                }
                return Check(name: name, app: checkSuite?.app?.name, state: state, url: detailsUrl, summary: title, startedAt: startedAt, completedAt: completedAt)
            case "StatusContext":
                guard let context else { return nil }
                let state: Check.State = switch self.state {
                case "SUCCESS": .passed
                case "FAILURE", "ERROR": .failed
                default: .pending
                }
                return Check(name: context, app: nil, state: state, url: targetUrl, summary: description, startedAt: createdAt, completedAt: nil)
            default:
                return nil
            }
        }
    }

    struct Node: Decodable, Sendable {
        struct Commit: Decodable, Sendable {
            struct Author: Decodable, Sendable {
                let user: ItemQuery.Login?
                let name: String?
            }

            let abbreviatedOid: String
            let messageHeadline: String
            let committedDate: Date
            let author: Author?
        }

        struct Comments: Decodable, Sendable {
            struct Comment: Decodable, Sendable {
                let id: String
                let path: String
                let line: Int?
                let originalLine: Int?
                let diffHunk: String
                let bodyHTML: String
                let outdated: Bool
                let url: String
            }

            let nodes: [Comment?]?
        }

        struct Label: Decodable, Sendable {
            let name: String
            let color: String
        }

        struct Source: Decodable, Sendable {
            let number: Int?
            let title: String?
            let url: String?
        }

        struct Reviewer: Decodable, Sendable {
            let login: String?
            let name: String?
        }

        struct AfterCommit: Decodable, Sendable { let abbreviatedOid: String }

        let typename: String
        let id: String?
        let author: TypedActor?
        let actor: TypedActor?
        let createdAt: Date?
        let submittedAt: Date?
        let state: String?
        let bodyHTML: String?
        let bodyText: String?
        let url: String?
        let comments: Comments?
        let commit: Commit?
        let afterCommit: AfterCommit?
        let requestedReviewer: Reviewer?
        let label: Label?
        let source: Source?
        let assignee: Reviewer?
        let currentTitle: String?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, author, actor, createdAt, submittedAt, state, bodyHTML, bodyText, url, comments, commit
            case afterCommit, requestedReviewer, label, source, assignee, currentTitle
        }

        var entry: TimelineEntry? {
            guard let id else { return nil }
            let who = author ?? actor
            func make(_ kind: TimelineEntry.Kind, at date: Date?, detail: String? = nil, color: String? = nil) -> TimelineEntry? {
                date.map {
                    TimelineEntry(id: id, kind: kind, actor: who?.login, isBot: who?.isBot ?? false, at: $0, url: url,
                                  bodyHTML: bodyHTML, bodyText: bodyText, detail: detail, color: color)
                }
            }
            switch typename {
            case "IssueComment":
                return make(.comment, at: createdAt)
            case "PullRequestReview":
                guard state != "PENDING" else { return nil }
                let kind: TimelineEntry.Kind = switch state {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                default: .reviewed
                }
                var entry = make(kind, at: submittedAt ?? createdAt)
                entry?.reviewComments = comments?.nodes?.compactMap { comment in
                    comment.map {
                        ReviewComment(id: $0.id, path: $0.path, line: $0.line ?? $0.originalLine, diffHunk: $0.diffHunk,
                                      bodyHTML: $0.bodyHTML, outdated: $0.outdated, url: $0.url)
                    }
                } ?? []
                return entry
            case "PullRequestCommit":
                guard let commit else { return nil }
                let login = commit.author?.user?.login
                return TimelineEntry(id: id, kind: .commit, actor: login ?? commit.author?.name, isBot: login.map(Item.Event.isBotLogin) ?? false,
                                     at: commit.committedDate, url: url, detail: "\(commit.abbreviatedOid) \(commit.messageHeadline)")
            case "HeadRefForcePushedEvent": return make(.forcePush, at: createdAt, detail: afterCommit?.abbreviatedOid)
            case "MergedEvent": return make(.merged, at: createdAt)
            case "ClosedEvent": return make(.closed, at: createdAt)
            case "ReopenedEvent": return make(.reopened, at: createdAt)
            case "ReadyForReviewEvent": return make(.readyForReview, at: createdAt)
            case "ConvertToDraftEvent": return make(.convertToDraft, at: createdAt)
            case "ReviewRequestedEvent": return make(.reviewRequested, at: createdAt, detail: requestedReviewer?.login ?? requestedReviewer?.name)
            case "ReviewDismissedEvent": return make(.reviewDismissed, at: createdAt)
            case "LabeledEvent": return make(.labeled, at: createdAt, detail: label?.name, color: label?.color)
            case "UnlabeledEvent": return make(.unlabeled, at: createdAt, detail: label?.name, color: label?.color)
            case "CrossReferencedEvent":
                guard let source, let number = source.number else { return nil }
                var entry = make(.crossReferenced, at: createdAt, detail: "#\(number) \(source.title ?? "")")
                entry?.url = source.url
                return entry
            case "AssignedEvent": return make(.assigned, at: createdAt, detail: assignee?.login)
            case "RenamedTitleEvent": return make(.renamed, at: createdAt, detail: currentTitle)
            default: return nil
            }
        }
    }
}

extension SyncEngine {
    /// Fetches the full detail of one item, following timeline pages.
    func fetchDetail(number: Int) async throws -> ItemDetail {
        var after: String?
        var entries: [TimelineEntry] = []
        var first: DetailQuery.Subject?
        repeat {
            let response = try await client.query(
                DetailQuery.text,
                variables: DetailQuery.Variables(owner: Self.owner, name: Self.name, number: number, after: after),
                as: DetailQuery.Response.self
            )
            guard let subject = response.repository?.issueOrPullRequest else { throw SyncError.notFound(number) }
            first = first ?? subject
            entries += subject.timelineItems.nodes.compactMap { $0?.entry }
            after = subject.timelineItems.pageInfo.hasNextPage ? subject.timelineItems.pageInfo.endCursor : nil
        } while after != nil && entries.count < 2000

        let subject = first!
        var checks = subject.contexts?.checks ?? []
        var checksCursor = subject.contexts.flatMap { $0.pageInfo.hasNextPage ? $0.pageInfo.endCursor : nil }
        while let cursor = checksCursor, checks.count < 1000 {
            let response = try await client.query(
                DetailQuery.moreChecks,
                variables: DetailQuery.Variables(owner: Self.owner, name: Self.name, number: number, after: cursor),
                as: DetailQuery.MoreChecksResponse.self
            )
            let contexts = response.repository?.pullRequest?.commits.values.last?.commit.statusCheckRollup?.contexts
            checks += contexts?.checks ?? []
            checksCursor = contexts.flatMap { $0.pageInfo.hasNextPage ? $0.pageInfo.endCursor : nil }
        }
        return ItemDetail(
            number: number,
            id: subject.id,
            bodyHTML: subject.bodyHTML,
            bodyText: subject.bodyText,
            headRef: subject.headRefName,
            baseRef: subject.baseRefName,
            entries: entries,
            checks: checks,
            itemUpdatedAt: subject.updatedAt,
            fetchedAt: Date()
        )
    }
}
