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

struct Badge: Hashable, Sendable {
    var org: Org
    /// Why the badge applies, shown as a tooltip.
    var source: String
}

/// Everything known about affiliations, and the rules that turn it into badges.
struct Affiliations: Equatable, Sendable {
    /// Lowercased login → area, from committers.md.
    var committers: [String: String] = [:]
    /// Lowercased members of each org's GitHub organizations, as visible to the viewer.
    var members: [Org: Set<String>] = [:]
    var users: [String: UserInfo] = [:]
    var overrides: [OrgOverride] = []

    static let committersKey = "committers"
    static let membersKey = "orgMembers"

    /// Sources in priority order: manual, committers.md, org membership, profile company,
    /// commit email domain, username suffix.
    func badges(for login: String) -> [Badge] {
        let key = login.lowercased()
        return Org.allCases.compactMap { org in
            if let override = overrides.first(where: { $0.login == key && $0.org == org }) {
                return override.include ? Badge(org: org, source: "added manually") : nil
            }
            return source(of: org, for: key).map { Badge(org: org, source: $0) }
        }
    }

    private func source(of org: Org, for key: String) -> String? {
        if org == .vllm {
            return committers[key].map { "committers.md: \($0)" }
        }
        if members[org]?.contains(key) == true {
            return "member of \(org.githubOrgs.joined(separator: " / "))"
        }
        if let user = users[key] {
            if let membership = user.orgs.first(where: { login in org.githubOrgs.contains { sameLogin($0, login) } }) {
                return "public member of \(membership)"
            }
            if let company = user.company, org.companyPatterns.contains(where: company.lowercased().contains) {
                return "profile company: \(company)"
            }
            if let domain = user.emailDomains.first(where: org.emailDomains.contains) {
                return "commit email @\(domain)"
            }
        }
        if let suffix = org.loginSuffixes.first(where: key.hasSuffix) {
            return "username ends with \(suffix)"
        }
        return nil
    }
}

extension Org {
    /// GitHub organizations whose members get this badge.
    var githubOrgs: [String] {
        switch self {
        case .vllm: []
        case .inferact: ["Inferact"]
        case .redhat: ["RedHatOfficial", "redhat-et", "neuralmagic"]
        case .nvidia: ["NVIDIA"]
        }
    }

    var companyPatterns: [String] {
        switch self {
        case .vllm: []
        case .inferact: ["inferact"]
        case .redhat: ["red hat", "redhat", "neural magic", "neuralmagic"]
        case .nvidia: ["nvidia"]
        }
    }

    var emailDomains: [String] {
        switch self {
        case .vllm: []
        case .inferact: ["inferact.ai", "inferact.com"]
        case .redhat: ["redhat.com"]
        case .nvidia: ["nvidia.com"]
        }
    }

    var loginSuffixes: [String] {
        switch self {
        case .vllm: []
        case .inferact: ["-inferact"]
        case .redhat: ["-redhat"]
        case .nvidia: ["-nv", "-nvidia"]
        }
    }
}

// MARK: - Database

extension AppDatabase {
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
                    members: Dictionary(uniqueKeysWithValues: members.compactMap { key, logins in
                        Org(rawValue: key).map { ($0, Set(logins)) }
                    }),
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
