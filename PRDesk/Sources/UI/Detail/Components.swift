import SwiftUI

/// A GitHub avatar, loaded through `AvatarCache`.
struct AvatarView: View {
    let login: String?
    var size: CGFloat = 16

    var body: some View {
        let cache = AvatarCache.shared
        _ = cache.version
        return Group {
            if let login, let image = cache.image(for: login) {
                Image(nsImage: image).resizable()
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// A login followed by the viewer's vote on that person. Right-click to vote.
struct LoginText: View {
    @Environment(AppModel.self) private var model
    let login: String?
    var weight: Font.Weight = .medium

    var body: some View {
        let isMe = sameLogin(login, model.viewer)
        HStack(spacing: 3) {
            Text(login ?? "ghost")
                .fontWeight(weight)
            if let vote = model.vote(for: login) {
                Image(systemName: vote.symbol)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: vote.nsColor))
                    .help(vote == .up ? "Upvoted" : "Downvoted: never puts items in Focus")
            }
        }
        .contextMenu {
            if let login, !isMe {
                VoteMenu(login: login)
            }
        }
    }
}

/// Upvote / clear / downvote choices for a person.
struct VoteMenu: View {
    @Environment(AppModel.self) private var model
    let login: String

    var body: some View {
        let current = model.vote(for: login)
        Button("Upvote \(login)", systemImage: "hand.thumbsup") { model.setVote(.up, for: login) }
            .disabled(current == .up)
        Button("Downvote \(login)", systemImage: "hand.thumbsdown") { model.setVote(.down, for: login) }
            .disabled(current == .down)
        Button("Clear Vote", systemImage: "hand.raised.slash") { model.setVote(nil, for: login) }
            .disabled(current == nil)
    }
}

/// Affiliation badges for a login, as small org avatars with explanatory tooltips.
struct BadgeIcons: View {
    @Environment(AppModel.self) private var model
    let login: String?
    var size: CGFloat = 13

    var body: some View {
        let cache = AvatarCache.shared
        _ = cache.version
        return HStack(spacing: 3) {
            ForEach(login.map(model.affiliations.badges(for:)) ?? [], id: \.org) { badge in
                Group {
                    if let image = cache.image(for: badge.org.avatarLogin) {
                        Image(nsImage: image).resizable()
                    } else {
                        Text(badge.org.shortLabel).font(.system(size: 8, weight: .bold))
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .help("\(badge.org.displayName) — \(badge.source)")
            }
        }
    }
}

/// A small rounded tag.
struct Chip: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A GitHub label chip in its own color.
struct LabelChip: View {
    let name: String
    let hex: String

    var body: some View {
        let color = Color(hex: hex) ?? .secondary
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 0.5))
    }
}

/// Lays out children left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    /// Narrower proposals (the window probing for its minimum size) are laid out at this width,
    /// so one chip per row doesn't turn into a tall minimum height.
    private static let minimumLayoutWidth: CGFloat = 240

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(subviews, width: max(proposal.width ?? .infinity, Self.minimumLayoutWidth))
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

extension Color {
    /// Parses `rrggbb` (no leading `#`).
    init?(hex: String) {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
