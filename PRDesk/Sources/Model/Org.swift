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

    /// GitHub organization whose avatar is used as the badge icon.
    var avatarLogin: String {
        switch self {
        case .vllm: "vllm-project"
        case .inferact: "Inferact"
        case .redhat: "RedHatOfficial"
        case .nvidia: "NVIDIA"
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
