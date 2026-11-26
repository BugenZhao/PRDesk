import SwiftUI

/// What both apps' detail headers are made of. Each header lays these out its own way (the Mac's
/// in a pane that stays put, the iPad's over a page that scrolls it away); what they say is one.

/// Draft, Open, Merged or Closed, in the state's color.
struct ItemStateChip: View {
    let item: Item

    var body: some View {
        switch (item.state, item.isDraft) {
        case (.open, true): Chip(text: "Draft")
        case (.open, false): Chip(text: "Open", color: .green)
        case (.merged, _): Chip(text: "Merged", color: .purple)
        case (.closed, _): Chip(text: "Closed", color: item.kind == .issue ? .purple : .red)
        }
    }
}

/// When the item was opened and last updated, and a PR's branches once its detail is loaded.
struct ItemDatesLine: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        HStack(spacing: 6) {
            Text("opened \(item.createdAt.compactAge()) ago · updated \(item.updatedAt.compactAge()) ago")
                .lineLimit(1)
            if let detail = model.detail, detail.id == item.id, let head = detail.headRef, let base = detail.baseRef {
                Text("·")
                Text("\(head) → \(base)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondaryText)
    }
}

/// Opens the agent sessions written to the board's Session field (SPEC §3.3): the one there is,
/// or the latest with a menu of them all when there are several. Nothing without one. The label
/// is the app's: a boxed symbol among the Mac header's small buttons, a bar button on the iPad.
struct SessionButton<Label: View>: View {
    @Environment(AppModel.self) private var model
    let item: Item
    @ViewBuilder let label: Label

    var body: some View {
        let links = model.board(for: item)?.sessionLinks ?? []
        if links.count == 1 {
            Button { AgentSession.open(links[0]) } label: { label }
                .help("Open the \(AgentSession.agentName(for: links[0])) session (t)")
        } else if let latest = links.last {
            Menu {
                ForEach(Array(links.enumerated().reversed()), id: \.offset) { index, link in
                    Button("\(AgentSession.agentName(for: link)) session \(index + 1)\(index == links.count - 1 ? " (latest)" : "")") {
                        AgentSession.open(link)
                    }
                }
            } label: {
                label
            } primaryAction: {
                AgentSession.open(latest)
            }
            .help("Open the latest agent session (t); the menu lists all \(links.count)")
        }
    }
}

extension AppModel {
    /// The item's Status as the list has it, to pick from: nil is Triage. Picking the Status it
    /// has is no change, and picking Triage clears it (setting the current Status again does).
    func statusBinding(for item: Item) -> Binding<TriageStatus?> {
        Binding(
            get: { self.listedTriage(for: item) },
            set: { status in
                let current = self.triage(for: item)
                if let status {
                    if status != current { self.perform(.triage(status), on: item.id) }
                } else if let current {
                    self.perform(.triage(current), on: item.id)
                }
            }
        )
    }

    /// The item's Priority on the board, to pick from: nil is none.
    func priorityBinding(for item: Item) -> Binding<Priority?> {
        Binding(
            get: { self.board(for: item)?.priorityValue },
            set: { priority in
                if priority != self.board(for: item)?.priorityValue { self.perform(.priority(priority), on: item.id) }
            }
        )
    }

    /// Whether the item's checks are shown (one popover at a time, wherever it was asked for).
    func checksBinding(for item: Item) -> Binding<Bool> {
        Binding(
            get: { self.checksShownFor == item.repoNumber },
            set: { self.checksShownFor = $0 ? item.repoNumber : nil }
        )
    }
}
