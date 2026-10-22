import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                TokenSettingsView()
            }
            Tab("Affiliations", systemImage: "person.2") {
                AffiliationSettingsView()
            }
        }
        .frame(width: 520)
    }
}

private struct TokenSettingsView: View {
    @State private var token = ""
    /// Loaded in `.task`: a keychain read is too slow to repeat on every view rebuild.
    @State private var hasSavedToken = false

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
        .task { hasSavedToken = Keychain.readToken() != nil }
    }
}

private struct AffiliationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var login = ""
    @State private var org = Org.inferact
    @State private var include = true
    @State private var selection: OrgOverride.ID?
    @State private var isRefreshing = false

    var body: some View {
        let affiliations = model.affiliations
        Form {
            Section {
                Table(affiliations.overrides, selection: $selection) {
                    TableColumn("User", value: \.login)
                    TableColumn("Organization") { Text($0.org.displayName) }
                    TableColumn("Badge") { Text($0.include ? "Shown" : "Hidden") }
                }
                .frame(height: 160)
                HStack {
                    TextField("GitHub login", text: $login, prompt: Text("GitHub login"))
                        .labelsHidden()
                        .frame(width: 140)
                    Picker("Organization", selection: $org) {
                        ForEach(Org.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    Picker("Badge", selection: $include) {
                        Text("Show").tag(true)
                        Text("Hide").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add") {
                        model.setOverride(OrgOverride(login: login.trimmingCharacters(in: .whitespaces).lowercased(), org: org, include: include))
                        login = ""
                    }
                    .disabled(login.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("Remove", systemImage: "minus") {
                        if let override = affiliations.overrides.first(where: { $0.id == selection }) {
                            model.removeOverride(override)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(selection == nil)
                }
            } header: {
                Text("Manual affiliations")
            } footer: {
                Text("Manual entries win over everything inferred below.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("vLLM committers", value: "\(affiliations.committers.count) from committers.md")
                ForEach([Org.inferact, .redhat, .nvidia]) { org in
                    LabeledContent(org.displayName, value: "\(affiliations.members[org]?.count ?? 0) members")
                }
                LabeledContent("User profiles", value: "\(affiliations.users.count) fetched")
                HStack {
                    Spacer()
                    if isRefreshing { ProgressView().controlSize(.small) }
                    Button("Refresh Now") {
                        isRefreshing = true
                        Task {
                            await model.refreshAffiliations(force: true)
                            isRefreshing = false
                        }
                    }
                    .disabled(isRefreshing)
                }
            } header: {
                Text("Inferred from public data")
            } footer: {
                Text("Also matched: profile company, commit email domains and username suffixes such as -redhat.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
