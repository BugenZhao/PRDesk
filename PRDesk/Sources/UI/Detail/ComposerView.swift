import SwiftUI

/// Markdown composer under the conversation: comment, close (with the text as a comment), or (on
/// PRs) approve / request changes.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail

    @State private var text = ""
    @State private var previewHTML: String?
    @State private var isPreviewing = false
    @State private var sending: Submission?
    @State private var isClosing = false
    /// The close waiting for confirmation; its reason is nil for a PR.
    @State private var pendingClose: PendingClose?
    @State private var error: String?
    /// The item whose draft `text` holds.
    @State private var draftItemID: Item.ID?
    @FocusState private var focused: Bool

    private struct PendingClose: Equatable {
        var reason: CloseReason?
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBusy: Bool { sending != nil || isClosing }
    private var closeTitle: String { trimmed.isEmpty ? "Close" : "Close with comment" }

    /// Grows with the number of lines, from three to about nine.
    private var editorHeight: CGFloat {
        let lines = CGFloat(text.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(160, max(54, lines * 17 + 10))
    }
    private var isAuthor: Bool { sameLogin(item.author, model.viewer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isPreviewing {
                ScrollView {
                    if let previewHTML {
                        HTMLBodyView(id: "preview-\(item.id)-\(previewHTML.hashValue)", html: previewHTML)
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
                    // An explicit height that follows the text, so the editor's own sizing can
                    // never feed into the window's minimum size.
                    .frame(height: editorHeight)
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
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                if item.isOpen {
                    closeButton
                }
                if item.kind == .pullRequest, item.isOpen, !isAuthor {
                    Button("Request changes") { send(.requestChanges) }
                        .disabled(trimmed.isEmpty || isBusy)
                        .help("Submit a review requesting changes; needs a comment")
                    Button("Approve") { send(.approve) }
                        .disabled(isBusy)
                        .help("Submit an approving review, with the text as its comment")
                }
                Button("Comment") { send(.comment) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || isBusy)
            }
            .controlSize(.small)
        }
        .padding(8)
        // Load the draft only when the item really changes: reassigning `text` while typing
        // would reset the cursor.
        .task(id: item.id) {
            guard draftItemID != item.id else { return }
            draftItemID = item.id
            text = model.draft(for: item.id)
            isPreviewing = false
            error = nil
        }
        .onChange(of: text) {
            if draftItemID == item.id { model.setDraft(text, for: item.id) }
        }
        .onChange(of: isPreviewing) { renderPreview() }
        .onChange(of: model.composerFocusRequest) {
            isPreviewing = false
            focused = true
        }
        .confirmationDialog(
            "Close #\(item.number)?",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            presenting: pendingClose
        ) { pending in
            Button(closeTitle, role: .destructive) { close(reason: pending.reason) }
        } message: { pending in
            Text(closeMessage(pending.reason))
        }
    }

    /// PRs close outright; issues ask why, as on GitHub.
    @ViewBuilder private var closeButton: some View {
        if item.kind == .pullRequest {
            Button(closeTitle) { pendingClose = PendingClose(reason: nil) }
                .disabled(isBusy)
                .help("Close the pull request, posting the text as a comment first")
        } else {
            Menu(closeTitle) {
                Button("Close as completed") { pendingClose = PendingClose(reason: .completed) }
                Button("Close as not planned") { pendingClose = PendingClose(reason: .notPlanned) }
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isBusy)
            .help("Close the issue, posting the text as a comment first")
        }
    }

    private func closeMessage(_ reason: CloseReason?) -> String {
        let what = switch reason {
        case nil: "The pull request will be closed"
        case .completed: "The issue will be closed as completed"
        case .notPlanned: "The issue will be closed as not planned"
        }
        let message = trimmed.isEmpty ? "\(what)." : "\(what), after posting your comment."
        // The agent reads a closed staging PR as a no (SPEC §3.2).
        return item.isParityStaging ? "\(message) The parity agent records the item as an accepted divergence." : message
    }

    private func close(reason: CloseReason?) {
        let body = trimmed
        isClosing = true
        error = nil
        Task {
            do {
                try await model.close(item, detail: detail, reason: reason, comment: body)
                text = ""
                isPreviewing = false
            } catch {
                self.error = error.localizedDescription
            }
            isClosing = false
        }
    }

    private func renderPreview() {
        guard isPreviewing else { return }
        previewHTML = nil
        let source = trimmed
        Task {
            do {
                previewHTML = try await model.renderMarkdown(source, in: item)
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
