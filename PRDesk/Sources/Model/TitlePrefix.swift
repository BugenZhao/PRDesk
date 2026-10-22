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
