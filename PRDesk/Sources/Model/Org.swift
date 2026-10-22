import Foundation

/// Affiliations shown as badges next to author names.
enum Org: String, CaseIterable, Codable, Sendable, Identifiable {
    case vllm, inferact, redhat, nvidia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vllm: "vLLM committer"
        case .inferact: "Inferact"
        case .redhat: "Red Hat"
        case .nvidia: "NVIDIA"
        }
    }

    /// Bundled logo on a transparent background, used as the badge icon instead of the avatar.
    var logoAsset: String? {
        switch self {
        case .vllm: "org-vllm"
        case .inferact: "org-inferact"
        case .redhat: nil
        case .nvidia: "org-nvidia"
        }
    }

    /// GitHub organization whose avatar is the badge icon when there's no logo asset.
    var avatarLogin: String {
        switch self {
        case .vllm: "vllm-project"
        case .inferact: "Inferact"
        case .redhat: "RedHatOfficial"
        case .nvidia: "NVIDIA"
        }
    }

    /// Fallback label while the avatar loads.
    var shortLabel: String {
        switch self {
        case .vllm: "V"
        case .inferact: "I"
        case .redhat: "RH"
        case .nvidia: "NV"
        }
    }

    /// Names accepted by the `org:` filter token.
    var filterNames: [String] {
        switch self {
        case .vllm: ["vllm", "committer"]
        case .inferact: ["inferact"]
        case .redhat: ["redhat", "rh"]
        case .nvidia: ["nvidia", "nv"]
        }
    }
}
