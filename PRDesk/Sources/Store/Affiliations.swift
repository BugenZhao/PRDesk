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
    /// Domain of the public email on the profile; empty when there is none, nil until fetched.
    var profileEmailDomain: String?
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

/// What hovering a login says about the person: PRs merged, then each affiliation and its source.
func personFacts(contribution: Contribution?, badges: [Badge]) -> [String] {
    (contribution.map { [$0.summary] } ?? []) + badges.map { "\($0.name) — \($0.source)" }
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
    /// Lowercased login → their roles in llm-d, e.g. "llm-d Project Leadership", "approver of
    /// llm-d, llm-d-kv-cache".
    var llmdMaintainers: [String: [String]] = [:]
    var users: [String: UserInfo] = [:]
    var overrides: [OrgOverride] = []

    static let committersKey = "committers"
    static let codeOwnersKey = "codeOwners"
    static let membersKey = "orgMembers"
    static let collaboratorsKey = "collaborators"
    static let llmdMaintainersKey = "llmdMaintainers"

    /// Sources in priority order: manual, committers.md (and CODEOWNERS for vLLM), org membership,
    /// profile company, commit email domain, username suffix.
    func badges(for login: String) -> [Badge] {
        Org.allCases.compactMap { badge(org: $0, for: login) }
    }

    func badge(org: Org, for login: String) -> Badge? {
        if let override = override(org: org, for: login) {
            return override.include ? Badge(org: org, source: "added manually") : nil
        }
        return detectedBadge(org: org, for: login)
    }

    /// The manual entry for `login` and `org`, if any.
    func override(org: Org, for login: String) -> OrgOverride? {
        let key = login.lowercased()
        return overrides.first { $0.login == key && $0.org == org }
    }

    /// The badge the public data gives, manual entries aside.
    func detectedBadge(org: Org, for login: String) -> Badge? {
        let key = login.lowercased()
        if org == .vllm { return vllmBadge(for: key) }
        if org == .llmd, let roles = llmdMaintainers[key], !roles.isEmpty {
            return Badge(org: .llmd, source: roles.joined(separator: "; "))
        }
        return source(of: org, for: key).map { Badge(org: org, source: $0) }
    }

    /// Whether `login` has the org's full badge (for vLLM, not just the gray member tier), which
    /// is what the affiliation menus check and toggle.
    func hasFullBadge(org: Org, for login: String) -> Bool {
        badge(org: org, for: login).map { !$0.isSecondary } ?? false
    }

    /// The manual entries that toggle the org's full badge for `logins`: when all of them have it,
    /// they lose it (a manual addition is dropped, a detected badge hidden); otherwise those
    /// without it get it (a hidden detected badge is shown again, anything else added manually).
    func toggling(_ org: Org, for logins: [String]) -> (save: [OrgOverride], delete: [OrgOverride]) {
        let keys = Array(Set(logins.map { $0.lowercased() })).sorted()
        var save: [OrgOverride] = []
        var delete: [OrgOverride] = []
        if keys.allSatisfy({ hasFullBadge(org: org, for: $0) }) {
            for key in keys {
                if let manual = override(org: org, for: key), manual.include {
                    delete.append(manual)
                } else {
                    save.append(OrgOverride(login: key, org: org, include: false))
                }
            }
        } else {
            for key in keys where !hasFullBadge(org: org, for: key) {
                if let hidden = override(org: org, for: key), detectedBadge(org: org, for: key)?.isSecondary == false {
                    delete.append(hidden)
                } else {
                    save.append(OrgOverride(login: key, org: org, include: true))
                }
            }
        }
        return (save, delete)
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
            // A public email can be left over from a past job: it counts only when the company
            // field doesn't name another org.
            if let domain = user.profileEmailDomain, org.matches(emailDomain: domain),
               !Org.allCases.contains(where: { $0 != org && !$0.isProject && user.company.map($0.matches(company:)) == true })
            {
                return "profile email @\(domain)"
            }
            if let domain = user.emailDomains.first(where: org.matches(emailDomain:)) {
                return "commit email @\(domain)"
            }
        }
        if let suffix = org.loginSuffixes.first(where: key.hasSuffix) {
            return "username ends with \(suffix)"
        }
        if let prefix = org.loginPrefixes.first(where: key.hasPrefix) {
            return "username starts with \(prefix)"
        }
        return nil
    }
}

// MARK: - Database

extension AppDatabase {
    func saveProfileEmailDomains(_ domains: [String: String]) async throws {
        try await writer.write { db in
            for (login, domain) in domains {
                try db.execute(sql: "UPDATE userInfo SET profileEmailDomain = ? WHERE login = ?", arguments: [domain, login])
            }
        }
    }

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
                    llmdMaintainers: meta(Affiliations.llmdMaintainersKey) ?? [:],
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

    /// Saves and deletes manual affiliations in one transaction, so the badges change at once.
    func update(saving: [OrgOverride], deleting: [OrgOverride]) async throws {
        try await writer.write { db in
            for override in deleting { _ = try override.delete(db) }
            for override in saving { try override.upsert(db) }
        }
    }

    func setMetaJSON(_ key: String, _ value: some Encodable & Sendable) async throws {
        let data = try JSONEncoder().encode(value)
        try await setMeta(key, String(decoding: data, as: UTF8.self))
    }
}
