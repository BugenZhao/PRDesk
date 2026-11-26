import Foundation

/// The queries behind the detail pane: body and full timeline of one item, and separately its checks,
/// so the two run side by side (GitHub takes a second or two on each).
enum DetailQuery {
    private static let actor = "{ __typename login }"
    /// Only the first few reactors, for the tooltip; the groups come back for every kind, even unused.
    private static let reactions = "reactionGroups { content viewerHasReacted reactors(first: 10) { totalCount nodes { ... on User { login } ... on Bot { login } ... on Organization { login } ... on Mannequin { login } } } }"

    private static let timelineFragment = """
    fragment TimelineFields on PullRequestTimelineItems {
      __typename
      ... on IssueComment { id author \(actor) createdAt bodyHTML bodyText url \(reactions) }
      ... on PullRequestReview {
        id author \(actor) state submittedAt createdAt bodyHTML bodyText url \(reactions) reviewCommit: commit { oid }
        comments(first: 50) { nodes { id path line originalLine diffHunk bodyHTML outdated url \(reactions) } }
      }
      ... on PullRequestCommit { id url commit { abbreviatedOid messageHeadline committedDate author { user { login } name } } }
      ... on HeadRefForcePushedEvent { id actor \(actor) createdAt beforeCommit { oid } afterCommit { oid abbreviatedOid } }
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
      ... on AddedToStackEvent { id actor \(actor) createdAt stackNumber }
      ... on RemovedFromStackEvent { id actor \(actor) createdAt stackNumber }
    }
    """

    private static let prTypes = "[ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, REVIEW_REQUESTED_EVENT, REVIEW_DISMISSED_EVENT, LABELED_EVENT, UNLABELED_EVENT, CROSS_REFERENCED_EVENT, ASSIGNED_EVENT, RENAMED_TITLE_EVENT, ADDED_TO_STACK_EVENT, REMOVED_FROM_STACK_EVENT]"
    private static let issueTypes = "[ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT, LABELED_EVENT, UNLABELED_EVENT, CROSS_REFERENCED_EVENT, ASSIGNED_EVENT, RENAMED_TITLE_EVENT]"

    /// A page of the timeline. The first page also brings the item as the lists store it (`item`,
    /// the list's own fields), so opening an item brings its row up to date with what it shows.
    static let text = """
    query($owner: String!, $name: String!, $number: Int!, $after: String, $withItem: Boolean!) {
      repository(owner: $owner, name: $name) {
        item: issueOrPullRequest(number: $number) @include(if: $withItem) { __typename ...PRFields ...IssueFields }
        issueOrPullRequest(number: $number) {
          __typename
          ... on PullRequest {
            id bodyHTML bodyText headRefName baseRefName updatedAt \(reactions)
            stack {
              number
              entries(first: 30) {
                nodes { position pullRequest { number title state isDraft mergedAt closedAt baseRefName headRefName } }
              }
            }
            timelineItems(first: 100, after: $after, itemTypes: \(prTypes)) {
              pageInfo { hasNextPage endCursor }
              nodes { ...TimelineFields }
            }
          }
          ... on Issue {
            id bodyHTML bodyText updatedAt \(reactions)
            timelineItems(first: 100, after: $after, itemTypes: \(issueTypes)) {
              pageInfo { hasNextPage endCursor }
              nodes { ...TimelineFields }
            }
          }
        }
      }
    }
    \(timelineFragment)
    \(ItemQuery.fragments)
    """

    private static let contextFragment = """
    fragment ContextFields on StatusCheckRollupContext {
      __typename
      ... on CheckRun { name status conclusion detailsUrl startedAt completedAt title checkSuite { app { name } } }
      ... on StatusContext { context state targetUrl description createdAt }
    }
    """

    /// A page of the checks on a PR's latest commit.
    static let checks = """
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

    /// A PR's latest commits, oldest first, for the Commits tab.
    static let commits = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          commits(last: 100) {
            nodes {
              commit {
                oid abbreviatedOid messageHeadline committedDate url additions deletions
                parents(first: 1) { totalCount nodes { oid } }
                author { user { login } name }
                statusCheckRollup { state }
              }
            }
          }
        }
      }
    }
    """

    struct CommitsResponse: Decodable, Sendable {
        struct Repository: Decodable, Sendable {
            struct PullRequest: Decodable, Sendable { let commits: Nodes<Node> }
            let pullRequest: PullRequest?
        }

        struct Node: Decodable, Sendable {
            struct Commit: Decodable, Sendable {
                struct Rollup: Decodable, Sendable { let state: String }
                struct Parent: Decodable, Sendable { let oid: String }
                struct Parents: Decodable, Sendable { let totalCount: Int; let nodes: [Parent?]? }
                let oid: String
                let abbreviatedOid: String
                let messageHeadline: String
                let committedDate: Date
                let url: String
                let additions: Int
                let deletions: Int
                let parents: Parents
                let author: DetailQuery.Node.Commit.Author?
                let statusCheckRollup: Rollup?
            }

