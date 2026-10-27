import Foundation
import GRDB

/// Public profile facts about a GitHub user, used to infer affiliations.
struct UserInfo: Codable, Hashable, Sendable {
    /// Lowercased login.
    var login: String
    var company: String?
    /// Public organization memberships.
    var orgs: [String]
    /// Domains of the user's commit emails in the repository.
    var emailDomains: [String]
    var fetchedAt: Date
    /// PRs merged in the repository, refreshed on its own schedule.
    var mergedCount: Int?
    var mergedFetchedAt: Date?
}

extension UserInfo: FetchableRecord, PersistableRecord {
    static let databaseTableName = "userInfo"
}

/// A manual affiliation: `include` adds the badge, otherwise it is suppressed.
struct OrgOverride: Codable, Hashable, Sendable, Identifiable {
    /// Lowercased login.
    var login: String
    var org: Org
    var include: Bool

    var id: String { "\(login)/\(org.rawValue)" }
}

extension OrgOverride: FetchableRecord, PersistableRecord {
    static let databaseTableName = "orgOverride"
}

/// An author's merged PR count in the repository, read against the threshold from Settings.
struct Contribution: Hashable, Sendable {
    var merged: Int
    var threshold: Int

    /// Has landed enough to count as a regular contributor.
    var isRegular: Bool { merged >= threshold }
    /// Nothing merged yet.
    var isFirstTime: Bool { merged == 0 }

    /// A first-timer nothing else vouches for, shown as a caution beside their name: a known
    /// affiliation (`badges`) outweighs an empty record.
    func isUnvouched(badges: [Badge]) -> Bool {
        isFirstTime && badges.isEmpty
    }

    var summary: String {
        isFirstTime ? "No PRs merged in vllm yet" : "\(merged) PR\(merged == 1 ? "" : "s") merged in vllm"
    }
}

struct Badge: Hashable, Sendable {
    var org: Org
    /// Why the badge applies, shown as a tooltip.
    var source: String
    /// Set for a lesser tie to the org, drawn in gray: a vLLM org member or collaborator who isn't
    /// a committer.
    var secondaryName: String?
    /// A name for a full badge other than the org's, e.g. a vLLM code owner who isn't a committer.
    var fullName: String?

    var isSecondary: Bool { secondaryName != nil }
    var name: String { secondaryName ?? fullName ?? org.displayName }

    /// Names accepted by the `org:` filter token: `org:vllm` matches both vLLM tiers,
    /// `org:committer` and `org:member` one each.
    var filterNames: [String] { isSecondary ? [org.rawValue, "member"] : org.filterNames }
}

/// Everything known about affiliations, and the rules that turn it into badges.
struct Affiliations: Equatable, Sendable {
    /// Lowercased login → area, from committers.md.
    var committers: [String: String] = [:]
    /// Lowercased login → paths they own, from CODEOWNERS.
    var codeOwners: [String: [String]] = [:]
    /// Lowercased members of each org's GitHub organizations, as visible to the viewer.
    var members: [Org: Set<String>] = [:]
    /// Lowercased login → role (triage and up), for collaborators on the repository.
    var collaborators: [String: String] = [:]
    var users: [String: UserInfo] = [:]
    var overrides: [OrgOverride] = []

    static let committersKey = "committers"
    static let codeOwnersKey = "codeOwners"
    static let membersKey = "orgMembers"
    static let collaboratorsKey = "collaborators"

    /// Sources in priority order: manual, committers.md (and CODEOWNERS for vLLM), org membership,
    /// profile company, commit email domain, username suffix.
    func badges(for login: String) -> [Badge] {
        let key = login.lowercased()
        return Org.allCases.compactMap { org in
            if let override = overrides.first(where: { $0.login == key && $0.org == org }) {
                return override.include ? Badge(org: org, source: "added manually") : nil
            }
            if org == .vllm { return vllmBadge(for: key) }
            return source(of: org, for: key).map { Badge(org: org, source: $0) }
        }
    }

    private static let codeOwnerPathsShown = 3

