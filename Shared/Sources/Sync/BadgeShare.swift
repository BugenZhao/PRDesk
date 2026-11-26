import CryptoKit
import Foundation
import os

/// What the Mac's badges come from, as one file (SPEC §5, §9): the lists, the profiles, the
/// manual entries and the regular contributor's threshold. A device that imports it shows the
/// badges the Mac shows, with the same rules (`Affiliations`), without a request of its own for
/// any of it.
///
/// The same data always encodes to the same bytes (sorted keys and lists, no fetch times), so
/// the file changes only when a badge could.
struct AffiliationSnapshot: Codable, Equatable, Sendable {
    struct User: Codable, Equatable, Sendable {
        var login: String
        var company: String?
        var orgs: [String]
        var emailDomains: [String]
        var profileEmailDomain: String?
        var bio: String?
        var mergedCount: Int?
    }

    /// A manual entry, with the org by name: a reader that doesn't know an org yet skips it.
    struct Override: Codable, Equatable, Sendable {
        var login: String
        var org: String
        var include: Bool
    }

    var version = 1
    var mergedThreshold: Int
    var committers: [String: String]
    var codeOwners: [String: [String]]
    var members: [String: [String]]
    var collaborators: [String: String]
    var llmdMaintainers: [String: [String]]
    var users: [User]
    var overrides: [Override]

