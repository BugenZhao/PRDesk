import SwiftUI

/// The selected item: a compact header with the board's controls, then the conversation (the
/// shared timeline page) and the composer; the CI status in the header shows the checks.
struct ItemDetailScreen: View {
    @Environment(AppModel.self) private var model
    /// The page lives as long as the screen, so switching tabs doesn't reload it.
    @State private var timelinePage = WebDocument(kind: .timeline)
    @AppStorage("showAutomated") private var showAutomated = false

    var body: some View {
        Group {
            if let item = model.selectedItem {
                VStack(spacing: 0) {
                    DetailHeader(item: item)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    Divider()
                    content(item)
                }
                .navigationTitle("#\(String(item.number))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .tabBar)
                .toolbar { DetailActions(item: item) }
            } else {
                ContentUnavailableView("No Selection", systemImage: "doc.text")
            }
        }
        .onAppear {
            // Links to the repository's issues and PRs open here, not in the browser.
            timelinePage.openItem = { [model] repo, number in model.openItem(repo: repo, number: number) }
            timelinePage.toggleReaction = { [model] content, subject in model.toggleReaction(content, on: subject) }
        }
    }

    @ViewBuilder
    private func content(_ item: Item) -> some View {
        if let detail = model.detail, detail.id == item.id {
            let document = TimelineDocument(
                item: item, detail: detail, previousSeenAt: model.selectedItemPreviousSeenAt,
                showAutomated: showAutomated, people: model
            )
            WebDocumentView(document: timelinePage, key: item.id, payload: document.payload)
                .safeAreaInset(edge: .bottom) {
                    ComposerView(item: item, detail: detail)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.bar)
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

/// Title, state, author and labels, then the board's Status and Priority.
private struct DetailHeader: View {
    @Environment(AppModel.self) private var model
    let item: Item

    /// The checks sheet, open while the model names this item.
    private var isShowingChecks: Binding<Bool> {
        Binding(
            get: { model.checksShownFor == item.repoNumber },
            set: { model.checksShownFor = $0 ? item.repoNumber : nil }
        )
    }

    var body: some View {
        let board = model.board(for: item)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StateIconView(item: item, size: 15, isMerging: item.isOpen && board?.triage == .merging)
                Text(item.title).font(.headline).lineLimit(3)
            }
            HStack(spacing: 5) {
                AvatarView(login: item.author, size: 16)
                LoginText(login: item.author)
                BadgeIcons(login: item.author)
                Text("· \(item.stateDescription(isMerging: board?.triage == .merging))").foregroundStyle(.secondary)
                if let ci = item.ci {
                    Button { model.checksShownFor = item.repoNumber } label: { CISummary(ci: ci) }
                        .buttonStyle(.plain)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .sheet(isPresented: isShowingChecks) { ChecksSheet(item: item) }
            AdoptionNote(item: item)
            if !item.labels.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(item.labels, id: \.name) { LabelChip(name: $0.name, hex: $0.color) }
                }
            }
            if item.isUpstream, board?.isForeign != true {
                BoardControls(item: item)
            }
            if let comment = board?.comment, !comment.isEmpty, board?.isArchived == false {
                Text(comment).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The checks, from the CI status in the header: half the screen, pulled up for more.
private struct ChecksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: Item

    var body: some View {
        NavigationStack {
            ItemChecksView(item: item)
                .navigationTitle("Checks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Open on GitHub", systemImage: "safari") {
                            if let url = URL(string: item.url + "/checks") { Platform.open(url) }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Status and Priority as menus, and the pin, written to the board as on the Mac.
private struct BoardControls: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        let board = model.board(for: item)
        let listed = model.listedTriage(for: item)
        let priority = board?.priorityValue
        HStack(spacing: 8) {
            Menu {
                Button("Triage") { if let current = model.triage(for: item) { model.perform(.triage(current), on: item.id) } }
                ForEach(TriageStatus.settable, id: \.self) { status in
                    Button(status.rawValue) { if status != model.triage(for: item) { model.perform(.triage(status), on: item.id) } }
                }
            } label: {
                Label(listed?.rawValue ?? "Triage", systemImage: "square.stack")
            }
            Menu {
                ForEach(Priority.allCases, id: \.self) { value in
                    Button(value.optionName) { if value != priority { model.perform(.priority(value), on: item.id) } }
                }
                Button("No Priority") { if let priority { model.perform(.priority(priority), on: item.id) } }
            } label: {
                Label(priority?.optionName ?? "No Priority", systemImage: priority?.symbol ?? "minus")
            }
            Button {
                model.perform(.togglePin, on: item.id)
            } label: {
                Image(systemName: board?.isPinned == true ? "pin.fill" : "pin")
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }
}

/// The toolbar's menu: open on GitHub, mark unread, mark ready or draft, and hand the item to a Grok Bot.
private struct DetailActions: ToolbarContent {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Open on GitHub", systemImage: "safari") { model.perform(.openInBrowser, on: item.id) }
                Button("Mark as Unread", systemImage: "envelope.badge") { model.perform(.toggleRead, on: item.id) }
                Button("Copy Link", systemImage: "link") { model.perform(.copyLink, on: item.id) }
                if let toggle = item.draftToggle {
                    Button {
                        let item = item
                        Task { await model.toggleDraft(item) }
                    } label: {
                        Label { Text(toggle.title) } icon: { toggle.icon.image }
                    }
                }
                if let session = model.board(for: item)?.sessionLinks.last {
                    Button("Open Agent Session", systemImage: "terminal") { AgentSession.open(session) }
                }
                Section("Grok Bot") {
                    ForEach(BotRequest.allCases, id: \.self) { request in
                        Button("\(request.emoji) \(request.title)…") { model.perform(.sendToBot(request, withNote: true), on: item.id) }
                            .disabled(!request.applies(to: item))
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

}
