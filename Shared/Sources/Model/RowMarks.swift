import Foundation

/// What the list's small columns say about a row, worked out once for both apps: the Mac draws
/// them into its table's cells, the iPad into its rows.

extension ItemRow {
    /// The Turn column: `review` while the viewer's review is asked for, else whose move it is.
    /// The viewer's move stands out by weight alone; color is left to priority.
    var turnMark: (text: String, isMine: Bool)? {
        // A pending review request is the most common reason it's the viewer's move; name it.
        // The parity agent requests review on every staging PR, parked ones too.
        // On an adopted PR the viewer's commits are on, a request (CODEOWNERS') is beside the point.
        if item.isOpen, insight.isReviewRequestedFromMe, !insight.isCoAuthor, !item.isParityStaging || insight.turn == .me {
            return ("review", true)
        }
        return switch insight.turn {
        case .me: ("me", true)
        case .them: ("them", false)
        case nil: nil
        }
    }

    /// Unread activity, or an unread notification in the Inbox.
    var showsUnread: Bool { insight.isUnread || (note.map { !$0.isRead } ?? false) }

    /// The symbol in the state icon's corner: an upstream PR the parity agent is adopting (or
    /// adopted), so in Landed too it stands apart from the viewer's own; else an agent session on
    /// the board. 🫴 both adopts a PR and opens a session on it, so most adopted PRs have both:
    /// the adoption says more, and the session is still there (`t`, the tooltip, the detail).
    var cornerMark: CornerMark? {
        if adoption != nil { return .adoption }
        if board?.sessionLinks.isEmpty == false { return .session }
        return nil
    }
}

/// What the state icon's corner can say about a row (`ItemRow.cornerMark`).
enum CornerMark: Sendable {
    case session, adoption

    var symbol: String {
        switch self {
        case .session: "terminal.fill"
        case .adoption: "link"
        }
    }

    /// For VoiceOver, after the state.
    var label: String {
        switch self {
        case .session: "agent session"
        case .adoption: "adopted by the parity agent"
        }
    }
}

extension ReviewMark {
    /// Crosses for change requests, checks for approvals; colored when it concerns the viewer,
    /// gray when only others think so.
    var symbol: (name: String, tint: StateTint)? {
        switch self {
        case .none: nil
        case .approvedByOthers: ("checkmark", .gray)
        case .approved: ("checkmark", .green)
        case .changesRequestedByOthers: ("xmark", .gray)
        case .changesRequested: ("xmark", .red)
        }
    }
}

extension Item {
    /// The CI dot's color: green passed, red failed, yellow running, gray cancelled (a failed
    /// rollup with no failed checks). Nil without CI.
    var ciTint: StateTint? {
        guard let ci else { return nil }
        if ci.failed > 0 { return .red }
        if ci.pending > 0 || ci.state == "PENDING" || ci.state == "EXPECTED" { return .yellow }
        return ci.state == "SUCCESS" ? .green : .gray
    }

    /// The `ready` label fills the CI dot.
    var isMarkedReady: Bool { labels.contains { $0.name == "ready" } }
}