            let commit: Commit

            var prCommit: PRCommit {
                PRCommit(
                    oid: commit.oid, shortOid: commit.abbreviatedOid, headline: commit.messageHeadline,
                    committedAt: commit.committedDate, url: commit.url,
                    parentOid: commit.parents.nodes?.first??.oid, parentCount: commit.parents.totalCount,
                    author: commit.author?.user?.login, authorName: commit.author?.name,
                    ciState: commit.statusCheckRollup?.state, additions: commit.additions, deletions: commit.deletions
                )
            }
        }

        let repository: Repository?
    }

    struct ChecksResponse: Decodable, Sendable {
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

    struct TimelineVariables: Encodable, Sendable {
        var owner: String
        var name: String
        var number: Int
        var after: String?
        var withItem: Bool
    }

    struct Response: Decodable, Sendable {
        struct Repository: Decodable, Sendable {
            let issueOrPullRequest: Subject?
            /// Only on the first page.
            let item: ItemQuery.Node?
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
        let reactionGroups: [ReactionGroup]?
        let stack: Stack?
        let timelineItems: Timeline
    }

    struct Stack: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            struct PullRequest: Decodable, Sendable {
                let number: Int
                let title: String
                let state: String
                let isDraft: Bool
                let mergedAt: Date?
                let closedAt: Date?
                let baseRefName: String
                let headRefName: String
            }

            let position: Int
            let pullRequest: PullRequest?
        }

        let number: Int
        let entries: Nodes<Entry>

        var stack: PRStack {
            PRStack(number: number, entries: entries.values.compactMap { entry in
                entry.pullRequest.map { pr in
                    PRStack.Entry(
                        position: entry.position, number: pr.number, title: pr.title,
                        state: pr.state == "MERGED" ? .merged : pr.state == "CLOSED" ? .closed : .open,
                        isDraft: pr.isDraft, closedAt: pr.mergedAt ?? pr.closedAt, baseRef: pr.baseRefName, headRef: pr.headRefName
                    )
                }
            }.sorted { $0.position < $1.position })
        }
    }

    struct ReactionGroup: Decodable, Sendable {
        struct Reactors: Decodable, Sendable {
            struct Reactor: Decodable, Sendable { let login: String? }
            let totalCount: Int
            let nodes: [Reactor?]?
        }

        let content: String
        let viewerHasReacted: Bool
        let reactors: Reactors

        /// The groups people used, in GitHub's order; unknown kinds are left out.
        static func reactions(_ groups: [ReactionGroup]?) -> [Reaction] {
            (groups ?? []).compactMap { group in
                guard group.reactors.totalCount > 0, let content = Reaction.Content(rawValue: group.content) else { return nil }
                return Reaction(
                    content: content, count: group.reactors.totalCount, viewerHasReacted: group.viewerHasReacted,
                    logins: group.reactors.nodes?.compactMap { $0?.login } ?? []
                )
            }
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
                let reactionGroups: [ReactionGroup]?
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

        struct AfterCommit: Decodable, Sendable { let oid: String; let abbreviatedOid: String }
        struct Oid: Decodable, Sendable { let oid: String }

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
        let reactionGroups: [ReactionGroup]?
        let comments: Comments?
        let commit: Commit?
        let afterCommit: AfterCommit?
        let beforeCommit: Oid?
        let reviewCommit: Oid?
        let requestedReviewer: Reviewer?
        let label: Label?
        let source: Source?
        let assignee: Reviewer?
        let currentTitle: String?
        let stackNumber: Int?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, author, actor, createdAt, submittedAt, state, bodyHTML, bodyText, url, reactionGroups, comments, commit
            case afterCommit, beforeCommit, reviewCommit, requestedReviewer, label, source, assignee, currentTitle, stackNumber
        }

