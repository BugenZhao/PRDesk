import Foundation

/// What this device does beyond showing GitHub's state and writing the viewer's own actions to it.
///
/// GitHub (the board, notifications) is the one source of truth for every device. The Mac is the
/// primary: it alone follows the board with rules (subscriptions for Skipped and Muted, putting
/// approved PRs on the board, SPEC §3.1), since two devices doing that would undo each other. The
/// phone is a companion: its edits reach the Mac as edits made on GitHub do, and the Mac follows
/// them up.
enum DeviceRole: Sendable {
    case primary
    case companion

    static let current: DeviceRole = {
        #if os(macOS)
            .primary
        #else
            .companion
        #endif
    }()

    /// Follows Status changes with the subscription and puts approved PRs on the board.
    var runsRules: Bool { self == .primary }

    /// Sends to Grok Bots itself, so a 🚀 send means Merger has the PR (and Merging can go on the
    /// board); the companion only opens Grok Bot with a draft.
    var sendsToBotsDirectly: Bool { self == .primary }

    /// Works out affiliation badges itself, which takes many requests a day (committers, org
    /// members, profiles, merged counts).
    var computesAffiliations: Bool { self == .primary }

    /// How far back the first sync looks.
    var initialLookback: TimeInterval {
        switch self {
        case .primary: 90 * 24 * 3600
        case .companion: 14 * 24 * 3600
        }
    }
}
