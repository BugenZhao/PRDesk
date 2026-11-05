import Foundation

/// Leading tags of a PR or issue title, shown dimmed so the subject stands out:
/// `[Core][Bugfix] `, `[Bug]: `, `fix(rust/chat): `, `feat: `, `Rust Frontend: `.
enum TitlePrefix {
    static func split(_ title: String) -> (prefix: Substring, rest: Substring) {
        var index = title.startIndex
        if let match = title.prefixMatch(of: /(?:\[[^\]\n]{1,40}\]\s*)+(?::\s+)?/) {
            // Issue templates write "[Bug]: …"; the colon belongs to the prefix.
            index = match.range.upperBound
        } else if let match = title.prefixMatch(of: /[A-Za-z][\w .\/-]{0,24}(?:\([^)\n]{1,40}\))?!?:\s+/) {
            // A short label before ": ", optionally with a "(scope)" and "!". Only without brackets:
            // after "[Bug]: " a colon is part of the subject ("System crash: …").
            index = match.range.upperBound
        }
        // Never dim the whole title.
        guard index < title.endIndex else { return ("", title[...]) }
        return (title[..<index], title[index...])
    }
}

extension TitlePrefix {
    /// Short forms of common tags, from the tags of vLLM's commits and of the items here. Matched
    /// ignoring case, spaces, `-` and `_` ("RustFrontend", "rust-frontend"); a tag that maps to
    /// itself is kept as it is.
    private static let abbreviations: [String: String] = [
        "rust frontend": "RF",
        "bugfix": "Fix",
        "frontend": "FE",
        "feature": "Feat",
        "performance": "Perf",
        "benchmark": "Bench",
        "security": "Sec",
        "spec decode": "SD",
        "metrics": "Metr",
        "kernel": "Kern",
        "ci/build": "CI",
        "docs": "Doc",
        "refactor": "Refac",
        "model runner v2": "MRV2",
        "quantization": "Quant",
        "attention": "Attn",
        "multimodal": "MM",
        "kv offload": "KVO",
        "kv connector": "KVC",
        "structured output": "SO",
        "structured outputs": "SO",
        "hardware": "HW",
        "moe refactor": "MoE Ref",
        "torch.compile": "compile",
        "pooling": "Pool",
        "auxoutput": "Aux",
        "observability": "Obs",
        "renderer": "Render",
        "tests": "Test",
        "tool parser": "Tool Parser",
    ]

    private static let lookup = Dictionary(abbreviations.map { (squashed($0.key), $0.value) }) { first, _ in first }

    private static func squashed(_ tag: some StringProtocol) -> String {
        String(tag.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" })
    }

    /// A tag's short form: from the table, else the initials of a tag of several plain words
    /// ("Spec Decode" → "SD"), else the tag itself.
    static func abbreviate(tag: Substring) -> String {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        if let short = lookup[squashed(tag)] { return short }
        let words = tag.split(separator: " ")
        if words.count > 1, words.allSatisfy({ $0.allSatisfy(\.isLetter) }) {
            return String(words.compactMap(\.first)).uppercased()
        }
        return tag
    }

    /// The prefix with its tags shortened, e.g. "[Rust Frontend][Bugfix] " → "[RF][Fix] " and
    /// "fix(rust): " → "fix: "; nil when that saves nothing.
    static func abbreviate(_ prefix: Substring) -> String? {
        let short: String
        if prefix.hasPrefix("[") {
            let tags = prefix.matches(of: /\[([^\]\n]+)\]/).map { "[\(abbreviate(tag: $0.1))]" }
            short = tags.joined() + " "
        } else if let match = prefix.prefixMatch(of: /([A-Za-z][\w .\/-]*?)(?:\([^)\n]*\))?!?:\s+/) {
            short = abbreviate(tag: match.1) + ": "
        } else {
            return nil
        }
        return short.count < prefix.count ? short : nil
    }
}
