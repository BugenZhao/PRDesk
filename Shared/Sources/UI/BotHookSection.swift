import SwiftUI

/// Settings for the bots' webhooks (`BotHook`): a URL and a secret for each, kept in the Keychain.
struct BotHookSection: View {
    /// Says what happens to a bot's sends without a webhook, which is the platform's.
    let fallback: String

    var body: some View {
        ForEach(BotRole.allCases, id: \.self) { role in
            Section {
                BotHookFields(role: role)
            } header: {
                Text("\(role.emojis) \(role.botName) webhook")
            } footer: {
                if role == BotRole.allCases.last {
                    Text("The URL and secret of the bot's webhook routine, as `notify-bot` keeps them in `~/.config/grokbot-hooks/` (the secret bare or as its `Authorization: Bearer …` line). Kept in this device's Keychain. \(fallback)")
                        .foregroundStyle(.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct BotHookFields: View {
    let role: BotRole
    @State private var url = ""
    @State private var secret = ""
    @State private var saved: BotHook?

    var body: some View {
        Group {
            TextField("URL", text: $url, prompt: Text("https://…"))
            SecureField("Secret", text: $secret, prompt: Text(saved == nil ? "Bearer token" : "Saved; enter a new one to replace it"))
        }
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
        HStack {
            Button("Save") {
                guard let hook else { return }
                if BotHook.save(hook, for: role) {
                    saved = hook
                    secret = ""
                }
            }
            .disabled(hook == nil || hook == saved)
            if saved != nil {
                Spacer()
                Button("Remove", role: .destructive) {
                    BotHook.delete(for: role)
                    saved = nil
                    url = ""
                    secret = ""
                }
            }
        }
        .task {
            saved = BotHook.stored(for: role)
            url = saved?.url.absoluteString ?? ""
        }
    }

    /// What Save would store: the URL as typed, and the secret typed or else the saved one.
    private var hook: BotHook? {
        guard let url = BotHook.url(from: url) else { return nil }
        let typed = BotHook.secret(from: secret)
        guard let secret = typed.isEmpty ? saved?.secret : typed, !secret.isEmpty else { return nil }
        return BotHook(url: url, secret: secret)
    }
}
