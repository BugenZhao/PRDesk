import Foundation

/// What the Commits tab diffs: the whole PR, one commit, or from one commit to another.
enum CommitRange: Hashable, Sendable {
    /// Everything, as the Files tab shows it.
    case all
    /// One commit against its first parent.
    case commit(String)
    /// From `base` to `head`, as GitHub compares them (from their merge base).
    case compare(base: String, head: String)

    /// Tells the page's remembered scroll and expanded files apart.
    var key: String {
        switch self {
        case .all: "all"
        case let .commit(sha): sha
        case let .compare(base, head): "\(base)...\(head)"
        }
    }
}

/// A PR's commits and force pushes as the Commits tab lists them, and the ranges it offers.
struct CommitHistory: Sendable {
    struct Push: Identifiable, Sendable {
        var id: String
        var actor: String?
        var at: Date
        var before: String?
        var after: String?
    }

    enum Row: Identifiable, Sendable {
        case commit(PRCommit, isNew: Bool)
        case push(Push)

        var id: String {
            switch self {
            case let .commit(commit, _): commit.oid
            case let .push(push): Self.pushPrefix + push.id
            }
        }

        static let pushPrefix = "push:"
    }

    /// The ranges the tab opens with, in the order the menu lists them.
    enum Preset: CaseIterable, Sendable {
        case sinceReview, sinceViewed, all

        var title: String {
            switch self {
            case .sinceReview: "Since your last review"
            case .sinceViewed: "Since you last looked"
            case .all: "All changes"
            }
        }
    }

    /// Oldest first.
    let commits: [PRCommit]
    /// Newest first, force pushes between the commits.
    let rows: [Row]
    /// The commit of the viewer's latest review.
    let lastReview: String?
    /// The head when the viewer last opened the PR.
    let previousHead: String?

    var head: String? { commits.last?.oid }

    /// - Parameters:
    ///   - previousHead: the head stored when the viewer last opened the PR.
    ///   - previousSeenAt: when they last saw it; stands in for `previousHead` before one was
    ///     stored, or when that head is gone from the branch.
    init(detail: ItemDetail, viewer: String?, previousHead: String?, previousSeenAt: Date?) {
        let commits = detail.commits ?? []
        self.commits = commits
        self.previousHead = previousHead
        lastReview = viewer.flatMap { viewer in
            detail.entries.last { entry in
                [.approved, .changesRequested, .reviewed].contains(entry.kind) && entry.oid != nil
                    && entry.actor.map { sameLogin($0, viewer) } == true
            }?.oid
        }

        let newSince: Int? = previousHead.flatMap { head in commits.firstIndex { $0.oid == head } }.map { $0 + 1 }
        var rows: [Row] = commits.enumerated().reversed().map { index, commit in
            let isNew = if let newSince { index >= newSince } else if let previousSeenAt { commit.committedAt > previousSeenAt } else { false }
            return .commit(commit, isNew: isNew)
        }
        // Each force push just above the head it left, or by time once later pushes rewrote that.
        // Newest first, so an older push at the same spot goes in below it.
        for entry in detail.entries.filter({ $0.kind == .forcePush }).reversed() {
            let push = Push(id: entry.id, actor: entry.actor, at: entry.at, before: entry.beforeOid, after: entry.oid)
            let index = rows.firstIndex { row in
                if case let .commit(commit, _) = row { commit.oid == push.after } else { false }
            } ?? rows.firstIndex { row in
                if case let .commit(commit, _) = row { commit.committedAt <= push.at } else { false }
            } ?? rows.endIndex
            rows.insert(.push(push), at: index)
        }
        self.rows = rows
    }

    /// The preset's range, or nil when it has none (no review, nothing seen, nothing new).
    func range(_ preset: Preset) -> CommitRange? {
        guard let head else { return preset == .all ? .all : nil }
        switch preset {
        case .sinceReview:
            guard let lastReview, lastReview != head else { return nil }
            return .compare(base: lastReview, head: head)
        case .sinceViewed:
            guard let previousHead, previousHead != head else { return nil }
            return .compare(base: previousHead, head: head)
        case .all:
            return .all
        }
    }

    /// Since the viewer's last review, else since they last looked, else everything.
    var defaultPreset: Preset {
        Preset.allCases.first { range($0) != nil } ?? .all
    }

    /// The range the selected rows cover: one commit, the stretch from the oldest selected to the
    /// newest, or a force push alone.
    func range(selecting ids: Set<String>) -> CommitRange? {
        let indices = commits.indices.filter { ids.contains(commits[$0].oid) }
        if let low = indices.first, let high = indices.last {
            if low == high { return .commit(commits[low].oid) }
            guard let base = commits[low].parentOid else { return .commit(commits[high].oid) }
            return .compare(base: base, head: commits[high].oid)
        }
        for row in rows {
            if case let .push(push) = row, ids.contains(row.id), let before = push.before, let after = push.after {
                return .compare(base: before, head: after)
            }
        }
        return nil
    }

    /// Whether a compare starts from a commit no longer on the branch, so a rebase onto the base
    /// branch shows up in it too.
    func isRewritten(_ range: CommitRange) -> Bool {
        guard case let .compare(base, _) = range else { return false }
        return !commits.contains { $0.oid == base || $0.parentOid == base }
    }

    /// The commit with this full or abbreviated sha.
    func commit(matching sha: String) -> PRCommit? {
        let sha = sha.lowercased()
        return commits.first { $0.oid.hasPrefix(sha) }
    }
}
