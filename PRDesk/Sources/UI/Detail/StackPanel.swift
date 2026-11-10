import SwiftUI

/// The stack the selected PR is in, in the detail header (SPEC §6): the base branch on top, then
/// the PRs from the base up, PRs merged together folded into one line. A row opens its PR.
struct StackPanel: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let ladder: StackLadder
    /// Folded merge runs the viewer opened, by line id.
    @State private var unfolded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            row {
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
                case let .merged(rungs):
                    mergedRow(rungs, id: line.id)
                    if unfolded.contains(line.id) {
                        ForEach(rungs) { rungRow($0) }
                    }
                }
            }
        }
        .font(.callout)
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
                StackStateIcon(state: entry.state, isDraft: entry.isDraft)
                Text("#\(String(entry.number))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                title(entry.title)
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

    private func mergedRow(_ rungs: [StackLadder.Rung], id: String) -> some View {
        let isOpen = unfolded.contains(id)
        let at = rungs.compactMap(\.entry.closedAt).max()
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isOpen { unfolded.remove(id) } else { unfolded.insert(id) }
            }
        } label: {
            row {
                StackStateIcon(state: .merged, isDraft: false)
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
        if let upstream = rung.upstream {
            HStack(spacing: 3) {
                StateIconView(item: upstream, size: 11)
                Text("⬆#\(String(upstream.number))")
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("Promoted as \(upstream.repo)#\(upstream.number): \(upstream.stateDescription)")
        } else if entry.state != .open {
            Text("\(entry.state == .merged ? "merged" : "closed") \(entry.closedAt.map { "\($0.compactAge()) ago" } ?? "")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if let below = stalePR(under: rung) {
            let gone = below.entry.state == .merged || below.upstream?.state == .merged ? "merged" : "closed"
            Text("on \(gone) #\(String(below.entry.number))")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Its base is still \(entry.baseRef), the branch of a PR no longer open")
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

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// The title with its leading tags shortened ("[RF][Fix] ") and dimmed, as in a narrow list:
    /// the panel is narrow, and a stack's PRs mostly share their tags.
    private func title(_ title: String) -> Text {
        let pieces = TitleMarkup.pieces(title)
        let short = TitlePrefix.abbreviate(TitlePrefix.split(title).prefix)
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

/// A PR state icon from a stack entry's state, which has no mergeability to show conflicts with.
private struct StackStateIcon: View {
    let state: Item.State
    let isDraft: Bool

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 12, height: 12)
            .foregroundStyle(color)
    }

    private var name: String {
        switch state {
        case .open: isDraft ? "pr-draft" : "pr-open"
        case .merged: "pr-merged"
        case .closed: "pr-closed"
        }
    }

    private var color: Color {
        switch state {
        case .open: isDraft ? .secondary : .green
        case .merged: .purple
        case .closed: .red
        }
    }
}
