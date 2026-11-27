import CloudKit
import Foundation
import os

/// What a device tells the others after one of its writes to GitHub went through: which items
/// to fetch again, and which of their parts. Never what changed: GitHub stays the one source of
/// truth, and a hint only saves the others waiting for their next sync (SPEC §9, Other devices).
struct ChangeHint: Sendable, Equatable {
    struct Parts: OptionSet, Sendable, Hashable {
        let rawValue: Int
        /// The item's row: title, state, draft, CI, reviews.
        static let item = Parts(rawValue: 1 << 0)
        /// Its board entry: Status, Priority, Comment, Pinned.
        static let board = Parts(rawValue: 1 << 1)
        /// Its conversation: comments, reviews, reactions, events.
        static let timeline = Parts(rawValue: 1 << 2)
        /// The viewer's Viewed marks on its files.
        static let files = Parts(rawValue: 1 << 3)
        /// The viewer's notifications (one was marked read).
        static let inbox = Parts(rawValue: 1 << 4)
    }

    /// Node ids.
    var itemIDs: [String]
    var parts: Parts
    /// The install that wrote to GitHub (`CloudHints.deviceID`), and its kind ("Mac", "iPad"),
    /// for Settings.
    var device: String
    var deviceKind: String
    var at: Date
}

/// Hints between the viewer's devices, as small records in a zone of their iCloud private
/// database. `CKSyncEngine` sends them and fetches the others' when CloudKit's silent push says
/// there are new ones (and at launch). Hints older than a few minutes are left to the regular
/// sync, and every hint is deleted a day after it was written.
///
/// Only a copy signed with the iCloud entitlements (installed with the scripts, on the Mac and
/// the devices) has this; elsewhere `make` returns nil and nothing here runs. A copy without them
/// would crash at the first use of CloudKit.
actor CloudHints: CKSyncEngineDelegate {
    static let containerID = "iCloud.com.bugenzhao.PRDesk"
    private static let recordType = "Hint"
    private static let zoneID = CKRecordZone.ID(zoneName: "Hints")
    /// Older hints are what a launch's own sync catches up on anyway.
    private static let freshness: TimeInterval = 15 * 60
    private static let lifetime: TimeInterval = 24 * 3600

    /// This install, kept in its preferences.
    static let deviceID: String = {
        let key = "cloudHintsDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "Hints")
    private let stateURL: URL
    private let receive: @Sendable ([ChangeHint]) async -> Void
    /// The latest failure (nil once something went through), for Settings.
    private let report: @Sendable (String?) async -> Void
    private var engine: CKSyncEngine?
    /// Hints waiting to go out, by record id.
    private var outgoing: [CKRecord.ID: CKRecord] = [:]
    private var saved: Saved

    /// What is kept between launches: the engine's state, and this install's hints still in
    /// iCloud, to delete when they are a day old.
    private struct Saved: Codable {
        var engine: CKSyncEngine.State.Serialization?
        var ownHints: [String: Date] = [:]
        /// The latest few things that happened, newest last: a device's log can't be read without
        /// root, and this file can (`devicectl device copy from`).
        var trace: [String]?
        /// Where `poll` left off in the zone, apart from the engine's own token.
        var pollToken: Data?
    }

    /// Hints already handed on, by record name: `poll` and the engine may both bring one.
    private var handedOn: Set<String> = []

    /// Nil where the app isn't signed for iCloud (test copies, simulators, a Mac without a
    /// development certificate).
    static func make(
        directory: URL,
        receive: @escaping @Sendable ([ChangeHint]) async -> Void,
        report: @escaping @Sendable (String?) async -> Void
    ) -> CloudHints? {
        guard isEntitled else { return nil }
        return CloudHints(stateURL: directory.appending(path: "cloud-hints.json"), receive: receive, report: report)
    }

    private init(stateURL: URL, receive: @escaping @Sendable ([ChangeHint]) async -> Void, report: @escaping @Sendable (String?) async -> Void) {
        self.stateURL = stateURL
        self.receive = receive
        self.report = report
        saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: stateURL))) ?? Saved()
    }

    /// Hints are what the viewer just did, and are wanted within seconds. CloudKit's default
    /// quality of service is discretionary: the system runs such work when it likes, and on an
    /// iPhone not at all in Low Power Mode. The engine's own sends and fetches (after a push)
    /// were left waiting so on a phone, with the hints pending and no request made.
    private static func urgent(_ name: String) -> CKOperationGroup {
        let group = CKOperationGroup()
        group.name = "Hints-\(name)"
        group.defaultConfiguration.qualityOfService = .userInitiated
        return group
    }

    private func note(_ line: String) {
        var trace = saved.trace ?? []
        trace.append("\(Date().formatted(.iso8601)) \(line)")
        saved.trace = Array(trace.suffix(40))
        save()
    }

    private func failed(_ what: String, _ error: any Error) async {
        logger.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        note("\(what) failed: \(error.localizedDescription)")
        await report("\(what) failed: \(error.localizedDescription)")
    }

    /// Whether this copy is signed with CloudKit. The Mac asks its own signature; iOS has no
    /// call for that, so it looks for the container in the profile the app was installed with.
    private static var isEntitled: Bool {
        #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil),
                  let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
            else { return false }
            return (value as? [String])?.contains("CloudKit") == true
        #else
            guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                  let profile = try? Data(contentsOf: url)
            else { return false }
            return profile.range(of: Data(containerID.utf8)) != nil
        #endif
    }

    func start() {
        guard engine == nil else { return }
        let database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        let engine = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: saved.engine, delegate: self))
        self.engine = engine
        if saved.engine == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        note("started")
        deleteExpired()
        Task {
            // Pending hints from before (left waiting, or the app stopped), and what the others
            // wrote meanwhile, at once rather than on the engine's schedule.
            await sendNow()
            await fetchNow()
        }
    }

    /// Fetches what the others wrote now, for when the app comes back to the front: a push that
    /// came while it was suspended may have been dropped.
    func fetchNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges(CKSyncEngine.FetchChangesOptions(operationGroup: Self.urgent("Fetch")))
            await report(nil)
        } catch {
            await failed("Fetching hints", error)
        }
    }

    /// Looks in the zone for new hints, for the Mac, which CloudKit's pushes reach late or not at
    /// all. The engine's `fetchChanges` asks the server only once it believes something changed (a
    /// push came, the app was brought to the front), so this reads the zone's changes itself, from
    /// a change token of its own: one small request, nothing when nothing changed.
    func poll() async {
        guard let engine else { return }
        let database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        var token = saved.pollToken.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            var records: [CKRecord] = []
            var moreComing = true
            while moreComing {
                let since = token
                let changes = try await database.configuredWith(group: Self.urgent("Poll")) { database in
                    try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: since)
                }
                records += changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                token = changes.changeToken
                moreComing = changes.moreComing
            }
            let data = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            if data != saved.pollToken {
                saved.pollToken = data
                save()
            }
            if !records.isEmpty { await received(records, syncEngine: engine) }
        } catch let error as CKError where [.changeTokenExpired, .zoneNotFound].contains(error.code) {
            // Read again from the start; a missing zone is made again with the next hint sent.
            saved.pollToken = nil
            save()
        } catch {
            await failed("Looking for hints", error)
        }
    }

    /// Records something the app saw, for the trace.
    func noted(_ line: String) {
        note(line)
    }

    /// For a silent push the app was handed (the engine may only schedule its own fetch).
    func pushed() async {
        note("push")
        await fetchNow()
    }

    private func sendNow() async {
        guard let engine, !engine.state.pendingRecordZoneChanges.isEmpty || !engine.state.pendingDatabaseChanges.isEmpty else { return }
        do {
            try await engine.sendChanges(CKSyncEngine.SendChangesOptions(operationGroup: Self.urgent("Send")))
            await report(nil)
        } catch {
            await failed("Sending hints", error)
        }
    }

    func send(_ hint: ChangeHint) async {
        guard let engine, !hint.itemIDs.isEmpty else { return }
        if isDryRun("hint \(hint.parts.rawValue) for \(hint.itemIDs.joined(separator: ", "))") { return }
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.zoneID))
        record["items"] = hint.itemIDs
        record["parts"] = hint.parts.rawValue
        record["device"] = hint.device
        record["deviceKind"] = hint.deviceKind
        record["at"] = hint.at
        outgoing[record.recordID] = record
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        note("send \(hint.parts.rawValue) for \(hint.itemIDs.count) items")
        // At once, rather than when the engine's own schedule gets to it.
        await sendNow()
    }

    /// Deletes this install's hints that are a day old.
    private func deleteExpired() {
        guard let engine else { return }
        let cutoff = Date().addingTimeInterval(-Self.lifetime)
        let expired = saved.ownHints.filter { $0.value < cutoff }.keys
        guard !expired.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: expired.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID)) })
    }

    private func save() {
        do {
            try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
        } catch {
            logger.error("Saving the hints' state failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            saved.engine = update.stateSerialization
            save()
        case let .accountChange(change):
            // Another account's hints are nobody's here; what was pending goes with it.
            if case .signIn = change.changeType { break }
            outgoing = [:]
            saved.ownHints = [:]
            save()
        case let .fetchedRecordZoneChanges(changes):
            await received(changes.modifications.map(\.record), syncEngine: syncEngine)
        case let .sentRecordZoneChanges(sent):
            if !sent.savedRecords.isEmpty { note("sent \(sent.savedRecords.count)") }
            for record in sent.savedRecords {
                outgoing[record.recordID] = nil
                saved.ownHints[record.recordID.recordName] = (record["at"] as? Date) ?? Date()
            }
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                if failure.error.code == .zoneNotFound {
                    // Deleted from iCloud's settings: make it again, and send the hint after it.
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                } else {
                    await failed("Saving a hint", failure.error)
                    outgoing[id] = nil
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                }
            }
            for id in sent.deletedRecordIDs {
                saved.ownHints[id.recordName] = nil
            }
            for (id, error) in sent.failedRecordDeletes where error.code == .unknownItem {
                saved.ownHints[id.recordName] = nil
            }
            save()
        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                saved.ownHints = [:]
                save()
            }
        default:
            break
        }
    }

    /// The engine's own fetches (at launch, after a push) as urgent as ours.
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.operationGroup = Self.urgent("Fetch")
        return options
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            // Nil for a hint from before a relaunch, which is dropped: it is stale by now.
            await self.outgoing[id]
        }
    }

    /// Hands on the others' fresh hints; the others' day-old ones are deleted, in case the
    /// device that wrote them isn't around to.
    private func received(_ records: [CKRecord], syncEngine: CKSyncEngine) async {
        let now = Date()
        var hints: [ChangeHint] = []
        var expired: [CKRecord.ID] = []
        for record in records where record.recordType == Self.recordType {
            guard let device = record["device"] as? String, let at = record["at"] as? Date else { continue }
            if now.timeIntervalSince(at) > Self.lifetime {
                expired.append(record.recordID)
                continue
            }
            guard device != Self.deviceID, now.timeIntervalSince(at) < Self.freshness,
                  handedOn.insert(record.recordID.recordName).inserted
            else { continue }
            hints.append(ChangeHint(
                itemIDs: record["items"] as? [String] ?? [],
                parts: ChangeHint.Parts(rawValue: record["parts"] as? Int ?? 0),
                device: device,
                deviceKind: record["deviceKind"] as? String ?? "",
                at: at
            ))
        }
        if !expired.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: expired.map { .deleteRecord($0) })
        }
        note("fetched \(records.count), \(hints.count) fresh from others")
        guard !hints.isEmpty else { return }
        logger.info("Received \(hints.count) hints")
        await receive(hints)
    }
}
