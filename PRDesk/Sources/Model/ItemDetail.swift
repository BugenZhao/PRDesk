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
            if let comment = entry.reviewComments.first(where: { $0.id == subjectID }) { return comment.reactions }
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
            if let commentIndex = entries[index].reviewComments.firstIndex(where: { $0.id == subjectID }) {
                entries[index].reviewComments[commentIndex].reactions = reactions
                return
            }
        }
    }
}
