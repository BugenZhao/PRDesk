import Observation
import UIKit

/// GitHub avatars as images, kept in memory; the data comes from `AvatarStore`. The same API as
/// the Mac's, so shared views (`AvatarView`, `BadgeIcons`) show them alike.
@MainActor
@Observable
final class AvatarCache {
    static let shared = AvatarCache()

    /// Bumped whenever an image finishes loading, so views showing avatars can redraw.
    private(set) var version = 0

    @ObservationIgnored private var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var isBumpScheduled = false

    /// Returns the avatar if loaded; otherwise starts loading it and returns nil.
    func image(for login: String) -> UIImage? {
        let key = login.lowercased()
        if let image = images[key] { return image }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        Task {
            if let data = await AvatarStore.data(for: key), let image = UIImage(data: data) {
                images[key] = image
                scheduleVersionBump()
            }
            loading.remove(key)
        }
        return nil
    }

    /// A list's worth of avatars arrives at once; redraw once per batch.
    private func scheduleVersionBump() {
        guard !isBumpScheduled else { return }
        isBumpScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            isBumpScheduled = false
            version += 1
        }
    }
}

extension Badge {
    /// The org's brand tile or bundled logo, without color for a secondary badge.
    @MainActor
    var image: UIImage? {
        BadgeImages.image(for: self, style: UITraitCollection.current.userInterfaceStyle)
    }
}
