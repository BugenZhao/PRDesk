import SwiftUI

/// Markdown composer under the conversation: comment, close (with the text as a comment), or (on
/// PRs) approve / request changes.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let detail: ItemDetail
    /// Folds the composer away, where it can be (the iPad's card); the text stays as the draft.
    var onDismiss: (() -> Void)?

    @State private var text = ""
    @State private var previewHTML: String?
    @State private var isPreviewing = false
    @State private var sending: Submission?
    @State private var isClosing = false
    /// The close waiting for confirmation; its reason is nil for a PR.
    @State private var pendingClose: PendingClose?
    @State private var error: String?
    @State private var isLoadingDraftedComment = false
    /// The height the text takes, wrapped at the editor's width.
    @State private var textHeight: CGFloat = 0
    /// The item whose draft `text` holds.
    @State private var draftItemID: Item.ID?
    @FocusState private var focused: Bool

    private struct PendingClose: Equatable {
        var reason: CloseReason?
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBusy: Bool { sending != nil || isClosing || isLoadingDraftedComment }
    private var closeTitle: String { trimmed.isEmpty ? "Close" : "Close with comment" }

    /// The text view's insets around the text: the line fragment padding on the sides, and the
    /// container inset above and below (none on the Mac, 8 points on iOS).
    #if os(macOS)
        private static let textInsets = EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5)
    #else
        private static let textInsets = EdgeInsets(top: 8, leading: 5, bottom: 8, trailing: 5)
    #endif

    /// Grows with the text as it wraps, from three lines to about twelve, then scrolls.
    private var editorHeight: CGFloat {
        min(210, max(54, textHeight + Self.textInsets.top + Self.textInsets.bottom + 8))
    }
    private var isAuthor: Bool { sameLogin(item.author, model.viewer) }

    private var placeholder: String {
        #if os(macOS)
            item.kind == .pullRequest ? "Comment or review (Markdown, ⌘↩ to comment)" : "Comment (Markdown, ⌘↩ to send)"
        #else
            item.kind == .pullRequest ? "Comment or review (Markdown)" : "Comment (Markdown)"
        #endif
    }

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
                .editorGround(focused: false)
            } else {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    // An explicit height that follows the text, so the editor's own sizing can
                    // never feed into the window's minimum size. The text is measured by a hidden
                    // copy behind it, which takes no part in the layout.
                    .background(alignment: .topLeading) { textMeasure }
                    .frame(height: editorHeight)
                    .padding(4)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .editorGround(focused: focused)
            }

            HStack(spacing: 8) {
                #if os(iOS)
                    if let onDismiss {
                        Button("Hide Composer", systemImage: "chevron.down", action: onDismiss)
                            .labelStyle(.iconOnly)
                    }
                #endif
                Toggle("Preview", systemImage: "eye", isOn: $isPreviewing)
                    .toggleStyle(.button)
                    #if os(iOS)
                        .labelStyle(.iconOnly)
                    #else
                        .labelStyle(.titleOnly)
                    #endif
                    .disabled(trimmed.isEmpty)
                draftedCommentButton
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
                #if os(iOS)
                    // Too narrow for every button: the rarer actions go in a menu.
                    if item.isOpen {
                        Menu("More", systemImage: "ellipsis") {
                            if item.kind == .pullRequest, !isAuthor {
                                Button("Request changes") { send(.requestChanges) }
                                    .disabled(trimmed.isEmpty || isBusy)
                            }
                            closeButton
                        }
                        .labelStyle(.iconOnly)
                        .disabled(isBusy)
                    }
                #else
                    if item.isOpen {
                        closeButton
                    }
                    if item.kind == .pullRequest, item.isOpen, !isAuthor {
                        Button("Request changes") { send(.requestChanges) }
                            .disabled(trimmed.isEmpty || isBusy)
                            .help("Submit a review requesting changes; needs a comment")
                    }
                #endif
                if item.kind == .pullRequest, item.isOpen, !isAuthor {
                    Button("Approve") { send(.approve) }
                        #if os(iOS)
                            .buttonStyle(.bordered)
                        #endif
                        .disabled(isBusy)
                        .help("Submit an approving review, with the text as its comment")
                }
                Button("Comment") { send(.comment) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || isBusy)
            }
            #if os(iOS)
                // On the card of glass: plain shapes, a capsule each, none of them glass.
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 4)
            #else
                .controlSize(.small)
            #endif
        }
        #if os(iOS)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
        #else
            .padding(8)
        #endif
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

    /// The text as the editor wraps it; a trailing newline still takes a line, as in the editor.
    private var textMeasure: some View {
        Text(text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
            .font(.body)
            .padding(.leading, Self.textInsets.leading)
            .padding(.trailing, Self.textInsets.trailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { textHeight = $0 }
    }

    /// On a PR the parity agent adopted and promoted, fills in the comment it drafted for the viewer
    /// to post (SPEC §3.2), until one is posted.
    @ViewBuilder private var draftedCommentButton: some View {
        if item.isOpen, let adoption = model.adoption(of: item), adoption.upstream?.id == item.id, adoption.isPromoted,
           model.awaitsDraftedComment(item)
        {
            // The bar is full with the review buttons; the tooltip names it.
            Button("Drafted Comment", systemImage: "text.quote") { loadDraftedComment(adoption) }
                .labelStyle(.iconOnly)
                .disabled(!trimmed.isEmpty || isBusy)
                .help(trimmed.isEmpty
                    ? "Fill in the comment the parity agent drafted in #\(adoption.staging.number)"
                    : "Clear the text to fill in the comment the parity agent drafted")
        }
    }

    private func loadDraftedComment(_ adoption: Parity.Adoption) {
        isLoadingDraftedComment = true
        error = nil
        Task {
            do {
                if let comment = try await model.draftedComment(for: adoption) {
                    if trimmed.isEmpty {
                        text = comment
                        isPreviewing = false
                        focused = true
                    }
                } else {
                    error = "#\(adoption.staging.number) has no drafted comment"
                }
            } catch {
                self.error = error.localizedDescription
            }
            isLoadingDraftedComment = false
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
        // The agent reads a closed staging PR as a no (SPEC §3.2): for an adoption, as leaving the
        // PR to its author.
        guard item.isParityStaging else { return message }
        if let number = Parity.adoptedNumber(item.headRef) {
            return "\(message) The parity agent stops adopting #\(number) and leaves it to its author."
        }
        return "\(message) The parity agent records the item as an accepted divergence."
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

private extension View {
    /// What the text is written on: a bordered field on the Mac. On the iPad the composer is a
    /// card of glass and the text lies on it directly.
    @ViewBuilder func editorGround(focused: Bool) -> some View {
        #if os(macOS)
            background(Color.textBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.separator, lineWidth: 1))
        #else
            self
        #endif
    }
}
