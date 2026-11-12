import Foundation

/// Affiliations shown as badges next to author names, projects before employers: vLLM itself and
/// llm-d, then the companies whose people do most of the work in the repository (picked from the
/// top contributors over half a year, overall and in the Rust frontend), in roughly that order.
enum Org: String, CaseIterable, Codable, Sendable, Identifiable {
    case vllm, llmd
    case inferact, redhat, nvidia
    case amd, intel, ibm, huggingface, mistral, meta, google, daocloud, huawei, microsoft
    case alibaba, antgroup, bytedance, moonshot, arm, samsung, embeddedllm, cohere

    var id: String { rawValue }

    var displayName: String { profile.displayName }

    /// Bundled mark on a transparent background (Simple Icons, the company's own, or its GitHub
    /// organization's avatar), the badge icon of every org without a `brandTile`; some have a
    /// dark-mode variant.
    var logoAsset: String? { profile.logoAsset }

    /// Fallback label should an icon be missing.
    var shortLabel: String { profile.shortLabel }

    /// Names accepted by the `org:` filter token.
    var filterNames: [String] { profile.filterNames }

    /// GitHub organizations whose (public) members get this badge.
    var githubOrgs: [String] { profile.githubOrgs }

    /// Whole words or phrases that name the org in a profile's company field.
    var companyPatterns: [String] { profile.companyPatterns }

    /// Commit email domains, subdomains included.
    var emailDomains: [String] { profile.emailDomains }

    var loginSuffixes: [String] { profile.loginSuffixes }

    /// A short label on the brand color (hex), drawn as the badge icon for orgs whose avatar is a
    /// wordmark that can't be read at badge size.
    var brandTile: (text: String, hex: String)? { profile.brandTile }

    /// Whether the members of `githubOrgs` are listed daily. Only for small organizations: the big
    /// companies have thousands of public members, so their people are found from their own
    /// profiles instead.
    var listsMembers: Bool {
        switch self {
        case .vllm, .inferact, .redhat, .nvidia, .llmd: true
        default: false
        }
    }

    /// An open source project rather than an employer: its badge says nothing about where
    /// someone works.
    var isProject: Bool { self == .vllm || self == .llmd }

    private struct Profile {
        var displayName: String
        var shortLabel: String
        var filterNames: [String]
        var githubOrgs: [String]
        var companyPatterns: [String] = []
        var emailDomains: [String] = []
        var loginSuffixes: [String] = []
        var logoAsset: String?
        var brandTile: (text: String, hex: String)?
    }

