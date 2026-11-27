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
                Image(platformImage: image).resizable()
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// A login, in italics for a first-timer nothing vouches for. Click to open their GitHub profile;
/// right-click to set their affiliation. Under a finger, where nothing hovers, a tap shows the
/// person's menu instead (`PersonMenuView`, as a page's names do): what hovering says on the Mac,
/// and the profile.
struct LoginText: View {
    @Environment(AppModel.self) private var model
    let login: String?
    var weight: Font.Weight = .medium
    #if os(macOS)
        @State private var isHovered = false
    #else
        @State private var showsMenu = false
    #endif

    var body: some View {
        let contribution = model.contribution(for: login)
        let badges = login.map(model.affiliations.badges(for:)) ?? []
        let unvouched = contribution?.isUnvouched(badges: badges) ?? false
        let text = Text(login ?? "ghost").fontWeight(weight).italic(unvouched)
        #if os(macOS)
            Button {
                if let login { AppModel.openProfile(login) }
            } label: {
                text.underline(isHovered && login != nil)
            }
            .buttonStyle(.plain)
            .disabled(login == nil)
            .pointerStyle(login == nil ? nil : .link)
            .onHover { isHovered = $0 }
            .help((personFacts(contribution: contribution, badges: badges) + (login.map { ["Open \($0)'s profile on GitHub"] } ?? []))
                .joined(separator: "\n"))
            .contextMenu {
                if let login {
                    AffiliationSubmenu(login: login)
                    Divider()
                    Button("Open Profile on GitHub") { AppModel.openProfile(login) }
                    Button("Copy Username") { Platform.copy(login) }
                }
            }
        #else
            Button { showsMenu = true } label: { text }
                .buttonStyle(.plain)
                .disabled(login == nil)
                .popover(isPresented: $showsMenu) {
                    if let login {
                        PersonMenuView(login: login)
                            .environment(model)
                            .presentationCompactAdaptation(.popover)
                    }
                }
        #endif
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
                    #if os(iOS)
                        // Drawn by SwiftUI at the badge's size: the catalog's SVG and a tile of
                        // text. A `UIImage` of either is drawn at its own size and its pixels
                        // scaled, which left stairs at every edge (or blurred them, smoothed).
                        if let tile = badge.org.brandTile {
                            BrandTile(text: tile.text, color: Color(hex: tile.hex) ?? .gray, size: size)
                        } else if let name = badge.org.logoAsset {
                            Image(name).resizable().scaledToFit().saturation(badge.isSecondary ? 0 : 1)
                        } else {
                            BadgeTile(text: badge.org.shortLabel, color: Color.tertiaryText, size: size)
                        }
                    #else
                        if let image = badge.image {
                            Image(platformImage: image).resizable().scaledToFit()
                        } else {
                            BadgeTile(text: badge.org.shortLabel, color: Color.tertiaryText, size: size)
                        }
                    #endif
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .help("\(badge.name) — \(badge.source)")
            }
        }
    }
}

/// An org's brand tile: its short name in white on its color, as heavy as it fits.
private struct BrandTile: View {
    let text: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size * 8 / 13, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, size * 0.06)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 3 / 13))
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

/// A small rounded tag.
struct Chip: View {
    let text: String
    var color: Color = .secondaryText

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
        let color = Color(hex: hex) ?? .secondaryText
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

extension Text {
    /// A PR or commit title with its leading tags dimmed, and shortened ("[RF][Fix] ") when
    /// `shortenedTags`; `code` spans in `codeFont`.
    init(
        itemTitle title: String, shortenedTags: Bool, codeFont: Font = .callout.monospaced(),
        tagStyle: AnyShapeStyle = .tertiaryText
    ) {
        let pieces = TitleMarkup.pieces(title)
        let short = shortenedTags ? TitlePrefix.abbreviate(TitlePrefix.split(title).prefix) : nil
        let start = short.map { Text(verbatim: $0).foregroundStyle(tagStyle) } ?? Text(verbatim: "")
        self = pieces.reduce(start) { text, piece in
            if piece.isPrefix, short != nil { return text }
            var part = Text(verbatim: piece.text)
            if piece.isCode { part = part.font(codeFont) }
            if piece.isPrefix { part = part.foregroundStyle(tagStyle) }
            return Text("\(text)\(part)")
        }
    }
}