        var entry: TimelineEntry? {
            guard let id else { return nil }
            let who = author ?? actor
            func make(_ kind: TimelineEntry.Kind, at date: Date?, detail: String? = nil, color: String? = nil) -> TimelineEntry? {
                date.map {
                    TimelineEntry(id: id, kind: kind, actor: who?.login, isAutomated: who?.isAutomated ?? false, at: $0, url: url,
                                  bodyHTML: bodyHTML, bodyText: bodyText, detail: detail, color: color,
                                  reactions: ReactionGroup.reactions(reactionGroups))
                }
            }
            switch typename {
            case "IssueComment":
                var entry = make(.comment, at: createdAt)
                // "@codex review", "/ci run" and the like drive tooling; hidden with the automation.
                if let bodyText, Item.Event.isCommand(bodyText) {
                    entry?.isAutomated = true
                }
                return entry
            case "PullRequestReview":
                guard state != "PENDING" else { return nil }
                let kind: TimelineEntry.Kind = switch state {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                default: .reviewed
                }
                var entry = make(kind, at: submittedAt ?? createdAt)
                entry?.oid = reviewCommit?.oid
                entry?.reviewComments = comments?.nodes?.compactMap { comment in
                    comment.map {
                        ReviewComment(id: $0.id, path: $0.path, line: $0.line ?? $0.originalLine, diffHunk: $0.diffHunk,
                                      bodyHTML: $0.bodyHTML, outdated: $0.outdated, url: $0.url,
                                      reactions: ReactionGroup.reactions($0.reactionGroups))
                    }
                } ?? []
                return entry
            case "PullRequestCommit":
                guard let commit else { return nil }
                let login = commit.author?.user?.login
                return TimelineEntry(id: id, kind: .commit, actor: login ?? commit.author?.name, isAutomated: login.map(Item.Event.isAutomationLogin) ?? false,
                                     at: commit.committedDate, url: url, detail: "\(commit.abbreviatedOid) \(commit.messageHeadline)")
            case "HeadRefForcePushedEvent":
                var entry = make(.forcePush, at: createdAt, detail: afterCommit?.abbreviatedOid)
                entry?.oid = afterCommit?.oid
                entry?.beforeOid = beforeCommit?.oid
                return entry
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
            case "AddedToStackEvent": return make(.addedToStack, at: createdAt, detail: stackNumber.map(String.init))
            case "RemovedFromStackEvent": return make(.removedFromStack, at: createdAt, detail: stackNumber.map(String.init))
            default: return nil
            }
        }
    }
}

extension SyncEngine {
    /// Fetches the full detail of one item, following timeline pages. A PR's checks are fetched
    /// alongside the timeline rather than after it. The item comes along as the lists see it, and
    /// is stored if it is already (`AppDatabase.refreshStored`): `nil` if GitHub gave none.
    func fetchDetail(of item: Item) async throws -> (detail: ItemDetail, item: Item?) {
        let (owner, name) = Self.split(item.repo)
        let number = item.number
        async let checks = item.kind == .pullRequest ? fetchChecks(owner: owner, name: name, number: number) : []
        async let commits = item.kind == .pullRequest ? fetchCommits(owner: owner, name: name, number: number) : []
        var after: String?
        var entries: [TimelineEntry] = []
        var first: DetailQuery.Subject?
        var fresh: Item?
        repeat {
            let response = try await client.query(
                DetailQuery.text,
                variables: DetailQuery.TimelineVariables(owner: owner, name: name, number: number, after: after, withItem: first == nil),
                as: DetailQuery.Response.self
            )
            guard let subject = response.repository?.issueOrPullRequest else { throw SyncError.notFound(repo: item.repo, number: number) }
            if first == nil { fresh = response.repository?.item?.item(fetchedAt: Date()) }
            first = first ?? subject
            entries += subject.timelineItems.nodes.compactMap { $0?.entry }
            after = subject.timelineItems.pageInfo.hasNextPage ? subject.timelineItems.pageInfo.endCursor : nil
        } while after != nil && entries.count < 2000

        let subject = first!
        if let fresh { try await db.refreshStored(fresh) }
        let detail = try await ItemDetail(
            number: number,
            id: subject.id,
            bodyHTML: subject.bodyHTML,
            bodyText: subject.bodyText,
            headRef: subject.headRefName,
            baseRef: subject.baseRefName,
            stack: subject.stack?.stack,
            reactions: DetailQuery.ReactionGroup.reactions(subject.reactionGroups),
            entries: entries,
            checks: checks,
            commits: commits,
            itemUpdatedAt: subject.updatedAt,
            fetchedAt: Date()
        )
        return (detail, fresh)
    }

    /// A PR's latest 100 commits, oldest first.
    private func fetchCommits(owner: String, name: String, number: Int) async throws -> [PRCommit] {
        let response = try await client.query(
            DetailQuery.commits,
            variables: ItemQuery.NumberVariables(owner: owner, name: name, number: number),
            as: DetailQuery.CommitsResponse.self
        )
        return response.repository?.pullRequest?.commits.values.map(\.prCommit) ?? []
    }

    /// The checks on a PR's latest commit, following pages.
    private func fetchChecks(owner: String, name: String, number: Int) async throws -> [Check] {
        var checks: [Check] = []
        var after: String?
        repeat {
            let response = try await client.query(
                DetailQuery.checks,
                variables: DetailQuery.Variables(owner: owner, name: name, number: number, after: after),
                as: DetailQuery.ChecksResponse.self
            )
            let contexts = response.repository?.pullRequest?.commits.values.last?.commit.statusCheckRollup?.contexts
            checks += contexts?.checks ?? []
            after = contexts.flatMap { $0.pageInfo.hasNextPage ? $0.pageInfo.endCursor : nil }
        } while after != nil && checks.count < 1000
        return checks
    }
}
