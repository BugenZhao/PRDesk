import Foundation

/// What this device does beyond showing GitHub's state and writing the viewer's own actions to it.
///
/// GitHub (the board, notifications) is the one source of truth for every device. The Mac is the
/// primary: it alone follows the board with rules (subscriptions for Shelf and Attic, putting
/// approved PRs on the board, SPEC §3.1), since two devices doing that would undo each other. The
/// phone is a companion: its edits reach the Mac as edits made on GitHub do, and the Mac follows
/// them up.
enum DeviceRole: Sendable {
    case primary
    case companion

    static let current: DeviceRole = {
        #if os(macOS)
            // Debug builds launched with `-PRDeskCompanion YES` run the Mac as a companion: a first
            // sync of 14 days, no prefetched details, no affiliation work and no board rules. For a
            // second Mac that starts from an empty database without spending much of the quota.
            #if DEBUG
                if UserDefaults.standard.bool(forKey: "PRDeskCompanion") { return .companion }
            #endif
            return .primary
        #else
            return .companion
        #endif
    }()

    /// Follows Status changes with the subscription and puts approved PRs on the board.
    var runsRules: Bool { self == .primary }

    /// Works out affiliation badges itself, which takes many requests a day (committers, org
    /// members, profiles, merged counts).
    var computesAffiliations: Bool { self == .primary }

    /// Fetches details ahead of opening (Desk, Good, Triage, the inbox, pins): hundreds of
    /// queries after a first sync. The companion fetches a detail when it is opened.
    var prefetchesDetails: Bool { self == .primary }

    /// How far back the first sync looks.
    var initialLookback: TimeInterval {
        switch self {
        case .primary: 90 * 24 * 3600
        case .companion: 14 * 24 * 3600
        }
    }
}
