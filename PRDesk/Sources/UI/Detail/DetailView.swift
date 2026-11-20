import SwiftUI

/// The right-hand pane: header, then Conversation / Commits / Files for the selected item.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    /// Whether the inspector is open; its toolbar items otherwise linger after it closes.
    let isShown: Bool
    /// The pages live as long as the pane, so switching items or tabs doesn't reload them.
    @State private var timelinePage = WebDocument(kind: .timeline)
    @State private var filesPage = WebDocument(kind: .files)
    @State private var commitsPage = WebDocument(kind: .files)

    typealias DetailTab = AppModel.DetailTab

    var body: some View {
        @Bindable var model = model
        return Group {
            if let item = model.selectedItem {
                VStack(spacing: 0) {
                    DetailHeader(item: item)
                        .padding(12)
                    Divider()
                    content(item)
                }
                .onChange(of: item.id) {
                    if item.kind == .issue { model.detailTab = .conversation }
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right", description: Text("Select a PR or issue."))
            }
        }
        // Start WebKit and load the page ahead of the first selection, which otherwise shows
        // nothing for a second or so.
        .onAppear {
            _ = timelinePage.webView
            // Links to the repository's (and the parity fork's) issues and PRs open here, not in the browser.
            for page in [timelinePage, commitsPage, filesPage] {
                page.openItem = { [model] repo, number in model.openItem(repo: repo, number: number) }
            }
        }
        .modifier(DetailToolbar(isShown: isShown, showsTabs: isShown && model.selectedItem?.kind == .pullRequest, tab: $model.detailTab))
    }

    @ViewBuilder
    private func content(_ item: Item) -> some View {
        if let detail = model.detail, detail.id == item.id {
            switch model.detailTab {
            case .conversation:
                VStack(spacing: 0) {
                    ConversationView(item: item, detail: detail, previousSeenAt: model.selectedItemPreviousSeenAt, page: timelinePage)
                    Divider()
                    ComposerView(item: item, detail: detail)
                }
            case .commits:
                // Its own per item, so the selection and the chosen range don't carry over.
                CommitsView(item: item, detail: detail, page: commitsPage)
                    .id(item.id)
            case .files:
                FilesView(item: item, page: filesPage)
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
            DelayedProgressView()
        }
    }
}

/// The Conversation / Commits / Files tabs in the inspector's part of the window toolbar. Its own
/// modifier, so the toolbar is only rebuilt when the tabs come or go, not on every selection.
private struct DetailToolbar: ViewModifier {
    let isShown: Bool
    let showsTabs: Bool
    @Binding var tab: DetailView.DetailTab

    func body(content: Content) -> some View {
        content.toolbar {
            // Over the pane it switches, only for a PR. Otherwise an invisible spacer stands in:
            // without an item of its own the inspector has no toolbar section, and the list's
            // buttons jump to the window's far edge.
            if isShown {
                if showsTabs {
                    // Spacers on both sides center the tabs over the pane.
                    ToolbarSpacer(.flexible)
                    ToolbarItem {
                        Picker("View", selection: $tab) {
                            Text("Conversation").tag(DetailView.DetailTab.conversation)
                            Text("Commits").tag(DetailView.DetailTab.commits)
                            Text("Files").tag(DetailView.DetailTab.files)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    ToolbarSpacer(.flexible)
                } else {
                    ToolbarSpacer(.flexible)
                }
            }
        }
    }
}

/// A spinner that appears only if loading takes a moment, so quick switches between items don't
/// flash it.
struct DelayedProgressView: View {
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeIn(duration: 0.15)) { isShown = true }
            }
    }
}

private struct DetailHeader: View {
    @Environment(AppModel.self) private var model
    let item: Item
    @State private var isParking = false
    /// The title being edited in place, and the item it belongs to (kept, so a rename committed
    /// as another item is selected still goes to this one).
    @State private var titleEdit: (item: Item, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(String(item.number))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // No vertical fixedSize: while the window measures its minimum size it proposes a
                // tiny width, and a fixed-height title would wrap to a window-sized column.
                if titleEdit?.item.id == item.id {
                    titleField
                } else {
                    titleText
                        .lineLimit(3)
                        .textSelection(.enabled)
                        // Double-clicking also selects a word; the field then selects the lot.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { beginTitleEdit() })
                }
            }
            .font(.title3.weight(.semibold))

