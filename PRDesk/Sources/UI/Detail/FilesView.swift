import SwiftUI

/// Read-only diff of a PR's changed files.
struct FilesView: View {
    @Environment(AppModel.self) private var model
    let item: Item

    @State private var files: [ParsedFile]?
    @State private var error: String?
    @State private var expanded: [String: Bool] = [:]

    /// Files with more diff lines than this start collapsed.
    private static let autoExpandLimit = 300

    var body: some View {
        Group {
            if let files {
                if files.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "doc")
                } else {
                    list(files)
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn't load files", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(item.number)-\(item.updatedAt.timeIntervalSince1970)") { await load() }
    }

    private func list(_ files: [ParsedFile]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                HStack {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                    Text("+\(files.reduce(0) { $0 + $1.file.additions })").foregroundStyle(.green)
                    Text("−\(files.reduce(0) { $0 + $1.file.deletions })").foregroundStyle(.red)
                    Spacer()
                    Button("Expand all") { expanded = Dictionary(uniqueKeysWithValues: files.map { ($0.id, true) }) }
                    Button("Collapse all") { expanded = Dictionary(uniqueKeysWithValues: files.map { ($0.id, false) }) }
                }
                .font(.caption.monospacedDigit())
                .buttonStyle(.link)

                ForEach(files) { parsed in
                    FileDiffView(file: parsed.file, lines: parsed.lines, expanded: Binding(
                        get: { expanded[parsed.id] ?? ((parsed.lines?.count ?? 0) < Self.autoExpandLimit) },
                        set: { expanded[parsed.id] = $0 }
                    ))
                }
            }
            .padding(10)
        }
    }

    private func load() async {
        error = nil
        do {
            files = try await model.files(for: item.number)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FileDiffView: View {
    let file: PullFile
    let lines: [DiffLine]?
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider()
                if let lines {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { DiffLineView(line: $0) }
                    }
                } else {
                    Text("No textual diff (binary or too large).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: statusSymbol.0).foregroundStyle(statusSymbol.1)
            Group {
                if let previous = file.previousFilename {
                    Text("\(previous) → \(file.filename)")
                } else {
                    Text(file.filename)
                }
            }
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
            Spacer()
            Text("+\(file.additions)").foregroundStyle(.green)
            Text("−\(file.deletions)").foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private var statusSymbol: (String, Color) {
        switch file.status {
        case "added": ("plus.square", .green)
        case "removed": ("minus.square", .red)
        case "renamed", "copied": ("arrow.right.square", .blue)
        default: ("square.and.pencil", .orange)
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker + line.text)
                .foregroundStyle(line.kind == .hunk ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        case .hunk: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.14)
        case .removed: .red.opacity(0.14)
        case .hunk: .blue.opacity(0.08)
        case .context: .clear
        }
    }
}
