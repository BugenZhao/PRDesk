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
