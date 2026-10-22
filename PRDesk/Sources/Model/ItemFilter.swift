import Foundation

/// A parsed filter string: free text plus `key:value` tokens.
///
/// Supported tokens: `is:pr|issue|draft|open|closed|merged|unread|pinned|untracked`,
/// `turn:me|them`, `author:x`, `label:x`, `ci:fail|pending|pass`, `p:h|m|l`, `org:x`.
/// A leading `-` negates a token.
struct ItemFilter: Equatable {
    struct Token: Equatable {
        var key: String
        var value: String
        var negated: Bool
    }

    private static let keys: Set = ["is", "turn", "author", "label", "ci", "p", "org"]

    var text: [String] = []
    var tokens: [Token] = []

    init(_ string: String) {
        for word in string.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) {
            let negated = word.hasPrefix("-")
            let body = negated ? String(word.dropFirst()) : word
            if let colon = body.firstIndex(of: ":"), Self.keys.contains(String(body[..<colon])) {
                tokens.append(Token(key: String(body[..<colon]), value: String(body[body.index(after: colon)...]), negated: negated))
            } else {
                text.append(word)
            }
        }
    }

    var isEmpty: Bool { text.isEmpty && tokens.isEmpty }

    /// Whether untracked items should be shown at all.
    var showsUntracked: Bool {
        tokens.contains { $0.key == "is" && $0.value == "untracked" && !$0.negated }
    }

    func matches(_ row: ItemRow, orgs: (String) -> [Org]) -> Bool {
        let item = row.item
        for word in text {
            let hit = item.title.lowercased().contains(word)
                || String(item.number).hasPrefix(word.trimmingCharacters(in: ["#"]))
                || (item.author?.lowercased().contains(word) ?? false)
            if !hit { return false }
        }
        for token in tokens where token.value.isEmpty == false {
            if matches(token, row, orgs: orgs) == token.negated { return false }
        }
        return true
    }

    private func matches(_ token: Token, _ row: ItemRow, orgs: (String) -> [Org]) -> Bool {
        let item = row.item
        let value = token.value
        switch token.key {
        case "is":
            return switch value {
            case "pr": item.kind == .pullRequest
            case "issue": item.kind == .issue
            case "draft": item.isDraft
            case "open": item.isOpen
            case "closed": item.state == .closed
            case "merged": item.state == .merged
            case "unread": row.insight.isUnread
            case "pinned": row.state.isPinned
            case "untracked": row.state.untrackedAt != nil
            default: false
            }
        case "turn":
            return row.insight.turn?.rawValue == value
        case "author":
            return item.author?.lowercased().contains(value) ?? false
        case "label":
            return item.labels.contains { $0.name.lowercased().contains(value) }
        case "ci":
            guard let ci = item.ci else { return false }
            return switch value {
            case "fail", "failed", "failure": ci.failed > 0
            case "pending": ci.failed == 0 && ci.pending > 0
            case "pass", "passed", "success": ci.state == "SUCCESS"
            default: false
            }
        case "p":
            return row.state.priority?.letter.lowercased() == value
        case "org":
            guard let author = item.author else { return false }
            return orgs(author).contains { $0.filterNames.contains(value) }
        default:
            return false
        }
    }
}
