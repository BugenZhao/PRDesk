import Foundation
import os

/// Collects the public data that affiliation badges are inferred from.
///
/// Daily: the committers list and CODEOWNERS, members of the relevant GitHub organizations (all members for
/// orgs the viewer belongs to, such as Inferact; public members otherwise), and the repository's
/// collaborators (listing them needs push access, so without it they're skipped).
/// Weekly per user: profile company and public org memberships, plus commit email
/// domains for users that nothing else identifies, and merged PR counts (daily for users with
/// none, so the first-timer mark goes away soon after their first merge).
actor AffiliationEngine {
    private static let listRefreshInterval: TimeInterval = 24 * 3600
    private static let userRefreshInterval: TimeInterval = 7 * 24 * 3600
    private static let committersFetchedKey = "committersFetchedAt"
    private static let membersFetchedKey = "orgMembersFetchedAt"
    private static let firstTimerRefreshInterval: TimeInterval = 24 * 3600
    /// Merged counts cost a search each, and bursts of searches trip GitHub's secondary rate
    /// limit (which then blocks all GraphQL for a while), so only a few are fetched per round.
    private static let mergedBatchSize = 10
    private static let mergedPerRound = 20
    private static let userBatchSize = 40
    private static let emailBatchSize = 10

    private let client: GitHubClient
    private let db: AppDatabase
    private let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "Affiliations")
    private var isRefreshing = false

    init(client: GitHubClient, db: AppDatabase) {
        self.client = client
        self.db = db
    }

    /// Refreshes what badges need for `logins`, and merged PR counts for `authors`.
    func refresh(logins: Set<String>, authors: Set<String> = [], force: Bool = false) async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let committersStale = try await isStale(Self.committersFetchedKey, Self.listRefreshInterval)
        // No code owners entry means the lists predate them; fetch them now.
        let predatesCodeOwners = try await db.meta(Affiliations.codeOwnersKey) == nil
        let predatesLLMD = try await db.meta(Affiliations.llmdMaintainersKey) == nil
        if force || committersStale || predatesCodeOwners || predatesLLMD {
            try await db.setMetaJSON(Affiliations.committersKey, fetchCommitters())
            try await db.setMetaJSON(Affiliations.codeOwnersKey, fetchCodeOwners())
            do {
                try await db.setMetaJSON(Affiliations.llmdMaintainersKey, fetchLLMDMaintainers())
            } catch {
                logger.error("llm-d maintainers unavailable: \(error.localizedDescription)")
                if predatesLLMD { try await db.setMetaJSON(Affiliations.llmdMaintainersKey, [String: [String]]()) }
            }
            try await db.setMeta(Self.committersFetchedKey, SyncEngine.format(Date()))
        }
        let membersStale = try await isStale(Self.membersFetchedKey, Self.listRefreshInterval)
        // No collaborators entry means the lists predate the vLLM member tier; fetch them now.
        let predatesTier = try await db.meta(Affiliations.collaboratorsKey) == nil
        // An org whose members are listed but missing from the stored lists was just added.
        let listed: [String: [String]] = try await db.meta(Affiliations.membersKey)
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: Data($0.utf8)) } ?? [:]
        let predatesOrg = Org.allCases.contains { $0.listsMembers && listed[$0.rawValue] == nil }
        if force || membersStale || predatesTier || predatesOrg {
            try await db.setMetaJSON(Affiliations.membersKey, fetchMembers())
            do {
                try await db.setMetaJSON(Affiliations.collaboratorsKey, fetchCollaborators())
            } catch {
                logger.error("Collaborators unavailable: \(error.localizedDescription)")
                if predatesTier { try await db.setMetaJSON(Affiliations.collaboratorsKey, [String: String]()) }
            }
            try await db.setMeta(Self.membersFetchedKey, SyncEngine.format(Date()))
        }

        let people = logins.map { $0.lowercased() }.filter { !Item.Event.isAutomationLogin($0) }.sorted()
        let known = try await db.userInfos()
        let cutoff = Date().addingTimeInterval(-Self.userRefreshInterval)
        let stale = people.filter { force || (known[$0]?.fetchedAt ?? .distantPast) < cutoff }
        if !stale.isEmpty {
            logger.info("Refreshing \(stale.count) users")
            try await refreshUsers(stale, known: known)
        }

        let current = try await db.userInfos()
        let now = Date()
        // Missing counts first, then the oldest; the rest wait for later rounds.
        let mergedStale = authors.map { $0.lowercased() }
            .filter { !Item.Event.isAutomationLogin($0) }
            .compactMap { login -> (String, Date)? in
                guard let user = current[login] else { return nil }
                guard let count = user.mergedCount, let at = user.mergedFetchedAt else { return (login, .distantPast) }
                let interval = count == 0 ? Self.firstTimerRefreshInterval : Self.userRefreshInterval
                return now.timeIntervalSince(at) > interval ? (login, at) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(Self.mergedPerRound)
            .map(\.0)
        for batch in mergedStale.chunked(Self.mergedBatchSize) {
            try await db.saveMergedCounts(fetchMergedCounts(batch))
        }
    }

    private func refreshUsers(_ stale: [String], known: [String: UserInfo]) async throws {
        for batch in stale.chunked(Self.userBatchSize) {
            var users = try await fetchUsers(batch)
            // Merged counts are refreshed separately; keep them.
            for login in users.keys {
                users[login]?.mergedCount = known[login]?.mergedCount
                users[login]?.mergedFetchedAt = known[login]?.mergedFetchedAt
            }
            // Commit emails cost a search each, so only look them up when nothing else matched.
            // Being in vllm-project says nothing about an employer.
            let employers = Org.allCases.filter { !$0.isProject }
            let unknown = users.values.filter { user in
                user.company == nil && !user.orgs.contains { org in employers.contains { $0.githubOrgs.contains { sameLogin($0, org) } } }
            }
            for emailBatch in unknown.map(\.login).chunked(Self.emailBatchSize) {
                for (login, domains) in try await fetchEmailDomains(emailBatch) {
                    users[login]?.emailDomains = domains
                }
            }
            try await db.save(Array(users.values))
        }
    }

    private func isStale(_ key: String, _ interval: TimeInterval) async throws -> Bool {
        guard let value = try await db.meta(key), let date = try? Date(value, strategy: .iso8601) else { return true }
        return Date().timeIntervalSince(date) > interval
    }

    // MARK: Lists

    private struct FileContent: Decodable, Sendable {
        let content: String
    }

    /// Parses `- [@login](...): area` lines under "Active Committers" in committers.md.
    private func fetchCommitters() async throws -> [String: String] {
        let file = try await client.rest("GET", "/repos/\(SyncEngine.repo)/contents/docs/governance/committers.md", as: FileContent.self)
        guard let data = Data(base64Encoded: file.content, options: .ignoreUnknownCharacters) else { return [:] }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "## Active Committers") else { return [:] }
        let section = text[start.upperBound...].components(separatedBy: "\n## ").first ?? ""
        let pattern = /^- \[@([A-Za-z0-9-]+)\]\([^)]*\):?\s*(.*)$/
        var result: [String: String] = [:]
        for line in section.split(separator: "\n") {
            if let match = String(line).firstMatch(of: pattern) {
                result[match.1.lowercased()] = String(match.2).trimmingCharacters(in: .whitespaces)
            }
        }
        logger.info("Parsed \(result.count) committers")
        return result
    }

    /// People named in `.github/CODEOWNERS` and the paths they own, in file order; teams
    /// (`@org/team`) are left out.
    private func fetchCodeOwners() async throws -> [String: [String]] {
        let file = try await client.rest("GET", "/repos/\(SyncEngine.repo)/contents/.github/CODEOWNERS", as: FileContent.self)
        guard let data = Data(base64Encoded: file.content, options: .ignoreUnknownCharacters) else { return [:] }
        var result: [String: [String]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(whereSeparator: \.isWhitespace)
            guard let pattern = fields.first else { continue }
            let path = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : String(pattern)
            for owner in fields.dropFirst() where owner.hasPrefix("@") && !owner.contains("/") {
                let login = owner.dropFirst().lowercased()
                if result[login]?.contains(path) != true { result[login, default: []].append(path) }
            }
        }
        logger.info("Parsed \(result.count) code owners")
        return result
    }

    private struct LLMDFiles: Decodable, Sendable {
        struct Blob: Decodable, Sendable { let text: String? }
        struct Repo: Decodable, Sendable {
            let name: String
            let owners: Blob?
            let codeOwners: Blob?
            let githubCodeOwners: Blob?
        }

        struct Repos: Decodable, Sendable { let nodes: [Repo?]? }
        struct Organization: Decodable, Sendable { let repositories: Repos }
        struct Main: Decodable, Sendable { let maintainers: Blob? }

        let organization: Organization?
        let repository: Main?
    }

    /// The people who run llm-d and what they do there, in one query: the sections of
    /// MAINTAINERS.md they're listed under (e.g. "llm-d Project Leadership"), then their strongest
    /// role in each active repository, the most starred first, grouped by role ("approver of
    /// llm-d, llm-d-kv-cache"): approver or reviewer in OWNERS, or code owner in CODEOWNERS.
    /// Teams (`@org/team`), OWNERS aliases and dot repositories (`.github`) are left out.
    private func fetchLLMDMaintainers() async throws -> [String: [String]] {
        let query = """
        query {
          organization(login: "llm-d") {
            repositories(first: 100, isArchived: false, orderBy: {field: STARGAZERS, direction: DESC}) {
              nodes {
                name
                owners: object(expression: "HEAD:OWNERS") { ... on Blob { text } }
                codeOwners: object(expression: "HEAD:CODEOWNERS") { ... on Blob { text } }
                githubCodeOwners: object(expression: "HEAD:.github/CODEOWNERS") { ... on Blob { text } }
              }
            }
          }
          repository(owner: "llm-d", name: "llm-d") {
            maintainers: object(expression: "HEAD:MAINTAINERS.md") { ... on Blob { text } }
          }
        }
        """
        let files = try await client.query(query, variables: [String: String](), as: LLMDFiles.self)
        var sections: [String: [String]] = [:]
        // Tables under "## Section" headings, one person a row: `| Name | Employer | @login |`.
        if let text = files.repository?.maintainers?.text {
            var section = "maintainer"
            for line in text.split(separator: "\n") {
                if line.hasPrefix("## ") {
                    section = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("|"), let match = line.firstMatch(of: /@([A-Za-z0-9-]+)/) {
                    let key = match.1.lowercased()
                    if sections[key]?.contains(section) != true { sections[key, default: []].append(section) }
                }
            }
        }
        // Login → role → repositories, in order; roles strongest first.
        let roles = ["approver", "code owner", "reviewer"]
        var repos: [String: [String: [String]]] = [:]
        for case let repo? in files.organization?.repositories.nodes ?? [] where !repo.name.hasPrefix(".") {
            var found: [String: String] = [:]
            for (login, role) in Self.owners(in: repo.owners?.text ?? "") { found[login] = role }
            for text in [repo.codeOwners?.text, repo.githubCodeOwners?.text].compactMap(\.self) {
                for line in text.split(separator: "\n") {
                    let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].split(whereSeparator: \.isWhitespace)
                    for owner in fields.dropFirst() where owner.hasPrefix("@") && !owner.contains("/") {
                        let login = owner.dropFirst().lowercased()
                        if found[login] != "approver" { found[login] = "code owner" }
                    }
                }
            }
            for (login, role) in found { repos[login, default: [:]][role, default: []].append(repo.name) }
        }
        var result: [String: [String]] = [:]
        for login in Set(sections.keys).union(repos.keys) where Self.isSafeLogin(login) {
            result[login] = (sections[login] ?? []).map { "llm-d \($0)" }
                + roles.compactMap { role in
                    repos[login]?[role].map { names in
                        let more = names.count > 3 ? " (+\(names.count - 3))" : ""
                        return "\(role) of \(names.prefix(3).joined(separator: ", "))\(more)"
                    }
                }
        }
        logger.info("Parsed \(result.count) llm-d maintainers")
        return result
    }

    /// Approvers and reviewers in a Prow OWNERS file (top-level `approvers:` / `reviewers:` lists),
    /// approvers first.
    static func owners(in text: String) -> [(login: String, role: String)] {
        var key: Substring = ""
        var approvers: [String] = []
        var reviewers: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- ") {
                let login = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
                if key == "approvers" { approvers.append(login) } else if key == "reviewers" { reviewers.append(login) }
            } else if !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") {
                key = line[..<colon]
            }
        }
        return approvers.map { ($0, "approver") } + reviewers.filter { !approvers.contains($0) }.map { ($0, "reviewer") }
    }

    private struct Member: Decodable, Sendable {
        let login: String
    }

    private func fetchMembers() async throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for org in Org.allCases where org.listsMembers {
            var logins: [String] = []
            for githubOrg in org.githubOrgs {
                var page = 1
                while true {
                    let members = try await client.rest(
                        // `/members` lists everyone when the viewer is in the org, and falls back to
                        // public members when not.
                        "GET", "/orgs/\(githubOrg)/members",
                        query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))],
                        as: [Member].self
                    )
                    logins += members.map { $0.login.lowercased() }
                    guard members.count == 100 else { break }
                    page += 1
                }
            }
            result[org.rawValue] = logins
        }
        return result
    }

    private struct Collaborator: Decodable, Sendable {
        let login: String
        let roleName: String

        enum CodingKeys: String, CodingKey {
            case login
            case roleName = "role_name"
        }
    }

    /// Collaborators with triage access or more, including those through org teams.
    private func fetchCollaborators() async throws -> [String: String] {
        var result: [String: String] = [:]
        var page = 1
        while true {
            let collaborators = try await client.rest(
                "GET", "/repos/\(SyncEngine.repo)/collaborators",
                query: [
                    URLQueryItem(name: "affiliation", value: "all"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page)),
                ],
                as: [Collaborator].self
            )
            for collaborator in collaborators where collaborator.roleName != "read" {
                result[collaborator.login.lowercased()] = collaborator.roleName
            }
            guard collaborators.count == 100 else { break }
            page += 1
        }
        logger.info("Fetched \(result.count) collaborators")
        return result
    }

    // MARK: Users

    private struct UserNode: Decodable, Sendable {
        struct Orgs: Decodable, Sendable {
            struct Node: Decodable, Sendable { let login: String }
            let nodes: [Node?]?
        }

        let login: String
        let company: String?
        let organizations: Orgs
    }

    /// Logins are `[A-Za-z0-9-]`, so they can be inlined in aliased fields safely.
    private static func isSafeLogin(_ login: String) -> Bool {
        !login.isEmpty && login.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private func fetchUsers(_ logins: [String]) async throws -> [String: UserInfo] {
        let safe = logins.filter(Self.isSafeLogin)
        guard !safe.isEmpty else { return [:] }
        let fields = safe.enumerated().map { index, login in
            "u\(index): user(login: \"\(login)\") { login company organizations(first: 30) { nodes { login } } }"
        }
        let response = try await client.query("query { \(fields.joined(separator: "\n")) }", variables: [String: String](), as: [String: UserNode?].self)
        let now = Date()
        var result: [String: UserInfo] = [:]
        // Users that no longer exist still get a row, so they aren't re-fetched every time.
        for login in safe {
            result[login] = UserInfo(login: login, company: nil, orgs: [], emailDomains: [], fetchedAt: now)
        }
        for case let node? in response.values {
            let key = node.login.lowercased()
            let company = node.company?.trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = UserInfo(
                login: key,
                company: company?.isEmpty == false ? company : nil,
                orgs: node.organizations.nodes?.compactMap { $0?.login } ?? [],
                emailDomains: [],
                fetchedAt: now
            )
        }
        return result
    }

    private struct Count: Decodable, Sendable {
        let issueCount: Int
    }

    /// PRs each user has had merged in the repository.
    private func fetchMergedCounts(_ logins: [String]) async throws -> [String: Int] {
        let safe = logins.filter(Self.isSafeLogin)
        guard !safe.isEmpty else { return [:] }
        let fields = safe.enumerated().map { index, login in
            "m\(index): search(query: \"repo:\(SyncEngine.repo) is:pr is:merged author:\(login)\", type: ISSUE, first: 0) { issueCount }"
        }
        let response = try await client.query("query { \(fields.joined(separator: "\n")) }", variables: [String: String](), as: [String: Count].self)
        var result: [String: Int] = [:]
        for (alias, count) in response {
            guard let index = Int(alias.dropFirst()), safe.indices.contains(index) else { continue }
            result[safe[index]] = count.issueCount
        }
        return result
    }

    private struct EmailSearch: Decodable, Sendable {
        struct PR: Decodable, Sendable {
            struct Commits: Decodable, Sendable {
                struct Node: Decodable, Sendable {
                    struct Commit: Decodable, Sendable {
                        struct Author: Decodable, Sendable {
                            struct User: Decodable, Sendable { let login: String }
                            let email: String?
                            let user: User?
                        }

                        let author: Author?
                    }

                    let commit: Commit
                }

                let nodes: [Node?]?
            }

            let commits: Commits?
        }

        let nodes: [PR?]
    }

    /// Looks at the commit emails on each user's recent PRs in the repository.
    private func fetchEmailDomains(_ logins: [String]) async throws -> [String: [String]] {
        let safe = logins.filter(Self.isSafeLogin)
        guard !safe.isEmpty else { return [:] }
        let fields = safe.enumerated().map { index, login in
            """
            e\(index): search(query: "repo:\(SyncEngine.repo) is:pr author:\(login)", type: ISSUE, first: 2) {
              nodes { ... on PullRequest { commits(first: 3) { nodes { commit { author { email user { login } } } } } } }
            }
            """
        }
        let response = try await client.query("query { \(fields.joined(separator: "\n")) }", variables: [String: String](), as: [String: EmailSearch].self)
        var result: [String: [String]] = [:]
        for (alias, search) in response {
            guard let index = Int(alias.dropFirst()), safe.indices.contains(index) else { continue }
            let login = safe[index]
            let domains = search.nodes.compactMap(\.self)
                .flatMap { $0.commits?.nodes?.compactMap { $0?.commit.author } ?? [] }
                .filter { sameLogin($0.user?.login, login) }
                .compactMap { $0.email?.split(separator: "@").last.map { $0.lowercased() } }
                .filter { !$0.hasSuffix("noreply.github.com") }
            result[login] = Array(Set(domains)).sorted()
        }
        return result
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