    init(_ affiliations: Affiliations, mergedThreshold: Int) {
        self.mergedThreshold = mergedThreshold
        committers = affiliations.committers
        codeOwners = affiliations.codeOwners
        members = Dictionary(uniqueKeysWithValues: affiliations.members.map { ($0.rawValue, $1.sorted()) })
        collaborators = affiliations.collaborators
        llmdMaintainers = affiliations.llmdMaintainers
        users = affiliations.users.values.sorted { $0.login < $1.login }.map {
            User(
                login: $0.login, company: $0.company, orgs: $0.orgs, emailDomains: $0.emailDomains,
                profileEmailDomain: $0.profileEmailDomain, bio: $0.bio, mergedCount: $0.mergedCount
            )
        }
        overrides = affiliations.overrides.sorted { $0.id < $1.id }.map {
            Override(login: $0.login, org: $0.org.rawValue, include: $0.include)
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Shares the Mac's badges with the iPad through a file in a private repository of the viewer's
/// (GitHub stays the only thing the devices have in common): the primary publishes its snapshot
/// there when it changes, a companion imports it in place of working badges out.
actor BadgeShare {
    /// Where the file is: a repository, or, for tests in debug builds, a local file
    /// (`-PRDeskBadgesFile <path>`), which no request is made for.
    enum Place: Sendable, CustomStringConvertible {
        case repository(owner: String, name: String)
        case file(URL)

        var description: String {
            switch self {
            case let .repository(owner, name): "\(owner)/\(name)"
            case let .file(url): url.path
            }
        }
    }

    enum Outcome: Sendable, Equatable {
        /// The file was written, or already held this.
        case published
        /// The file was imported, with the threshold it carries; nil when it held nothing new.
        case read(mergedThreshold: Int?)
        /// Nothing to do yet: no badges worked out, or too soon after the last time.
        case waiting
    }

    enum Failure: LocalizedError {
        case notPrivate(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case let .notPrivate(repository): "\(repository) is not private"
            case .unreadable: "The badges file can't be read"
            }
        }
    }

    /// The repository, as "owner/name", in the app's preferences.
    static let repositoryKey = "badgesRepository"
    static let directory = "pr-desk"
    static let fileName = "affiliations.json"

    /// The primary publishes at most this often on its own; a manual entry goes out at once.
    private static let publishInterval: TimeInterval = 3 * 3600
    /// A companion looks for a new file at most this often.
    private static let readInterval: TimeInterval = 10 * 60
    private static let publishedKey = "badgesPublished"
    private static let publishedAtKey = "badgesPublishedAt"
    private static let importedKey = "badgesImported"

    static var place: Place? {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: "PRDeskBadgesFile"), !path.isEmpty {
                return .file(URL(fileURLWithPath: path))
            }
        #endif
        let parts = (UserDefaults.standard.string(forKey: repositoryKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        guard parts.count == 2 else { return nil }
        return .repository(owner: String(parts[0]), name: String(parts[1]))
    }

    /// Reading or writing the file needs no request (a test's local file).
    static var isLocal: Bool {
        if case .file = place { true } else { false }
    }

    private let client: GitHubClient
    private let db: AppDatabase
    private var lastReadAt: Date?

    init(client: GitHubClient, db: AppDatabase) {
        self.client = client
        self.db = db
    }

    // MARK: Publishing

    /// Writes the snapshot where it differs from the one last written. `soon` skips the wait
    /// between publishes (a manual entry, a refresh asked for).
    func publish(mergedThreshold: Int, soon: Bool) async throws -> Outcome? {
        guard let place = Self.place else { return nil }
        let affiliations = try await db.affiliations()
        // Nothing worked out yet (a new install): an empty file would take the reader's badges.
        guard !affiliations.users.isEmpty else { return .waiting }
        let data = try AffiliationSnapshot(affiliations, mergedThreshold: mergedThreshold).encoded()
        let sha = Self.blobSHA(data)
        let mark = "\(place) \(sha)"
        if try await db.meta(Self.publishedKey) == mark { return .published }
        if !soon, let last = try await db.meta(Self.publishedAtKey).flatMap(SyncEngine.parse),
           Date().timeIntervalSince(last) < Self.publishInterval {
            return .waiting
        }
        switch place {
        case let .file(url):
            // A test's, in a database it may share with the installed app: nothing is noted.
            try data.write(to: url, options: .atomic)
            return .published
        case let .repository(owner, name):
            // Members of private organizations are in the file: never to a public repository.
            let repository: Repository = try await client.rest("GET", "/repos/\(owner)/\(name)")
            guard repository.private else { throw Failure.notPrivate("\(owner)/\(name)") }
            let current = try await remoteSHA(owner: owner, name: name)
            if current != sha {
                if isDryRun("publish badges to \(place) (\(data.count) bytes)") { return .waiting }
                try await client.rest(
                    "PUT", Self.contentsPath(owner: owner, name: name, file: true),
                    json: Put(message: "Update affiliations", content: data.base64EncodedString(), sha: current)
                )
            }
        }
        try await db.setMeta(Self.publishedKey, mark)
        try await db.setMeta(Self.publishedAtKey, SyncEngine.format(Date()))
        return .published
    }

    // MARK: Reading

    /// Imports the file where it is another than the one last imported.
    func read(force: Bool) async throws -> Outcome? {
        guard let place = Self.place else { return nil }
        if !force, let lastReadAt, Date().timeIntervalSince(lastReadAt) < Self.readInterval { return .waiting }
        let imported = try await db.meta(Self.importedKey)
        let data: Data
        let mark: String
        switch place {
        case let .file(url):
            data = try Data(contentsOf: url)
            mark = "\(place) \(Self.blobSHA(data))"
            if mark == imported { return done(nil) }
        case let .repository(owner, name):
            guard let sha = try await remoteSHA(owner: owner, name: name) else { return done(nil) }
            mark = "\(place) \(sha)"
            if mark == imported { return done(nil) }
            let blob: Blob = try await client.rest("GET", "/repos/\(owner)/\(name)/git/blobs/\(sha)")
            guard let content = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters) else {
                throw Failure.unreadable
            }
            data = content
        }
        let snapshot = try JSONDecoder().decode(AffiliationSnapshot.self, from: data)
        try await db.replaceAffiliations(with: snapshot)
        try await db.setMeta(Self.importedKey, mark)
        return done(snapshot.mergedThreshold)
    }

    private func done(_ mergedThreshold: Int?) -> Outcome {
        lastReadAt = Date()
        return .read(mergedThreshold: mergedThreshold)
    }

    // MARK: GitHub

    private struct Repository: Decodable {
        var `private`: Bool
    }

    private struct Entry: Decodable {
        var name: String
        var sha: String
    }

    private struct Blob: Decodable {
        var content: String
    }

    private struct Put: Encodable {
        var message: String
        var content: String
        var sha: String?
    }

    private static func contentsPath(owner: String, name: String, file: Bool) -> String {
        "/repos/\(owner)/\(name)/contents/\(directory)" + (file ? "/\(fileName)" : "")
    }

    /// The file's blob as the repository has it, from its directory's listing (which is small,
    /// where the file's own entry would bring its contents along); nil while there is none.
    private func remoteSHA(owner: String, name: String) async throws -> String? {
        do {
            let entries: [Entry] = try await client.rest("GET", Self.contentsPath(owner: owner, name: name, file: false))
            return entries.first { $0.name == Self.fileName }?.sha
        } catch GraphQLClientError.http(status: 404, _) {
            return nil
        }
    }

    /// The id git gives a file with these contents, which is what GitHub reports for one.
    static func blobSHA(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
