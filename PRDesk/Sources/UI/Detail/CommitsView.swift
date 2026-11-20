import SwiftUI

/// A PR's commits above the diff of what is chosen: since the viewer's last review, since they last
/// looked, everything, one commit, a stretch of commits, or a force push.
struct CommitsView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail
    let page: WebDocument

    /// Selected rows; empty means the preset.
    @State private var selection: Set<String> = []
    /// The chosen preset; nil for the default.
    @State private var preset: CommitHistory.Preset?
    @State private var loaded: Loaded?
    @State private var error: String?
    @AppStorage("wrapDiffLines") private var wrapLines = true

    private struct Loaded {
        var range: CommitRange
        var files: [PullFile]
        var payload: String
    }

    /// Small diffs (a commit or two) start with their files expanded.
    private static let expandedLimit = (files: 10, lines: 600)

    private var history: CommitHistory {
        CommitHistory(
            detail: detail, viewer: model.viewer,
            previousHead: model.selectedItemPreviousSeenHead, previousSeenAt: model.selectedItemPreviousSeenAt
        )
    }

    var body: some View {
        let history = history
        let range = range(in: history)
        Group {
            if detail.commits == nil {
                // Cached before details had commits: fetch it again.
                DelayedProgressView()
                    .task { model.loadDetail(force: true) }
            } else if history.commits.isEmpty {
                ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                VStack(spacing: 0) {
                    list(history)
                        .frame(height: min(CGFloat(history.rows.count) * 24 + 10, 200))
                    Divider()
                    toolbar(history, range: range)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    Divider()
                    diff(range)
                }
            }
        }
        .task(id: range) { await load(range) }
        .onChange(of: wrapLines, initial: true) { page.setting("wrap", "PRDesk.setWrap(\(wrapLines))") }
        .onChange(of: model.linkedCommit?.commit, initial: true) { selectLinkedCommit(history) }
    }

    private func range(in history: CommitHistory) -> CommitRange {
        if !selection.isEmpty, let range = history.range(selecting: selection) { return range }
        return history.range(preset ?? history.defaultPreset) ?? .all
    }

    private func selectLinkedCommit(_ history: CommitHistory) {
        guard let link = model.linkedCommit, link.key == item.repoNumber,
              let sha = link.commit, let commit = history.commit(matching: sha) else { return }
        selection = [commit.oid]
    }

    // MARK: List

    private func list(_ history: CommitHistory) -> some View {
        List(selection: $selection) {
            ForEach(history.rows) { row in
                switch row {
                case let .commit(commit, isNew):
                    CommitRow(commit: commit, isNew: isNew, pullURL: item.url)
                case let .push(push):
                    PushRow(push: push)
                        .selectionDisabled(push.before == nil || push.after == nil)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 22)
    }

    // MARK: Toolbar

    private func toolbar(_ history: CommitHistory, range: CommitRange) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(CommitHistory.Preset.allCases, id: \.self) { option in
                    Button(option.title) {
                        selection = []
                        preset = option
                    }
                    .disabled(history.range(option) == nil)
                }
            } label: {
                Text(title(history, range: range))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if history.isRewritten(range) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Force-pushed since: a rebase onto the base branch shows up here too")
            }
            if let loaded, loaded.range == range {
                Text("\(loaded.files.count) file\(loaded.files.count == 1 ? "" : "s")")
                    .padding(.leading, 4)
                Text("+\(loaded.files.reduce(0) { $0 + $1.additions })").foregroundStyle(.green)
                Text("−\(loaded.files.reduce(0) { $0 + $1.deletions })").foregroundStyle(.red)
            }
            Spacer()
            Toggle("Wrap lines", isOn: $wrapLines)
                .toggleStyle(.checkbox)
            Button("Expand all") { page.run("PRDesk.setAllFiles(true)") }
                .buttonStyle(.link)
                .padding(.leading, 4)
            Button("Collapse all") { page.run("PRDesk.setAllFiles(false)") }
                .buttonStyle(.link)
        }
        .font(.caption.monospacedDigit())
        .controlSize(.small)
    }

    /// What the diff shows: the preset, or what the selection covers.
    private func title(_ history: CommitHistory, range: CommitRange) -> String {
        guard !selection.isEmpty else { return (preset ?? history.defaultPreset).title }
        switch range {
        case let .commit(sha):
            return "Commit \(history.commit(matching: sha)?.shortOid ?? String(sha.prefix(7)))"
        case let .compare(base, head):
            let indices = history.commits.indices.filter { selection.contains(history.commits[$0].oid) }
            if let low = indices.first, let high = indices.last {
                return "\(high - low + 1) commits"
            }
            return "Force push \(base.prefix(7)) → \(head.prefix(7))"
        case .all:
            return CommitHistory.Preset.all.title
        }
    }

    // MARK: Diff

    @ViewBuilder
    private func diff(_ range: CommitRange) -> some View {
        if let loaded, loaded.range == range {
            if loaded.files.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "doc")
            } else {
                WebDocumentView(document: page, key: "\(item.id)#\(range.key)", payload: loaded.payload)
            }
        } else if let error {
            ContentUnavailableView {
                Label("Couldn't load changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await load(range) } }
            }
        } else {
            DelayedProgressView()
        }
    }

    private func load(_ range: CommitRange) async {
        error = nil
        let item = item
        do {
            let files = try await model.files(for: item, in: range)
            let lines = files.reduce(0) { $0 + $1.additions + $1.deletions }
            let isSmall = files.count <= Self.expandedLimit.files && lines <= Self.expandedLimit.lines
            let filesURL: String? = switch range {
            case .all: nil
            case let .commit(sha): "\(item.url)/commits/\(sha)"
            case let .compare(base, head): "\(item.url)/files/\(base)..\(head)"
            }
            let payload = await FilesDocument.payload(
                files, key: "\(item.id)#\(range.key)", pullURL: item.url, filesURL: filesURL,
                expanded: range != .all && isSmall ? true : nil
            )
            guard !Task.isCancelled else { return }
            loaded = Loaded(range: range, files: files, payload: payload)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct CommitRow: View {
    let commit: PRCommit
    let isNew: Bool
    let pullURL: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ciColor)
                .frame(width: 7, height: 7)
            AvatarView(login: commit.author, size: 16)
            Text(commit.shortOid)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Text(commit.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if isNew {
                Text("new")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 5)
                    .background(.tint.opacity(0.15), in: .capsule)
            }
            Text(commit.committedAt.compactAge())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .help("\(commit.authorName ?? commit.author ?? "") · +\(commit.additions) −\(commit.deletions)")
        .contextMenu {
            Button("Open on GitHub") {
                if let url = URL(string: "\(pullURL)/commits/\(commit.oid)") { Platform.open(url) }
            }
            Button("Copy SHA") { Platform.copy(commit.oid) }
        }
    }

    private var ciColor: Color {
        switch commit.ciState {
        case "SUCCESS": .green
        case "FAILURE", "ERROR": .red
        case "PENDING", "EXPECTED": .yellow
        default: .clear
        }
    }
}

private struct PushRow: View {
    let push: CommitHistory.Push

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .frame(width: 7 + 6 + 16)
            Text("\(push.actor ?? "Someone") force-pushed")
            if let before = push.before, let after = push.after {
                Text("\(before.prefix(7)) → \(after.prefix(7))")
                    .font(.callout.monospaced())
            }
            Spacer(minLength: 4)
            Text(push.at.compactAge())
                .monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .help(push.before == nil || push.after == nil ? "" : "Select to see what the push changed")
    }
}
