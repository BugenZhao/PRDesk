import Foundation

/// The icon for an item's kind and state.
enum StateIcon: Hashable {
    /// A template image in the asset catalog: the PR state glyphs (GitHub Octicons).
    case asset(String)
    case symbol(String)
}

/// GitHub's state colors, named for what they mean; each platform picks its system color.
enum StateTint: Hashable, Sendable {
    case green, gray, yellow, purple, red
}

extension Item {
    var hasConflicts: Bool { isOpen && mergeable == "CONFLICTING" }

    /// Each PR state has its own glyph; draft wins over conflicts. Issues use SF Symbols.
    var stateIcon: StateIcon {
        switch (kind, state) {
        case (.pullRequest, .open): .asset(isDraft ? "pr-draft" : hasConflicts ? "pr-conflict" : "pr-open")
        case (.pullRequest, .merged): .asset("pr-merged")
        case (.pullRequest, .closed): .asset("pr-closed")
        case (.issue, .open): .symbol("circle.circle")
        case (.issue, _): .symbol("checkmark.circle")
        }
    }

    var stateDescription: String {
        switch (kind, state) {
        case (.pullRequest, .open): isDraft ? "Draft" : hasConflicts ? "Open, merge conflicts" : "Open"
        case (_, .merged): "Merged"
        case (_, .closed): "Closed"
        case (.issue, .open): "Open"
        }
    }

    /// An open PR Merger is merging draws its open icon purple, the merge color, unless what the
    /// icon shows matters more (a draft, conflicts).
    private func showsMerging(_ isMerging: Bool) -> Bool {
        isMerging && kind == .pullRequest && state == .open && !isDraft && !hasConflicts
    }

    func stateTint(isMerging: Bool) -> StateTint {
        showsMerging(isMerging) ? .purple : stateTint
    }

    func stateDescription(isMerging: Bool) -> String {
        showsMerging(isMerging) ? "Open, being merged by Merger" : stateDescription
    }

    /// GitHub's state colors: open green, draft gray, merged/completed purple, closed PR red;
    /// an open, ready PR with merge conflicts is yellow.
    var stateTint: StateTint {
        switch (kind, state) {
        case (.pullRequest, .open): isDraft ? .gray : hasConflicts ? .yellow : .green
        case (.pullRequest, .merged): .purple
        case (.pullRequest, .closed): .red
        case (.issue, .open): .green
        case (.issue, _): .purple
        }
    }
}
