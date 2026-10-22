import Foundation

extension Date {
    /// Short age like `now`, `37m`, `5h`, `12d`, `3mo`, `2y`.
    func compactAge(relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(self))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        return switch seconds {
        case ..<60: "now"
        case ..<3600: "\(minutes)m"
        case ..<86400: "\(hours)h"
        case ..<(60 * 86400): "\(days)d"
        case ..<(365 * 86400): "\(days / 30)mo"
        default: "\(days / 365)y"
        }
    }
}
