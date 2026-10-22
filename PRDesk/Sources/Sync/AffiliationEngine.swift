import Foundation
import os

/// Collects the public data that affiliation badges are inferred from.
///
/// Daily: the committers list and members of the relevant GitHub organizations (all members for
/// orgs the viewer belongs to, such as Inferact; public members otherwise).
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
        if force || committersStale {
            try await db.setMetaJSON(Affiliations.committersKey, fetchCommitters())
            try await db.setMeta(Self.committersFetchedKey, SyncEngine.format(Date()))
        }
        let membersStale = try await isStale(Self.membersFetchedKey, Self.listRefreshInterval)
        if force || membersStale {
            try await db.setMetaJSON(Affiliations.membersKey, fetchMembers())
            try await db.setMeta(Self.membersFetchedKey, SyncEngine.format(Date()))
        }

        let people = logins.map { $0.lowercased() }.filter { !Item.Event.isBotLogin($0) }.sorted()
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
            .filter { !Item.Event.isBotLogin($0) }
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
            let unknown = users.values.filter { user in
                user.company == nil && !user.orgs.contains { org in Org.allCases.contains { $0.githubOrgs.contains(org) } }
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

    private struct Member: Decodable, Sendable {
        let login: String
    }

    private func fetchMembers() async throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for org in Org.allCases {
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
