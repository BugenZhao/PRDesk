import Foundation

extension AppModel {
    /// How syncing stands, in a line: syncing, failed, rate limited, or how long ago it last
    /// went through; nil before the first sync.
    func syncLine(at now: Date = Date()) -> String? {
        if requestsStopped { return "GitHub requests stopped" }
        switch syncState {
        case .syncing: return "Syncing…"
        case .failed: return "Sync failed"
        case let .rateLimited(until):
            return "Rate limited until \(until.formatted(date: .omitted, time: .shortened))"
        case .idle:
            guard let last = lastSyncedAt else { return nil }
            let age = last.compactAge(relativeTo: now)
            return age == "now" ? "Synced just now" : "Synced \(age) ago"
        }
    }
}
