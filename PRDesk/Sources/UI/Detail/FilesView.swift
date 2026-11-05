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
        var itemID: Item.ID
        var files: [PullFile]
        var payload: String
    }

    var body: some View {
        Group {
            if let loaded, loaded.itemID == item.id {
                if loaded.files.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "doc")
                } else {
                    VStack(spacing: 0) {
                        toolbar(loaded.files)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        Divider()
                        WebDocumentView(document: page, key: loaded.itemID, payload: loaded.payload)
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
        .task(id: "\(item.id)-\(item.updatedAt.timeIntervalSince1970)") { await load() }
        .onChange(of: wrapLines, initial: true) { page.setting("wrap", "PRDesk.setWrap(\(wrapLines))") }
        .onChange(of: model.viewedFiles[item.id], initial: true) { sendViewed() }
        .onChange(of: item.id, initial: true) {
            page.setFileViewed = { [model, itemID = item.id] path, viewed in model.setFileViewed(viewed, path: path, in: itemID) }
        }
    }

    /// The item's "Viewed" marks, for the page to show on the files' headers.
    private func sendViewed() {
        let states = model.viewedFiles[item.id]?.mapValues(\.rawValue)
        let key = WebDocument.jsonLiteral(item.id) ?? "null"
        let json = states.flatMap { WebDocument.jsonLiteral($0) } ?? "null"
        page.setting("viewed", "PRDesk.setViewedFiles(\(key), \(json))")
    }

    private func toolbar(_ files: [PullFile]) -> some View {
        HStack(spacing: 6) {
            Text("\(files.count) file\(files.count == 1 ? "" : "s")")
            Text("+\(files.reduce(0) { $0 + $1.additions })").foregroundStyle(.green)
            Text("−\(files.reduce(0) { $0 + $1.deletions })").foregroundStyle(.red)
            if let viewed = model.viewedFiles[item.id] {
                let count = files.count { viewed[$0.filename] == .viewed }
                Text("\(count) / \(files.count) viewed")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
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
        let item = item
        do {
            // The marks come on their own, so the diff doesn't wait for them.
            async let viewed: Void = model.loadViewedFiles(for: item)
            let files = try await model.files(for: item)
            let payload = await FilesDocument.payload(files, key: item.id, pullURL: item.url)
            guard !Task.isCancelled else { return }
            loaded = Loaded(itemID: item.id, files: files, payload: payload)
            await viewed
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
