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

/// A login followed by the viewer's vote on that person, in italics for a first-timer nothing
/// vouches for. Click to open their GitHub profile; right-click to vote or set their affiliation.
struct LoginText: View {
    @Environment(AppModel.self) private var model
    let login: String?
    var weight: Font.Weight = .medium
    @State private var isHovered = false

    var body: some View {
        let isMe = sameLogin(login, model.viewer)
        let contribution = model.contribution(for: login)
        let unvouched = contribution?.isUnvouched(badges: login.map(model.affiliations.badges(for:)) ?? []) ?? false
        HStack(spacing: 3) {
            Button {
                if let login { AppModel.openProfile(login) }
            } label: {
                Text(login ?? "ghost")
                    .fontWeight(weight)
                    .italic(unvouched)
                    .underline(isHovered && login != nil)
            }
            .buttonStyle(.plain)
            .disabled(login == nil)
            .pointerStyle(login == nil ? nil : .link)
            .onHover { isHovered = $0 }
            .help([unvouched ? contribution?.summary : nil, login.map { "Open \($0)'s profile on GitHub" }].compactMap(\.self).joined(separator: "\n"))
            if let vote = model.vote(for: login) {
                Image(systemName: vote.symbol)
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: vote.nsColor))
                    .help(vote == .up ? "Upvoted" : "Downvoted: sinks to the bottom of Triage")
            }
        }
        .contextMenu {
            if let login {
                if !isMe {
                    VoteMenu(login: login)
                    Divider()
                }
                AffiliationSubmenu(login: login)
                Divider()
                Button("Open Profile on GitHub") { AppModel.openProfile(login) }
                Button("Copy Username") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(login, forType: .string)
                }
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
        let badges = login.map(model.affiliations.badges(for:)) ?? []
        return HStack(spacing: 3) {
            // An org badge already says the author is established. (A first-timer's italics are
            // `LoginText`'s.)
            if let contribution = model.contribution(for: login), contribution.isRegular, badges.isEmpty {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: size - 2))
                    .foregroundStyle(.green)
                    .help(contribution.summary)
            }
            ForEach(badges, id: \.org) { badge in
                Group {
                    if let image = badge.image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        BadgeTile(text: badge.org.shortLabel, color: Color(nsColor: .tertiaryLabelColor), size: size)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .help("\(badge.name) — \(badge.source)")
            }
        }
    }
}

/// A short label on a solid rounded square, sized and shaped like an org badge.
struct BadgeTile: View {
    let text: String
    let color: Color
    var size: CGFloat = 13

    var body: some View {
        Text(text)
            .font(.system(size: size * 8 / 13, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// An item's state icon in its state color, as in the list.
struct StateIconView: View {
    let item: Item
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch item.stateIcon {
            case let .asset(name): Image(name).renderingMode(.template).resizable()
            case let .symbol(name): Image(systemName: name).resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(Color(nsColor: item.stateColor))
        .help(item.stateDescription)
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
