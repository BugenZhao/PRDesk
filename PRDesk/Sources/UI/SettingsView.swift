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
            Tab("Grok Bot", systemImage: "paperplane") {
                GrokBotSettingsView()
            }
        }
        .frame(width: 520)
    }
}

private struct TokenSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    /// The same setting as `PRDeskApp`'s, which inserts the menu bar extra.
    @AppStorage("showsMenuBarExtra") private var showsMenuBarExtra = true
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

            Section {
                @Bindable var model = model
                Picker("Sync every", selection: $model.syncInterval) {
                    ForEach(AppModel.syncIntervals, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes").tag(seconds)
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Each round costs a few of GitHub's 5,000 hourly API points; the triage board is read at most every 3 minutes. ⌘R syncs everything at once.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show in menu bar", isOn: $showsMenuBarExtra)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("The unread inbox count, with a menu of the items you are working on.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { hasSavedToken = Keychain.readToken() != nil }
    }
}

private struct GrokBotSettingsView: View {
    @AppStorage(GrokBot.assistantBotKey) private var assistant = GrokBot.defaultAssistantBot
    @AppStorage(GrokBot.mergeBotKey) private var merger = GrokBot.defaultMergeBot
    /// nil while checking; the account, or why there is none.
    @State private var account: Result<String?, any Error>?

    var body: some View {
        Form {
            Section {
                TextField("👀 Investigate, 🔥 Track", text: $assistant, prompt: Text(GrokBot.defaultAssistantBot))
                TextField("🚀 Merge", text: $merger, prompt: Text(GrokBot.defaultMergeBot))
            } header: {
                Text("Bots")
            } footer: {
                Text("A bot's name, a unique prefix of it, or its id. e, f and r in the list send the selected items; merging asks first.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Account") {
                    switch account {
                    case nil: ProgressView().controlSize(.small)
                    case let .success(name?): Text(name)
                    case .success(nil): Text("Not signed in").foregroundStyle(.secondary)
                    case let .failure(error): Text(error.localizedDescription).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("grokbot CLI")
            } footer: {
                Text("Built into the app, and signed in like any other grokbot: run `grokbot login` in Terminal.")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .task {
            do {
                account = .success(try await GrokBot.whoami())
            } catch {
                account = .failure(error)
            }
        }
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
                LabeledContent("vLLM committers", value: "\(affiliations.committers.count) from committers.md, \(affiliations.codeOwners.count) code owners")
                LabeledContent("vLLM members", value: "\(affiliations.members[.vllm]?.count ?? 0) in vllm-project, \(affiliations.collaborators.count) collaborators")
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
                Text("Also matched: profile company, commit email domains and username suffixes such as -redhat. Code owners in CODEOWNERS get the full vLLM badge like committers; vLLM members and collaborators (triage access or more) who are neither get a gray one; filter with org:committer, org:member, or org:vllm for both.")
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
                Text("Regular contributors without an affiliation badge get a seal; authors with nothing merged yet and no affiliation have their name in italics. Counts refresh weekly, or daily for first-timers. Filter with merged:>=N, is:regular or is:first.")
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
                Text("Vote with + / - on selected rows, or right-click a name. Downvoted authors' items sink to the bottom of Triage.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
