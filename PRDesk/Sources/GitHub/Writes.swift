import Foundation
import os

/// What submitting the composer does.
enum Submission: Sendable {
    case comment
    case approve
    case requestChanges

    var reviewEvent: String? {
        switch self {
        case .comment: nil
        case .approve: "APPROVE"
        case .requestChanges: "REQUEST_CHANGES"
        }
    }
}

/// Why an issue was closed; PRs are closed without one.
enum CloseReason: String, Sendable {
    case completed = "COMPLETED"
    case notPlanned = "NOT_PLANNED"
}

/// A notification thread from the GitHub inbox, for an issue or PR in the repository or the
/// parity fork.
struct InboxNote: Hashable, Sendable {
    var threadID: String
    var repo: String
    var number: Int
    /// GitHub's reason, e.g. `mention`, `review_requested`, `comment`, `author`.
    var reason: String
    var updatedAt: Date
    /// Read on GitHub, or in this session (then it stays listed, without the unread dot, until the
    /// next inbox sync).
    var isRead = false
    /// When the viewer last read the thread, wherever: here, on the web or in GitHub's apps.
    var lastReadAt: Date?

    /// As `Item.repoNumber`.
    var repoNumber: String { "\(repo.lowercased())#\(number)" }

    var isUpstream: Bool { repo.caseInsensitiveCompare(SyncEngine.repo) == .orderedSame }

