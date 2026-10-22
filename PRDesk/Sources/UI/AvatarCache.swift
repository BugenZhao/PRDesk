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
    nonisolated private static let directory: URL = {
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
        guard let data = await Self.fetch(key), let image = NSImage(data: data) else { return }
        images[key] = image
        version += 1
    }

    /// Disk and network I/O, off the main thread: this is reached while the table builds cells.
    @concurrent
    private static func fetch(_ key: String) async -> Data? {
        let file = directory.appending(path: "\(key).png")
        if let data = try? Data(contentsOf: file) { return data }
        guard let url = URL(string: "https://github.com/\(key).png?size=64"),
              let data = try? await URLSession.shared.data(from: url).0
        else { return nil }
        try? data.write(to: file)
        return data
    }
}