            HStack(spacing: 6) {
                AvatarView(login: item.author, size: 16)
                LoginText(login: item.author)
                BadgeIcons(login: item.author)
                StateIconView(item: item, isMerging: item.isOpen && model.board(for: item)?.triage == .merging)
                stateChip
                if let ci = item.ci {
                    Button { model.checksShownFor = isShowingChecks.wrappedValue ? nil : item.repoNumber } label: { CISummary(ci: ci) }
                        .buttonStyle(.plain)
                        .help("Show checks")
                        .popover(isPresented: isShowingChecks, arrowEdge: .bottom) {
                            VStack(spacing: 0) {
                                ItemChecksView(item: item, maxHeight: 460)
                                Divider()
                                HStack {
                                    Spacer()
                                    Button("Open on GitHub", systemImage: "arrow.up.right") {
                                        if let url = URL(string: item.url + "/checks") { Platform.open(url) }
                                    }
                                    .buttonStyle(.link)
                                    .font(.callout)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                            .frame(width: 420)
                        }
                }
                Spacer(minLength: 0)
            }
            .font(.callout)

            HStack(spacing: 6) {
                Text("opened \(item.createdAt.compactAge()) ago · updated \(item.updatedAt.compactAge()) ago")
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
            .foregroundStyle(.secondary)

            AdoptionNote(item: item)

            if let ladder = model.stackLadder, ladder.rungs.contains(where: { $0.entry.number == item.number }) {
                StackPanel(item: item, ladder: ladder)
            }

            if !item.labels.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(item.labels, id: \.name) { LabelChip(name: $0.name, hex: $0.color) }
                }
            }

            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Moving to another item (e.g. going back) while renaming renames the one being edited.
        .onChange(of: item.id) { commitTitleEdit() }
    }

