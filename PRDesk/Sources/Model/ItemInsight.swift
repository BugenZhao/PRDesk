import Foundation

/// Whose move it is on an open item.
enum Turn: String, Sendable {
    case me, them
}

/// Facts derived from an item, its local state and the viewer.
struct ItemInsight: Hashable, Sendable {
    var turn: Turn?
    var isUnread: Bool
    /// Latest activity by someone other than the viewer (bots excluded).
    var othersActivityAt: Date?
    /// Short description of the latest human event, e.g. "@njhill approved".
    var summary: String?
    var summaryAt: Date?
    var isReviewRequestedFromMe: Bool
    /// An untracked item comes back when it is requested for review again afterwards.
    var isTracked: Bool

    init(item: Item, state: ItemState?, viewer: String?, baseline: Date?) {
        let isMe = { (login: String?) in sameLogin(login, viewer) }
        let human = item.events.filter { !$0.isBot && $0.actor != nil }

        let othersActivity = human.filter { event in
            guard !isMe(event.actor) else { return false }
            // A request to someone else is not news for the viewer.
            return event.kind != .reviewRequested || isMe(event.target)
        }
        othersActivityAt = othersActivity.map(\.at).max()

        let seen = [state?.seenAt, baseline].compactMap(\.self).max() ?? .distantPast
        isUnread = (othersActivityAt ?? .distantPast) > seen

        isReviewRequestedFromMe = viewer.map(item.isReviewRequested(from:)) ?? false

        if let untrackedAt = state?.untrackedAt {
            isTracked = human.contains { $0.kind == .reviewRequested && isMe($0.target) && $0.at > untrackedAt }
        } else {
            isTracked = true
        }

        let latest = human.last { $0.kind != .reviewRequested || isMe($0.target) }
        summary = latest.map { Self.describe($0, isMe: isMe($0.actor)) }
        summaryAt = latest?.at

        turn = item.isOpen ? Self.turn(item: item, viewer: viewer, human: human, isMe: isMe, requested: isReviewRequestedFromMe) : nil
    }

    private static func turn(item: Item, viewer: String?, human: [Item.Event], isMe: (String?) -> Bool, requested: Bool) -> Turn {
        let mine = human.filter { isMe($0.actor) }
        let myLast = mine.map(\.at).max()
        /// Conversation by others (comments and reviews), ignoring pushes and bookkeeping.
        let othersTalk = human.filter { !isMe($0.actor) && [.comment, .approved, .changesRequested, .reviewed].contains($0.kind) }
        let othersTalkLast = othersTalk.map(\.at).max()

        let isAuthor = isMe(item.author)
        switch item.kind {
        case .pullRequest where isAuthor:
            if item.isDraft { return .me }
            if item.reviewDecision == "CHANGES_REQUESTED" {
                let lastChangesRequest = human.filter { $0.kind == .changesRequested }.map(\.at).max() ?? .distantPast
                let myLastPush = mine.filter { [.commit, .forcePush].contains($0.kind) }.map(\.at).max() ?? .distantPast
                if myLastPush < lastChangesRequest { return .me }
            }
            if (item.ci?.failed ?? 0) > 0 || item.mergeable == "CONFLICTING" { return .me }
            if let othersTalkLast, othersTalkLast > (myLast ?? .distantPast) { return .me }
            return .them

        case .pullRequest:
            if requested, !item.isDraft { return .me }
            guard let myLast else { return .them }
            // After my review or comment, the ball is back with me once the author or others respond.
            let responses = human.filter { !isMe($0.actor) && $0.kind != .reviewRequested }
            return responses.contains { $0.at > myLast } ? .me : .them

        case .issue:
            let assigned = item.assignees.contains { isMe($0) }
            guard isAuthor || assigned || myLast != nil else { return .them }
            if let othersTalkLast, othersTalkLast > (myLast ?? .distantPast) { return .me }
            return assigned && myLast == nil ? .me : .them
        }
    }

    private static func describe(_ event: Item.Event, isMe: Bool) -> String {
        let who = isMe ? "you" : "@\(event.actor ?? "ghost")"
        return switch event.kind {
        case .comment: "\(who) commented"
        case .approved: "\(who) approved"
        case .changesRequested: "\(who) requested changes"
        case .reviewed: "\(who) reviewed"
        case .commit, .forcePush: "\(who) pushed"
        case .merged: "merged by \(who)"
        case .closed: "closed by \(who)"
        case .reopened: "reopened by \(who)"
        case .readyForReview: "\(who) marked ready"
        case .reviewRequested: "\(who) requested your review"
        }
    }
}
