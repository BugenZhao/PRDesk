import SwiftUI

/// What this copy is and how syncing goes first, then badges; the token and the Grok Bots,
/// set once, below.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var hasSavedToken = false
    @AppStorage(GrokBot.assistantBotKey) private var assistantBot = ""
    @AppStorage(GrokBot.mergeBotKey) private var mergeBot = ""
    @AppStorage(BadgeShare.repositoryKey) private var badgesRepository = ""

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    VersionRow()
                }

                Section {
                    LabeledContent("Last Synced", value: model.lastSyncedAt.map { "\($0.compactAge()) ago" } ?? "never")
                    if case let .rateLimited(until) = model.syncState {
                        LabeledContent("API Quota", value: "used up until \(until.formatted(date: .omitted, time: .shortened))")
                    } else if let rate = model.rateLimit {
                        LabeledContent("API Quota", value: "\(rate.remaining.formatted()) left")
                    }
                } header: {
                    Text("Syncing")
                } footer: {
                    Text("The quota is GitHub's hourly budget, shared with the Mac. Your Mac follows up what you change here: notifications for Shelf and Attic items, approved PRs on the board.")
                }

                Section {
                    TextField("owner/name", text: $badgesRepository)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await model.shareBadges(soon: true) } }
                    LabeledContent("Status") {
                        BadgeShareStatus(state: model.badgeShareState, verb: "Read")
                    }
                } header: {
                    Text("Badges")
                } footer: {
                    Text("The private repository your Mac publishes its badges to (Settings › Affiliations there). They are read from it at each sync, the ones set by hand included; the token below must be able to read it. Without one, badges are only what you set by hand here.")
                }

                Section {
                    SecureField(hasSavedToken ? "Saved; enter a new one to replace it" : "Personal access token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Token") {
                        if Keychain.saveToken(trimmedToken) {
                            token = ""
                            hasSavedToken = true
                            Task { await model.sync() }
                        }
                    }
                    .disabled(trimmedToken.isEmpty)
                    if hasSavedToken {
                        Button("Remove Token", role: .destructive) {
                            if Keychain.deleteToken() { hasSavedToken = false }
                        }
                    }
                } header: {
                    Text("GitHub")
                } footer: {
                    Text("A classic token with the repo, notifications and project scopes, kept in this device's Keychain. Signed in as \(model.viewer ?? "nobody yet").")
                }

                Section {
                    LabeledContent("👀 🔥 🫴") {
                        TextField("Richard Loop's id", text: $assistantBot)
                    }
                    LabeledContent("🚀") {
                        TextField("Merger's id", text: $mergeBot)
                    }
                } header: {
                    Text("Grok Bot")
                } footer: {
                    Text("Bot ids as `grokbot agents` lists them, for bots without a webhook below: a send to one opens Grok Bot on the bot's chat with the message as a draft, and nothing goes out until you send it there.")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                BotHookSection(fallback: "With one set, sends go out from here.")
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
