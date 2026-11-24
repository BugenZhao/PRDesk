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

/// See `Item.draftToggle`.
struct DraftToggle: Hashable, Sendable {
    /// Converts to a draft, rather than marking ready for review.
    var makesDraft: Bool
    var title: String
    /// The state the click switches to: the PR glyphs, or play / pause for Resume / Park.
    var icon: StateIcon
    /// For the error: "Couldn't \(verb) #123".
    var verb: String
    var help: String
}

extension Item {
    var hasConflicts: Bool { isOpen && mergeable == "CONFLICTING" }

    /// The button that flips an open PR between draft and ready for review; nil for issues and
    /// closed PRs. On a parity staging PR it parks or resumes the item (SPEC §3.2).
    var draftToggle: DraftToggle? {
        guard kind == .pullRequest, isOpen else { return nil }
        return switch (isParityStaging, isDraft) {
        case (true, true): DraftToggle(
                makesDraft: false, title: "Resume", icon: .symbol("play"), verb: "resume",
                help: "Mark ready for review: the parity agent picks the item up again"
            )
        case (true, false): DraftToggle(
                makesDraft: true, title: "Park", icon: .symbol("pause"), verb: "park",
                help: "Convert to a draft: the parity agent parks the item as backlog"
            )
        case (false, true): DraftToggle(
                makesDraft: false, title: "Ready for Review", icon: .asset("pr-open"), verb: "mark ready for review",
                help: "Mark the pull request ready for review, which requests reviews from its code owners"
            )
        case (false, false): DraftToggle(
                makesDraft: true, title: "Convert to Draft", icon: .asset("pr-draft"), verb: "convert to draft",
                help: "Convert the pull request to a draft"
            )
        }
    }

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

    /// An open PR Merger is merging draws its icon purple, the merge color: the open glyph, or the
    /// conflict one while Merger works through (mechanical) conflicts itself. A draft stays a draft.
    private func showsMerging(_ isMerging: Bool) -> Bool {
        isMerging && kind == .pullRequest && state == .open && !isDraft
    }

    func stateTint(isMerging: Bool) -> StateTint {
        showsMerging(isMerging) ? .purple : stateTint
    }

    func stateDescription(isMerging: Bool) -> String {
        guard showsMerging(isMerging) else { return stateDescription }
        return hasConflicts ? "Open, being merged by Merger (merge conflicts)" : "Open, being merged by Merger"
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