    var reasonLabel: String {
        switch reason {
        case "review_requested": "Review requested"
        case "team_mention": "Team mention"
        case "state_change": "State change"
        case "ci_activity": "CI"
        default:
            // e.g. "mention" → "Mention", "security_alert" → "Security alert".
            reason.prefix(1).uppercased() + reason.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Decodes any JSON value and throws it away, for mutation results we don't need.
private struct Ignored: Decodable, Sendable {
    init(from _: any Decoder) throws {}
}

/// Debug builds launched with `-PRDeskDryRunWrites YES` log writes to GitHub instead of sending
/// them, so flows that comment or mark notifications read can be tested safely.
func isDryRun(_ what: @autoclosure () -> String) -> Bool {
    #if DEBUG
        if UserDefaults.standard.bool(forKey: "PRDeskDryRunWrites") {
            let message = what()
            Logger(subsystem: "com.bugenzhao.PRDesk", category: "DryRun").notice("Dry run: \(message, privacy: .public)")
            return true
        }
    #endif
    return false
}

extension SyncEngine {
    func submit(_ submission: Submission, body: String, subjectID: String) async throws {
        if isDryRun("submit \(String(describing: submission)) on \(subjectID)") { return }
        if let event = submission.reviewEvent {
            struct Input: Encodable, Sendable { let pullRequestId: String; let event: String; let body: String }
            struct Variables: Encodable, Sendable { let input: Input }
            _ = try await client.query(
                "mutation($input: AddPullRequestReviewInput!) { addPullRequestReview(input: $input) { pullRequestReview { id } } }",
                variables: Variables(input: Input(pullRequestId: subjectID, event: event, body: body)),
                as: [String: Ignored].self,
                strict: true
            )
        } else {
            struct Input: Encodable, Sendable { let subjectId: String; let body: String }
            struct Variables: Encodable, Sendable { let input: Input }
            _ = try await client.query(
                "mutation($input: AddCommentInput!) { addComment(input: $input) { clientMutationId } }",
                variables: Variables(input: Input(subjectId: subjectID, body: body)),
                as: [String: Ignored].self,
                strict: true
            )
        }
    }

    func close(subjectID: String, isPullRequest: Bool, reason: CloseReason?) async throws {
        if isDryRun("close \(subjectID) (\(reason?.rawValue ?? "no reason"))") { return }
        if isPullRequest {
            struct Input: Encodable, Sendable { let pullRequestId: String }
            struct Variables: Encodable, Sendable { let input: Input }
            _ = try await client.query(
                "mutation($input: ClosePullRequestInput!) { closePullRequest(input: $input) { clientMutationId } }",
                variables: Variables(input: Input(pullRequestId: subjectID)),
                as: [String: Ignored].self,
                strict: true
            )
        } else {
            struct Input: Encodable, Sendable { let issueId: String; let stateReason: String? }
            struct Variables: Encodable, Sendable { let input: Input }
            _ = try await client.query(
                "mutation($input: CloseIssueInput!) { closeIssue(input: $input) { clientMutationId } }",
                variables: Variables(input: Input(issueId: subjectID, stateReason: reason?.rawValue)),
                as: [String: Ignored].self,
                strict: true
            )
        }
    }

    /// Renames a PR or issue, then fetches it again so the stored item has GitHub's version.
    func setTitle(_ title: String, subjectID: String, isPullRequest: Bool) async throws {
        if isDryRun("rename \(subjectID) to \(title)") { return }
        if isPullRequest {
            struct Input: Encodable, Sendable { let pullRequestId: String; let title: String }
            struct Variables: Encodable, Sendable { let input: Input }
            _ = try await client.query(
                "mutation($input: UpdatePullRequestInput!) { updatePullRequest(input: $input) { clientMutationId } }",
                variables: Variables(input: Input(pullRequestId: subjectID, title: title)),
                as: [String: Ignored].self,
                strict: true
            )
        } else {
            struct Input: Encodable, Sendable { let id: String; let title: String }
            struct Variables: Encodable, Sendable { let input: Input }
            _ = try await client.query(
                "mutation($input: UpdateIssueInput!) { updateIssue(input: $input) { clientMutationId } }",
                variables: Variables(input: Input(id: subjectID, title: title)),
                as: [String: Ignored].self,
                strict: true
            )
        }
        _ = try? await refresh(ids: [subjectID])
    }

    /// Adds the viewer's reaction to a comment, review, review comment or description, or takes it back.
    func setReaction(_ content: Reaction.Content, on subjectID: String, reacted: Bool) async throws {
        if isDryRun("\(reacted ? "add" : "remove") \(content.rawValue) reaction on \(subjectID)") { return }
        struct Input: Encodable, Sendable { let subjectId: String; let content: String }
        struct Variables: Encodable, Sendable { let input: Input }
        let mutation = reacted
            ? "mutation($input: AddReactionInput!) { addReaction(input: $input) { clientMutationId } }"
            : "mutation($input: RemoveReactionInput!) { removeReaction(input: $input) { clientMutationId } }"
        _ = try await client.query(
            mutation,
            variables: Variables(input: Input(subjectId: subjectID, content: content.rawValue)),
            as: [String: Ignored].self,
            strict: true
        )
    }

    /// Renders Markdown the way GitHub would in `repo`.
    func renderMarkdown(_ text: String, repo: String) async throws -> String {
        struct Body: Encodable, Sendable { let text: String; let mode: String; let context: String }
        let data = try await client.rest("POST", "/markdown", json: Body(text: text, mode: "gfm", context: repo))
        return String(decoding: data, as: UTF8.self)
    }

    struct NotificationDTO: Decodable, Sendable {
        struct Subject: Decodable, Sendable {
            let url: String?
            let type: String
        }

        let id: String
        let reason: String
        let unread: Bool
        let updated_at: Date
        let last_read_at: Date?
        let subject: Subject
    }

    /// Unread notifications in the repository and the parity fork that the viewer participates in.
    func fetchInbox() async throws -> [InboxNote] {
        var notes: [InboxNote] = []
        for repo in [Self.repo, Parity.repo] {
            notes += try await fetchThreads(repo: repo, since: nil)
        }
        return notes
    }

    /// Those notifications updated in the last `readWindow`, read ones too: for when each was last
    /// read, which counts as seeing the item (`ItemState.notificationReadAt`).
    func fetchRecentThreads() async throws -> [InboxNote] {
        let since = Date().addingTimeInterval(-Self.readWindow)
        var notes: [InboxNote] = []
        for repo in [Self.repo, Parity.repo] {
            notes += try await fetchThreads(repo: repo, since: since)
        }
        return notes
    }

    private static let readWindow: TimeInterval = 14 * 24 * 3600

    /// Unread threads, or with `since`, all threads updated since then.
    private func fetchThreads(repo: String, since: Date?) async throws -> [InboxNote] {
        var notes: [InboxNote] = []
        for page in 1 ... 5 {
            var query = [
                URLQueryItem(name: "participating", value: "true"),
                URLQueryItem(name: "per_page", value: "50"),
                URLQueryItem(name: "page", value: String(page)),
            ]
            if let since {
                query += [URLQueryItem(name: "all", value: "true"), URLQueryItem(name: "since", value: since.formatted(.iso8601))]
            }
            let batch = try await client.rest("GET", "/repos/\(repo)/notifications", query: query, as: [NotificationDTO].self)
            notes += batch.compactMap { note in
                guard ["PullRequest", "Issue"].contains(note.subject.type),
                      let number = note.subject.url?.split(separator: "/").last.flatMap({ Int($0) })
                else { return nil }
                return InboxNote(
                    threadID: note.id, repo: repo, number: number, reason: note.reason, updatedAt: note.updated_at,
                    isRead: !note.unread, lastReadAt: note.last_read_at
                )
            }
            if batch.count < 50 { break }
        }
        return notes
    }

    /// Converts a PR to a draft, or marks a draft ready for review: how a parity staging PR is
    /// parked and resumed.
    func setDraft(_ draft: Bool, pullRequestID: String) async throws {
        if isDryRun("\(draft ? "convert \(pullRequestID) to draft" : "mark \(pullRequestID) ready for review")") { return }
        struct Input: Encodable, Sendable { let pullRequestId: String }
        struct Variables: Encodable, Sendable { let input: Input }
        let mutation = draft
            ? "mutation($input: ConvertPullRequestToDraftInput!) { convertPullRequestToDraft(input: $input) { clientMutationId } }"
            : "mutation($input: MarkPullRequestReadyForReviewInput!) { markPullRequestReadyForReview(input: $input) { clientMutationId } }"
        _ = try await client.query(
            mutation,
            variables: Variables(input: Input(pullRequestId: pullRequestID)),
            as: [String: Ignored].self,
            strict: true
        )
    }

    /// Ticks or clears the viewer's "Viewed" checkbox on a file of a PR.
    func setFileViewed(_ viewed: Bool, path: String, pullRequestID: String) async throws {
        if isDryRun("mark \(path) of \(pullRequestID) \(viewed ? "viewed" : "not viewed")") { return }
        struct Input: Encodable, Sendable { let pullRequestId: String; let path: String }
        struct Variables: Encodable, Sendable { let input: Input }
        let mutation = viewed
            ? "mutation($input: MarkFileAsViewedInput!) { markFileAsViewed(input: $input) { clientMutationId } }"
            : "mutation($input: UnmarkFileAsViewedInput!) { unmarkFileAsViewed(input: $input) { clientMutationId } }"
        _ = try await client.query(
            mutation,
            variables: Variables(input: Input(pullRequestId: pullRequestID, path: path)),
            as: [String: Ignored].self,
            strict: true
        )
    }

    func markThreadRead(_ threadID: String) async throws {
        if isDryRun("mark thread \(threadID) read") { return }
        try await client.rest("PATCH", "/notifications/threads/\(threadID)")
    }
}
