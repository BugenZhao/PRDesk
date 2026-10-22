import AppKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class AppModel {
    enum SyncState: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    /// Closed or merged items stay visible this long after closing.
    static let closedRetention: TimeInterval = 14 * 24 * 3600
    private static let pollInterval: Duration = .seconds(60)
    /// Minimum gap before re-syncing when the app is activated.
    private static let activationThreshold: TimeInterval = 15

    private(set) var items: [Item] = []
    private(set) var viewer: String?
    private(set) var syncState: SyncState = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var rateLimit: RateLimit?

    var selection: Item.ID?
    var filterText = ""

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "App")

    init(db: AppDatabase) {
        self.db = db
        engine = SyncEngine(client: GraphQLClient(), db: db)
    }

    var visibleItems: [Item] {
        let cutoff = Date().addingTimeInterval(-Self.closedRetention)
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            guard item.isOpen || (item.closedAt ?? item.updatedAt) >= cutoff else { return false }
            guard !query.isEmpty else { return true }
            return item.title.lowercased().contains(query)
                || String(item.number).hasPrefix(query)
                || (item.author?.lowercased().contains(query) ?? false)
        }
    }

    var selectedItem: Item? {
        selection.flatMap { id in items.first { $0.id == id } }
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self, db] in
            do {
                for try await items in db.observeItems() {
                    self?.items = items
                }
            } catch {
                self?.logger.error("Item observation failed: \(error)")
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: Self.pollInterval)
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self else { return }
                if let last = lastSyncedAt, Date().timeIntervalSince(last) < Self.activationThreshold { continue }
                await sync()
            }
        })
    }

    func sync() async {
        guard syncState != .syncing else { return }
        syncState = .syncing
        do {
            if let result = try await engine.sync() {
                viewer = result.viewer
                lastSyncedAt = result.finishedAt
                rateLimit = result.rateLimit
            }
            syncState = .idle
        } catch {
            logger.error("Sync failed: \(error)")
            syncState = .failed(error.localizedDescription)
        }
    }
}
