import Foundation

/// Whose move it is on an open item.
enum Turn: String, Sendable {
    case me, them
}

/// Someone turning to the viewer directly: what wakes a Skipped item (SPEC §3.1).
struct DirectAsk: Hashable, Sendable {
    var at: Date
    /// E.g. "Mentioned you", "@x requested your review", "@x replied".
    var reason: String
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
    /// The latest time someone turned to the viewer directly, as far as the recent events tell.
    var directAsk: DirectAsk?

    init(item: Item, state: ItemState?, viewer: String?, baseline: Date?) {
        let isMe = { (login: String?) in sameLogin(login, viewer) }
        let human = item.events.filter { !$0.isAutomated && $0.actor != nil }

        let othersActivity = human.filter { event in
            guard !isMe(event.actor) else { return false }
            // A request to someone else is not news for the viewer.
            return event.kind != .reviewRequested || isMe(event.target)
        }
        othersActivityAt = othersActivity.map(\.at).max()

        let seen = [state?.seenAt, baseline].compactMap(\.self).max() ?? .distantPast
        isUnread = (othersActivityAt ?? .distantPast) > seen

        isReviewRequestedFromMe = viewer.map(item.isReviewRequested(from:)) ?? false
        // Opinionated reviews are known for the whole PR; other activity only from recent events.
        let myReview = viewer.flatMap(item.review(by:))
        let myLast = ([myReview?.submittedAt] + human.filter { isMe($0.actor) }.map(\.at)).compactMap(\.self).max()

        directAsk = Self.directAsk(item: item, human: human, myLast: myLast, isMe: isMe)

        // Merging also closes; on a merged PR the merge is the event worth naming.
        let latest = human.last { event in
            if event.kind == .reviewRequested { return isMe(event.target) }
            return !(item.state == .merged && event.kind == .closed)
        }
        summary = latest.map { Self.describe($0, isMe: isMe($0.actor), isAuthor: sameLogin($0.actor, item.author)) }
        summaryAt = latest?.at

        turn = item.isOpen ? Self.turn(item: item, human: human, myLast: myLast, isMe: isMe, requested: isReviewRequestedFromMe) : nil
    }

    /// Requests made by the author right when the PR was opened, marked ready or pushed to are
    /// almost always CODEOWNERS; anything else (another person, or a later request) is deliberate.
    private static let automaticWindow: TimeInterval = 120
    private static let pushWindow: TimeInterval = 300

    private static func isManual(_ request: Item.Event, item: Item, isMe: (String?) -> Bool) -> Bool {
        if isMe(request.actor) { return false }
        if !sameLogin(request.actor, item.author) { return true }
        if abs(request.at.timeIntervalSince(item.createdAt)) < automaticWindow { return false }
        let nearPush = item.events.contains { event in
            [.readyForReview, .forcePush, .commit].contains(event.kind) && abs(event.at.timeIntervalSince(request.at)) < pushWindow
        }
        return !nearPush
    }

    /// A mention, a deliberate review request, or others talking after the viewer took part.
    private static func directAsk(item: Item, human: [Item.Event], myLast: Date?, isMe: (String?) -> Bool) -> DirectAsk? {
        var asks: [DirectAsk] = []
        for event in item.events {
            switch event.kind {
            case .mentioned where isMe(event.target):
                asks.append(DirectAsk(at: event.at, reason: "Mentioned you"))
            case .reviewRequested where isMe(event.target) && !event.isAutomated && isManual(event, item: item, isMe: isMe):
                asks.append(DirectAsk(at: event.at, reason: "@\(event.actor ?? "ghost") requested your review"))
            default:
                break
            }
        }
        if let myLast {
            let talk: Set<Item.Event.Kind> = [.comment, .approved, .changesRequested, .reviewed]
            if let reply = human.last(where: { !isMe($0.actor) && talk.contains($0.kind) && $0.at > myLast }) {
                asks.append(DirectAsk(at: reply.at, reason: "@\(reply.actor ?? "ghost") replied"))
            }
        }
        return asks.max { $0.at < $1.at }
    }

    private static func turn(
        item: Item, human: [Item.Event], myLast: Date?, isMe: (String?) -> Bool,
        requested: Bool
    ) -> Turn? {
        let mine = human.filter { isMe($0.actor) }
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

    /// "you" for the viewer, "author" for the item's author, "@login" for anyone else.
    private static func describe(_ event: Item.Event, isMe: Bool, isAuthor: Bool) -> String {
        let who = isMe ? "you" : isAuthor ? "author" : "@\(event.actor ?? "ghost")"
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
        case .mentioned: "you were mentioned"
        }
    }
}