    /// The title as a field in the same place and font, as renaming in Finder: Return or clicking
    /// away renames the item, Escape leaves it as it was.
    private var titleField: some View {
        RenameField(
            text: Binding(get: { titleEdit?.text ?? "" }, set: { titleEdit?.text = $0 }),
            font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold),
            onEnd: { commit in
                if commit { commitTitleEdit() } else { titleEdit = nil }
            }
        )
    }

    private func beginTitleEdit() {
        titleEdit = (item, item.title)
    }

    private func commitTitleEdit() {
        guard let edit = titleEdit else { return }
        titleEdit = nil
        model.rename(edit.item, to: edit.text)
    }

    /// The title with its leading tags ("[Core] ", "fix(x): ") dimmed and its inline code monospaced.
    private var titleText: Text {
        TitleMarkup.pieces(item.title).reduce(Text(verbatim: "")) { text, piece in
            var part = Text(verbatim: piece.text)
            // SF Mono a point smaller looks the same size as the title's 15-point text.
            if piece.isCode { part = part.font(.system(size: 14, weight: .semibold, design: .monospaced)) }
            if piece.isPrefix { part = part.foregroundStyle(.secondary) }
            return Text("\(text)\(part)")
        }
    }

    /// The checks popover, open while the model names this item.
    private var isShowingChecks: Binding<Bool> {
        Binding(
            get: { model.checksShownFor == item.repoNumber },
            set: { model.checksShownFor = $0 ? item.repoNumber : nil }
        )
    }

    private var stateChip: some View {
        switch (item.state, item.isDraft) {
        case (.open, true): Chip(text: "Draft")
        case (.open, false): Chip(text: "Open", color: .green)
        case (.merged, _): Chip(text: "Merged", color: .purple)
        case (.closed, _): Chip(text: "Closed", color: item.kind == .issue ? .purple : .red)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if item.isParityStaging {
                parkButton
            } else {
                boardControls
            }
            Spacer()
            if model.detailState == .loading || isParking {
                ProgressView().controlSize(.small)
            }
            sessionButton
            iconButton("Refresh", symbol: "arrow.clockwise") { model.loadDetail(force: true) }
                .disabled(model.detailState == .loading)
            iconButton("Open", symbol: "arrow.up.right") { model.perform(.openInBrowser, on: item.id) }
                .help("Open on GitHub (o)")
        }
        .controlSize(.small)
    }

    /// Opens the agent sessions the assistant bot wrote to the board's Session field: the latest
    /// one, or any of them from a menu when there are several.
    @ViewBuilder private var sessionButton: some View {
        let links = model.board(for: item)?.sessionLinks ?? []
        if links.count == 1 {
            iconButton("Agent Session", symbol: "terminal") { AgentSession.open(links[0]) }
                .help("Open the \(AgentSession.agentName(for: links[0])) session (t)")
        } else if links.count > 1 {
            Menu {
                ForEach(Array(links.enumerated().reversed()), id: \.offset) { index, link in
                    Button("\(AgentSession.agentName(for: link)) session \(index + 1)\(index == links.count - 1 ? " (latest)" : "")") {
                        AgentSession.open(link)
                    }
                }
            } label: {
                Image(systemName: "terminal")
            } primaryAction: {
                AgentSession.open(links[links.count - 1])
            }
            .menuIndicator(.visible)
            .fixedSize()
            .help("Open the latest agent session (t); the menu lists all \(links.count)")
        }
    }

    /// A staging PR is parked as a draft, which the parity agent reads as "not now" (SPEC §3.2).
    private var parkButton: some View {
        Button(item.isDraft ? "Resume" : "Park", systemImage: item.isDraft ? "play" : "pause") {
            let item = item
            isParking = true
            Task {
                do {
                    try await model.setParked(!item.isDraft, item)
                } catch {
                    model.writeError = "Couldn't \(item.isDraft ? "resume" : "park") #\(item.number): \(error.localizedDescription)"
                }
                isParking = false
            }
        }
        .disabled(!item.isOpen || isParking)
        .help(item.isDraft
            ? "Mark ready for review: the parity agent picks the item up again"
            : "Convert to a draft: the parity agent parks the item as backlog")
    }

    @ViewBuilder private var boardControls: some View {
        let board = model.board(for: item)
        let triage = model.triage(for: item)
        Group {
            Picker("Status", selection: Binding(
                get: { model.listedTriage(for: item) },
                set: { status in
                    if let status {
                        if status != triage { model.perform(.triage(status), on: item.id) }
                    } else if let current = triage {
                        // Choosing the current status again clears it.
                        model.perform(.triage(current), on: item.id)
                    }
                }
            )) {
                Text("Triage").tag(TriageStatus?.none)
                Divider()
                ForEach(TriageStatus.settable, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                // Merging comes with 🚀 or from Merger; shown while the item has it, never offered.
                if triage == .merging {
                    Text(TriageStatus.merging.rawValue).tag(Optional(TriageStatus.merging)).selectionDisabled()
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Status on the board (w/b/s/m)")

            Picker("Priority", selection: Binding(
                get: { board?.priorityValue },
                set: { model.perform(.priority($0), on: item.id) }
            )) {
                Text("No Priority").tag(Priority?.none)
                Divider()
                ForEach(Priority.allCases, id: \.self) { priority in
                    Label(priority.optionName, systemImage: priority.symbol).tag(Optional(priority))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Priority on the board (1/2/3, 0 to clear)")

            if model.canAddToDesk(item) {
                Button("Add to Desk", systemImage: "plus") { model.perform(.addToDesk, on: item.id) }
                    .help("Keep this item on the desk, in Triage (a)")
            }
            let isPinned = board?.isPinned == true
            iconButton(isPinned ? "Unpin" : "Pin", symbol: isPinned ? "pin.slash" : "pin") {
                model.perform(.togglePin, on: item.id)
            }
            .help(isPinned ? "Unpin (p)" : "Pin (p)")
        }
    }

    /// An icon-only button whose icon gets a fixed box: symbols differ in height, and the button
    /// sizes to its icon, so otherwise neighbors come out different heights.
    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 14, height: 14)
        }
        .accessibilityLabel(title)
    }
}
