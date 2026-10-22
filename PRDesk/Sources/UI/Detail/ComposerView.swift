import SwiftUI

/// Markdown composer under the conversation: comment, or (on PRs) approve / request changes.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail

    @State private var text = ""
    @State private var previewHTML: String?
    @State private var isPreviewing = false
    @State private var sending: Submission?
    @State private var error: String?
    /// The item whose draft `text` holds.
    @State private var draftNumber: Int?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isAuthor: Bool { sameLogin(item.author, model.viewer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isPreviewing {
                ScrollView {
                    if let previewHTML {
                        HTMLBodyView(id: "preview-\(item.number)-\(previewHTML.hashValue)", html: previewHTML)
                            .padding(6)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            } else {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 54, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(item.kind == .pullRequest ? "Comment or review (Markdown, ⌘↩ to comment)" : "Comment (Markdown, ⌘↩ to send)")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1))
            }

            HStack(spacing: 8) {
                Toggle("Preview", isOn: $isPreviewing)
                    .toggleStyle(.button)
                    .disabled(trimmed.isEmpty)
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(error)
                }
                Spacer()
                if sending != nil {
                    ProgressView().controlSize(.small)
                }
                if item.kind == .pullRequest, item.isOpen, !isAuthor {
                    Button("Request changes") { send(.requestChanges) }
                        .disabled(trimmed.isEmpty || sending != nil)
                        .help("Submit a review requesting changes; needs a comment")
                    Button("Approve") { send(.approve) }
                        .disabled(sending != nil)
                        .help("Submit an approving review, with the text as its comment")
                }
                Button("Comment") { send(.comment) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || sending != nil)
            }
            .controlSize(.small)
        }
        .padding(8)
        // Load the draft only when the item really changes: reassigning `text` while typing
        // would reset the cursor.
        .task(id: item.number) {
            guard draftNumber != item.number else { return }
            draftNumber = item.number
            text = model.draft(for: item.number)
            isPreviewing = false
            error = nil
        }
        .onChange(of: text) {
            if draftNumber == item.number { model.setDraft(text, for: item.number) }
        }
        .onChange(of: isPreviewing) { renderPreview() }
        .onChange(of: model.composerFocusRequest) {
            isPreviewing = false
            focused = true
        }
    }

    private func renderPreview() {
        guard isPreviewing else { return }
        previewHTML = nil
        let source = trimmed
        Task {
            do {
                previewHTML = try await model.renderMarkdown(source)
            } catch {
                previewHTML = "<p><em>Preview failed: \(error.localizedDescription)</em></p>"
            }
        }
    }

    private func send(_ submission: Submission) {
        let body = trimmed
        sending = submission
        error = nil
        Task {
            do {
                try await model.submit(submission, body: body, item: item, detail: detail)
                text = ""
                isPreviewing = false
            } catch {
                self.error = error.localizedDescription
            }
            sending = nil
        }
    }
}
