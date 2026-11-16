import SwiftUI

/// A list row on the phone: what the Mac's columns show, in two lines. The state icon and title
/// (tags faded) first; then the number, author with badges, the latest event, and on the right
/// whose turn it is, CI and the age.
struct ItemRowView: View {
    @Environment(AppModel.self) private var model
    let row: ItemRow

    private var item: Item { row.item }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .topLeading) {
                StateIconView(item: item, size: 16, isMerging: row.isMerging)
                    .padding(.top, 2)
                if row.insight.isUnread {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: -9, y: 7)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(.subheadline.weight(row.insight.isUnread ? .semibold : .regular))
                    .lineLimit(2)
                    .opacity(fades ? 0.55 : 1)
                if let comment = row.comment, !comment.isEmpty {
                    Text(comment).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                meta
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Closed items and drafts recede, as in the Mac list.
    private var fades: Bool { !item.isOpen || item.isDraft }

    private var title: Text {
        let (prefix, rest) = TitlePrefix.split(item.title)
        let tags = Text(String(prefix)).foregroundStyle(.secondary)
        guard let reason = row.wakeReason else { return Text("\(tags)\(String(rest))") }
        let tag = Text(reason).font(.caption.weight(.medium)).foregroundStyle(.purple)
        return Text("\(tags)\(String(rest))  \(tag)")
    }

    private var meta: some View {
        HStack(spacing: 5) {
            Text("#\(String(item.number))").monospacedDigit().foregroundStyle(.secondary)
            AvatarView(login: item.author, size: 14)
            Text(item.author ?? "ghost").lineLimit(1)
            BadgeIcons(login: item.author, size: 12)
            if row.isPinned {
                Image(systemName: "pin.fill").foregroundStyle(.orange)
            }
            // An upstream PR the parity agent is adopting (or adopted).
            if row.adoption != nil {
                Image(systemName: "link").foregroundStyle(.secondary)
            }
            if let summary = row.insight.summary {
                Text(summary).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let turn = row.insight.turn {
                Text(row.insight.isReviewRequestedFromMe && !row.insight.isCoAuthor ? "review" : turn.rawValue)
                    .fontWeight(turn == .me ? .semibold : .regular)
                    .foregroundStyle(turn == .me ? .primary : .tertiary)
            }
            if let ci = item.ci, item.kind == .pullRequest {
                CIDot(ci: ci, isReady: item.labels.contains { $0.name == "ready" })
            }
            Text(item.updatedAt.compactAge()).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
    }
}

/// CI as the Mac's column draws it: green passed, red failed, yellow running, gray cancelled;
/// solid with the `ready` label, hollow without.
private struct CIDot: View {
    let ci: Item.CIStatus
    let isReady: Bool

    private var color: Color {
        if ci.failed > 0 || ci.state == "FAILURE" || ci.state == "ERROR" { return .red }
        if ci.pending > 0 || ci.state == "PENDING" || ci.state == "EXPECTED" { return .yellow }
        return ci.state == "SUCCESS" ? .green : .gray
    }

    var body: some View {
        Group {
            if isReady {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(color, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
    }
}
