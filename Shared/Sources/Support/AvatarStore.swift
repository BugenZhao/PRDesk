import Foundation
import ImageIO
import Synchronization

/// GitHub avatars (users and Apps) as image data, kept on disk; each platform makes its images
/// from it (`AvatarCache` on the Mac).
enum AvatarStore {
    private static let directory: URL = {
        let dir = AppDatabase.directory.appending(path: "avatars", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Avatar URLs of GitHub Apps by lowercased login, which `github.com/<login>.png` doesn't serve.
    private static let appAvatarURLs = Mutex<[String: String]>([:])

    /// Remembers an avatar URL GitHub gave for `login`, if it is a GitHub App's (such as the parity
    /// agent's); people's avatars load by login.
    static func remember(_ url: String, for login: String) {
        guard url.contains("githubusercontent.com/in/") else { return }
        appAvatarURLs.withLock { $0[login.lowercased()] = url }
    }

    /// An avatar's image data, from disk or GitHub. Disk and network I/O, off the main thread:
    /// this is reached while lists build their rows.
    @concurrent
    static func data(for login: String) async -> Data? {
        let key = login.lowercased()
        let file = directory.appending(path: "\(key).png")
        if let data = try? Data(contentsOf: file) {
            if isImage(data) { return data }
            // Earlier versions saved GitHub's "Not Found" page for accounts it has no avatar for.
            try? FileManager.default.removeItem(at: file)
        }
        // Commits by someone without an account name a person, not a login.
        guard !key.contains(" ") else { return nil }
        // An App's commits carry its `[bot]` login, its PRs and comments the bare one.
        let appURL = appAvatarURLs.withLock { $0[key.hasSuffix("[bot]") ? String(key.dropLast(5)) : key] }
        let source = appURL.map { "\($0)\($0.contains("?") ? "&" : "?")s=64" } ?? "https://github.com/\(key).png?size=64"
        guard let url = URL(string: source),
              let (data, response) = try? await URLSession.shared.data(from: url) as (Data, URLResponse),
              (response as? HTTPURLResponse)?.statusCode == 200, isImage(data)
        else { return nil }
        try? data.write(to: file)
        return data
    }

    private static func isImage(_ data: Data) -> Bool {
        CGImageSourceCreateWithData(data as CFData, nil).map { CGImageSourceGetCount($0) > 0 } ?? false
    }
}
