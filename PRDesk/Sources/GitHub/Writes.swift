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

/// A notification thread from the GitHub inbox, for an issue or PR in the repository.
struct InboxNote: Hashable, Sendable {
    var threadID: String
    var number: Int
    /// GitHub's reason, e.g. `mention`, `review_requested`, `comment`, `author`.
    var reason: String
    var updatedAt: Date
    /// Read in this session; stays listed (without the unread dot) until the next inbox sync.
    var isRead = false

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

    /// Renders Markdown the way GitHub would in this repository.
    func renderMarkdown(_ text: String) async throws -> String {
        struct Body: Encodable, Sendable { let text: String; let mode: String; let context: String }
        let data = try await client.rest("POST", "/markdown", json: Body(text: text, mode: "gfm", context: Self.repo))
        return String(decoding: data, as: UTF8.self)
    }

    struct NotificationDTO: Decodable, Sendable {
        struct Subject: Decodable, Sendable {
            let url: String?
            let type: String
        }

        let id: String
        let reason: String
        let updated_at: Date
        let subject: Subject
    }

    /// Unread notifications in the repository that the viewer participates in.
    func fetchInbox() async throws -> [InboxNote] {
        var notes: [InboxNote] = []
        for page in 1 ... 5 {
            let batch = try await client.rest(
                "GET", "/repos/\(Self.repo)/notifications",
                query: [
                    URLQueryItem(name: "participating", value: "true"),
                    URLQueryItem(name: "per_page", value: "50"),
                    URLQueryItem(name: "page", value: String(page)),
                ],
                as: [NotificationDTO].self
            )
            notes += batch.compactMap { note in
                guard ["PullRequest", "Issue"].contains(note.subject.type),
                      let number = note.subject.url?.split(separator: "/").last.flatMap({ Int($0) })
                else { return nil }
                return InboxNote(threadID: note.id, number: number, reason: note.reason, updatedAt: note.updated_at)
            }
            if batch.count < 50 { break }
        }
        return notes
    }

    func markThreadRead(_ threadID: String) async throws {
        if isDryRun("mark thread \(threadID) read") { return }
        try await client.rest("PATCH", "/notifications/threads/\(threadID)")
    }
}
