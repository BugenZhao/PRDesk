import Foundation

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

/// A notification thread from the GitHub inbox, for an issue or PR in the repository.
struct InboxNote: Hashable, Sendable {
    var threadID: String
    var number: Int
    /// GitHub's reason, e.g. `mention`, `review_requested`, `comment`, `author`.
    var reason: String
    var updatedAt: Date

    var reasonLabel: String {
        switch reason {
        case "review_requested": "review requested"
        case "team_mention": "team mention"
        case "state_change": "state change"
        case "ci_activity": "ci"
        default: reason.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Decodes any JSON value and throws it away, for mutation results we don't need.
private struct Ignored: Decodable, Sendable {
    init(from _: any Decoder) throws {}
}

extension SyncEngine {
    func submit(_ submission: Submission, body: String, subjectID: String) async throws {
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

    /// Renders Markdown the way GitHub would in this repository.
    func renderMarkdown(_ text: String) async throws -> String {
        struct Body: Encodable, Sendable { let text: String; let mode: String; let context: String }
        let data = try await client.rest("POST", "/markdown", json: Body(text: text, mode: "gfm", context: Self.repo))
        return String(decoding: data, as: UTF8.self)
    }

    private struct NotificationDTO: Decodable, Sendable {
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
        try await client.rest("PATCH", "/notifications/threads/\(threadID)")
    }
}
