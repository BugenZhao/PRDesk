import Foundation

/// Everything shown in the detail pane for one item, beyond what the list has.
struct ItemDetail: Codable, Equatable, Sendable {
    var number: Int
    /// Node id, needed for comments and reviews.
    var id: String
    var bodyHTML: String
    var bodyText: String
    var headRef: String?
    var baseRef: String?
    /// The GitHub stack a PR is in.
    var stack: PRStack? = nil
    /// Reactions to the description.
    var reactions: [Reaction]
    var entries: [TimelineEntry]
    var checks: [Check]
    /// A PR's latest commits, oldest first; nil in details cached before they were fetched.
    var commits: [PRCommit]? = nil
    /// The item's `updatedAt` when this was fetched.
    var itemUpdatedAt: Date
    var fetchedAt: Date
}

struct TimelineEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case comment
        case approved, changesRequested, reviewed
        case commit, forcePush, merged, closed, reopened, readyForReview, convertToDraft
        case reviewRequested, reviewDismissed, labeled, unlabeled, crossReferenced, assigned, renamed
        case addedToStack, removedFromStack
    }

    var id: String
    var kind: Kind
    var actor: String?
    var isAutomated: Bool
    var at: Date
    var url: String?
    var bodyHTML: String?
    var bodyText: String?
    /// Kind-specific text: commit headline, label name, referenced item title, …
    var detail: String?
    /// Hex color for labels.
    var color: String?
    /// The commit a review was made on, or the head a force push left.
    var oid: String? = nil
    /// The head before a force push.
    var beforeOid: String? = nil
    var reviewComments: [ReviewComment] = []
    var reactions: [Reaction] = []

    var hasBody: Bool {
        !(bodyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !reviewComments.isEmpty
    }

    /// Shown as a card (with a body) rather than a one-line event.
    var isCard: Bool {
        switch kind {
        case .comment: true
        case .approved, .changesRequested, .reviewed: hasBody || kind != .reviewed
        default: false
        }
    }
}

struct ReviewComment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var path: String
    var line: Int?
    var diffHunk: String
    var bodyHTML: String
    var outdated: Bool
    var url: String
    var reactions: [Reaction] = []
    /// The thread's later comments, oldest first; nil in details cached before threads were fetched.
    var replies: [ReviewReply]? = nil
    var isResolved: Bool? = nil
}

/// A reply in a review comment's thread.
struct ReviewReply: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var actor: String?
    var isAutomated: Bool
    var at: Date
    var bodyHTML: String
    var url: String
    var reactions: [Reaction]
}

/// A review thread as fetched apart from the timeline: its root comment (one of a review's) and
/// the replies after it.
struct ReviewThread: Equatable, Sendable {
    var rootID: String
    var isResolved: Bool
    var replies: [ReviewReply]
}

extension [TimelineEntry] {
    /// The entries with each review comment's thread. A reply that came in a review of its own
    /// moves under the comment it answers, as on GitHub; a bodiless review left with nothing goes.
    func threaded(_ threads: [ReviewThread]) -> [TimelineEntry] {
        let byRoot = Dictionary(threads.map { ($0.rootID, $0) }, uniquingKeysWith: { first, _ in first })
        let replyIDs = Set(threads.flatMap { $0.replies.map(\.id) })
        return compactMap { entry in
            guard !entry.reviewComments.isEmpty else { return entry }
            var entry = entry
            entry.reviewComments = entry.reviewComments.compactMap { comment in
                guard !replyIDs.contains(comment.id) else { return nil }
                var comment = comment
                let thread = byRoot[comment.id]
                comment.replies = thread?.replies ?? []
                comment.isResolved = thread?.isResolved ?? false
                return comment
            }
            if entry.kind == .reviewed, !entry.hasBody { return nil }
            return entry
        }
    }
}

/// One kind of reaction to a comment, review or description, as GitHub groups them.
struct Reaction: Codable, Equatable, Sendable {
    enum Content: String, Codable, CaseIterable, Sendable {
        case thumbsUp = "THUMBS_UP"
        case thumbsDown = "THUMBS_DOWN"
        case laugh = "LAUGH"
        case hooray = "HOORAY"
        case confused = "CONFUSED"
        case heart = "HEART"
        case rocket = "ROCKET"
        case eyes = "EYES"

        var emoji: String {
            switch self {
            case .thumbsUp: "👍"
            case .thumbsDown: "👎"
            case .laugh: "😄"
            case .hooray: "🎉"
            case .confused: "😕"
            case .heart: "❤️"
            case .rocket: "🚀"
            case .eyes: "👀"
            }
        }

        var name: String {
            switch self {
            case .thumbsUp: "Thumbs Up"
            case .thumbsDown: "Thumbs Down"
            case .laugh: "Laugh"
            case .hooray: "Hooray"
            case .confused: "Confused"
            case .heart: "Heart"
            case .rocket: "Rocket"
            case .eyes: "Eyes"
            }
        }
    }

    var content: Content
    var count: Int
    var viewerHasReacted: Bool
    /// The first few people who reacted.
    var logins: [String]

