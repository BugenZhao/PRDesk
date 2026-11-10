import SwiftUI

/// The stack the selected PR is in, in the detail header (SPEC §6): the base branch on top, then
/// the PRs from the base up, PRs merged together folded into one line. A row opens its PR.
struct StackPanel: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let ladder: StackLadder
    /// Folded merge runs the viewer opened, by line id.
    @State private var unfolded: Set<String> = []
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            row {
                Color.clear.frame(width: StackRailShape.width)
                Text(baseBranch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(ladder.lines) { line in
                switch line {
                case let .rung(rung):
                    rungRow(rung)
                case let .merged(rungs, rail):
                    mergedRow(rungs, rail: rail, id: line.id)
                    if unfolded.contains(line.id) {
                        ForEach(rungs) { rungRow($0) }
                    }
                }
            }
        }
        .font(.callout)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private var header: some View {
        let index = ladder.rungs.firstIndex { $0.entry.number == item.number }
        let parts = [
            ladder.number.map { "Stack \($0)" } ?? "Stacked by branch",
            index.map { "\($0 + 1) of \(ladder.rungs.count)" },
            ladder.mergedCount > 0 ? "\(ladder.mergedCount) merged" : nil,
        ].compactMap(\.self)
        return HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
            Text(parts.joined(separator: " · "))
            Spacer(minLength: 0)
            Text("⌥↑ ⌥↓")
                .foregroundStyle(.tertiary)
                .help("Move along the stack")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// The branch the stack's base PR targets.
    private var baseBranch: String {
        ladder.number != nil ? "main" : ladder.rungs.first?.entry.baseRef ?? "main"
    }

    private func rungRow(_ rung: StackLadder.Rung) -> some View {
        let entry = rung.entry
        let isCurrent = entry.number == item.number
        return Button {
            model.openItem(repo: ladder.repo, number: entry.number)
        } label: {
            row {
                // A staging PR landed upstream is closed on the fork; it shows as merged.
                RailView(rail: rung.rail, color: rung.upstream?.state == .merged ? .purple : entry.stateColor, hollow: entry.state == .open && entry.isDraft)
                    .help(entry.stateDescription)
                Text("#\(String(entry.number))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                title(entry.title, shortened: shortensTags)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Spacer(minLength: 8)
                note(rung)
            }
            .background(isCurrent ? Color.accentColor.opacity(0.14) : .clear)
        }
        .buttonStyle(.plain)
        // Not disabled, which would gray it out: the current row is the one to read.
        .allowsHitTesting(!isCurrent)
        .help(entry.title)
    }

    private func mergedRow(_ rungs: [StackLadder.Rung], rail: StackRail, id: String) -> some View {
        let isOpen = unfolded.contains(id)
        let at = rungs.compactMap(\.entry.closedAt).max()
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isOpen { unfolded.remove(id) } else { unfolded.insert(id) }
            }
        } label: {
            row {
                RailView(rail: rail, color: .purple, hollow: false)
                Text("\(rungs.count) merged together" + (at.map { " · \($0.compactAge()) ago" } ?? ""))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(rungs.map { "#\($0.entry.number) \($0.entry.title)" }.joined(separator: "\n"))
    }

    /// What to know about a PR beyond its icon: when it merged, where a staging PR landed, or that
    /// its base is a PR that is gone.
    @ViewBuilder
    private func note(_ rung: StackLadder.Rung) -> some View {
        let entry = rung.entry
        let text = noteText(rung)
        if let upstream = rung.upstream {
            HStack(spacing: 3) {
                StateIconView(item: upstream, size: Self.noteIconSize)
                Text(text ?? "")
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("Promoted as \(upstream.repo)#\(upstream.number): \(upstream.stateDescription)")
        } else if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(entry.state == .open ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .help(entry.state == .open ? "Its base is still \(entry.baseRef), the branch of a PR no longer open" : "")
        }
    }

    private static let noteIconSize: CGFloat = 11

    /// The note's text; see `note`.
    private func noteText(_ rung: StackLadder.Rung) -> String? {
        let entry = rung.entry
        if let upstream = rung.upstream { return "⬆#\(String(upstream.number))" }
        if entry.state != .open {
            return "\(entry.state == .merged ? "merged" : "closed") \(entry.closedAt.map { "\($0.compactAge()) ago" } ?? "")"
        }
        guard let below = stalePR(under: rung) else { return nil }
        let gone = below.entry.state == .merged || below.upstream?.state == .merged ? "merged" : "closed"
        return "on \(gone) #\(String(below.entry.number))"
    }

    /// Whether every title's tags are shortened: when any row's title wouldn't fit with them in
    /// full, as the list does, so a tag reads the same in every row.
    private var shortensTags: Bool {
        guard width > 0 else { return false }
        let body = NSFont.preferredFont(forTextStyle: .callout)
        let bold = NSFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        let caption = NSFont.preferredFont(forTextStyle: .caption1)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
        func measure(_ text: String, _ font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        return ladder.rungs.contains { rung in
            let font = rung.entry.number == item.number ? bold : body
            var needed = 2 * 8 + StackRailShape.width + 6 + measure("#\(rung.entry.number)", digits) + 6
                + measure(rung.entry.title, font) + 8
            if let note = noteText(rung) {
                needed += measure(note, caption) + (rung.upstream != nil ? Self.noteIconSize + 3 : 0)
            }
            return needed > width
        }
    }

    /// The PR below an open one whose branch it is still based on, if that PR is closed or merged.
    /// A staging PR landed upstream is closed on the fork; it counts as merged.
    private func stalePR(under rung: StackLadder.Rung) -> StackLadder.Rung? {
        guard let index = ladder.rungs.firstIndex(of: rung), index > 0 else { return nil }
        let below = ladder.rungs[index - 1]
        guard below.entry.state != .open, below.entry.headRef == rung.entry.baseRef else { return nil }
        return below
    }

    static let rowHeight: CGFloat = 20

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        // A fixed height, so the rail's lines meet from row to row.
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// The title with its leading tags dimmed, and shortened ("[RF][Fix] ") when `shortened`.
    private func title(_ title: String, shortened: Bool) -> Text {
        let pieces = TitleMarkup.pieces(title)
        let short = shortened ? TitlePrefix.abbreviate(TitlePrefix.split(title).prefix) : nil
        let start = short.map { Text(verbatim: $0).foregroundStyle(.tertiary) } ?? Text(verbatim: "")
        return pieces.reduce(start) { text, piece in
            if piece.isPrefix, short != nil { return text }
            var part = Text(verbatim: piece.text)
            if piece.isCode { part = part.font(.callout.monospaced()) }
            if piece.isPrefix { part = part.foregroundStyle(.tertiary) }
            return Text("\(text)\(part)")
        }
    }
}

/// A row's piece of a stack rail (see `StackRailShape`), the node in the PR's state color.
private struct RailView: View {
    let rail: StackRail
    let color: Color
    let hollow: Bool

    var body: some View {
        Canvas { context, size in
            let shape = StackRailShape.layout(rail, in: CGRect(origin: .zero, size: size))
            for line in shape.lines {
                context.stroke(
                    Path(line.path), with: .style(.tertiary),
                    style: StrokeStyle(lineWidth: StackRailShape.lineWidth, dash: line.isDashed ? StackRailShape.dash : [])
                )
            }
            if hollow {
                context.stroke(Path(ellipseIn: shape.node.insetBy(dx: 0.65, dy: 0.65)), with: .color(color), lineWidth: 1.3)
            } else {
                context.fill(Path(ellipseIn: shape.node), with: .color(color))
            }
        }
        .frame(width: StackRailShape.width, height: StackPanel.rowHeight)
    }
}

private extension PRStack.Entry {
    /// As `Item.stateColor`, without mergeability to show conflicts with.
    var stateColor: Color {
        switch state {
        case .open: isDraft ? .secondary : .green
        case .merged: .purple
        case .closed: .red
        }
    }

    var stateDescription: String {
        switch state {
        case .open: isDraft ? "Draft" : "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}