    /// Committers and code owners get the full badge; other org members and collaborators a gray one.
    private func vllmBadge(for key: String) -> Badge? {
        if let area = committers[key] {
            return Badge(org: .vllm, source: "committers.md: \(area)")
        }
        if let paths = codeOwners[key], !paths.isEmpty {
            let shown = paths.prefix(Self.codeOwnerPathsShown).joined(separator: ", ")
            let more = paths.count > Self.codeOwnerPathsShown ? " (+\(paths.count - Self.codeOwnerPathsShown))" : ""
            return Badge(org: .vllm, source: "CODEOWNERS: \(shown)\(more)", fullName: "vLLM code owner")
        }
        if members[.vllm]?.contains(key) == true || users[key]?.orgs.contains(where: { sameLogin($0, "vllm-project") }) == true {
            return Badge(org: .vllm, source: "member of vllm-project", secondaryName: "vLLM member")
        }
        if let role = collaborators[key] {
            return Badge(org: .vllm, source: "\(role) access to \(SyncEngine.repo)", secondaryName: "vLLM collaborator")
        }
        return nil
    }

    private func source(of org: Org, for key: String) -> String? {
        if members[org]?.contains(key) == true {
            return "member of \(org.githubOrgs.joined(separator: " / "))"
        }
        if let user = users[key] {
            if let membership = user.orgs.first(where: { login in org.githubOrgs.contains { sameLogin($0, login) } }) {
                return "public member of \(membership)"
            }
            if let company = user.company, org.matches(company: company) {
                return "profile company: \(company)"
            }
            if let domain = user.emailDomains.first(where: org.matches(emailDomain:)) {
                return "commit email @\(domain)"
            }
        }
        if let suffix = org.loginSuffixes.first(where: key.hasSuffix) {
            return "username ends with \(suffix)"
        }
        return nil
    }
}

// MARK: - Database

extension AppDatabase {
    func saveMergedCounts(_ counts: [String: Int]) async throws {
        let now = Date()
        try await writer.write { db in
            for (login, count) in counts {
                try db.execute(
                    sql: "UPDATE userInfo SET mergedCount = ?, mergedFetchedAt = ? WHERE login = ?",
                    arguments: [count, now, login]
                )
            }
        }
    }

    func observeAffiliations() -> AsyncValueObservation<Affiliations> {
        ValueObservation
            .tracking { db in
                let decoder = JSONDecoder()
                func meta<T: Decodable>(_ key: String) throws -> T? {
                    try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
                        .flatMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
                }
                let members: [String: [String]] = try meta(Affiliations.membersKey) ?? [:]
                return try Affiliations(
                    committers: meta(Affiliations.committersKey) ?? [:],
                    codeOwners: meta(Affiliations.codeOwnersKey) ?? [:],
                    members: Dictionary(uniqueKeysWithValues: members.compactMap { key, logins in
                        Org(rawValue: key).map { ($0, Set(logins)) }
                    }),
                    collaborators: meta(Affiliations.collaboratorsKey) ?? [:],
                    users: Dictionary(uniqueKeysWithValues: UserInfo.fetchAll(db).map { ($0.login, $0) }),
                    overrides: OrgOverride.order(Column("login")).fetchAll(db)
                )
            }
            .removeDuplicates()
            .values(in: reader)
    }

    func userInfos() async throws -> [String: UserInfo] {
        try await reader.read { db in
            try Dictionary(uniqueKeysWithValues: UserInfo.fetchAll(db).map { ($0.login, $0) })
        }
    }

    func save(_ users: [UserInfo]) async throws {
        try await writer.write { db in
            for user in users {
                try user.upsert(db)
            }
        }
    }

    func save(_ override: OrgOverride) async throws {
        try await writer.write { db in try override.upsert(db) }
    }

    func delete(_ override: OrgOverride) async throws {
        _ = try await writer.write { db in try override.delete(db) }
    }

    func setMetaJSON(_ key: String, _ value: some Encodable & Sendable) async throws {
        let data = try JSONEncoder().encode(value)
        try await setMeta(key, String(decoding: data, as: UTF8.self))
    }
}