    /// `reactions` with the viewer's `content` reaction added or taken back.
    static func toggling(_ content: Content, in reactions: [Reaction], viewer: String?) -> [Reaction] {
        var reactions = reactions
        if let index = reactions.firstIndex(where: { $0.content == content }) {
            var reaction = reactions[index]
            reaction.viewerHasReacted.toggle()
            reaction.count += reaction.viewerHasReacted ? 1 : -1
            if let viewer {
                reaction.logins.removeAll { sameLogin($0, viewer) }
                if reaction.viewerHasReacted { reaction.logins.insert(viewer, at: 0) }
            }
            if reaction.count > 0 { reactions[index] = reaction } else { reactions.remove(at: index) }
        } else {
            reactions.append(Reaction(content: content, count: 1, viewerHasReacted: true, logins: viewer.map { [$0] } ?? []))
            // In GitHub's order.
            let order = Content.allCases
            reactions.sort { order.firstIndex(of: $0.content)! < order.firstIndex(of: $1.content)! }
        }
        return reactions
    }
}

/// One commit of a PR, for the Commits tab.
struct PRCommit: Codable, Equatable, Identifiable, Sendable {
    var oid: String
    var shortOid: String
    var headline: String
    var committedAt: Date
    var url: String
    /// The first parent: the base to diff the commit against.
    var parentOid: String?
    /// More than one for a merge; nil in details cached before it was fetched.
    var parentCount: Int? = nil
    var author: String?
    var authorName: String?
    /// The rollup of the commit's checks: `SUCCESS`, `FAILURE`, `ERROR`, `PENDING`, `EXPECTED`.
    var ciState: String?
    var additions: Int
    var deletions: Int
    /// The whole message; nil in details cached before it was fetched.
    var message: String? = nil

    var id: String { oid }

    var isMerge: Bool { (parentCount ?? 1) > 1 }

    /// The message's first line in full: GitHub cuts a long headline short with "…".
    var messageTitle: String {
        guard let message else { return headline }
        let first = message.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? headline : first
    }

    /// The message after its first line, trimmed; empty when there is none (or isn't known).
    var messageBody: String {
        guard let message, let newline = message.firstIndex(of: "\n") else { return "" }
        return message[message.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body with each paragraph's hard-wrapped lines joined (see `reflowed`), for views that
    /// wrap it at their own width.
    var reflowedBody: String { Self.reflowed(messageBody) }

    /// The whole message for a tooltip, at most `maxLines` lines of its reflowed body.
    func tooltipMessage(maxLines: Int = 30) -> String {
        let body = reflowedBody
        guard !body.isEmpty else { return messageTitle }
        var lines = body.components(separatedBy: "\n")
        if lines.count > maxLines { lines = lines.prefix(maxLines) + ["…"] }
        return messageTitle + "\n\n" + lines.joined(separator: "\n")
    }

    /// Commit messages are wrapped by hand at about 72 columns, which re-wrapped at another width
    /// leaves every other line short. Joins a line to the one before it, unless either is blank,
    /// in a code block, or a line that stands alone: a list item, an indented or quoted line, a
    /// table row, a trailer (`Signed-off-by: …`).
    static func reflowed(_ text: String) -> String {
        var lines: [String] = []
        var inFence = false
        var joinable = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .init(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                lines.append(line)
                joinable = false
                continue
            }
            if inFence || trimmed.isEmpty {
                lines.append(line)
                joinable = false
                continue
            }
            let standsAlone = line.first?.isWhitespace == true || isListItem(trimmed)
                || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || isTrailer(trimmed)
            if joinable, !standsAlone, let last = lines.popLast() {
                lines.append(last + " " + trimmed)
            } else {
                lines.append(line)
            }
            // A trailer is never continued; a list item's own wrapped lines are.
            joinable = !isTrailer(trimmed) && !trimmed.hasPrefix("|")
        }
        return lines.joined(separator: "\n")
    }

    private static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line.hasPrefix("• ") { return true }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < 4 else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    private static func isTrailer(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":"), line[line.index(after: colon)...].hasPrefix(" ") else { return false }
        let key = line[..<colon]
        return !key.isEmpty && key.count < 40 && key.allSatisfy { $0.isLetter || $0 == "-" } && key.contains("-")
    }
}

struct Check: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable, CaseIterable {
        case failed, pending, passed, skipped
    }

    var id: String { "\(app ?? "")/\(name)" }
    var name: String
    var app: String?
    var state: State
    var url: String?
    var summary: String?
    var startedAt: Date?
    var completedAt: Date?
}

extension ItemDetail {
    /// Reactions to the description, a comment, a review or a review comment, by its node id.
    func reactions(on subjectID: String) -> [Reaction]? {
        if subjectID == id { return reactions }
        for entry in entries {
            if entry.id == subjectID { return entry.reactions }
            for comment in entry.reviewComments {
                if comment.id == subjectID { return comment.reactions }
                if let reply = comment.replies?.first(where: { $0.id == subjectID }) { return reply.reactions }
            }
        }
        return nil
    }

    mutating func setReactions(_ reactions: [Reaction], on subjectID: String) {
        if subjectID == id {
            self.reactions = reactions
            return
        }
        for index in entries.indices {
            if entries[index].id == subjectID {
                entries[index].reactions = reactions
                return
            }
            for commentIndex in entries[index].reviewComments.indices {
                if entries[index].reviewComments[commentIndex].id == subjectID {
                    entries[index].reviewComments[commentIndex].reactions = reactions
                    return
                }
                if let replyIndex = entries[index].reviewComments[commentIndex].replies?.firstIndex(where: { $0.id == subjectID }) {
                    entries[index].reviewComments[commentIndex].replies?[replyIndex].reactions = reactions
                    return
                }
            }
        }
    }
}
