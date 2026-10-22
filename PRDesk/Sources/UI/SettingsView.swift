import SwiftUI

struct SettingsView: View {
    @State private var token = ""
    @State private var hasSavedToken = Keychain.readToken() != nil

    var body: some View {
        Form {
            Section {
                SecureField("Personal access token", text: $token)
                HStack {
                    Button("Save") {
                        hasSavedToken = Keychain.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                        token = ""
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove") {
                        Keychain.deleteToken()
                        hasSavedToken = false
                    }
                    .disabled(!hasSavedToken)
                }
            } header: {
                Text("GitHub token")
            } footer: {
                Text(hasSavedToken
                    ? "Using the saved token. Changes take effect after relaunching."
                    : "No saved token; using `gh auth token`.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
