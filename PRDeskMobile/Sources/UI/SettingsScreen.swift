import SwiftUI

/// The token for GitHub, and the Grok Bots to send to (by id: Grok Bot opens a bot by its id).
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var hasSavedToken = false
    @AppStorage(GrokBot.assistantBotKey) private var assistantBot = ""
    @AppStorage(GrokBot.mergeBotKey) private var mergeBot = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(hasSavedToken ? "Saved; enter a new one to replace it" : "Personal access token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("Save") {
                            if Keychain.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                token = ""
                                hasSavedToken = true
                                Task { await model.sync() }
                            }
                        }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasSavedToken {
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Keychain.deleteToken()
                                hasSavedToken = false
                            }
                        }
                    }
                } header: {
                    Text("GitHub")
                } footer: {
                    Text("A classic token with the repo, notifications and project scopes. Signed in as \(model.viewer ?? "nobody yet").")
                }

                Section {
                    LabeledContent("👀 🔥") {
                        TextField("Richard Loop's id", text: $assistantBot)
                    }
                    LabeledContent("🚀") {
                        TextField("Merger's id", text: $mergeBot)
                    }
                } header: {
                    Text("Grok Bot")
                } footer: {
                    Text("Bot ids as `grokbot agents` lists them. A send opens Grok Bot on the bot's chat with the message as a draft; nothing goes out until you send it there.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())

                Section {
                    LabeledContent("Last synced", value: model.lastSyncedAt.map { "\($0.compactAge()) ago" } ?? "never")
                    if let rate = model.rateLimit {
                        LabeledContent("API quota", value: "\(rate.remaining) left")
                    }
                } footer: {
                    Text("Your Mac follows up what you change here: notifications for Skipped and Muted items, approved PRs on the board.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { hasSavedToken = Keychain.readToken() != nil }
        }
    }
}
