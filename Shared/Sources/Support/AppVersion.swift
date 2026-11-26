import Foundation

/// Which commit this copy was built from. The install scripts stamp it (`PRDeskCommit` in the
/// Info.plist, from the `PRDESK_COMMIT` build setting): with a Mac, an iPad and an iPhone each
/// installed on its own, this is how to tell which of them has what.
enum AppVersion {
    /// The app's own repository, which is public.
    static let repository = "BugenZhao/PRDesk"

    /// "abc1234", with a "+" when built with changes not committed; nil for a build that is no
    /// install (from Xcode, a test copy).
    static let commit: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "PRDeskCommit") as? String
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }()
}

extension AppModel {
    /// How many commits the repository's `main` has that this copy doesn't; nil when that can't
    /// be told (no stamp, the commit not pushed, no network). One REST request.
    func commitsBehindMain() async -> Int? {
        struct Comparison: Decodable {
            var aheadBy: Int

            enum CodingKeys: String, CodingKey {
                case aheadBy = "ahead_by"
            }
        }
        guard let commit = AppVersion.commit?.trimmingCharacters(in: CharacterSet(charactersIn: "+")) else { return nil }
        let comparison: Comparison? = try? await engine.client.rest("GET", "/repos/\(AppVersion.repository)/compare/\(commit)...main")
        return comparison?.aheadBy
    }
}
