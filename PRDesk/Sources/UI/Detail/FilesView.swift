import SwiftUI

/// Read-only diff of a PR's changed files, highlighted, in one web page (see `detail.js`).
struct FilesView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let page: WebDocument

    @State private var loaded: Loaded?
    @State private var error: String?
    @AppStorage("wrapDiffLines") private var wrapLines = true

    private struct Loaded {
        var number: Int
        var files: [PullFile]
        var payload: String
    }

    var body: some View {
        Group {
            if let loaded, loaded.number == item.number {
                if loaded.files.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "doc")
                } else {
                    VStack(spacing: 0) {
                        toolbar(loaded.files)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        Divider()
                        WebDocumentView(document: page, key: String(loaded.number), payload: loaded.payload)
                    }
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
                DelayedProgressView()
            }
        }
        .task(id: "\(item.number)-\(item.updatedAt.timeIntervalSince1970)") { await load() }
        .onChange(of: wrapLines, initial: true) { page.setting("wrap", "PRDesk.setWrap(\(wrapLines))") }
    }

    private func toolbar(_ files: [PullFile]) -> some View {
        HStack(spacing: 6) {
            Text("\(files.count) file\(files.count == 1 ? "" : "s")")
            Text("+\(files.reduce(0) { $0 + $1.additions })").foregroundStyle(.green)
            Text("−\(files.reduce(0) { $0 + $1.deletions })").foregroundStyle(.red)
            Spacer()
            Toggle("Wrap lines", isOn: $wrapLines)
                .toggleStyle(.checkbox)
            Button("Expand all") { page.run("PRDesk.setAllFiles(true)") }
                .padding(.leading, 4)
            Button("Collapse all") { page.run("PRDesk.setAllFiles(false)") }
        }
        .font(.caption.monospacedDigit())
        .controlSize(.small)
        .buttonStyle(.link)
    }

    private func load() async {
        error = nil
        let number = item.number
        let url = item.url
        do {
            let files = try await model.files(for: number)
            let payload = await FilesDocument.payload(files, number: number, pullURL: url)
            guard !Task.isCancelled else { return }
            loaded = Loaded(number: number, files: files, payload: payload)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
