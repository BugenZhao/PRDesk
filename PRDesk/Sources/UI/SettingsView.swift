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
            Tab("Votes", systemImage: "hand.thumbsup") {
                VoteSettingsView()
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

            Section {
                @Bindable var model = model
                Stepper(value: $model.mergedThreshold, in: 1 ... 500) {
                    LabeledContent("Regular contributor", value: "\(model.mergedThreshold)+ merged PRs")
                }
            } header: {
                Text("Contributors")
            } footer: {
                Text("Regular contributors get a seal after their name; authors with nothing merged yet get \"1st\". Counts refresh weekly, or daily for first-timers. Filter with merged:>=N, is:regular or is:first.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoteSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    private struct Row: Identifiable {
        var login: String
        var vote: Vote
        var id: String { login }
    }

    var body: some View {
        let rows = model.votes.map { Row(login: $0.key, vote: $0.value) }
            .sorted { ($0.vote.rawValue, $1.login) > ($1.vote.rawValue, $0.login) }
        Form {
            Section {
                Table(rows, selection: $selection) {
                    TableColumn("User", value: \.login)
                    TableColumn("Vote") { row in
                        Label(row.vote == .up ? "Upvoted" : "Downvoted", systemImage: row.vote.symbol)
                            .foregroundStyle(Color(nsColor: row.vote.nsColor))
                    }
                }
                .frame(height: 220)
                HStack {
                    Spacer()
                    Button("Clear Vote", systemImage: "minus") {
                        if let selection { model.setVote(nil, for: selection) }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(selection == nil)
                }
            } header: {
                Text("People")
            } footer: {
                Text("Vote with + / - on a selected row, or right-click a name. Downvoted authors never put items in Focus unless the item is marked H.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
