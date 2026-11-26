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

private struct DetailHeader: View {
    @Environment(AppModel.self) private var model
    let item: Item
    @State private var isSettingDraft = false
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
                    // SF Mono a point smaller looks the same size as the title's 15-point text.
                    Text(itemTitle: item.title, shortenedTags: false, codeFont: .system(size: 14, weight: .semibold, design: .monospaced), tagStyle: .secondaryText)
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
                ItemStateChip(item: item)
                if let ci = item.ci {
                    let isShowingChecks = model.checksBinding(for: item)
                    Button { isShowingChecks.wrappedValue.toggle() } label: { CISummary(ci: ci) }
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

            ItemDatesLine(item: item)

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

    private var controls: some View {
        HStack(spacing: 8) {
            // Staging PRs aren't on the board (SPEC §3.2).
            if !item.isParityStaging { boardControls }
            draftButton
            Spacer()
            if model.detailState == .loading || isSettingDraft {
                ProgressView().controlSize(.small)
            }
            SessionButton(item: item) { iconLabel("Agent Session", icon: .symbol("terminal")) }
                .menuIndicator(.visible)
                .fixedSize()
            iconButton("Refresh", symbol: "arrow.clockwise") { model.loadDetail(force: true) }
                .disabled(model.detailState == .loading)
            iconButton("Open", symbol: "arrow.up.right") { model.perform(.openInBrowser, on: item.id) }
                .help("Open on GitHub (o)")
        }
        .controlSize(.small)
    }

    /// Draft ⇄ ready for review; Park / Resume on a staging PR, which the parity agent reads as
    /// "not now" (SPEC §3.2).
    @ViewBuilder private var draftButton: some View {
        if let toggle = item.draftToggle {
            // Icon only, like Pin; the tooltip names it.
            iconButton(toggle.title, icon: toggle.icon) {
                let item = item
                isSettingDraft = true
                Task {
                    await model.toggleDraft(item)
                    isSettingDraft = false
                }
            }
            .disabled(isSettingDraft)
            .help(toggle.help)
        }
    }

    @ViewBuilder private var boardControls: some View {
        let board = model.board(for: item)
        let triage = model.triage(for: item)
        Group {
            Picker("Status", selection: model.statusBinding(for: item)) {
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

            Picker("Priority", selection: model.priorityBinding(for: item)) {
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
        iconButton(title, icon: .symbol(symbol), action: action)
    }

    private func iconButton(_ title: String, icon: StateIcon, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(title, icon: icon) }
    }

    private func iconLabel(_ title: String, icon: StateIcon) -> some View {
        Group {
            switch icon {
            // The PR glyphs are drawn on a 16 px grid; scaled down they match the symbols' weight.
            case .asset: icon.image.resizable().scaledToFit().frame(width: 13, height: 13).frame(width: 14, height: 14)
            case .symbol: icon.image.frame(width: 14, height: 14)
            }
        }
        .accessibilityLabel(title)
    }
}
