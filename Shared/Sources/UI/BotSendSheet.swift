import SwiftUI

/// Sends items to a Grok Bot with an optional note: shown for every merge, for re-sends, and when
/// the viewer holds ⌥ to add a note (SPEC §3.3).
struct BotSendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingBotSend
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    /// Items listed by name; the rest are counted.
    private static let listedItems = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pending.items.prefix(Self.listedItems), id: \.id) { item in
                    Text(verbatim: "#\(item.number) \(item.title)").lineLimit(1).truncationMode(.tail)
                }
                if pending.items.count > Self.listedItems {
                    Text("and \(pending.items.count - Self.listedItems) more").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            TextEditor(text: $note)
                .font(.body)
                .focused($noteFocused)
                .frame(height: 72)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background, in: .rect(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if note.isEmpty {
                        Text("Note for \(pending.request.botName) (optional)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sendTitle) {
                    model.sendToBot(pending.request, items: pending.items, note: note)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("Send (⌘↩)")
            }
        }
        .padding(20)
        #if os(macOS)
            .frame(width: 440)
        #else
            .frame(maxHeight: .infinity, alignment: .top)
            .presentationDetents([.medium])
        #endif
        .onAppear { noteFocused = true }
    }

    /// Without a webhook the phone hands the message to Grok Bot as a draft, sent from there.
    private var sendTitle: String {
        GrokBot.sendsDirectly(pending.request) ? "Send" : "Open in Grok Bot"
    }

    private var title: String {
        let what = pending.items.count == 1 ? "#\(pending.items[0].number)" : "\(pending.items.count) items"
        let again = pending.resends == 0 ? "" : pending.resends == pending.items.count ? " again" : " (\(pending.resends) again)"
        return "Send \(what) to \(pending.request.botName) \(pending.request.emoji)\(again)"
    }
}
