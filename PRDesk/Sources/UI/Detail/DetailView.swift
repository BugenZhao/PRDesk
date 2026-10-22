import SwiftUI

/// The right-hand pane: header, then Conversation / Checks for the selected item.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: DetailTab = .conversation

    enum DetailTab: Hashable {
        case conversation, checks, files
    }

    var body: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                DetailHeader(item: item, state: model.state(for: item), tab: $tab)
                    .padding(12)
                if item.kind == .pullRequest {
                    Picker("View", selection: $tab) {
                        Text("Conversation").tag(DetailTab.conversation)
                        Text(checksTitle(item)).tag(DetailTab.checks)
                        Text("Files").tag(DetailTab.files)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                Divider()
                content(item)
            }
            .onChange(of: item.number) {
                if item.kind == .issue { tab = .conversation }
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a PR or issue."))
        }
    }

    private func checksTitle(_ item: Item) -> String {
        guard let ci = item.ci else { return "Checks" }
        return ci.failed > 0 ? "Checks (\(ci.failed) failed)" : "Checks (\(ci.total))"
    }

    @ViewBuilder
    private func content(_ item: Item) -> some View {
        if let detail = model.detail, detail.number == item.number {
            switch tab {
            case .conversation:
                VStack(spacing: 0) {
                    ConversationView(item: item, detail: detail, previousSeenAt: model.selectedItemPreviousSeenAt)
                    Divider()
                    ComposerView(item: item, detail: detail)
                }
            case .checks:
                ChecksView(checks: detail.checks)
            case .files:
                FilesView(item: item)
            }
        } else if case let .failed(message) = model.detailState {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { model.loadDetail(force: true) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DetailHeader: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let state: ItemState
    @Binding var tab: DetailView.DetailTab

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(String(item.number))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // No vertical fixedSize: while the window measures its minimum size it proposes a
                // tiny width, and a fixed-height title would wrap to a window-sized column.
                titleText
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .font(.title3.weight(.semibold))

            HStack(spacing: 6) {
                AvatarView(login: item.author, size: 16)
                LoginText(login: item.author)
                BadgeIcons(login: item.author)
                StateIconView(item: item)
                stateChip
                if let ci = item.ci {
                    Button { tab = .checks } label: { CISummary(ci: ci) }
                        .buttonStyle(.plain)
                        .help("Show checks")
                }
                Spacer(minLength: 0)
            }
            .font(.callout)

            HStack(spacing: 6) {
                Text("opened \(item.createdAt.compactAge()) ago · updated \(item.updatedAt.compactAge()) ago")
                if let detail = model.detail, detail.number == item.number, let head = detail.headRef, let base = detail.baseRef {
                    Text("·")
                    Text("\(head) → \(base)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !item.labels.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(item.labels, id: \.name) { LabelChip(name: $0.name, hex: $0.color) }
                }
            }

            controls
            BoardCommentField(item: item, saved: model.board(for: item)?.comment ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The title with its leading tags ("[Core] ", "fix(x): ") dimmed.
    private var titleText: Text {
        let (prefix, rest) = TitlePrefix.split(item.title)
        return Text("\(Text(prefix).foregroundStyle(.secondary))\(Text(rest))")
    }

    private var stateChip: some View {
        switch (item.state, item.isDraft) {
        case (.open, true): Chip(text: "draft")
        case (.open, false): Chip(text: "open", color: .green)
        case (.merged, _): Chip(text: "merged", color: .purple)
        case (.closed, _): Chip(text: "closed", color: item.kind == .issue ? .purple : .red)
        }
    }

    private var controls: some View {
        let board = model.board(for: item)
        return HStack(spacing: 8) {
            Picker("Status", selection: Binding(
                get: { board?.triage },
                set: { status in
                    if let status {
                        if status != board?.triage { model.perform(.triage(status), on: item.id) }
                    } else if let current = board?.triage {
                        // Choosing the current status again clears it.
                        model.perform(.triage(current), on: item.id)
                    }
                }
            )) {
                Text("Triage").tag(TriageStatus?.none)
                Divider()
                ForEach(TriageStatus.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Status on the board (w/b/s/m)")

            Picker("Priority", selection: Binding(
                get: { board?.priorityValue },
                set: { model.perform(.priority($0), on: item.id) }
            )) {
                ForEach(Priority.allCases, id: \.self) { Text($0.letter).tag(Optional($0)) }
                Text("–").tag(Priority?.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Priority on the board (1/2/3, 0 to clear)")

            Button(state.isPinned ? "Unpin" : "Pin", systemImage: state.isPinned ? "pin.slash" : "pin") {
                model.perform(.togglePin, on: item.id)
            }
            .labelStyle(.iconOnly)
            .help(state.isPinned ? "Unpin (p)" : "Pin (p)")
            Spacer()
            if model.detailState == .loading {
                ProgressView().controlSize(.small)
            }
            Button("Refresh", systemImage: "arrow.clockwise") { model.loadDetail(force: true) }
                .labelStyle(.iconOnly)
                .disabled(model.detailState == .loading)
            Button("Open", systemImage: "arrow.up.right") { model.perform(.openInBrowser, on: item.id) }
                .labelStyle(.iconOnly)
                .help("Open on GitHub (o)")
        }
        .controlSize(.small)
    }
}

/// The board's Comment field: a note on the item, saved on Return or when focus leaves.
private struct BoardCommentField: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let saved: String
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Comment", text: $text, axis: .vertical)
            .lineLimit(1 ... 4)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($isFocused)
            .onSubmit(save)
            .onChange(of: isFocused) { if !isFocused { save() } }
            // Reload when another item is shown or the board changes, but not under the cursor.
            .task(id: "\(item.number)\n\(saved)") {
                if !isFocused { text = saved }
            }
            .help("Comment on the board")
    }

    private func save() {
        model.setComment(text, for: item)
    }
}

private struct CISummary: View {
    let ci: Item.CIStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(ci.failed > 0 ? .red : .secondary)
        }
    }

    private var color: Color {
        if ci.failed > 0 { return .red }
        if ci.pending > 0 || ci.state == "PENDING" || ci.state == "EXPECTED" { return .yellow }
        return ci.state == "SUCCESS" ? .green : .red
    }

    private var text: String {
        if ci.failed > 0 { return "CI \(ci.failed) failed" }
        if ci.pending > 0 { return "CI \(ci.pending) pending" }
        return ci.state == "SUCCESS" ? "CI passed" : "CI \(ci.state.lowercased())"
    }
}
