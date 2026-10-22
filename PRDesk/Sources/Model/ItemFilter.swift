import Foundation

/// A parsed filter string: free text plus `key:value` tokens.
///
/// Supported tokens: `is:pr|issue|draft|open|closed|merged|unread|pinned|first|regular`,
/// `status:triage|working|backlog|skipped|muted`, `turn:me|them`, `author:x`, `label:x`,
/// `ci:fail|pending|pass`, `p:h|m|l`, `org:x`, `vote:up|down|none`, and `merged:N` / `merged:>=N`
/// (also `>`, `<`, `<=`) on the author's merged PR count.
/// A leading `-` negates a token.
struct ItemFilter: Equatable {
    struct Token: Equatable {
        var key: String
        var value: String
        var negated: Bool
    }

    private static let keys: Set = ["is", "status", "turn", "author", "label", "ci", "p", "org", "vote", "merged"]

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

    func matches(_ row: ItemRow, orgs: (String) -> [Org], contribution: (String) -> Contribution?) -> Bool {
        let item = row.item
        for word in text {
            let hit = item.title.lowercased().contains(word)
                || String(item.number).hasPrefix(word.trimmingCharacters(in: ["#"]))
                || (item.author?.lowercased().contains(word) ?? false)
            if !hit { return false }
        }
        for token in tokens where token.value.isEmpty == false {
            if matches(token, row, orgs: orgs, contribution: contribution) == token.negated { return false }
        }
        return true
    }

    private func matches(_ token: Token, _ row: ItemRow, orgs: (String) -> [Org], contribution: (String) -> Contribution?) -> Bool {
        let item = row.item
        let value = token.value
        let authorContribution = item.author.flatMap(contribution)
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
            case "first": authorContribution?.isFirstTime ?? false
            case "regular": authorContribution?.isRegular ?? false
            default: false
            }
        case "status":
            return switch value {
            case "triage", "untriaged": row.triage == nil || row.wakeReason != nil
            default: row.triage?.rawValue.lowercased() == value
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
            return row.priority?.letter.lowercased() == value
        case "vote":
            return switch value {
            case "up": row.authorVote == .up
            case "down": row.authorVote == .down
            case "none": row.authorVote == nil
            default: false
            }
        case "merged":
            guard let merged = authorContribution?.merged else { return false }
            return Self.compare(merged, value)
        case "org":
            guard let author = item.author else { return false }
            return orgs(author).contains { $0.filterNames.contains(value) }
        default:
            return false
        }
    }

    /// `N`, `>=N`, `>N`, `<=N` or `<N`.
    private static func compare(_ count: Int, _ value: String) -> Bool {
        let tests: [(String, (Int, Int) -> Bool)] = [(">=", >=), ("<=", <=), (">", >), ("<", <)]
        for (op, test) in tests {
            if value.hasPrefix(op), let n = Int(value.dropFirst(op.count)) { return test(count, n) }
        }
        return Int(value).map { count == $0 } ?? false
    }
}