    private var profile: Profile {
        switch self {
        case .vllm:
            Profile(displayName: "vLLM committer", shortLabel: "V", filterNames: ["vllm", "committer"],
                    githubOrgs: ["vllm-project"], logoAsset: "org-vllm")
        case .inferact:
            Profile(displayName: "Inferact", shortLabel: "I", filterNames: ["inferact"], githubOrgs: ["Inferact"],
                    companyPatterns: ["inferact"], emailDomains: ["inferact.ai", "inferact.com"],
                    loginSuffixes: ["-inferact"], logoAsset: "org-inferact")
        case .redhat:
            Profile(displayName: "Red Hat", shortLabel: "RH", filterNames: ["redhat", "rh"],
                    githubOrgs: ["RedHatOfficial", "redhat-et", "neuralmagic"],
                    companyPatterns: ["red hat", "redhat", "redhatofficial", "redhatproductsecurity", "neural magic", "neuralmagic"],
                    emailDomains: ["redhat.com"], loginSuffixes: ["-redhat", "-rh"], logoAsset: "org-redhat")
        case .nvidia:
            Profile(displayName: "NVIDIA", shortLabel: "NV", filterNames: ["nvidia", "nv"], githubOrgs: ["NVIDIA", "ai-dynamo"],
                    companyPatterns: ["nvidia", "ai dynamo"], emailDomains: ["nvidia.com"], loginSuffixes: ["-nv", "-nvidia"],
                    logoAsset: "org-nvidia")
        case .amd:
            Profile(displayName: "AMD", shortLabel: "A", filterNames: ["amd"], githubOrgs: ["AMD", "ROCm", "AMD-AGI"],
                    companyPatterns: ["amd", "rocm", "advanced micro devices"], emailDomains: ["amd.com"],
                    loginSuffixes: ["-amd"], logoAsset: "org-amd")
        case .intel:
            Profile(displayName: "Intel", shortLabel: "In", filterNames: ["intel"],
                    githubOrgs: ["intel", "IntelLabs", "intel-analytics", "otcshare", "HabanaAI"],
                    companyPatterns: ["intel", "intellabs", "habana"], emailDomains: ["intel.com", "habana.ai"],
                    loginSuffixes: ["-intel"], brandTile: ("intel", "0068B5"))
        case .ibm:
            Profile(displayName: "IBM", shortLabel: "IB", filterNames: ["ibm"], githubOrgs: ["IBM", "IBMResearch"],
                    companyPatterns: ["ibm", "ibmresearch"], emailDomains: ["ibm.com"], loginSuffixes: ["-ibm"],
                    brandTile: ("IBM", "0F62FE"))
        case .huggingface:
            Profile(displayName: "Hugging Face", shortLabel: "HF", filterNames: ["huggingface", "hf"],
                    githubOrgs: ["huggingface"], companyPatterns: ["hugging face", "huggingface"],
                    emailDomains: ["huggingface.co"], logoAsset: "org-huggingface")
        case .mistral:
            Profile(displayName: "Mistral AI", shortLabel: "Mi", filterNames: ["mistral"], githubOrgs: ["mistralai"],
                    companyPatterns: ["mistral", "mistralai"], emailDomains: ["mistral.ai"], logoAsset: "org-mistral")
        case .meta:
            Profile(displayName: "Meta", shortLabel: "Me", filterNames: ["meta", "facebook"],
                    githubOrgs: ["facebook", "facebookresearch", "meta-llama"],
                    companyPatterns: ["meta", "facebook", "fb"], emailDomains: ["meta.com", "fb.com"], logoAsset: "org-meta")
        case .google:
            Profile(displayName: "Google", shortLabel: "G", filterNames: ["google"],
                    githubOrgs: ["google", "google-deepmind", "google-research", "GoogleCloudPlatform"],
                    companyPatterns: ["google", "deepmind"], emailDomains: ["google.com", "deepmind.com"],
                    logoAsset: "org-google")
        case .daocloud:
            Profile(displayName: "DaoCloud", shortLabel: "DC", filterNames: ["daocloud"], githubOrgs: ["DaoCloud"],
                    companyPatterns: ["daocloud"], emailDomains: ["daocloud.io"], logoAsset: "org-daocloud")
        case .huawei:
            Profile(displayName: "Huawei", shortLabel: "Hw", filterNames: ["huawei"], githubOrgs: ["Huawei", "Ascend"],
                    companyPatterns: ["huawei"], emailDomains: ["huawei.com"], logoAsset: "org-huawei")
        case .microsoft:
            Profile(displayName: "Microsoft", shortLabel: "MS", filterNames: ["microsoft", "msft"],
                    githubOrgs: ["microsoft", "Azure"], companyPatterns: ["microsoft", "msft"],
                    emailDomains: ["microsoft.com"], loginSuffixes: ["-msft"], logoAsset: "org-microsoft")
        case .alibaba:
            Profile(displayName: "Alibaba", shortLabel: "Al", filterNames: ["alibaba", "qwen"],
                    githubOrgs: ["alibaba", "QwenLM"], companyPatterns: ["alibaba", "aliyun", "qwen"],
                    emailDomains: ["alibaba-inc.com", "alibaba.com", "aliyun.com"], logoAsset: "org-alibaba")
        case .antgroup:
            Profile(displayName: "Ant Group", shortLabel: "An", filterNames: ["ant", "antgroup"],
                    githubOrgs: ["antgroup", "inclusionAI"], companyPatterns: ["ant group", "antgroup", "ant financial"],
                    emailDomains: ["antgroup.com", "antfin.com"], logoAsset: "org-antgroup")
        case .bytedance:
            Profile(displayName: "ByteDance", shortLabel: "BD", filterNames: ["bytedance"], githubOrgs: ["bytedance"],
                    companyPatterns: ["bytedance", "byte dance"], emailDomains: ["bytedance.com"],
                    logoAsset: "org-bytedance")
        case .moonshot:
            Profile(displayName: "Moonshot AI", shortLabel: "Mo", filterNames: ["moonshot", "kimi"],
                    githubOrgs: ["MoonshotAI"], companyPatterns: ["moonshot", "moonshotai", "kimi"],
                    emailDomains: ["moonshot.cn", "msh.team"], logoAsset: "org-moonshot")
        case .arm:
            Profile(displayName: "Arm", shortLabel: "Ar", filterNames: ["arm"], githubOrgs: ["ARM-software"],
                    companyPatterns: ["arm"], emailDomains: ["arm.com"], brandTile: ("arm", "0091BD"))
        case .samsung:
            Profile(displayName: "Samsung", shortLabel: "Sa", filterNames: ["samsung"],
                    githubOrgs: ["Samsung", "SamsungLabs"], companyPatterns: ["samsung"], emailDomains: ["samsung.com"],
                    brandTile: ("S", "1428A0"))
        case .embeddedllm:
            Profile(displayName: "EmbeddedLLM", shortLabel: "EL", filterNames: ["embeddedllm"],
                    githubOrgs: ["EmbeddedLLM"], companyPatterns: ["embeddedllm"], emailDomains: ["embeddedllm.com"],
                    brandTile: ("E", "2E1A47"))
        case .cohere:
            Profile(displayName: "Cohere", shortLabel: "Co", filterNames: ["cohere"],
                    githubOrgs: ["cohere-ai", "Cohere-Labs"], companyPatterns: ["cohere"],
                    emailDomains: ["cohere.com", "cohere.ai"], loginSuffixes: ["-cohere"], logoAsset: "org-cohere")
        case .llmd:
            Profile(displayName: "llm-d", shortLabel: "ld", filterNames: ["llm-d", "llmd"],
                    githubOrgs: ["llm-d", "llm-d-incubation"], companyPatterns: ["llm d"], logoAsset: "org-llmd")
        }
    }

    /// Whether a profile's company field names this org, word by word: "intel" matches
    /// "@intel" and "Intel Corporation" but not "Intelligence".
    func matches(company: String) -> Bool {
        let words = " " + company.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
        return companyPatterns.contains { words.contains(" \($0) ") }
    }

    /// Whether a commit email domain is one of the org's, or a subdomain of one (`us.ibm.com`).
    func matches(emailDomain domain: String) -> Bool {
        emailDomains.contains { domain == $0 || domain.hasSuffix(".\($0)") }
    }
}
