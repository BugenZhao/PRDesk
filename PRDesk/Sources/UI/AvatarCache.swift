import AppKit
import Observation

/// Loads GitHub avatars (users and orgs) once, keeping them in memory and on disk.
@MainActor
@Observable
final class AvatarCache {
    static let shared = AvatarCache()

    /// Bumped whenever an image finishes loading, so views showing avatars can redraw.
    private(set) var version = 0

    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    private static let directory: URL = {
        let dir = AppDatabase.directory.appending(path: "avatars", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Returns the avatar if loaded; otherwise starts loading it and returns nil.
    func image(for login: String) -> NSImage? {
        let key = login.lowercased()
        if let image = images[key] { return image }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        Task { await load(key) }
        return nil
    }

    private func load(_ key: String) async {
        let file = Self.directory.appending(path: "\(key).png")
        var data = try? Data(contentsOf: file)
        if data == nil, let url = URL(string: "https://github.com/\(key).png?size=64") {
            data = try? await URLSession.shared.data(from: url).0
            if let data { try? data.write(to: file) }
        }
        guard let data, let image = NSImage(data: data) else { return }
        images[key] = image
        version += 1
    }
}
