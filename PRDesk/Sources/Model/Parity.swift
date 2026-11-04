import Foundation

/// The Rust parity agent's pipeline (SPEC §3.2): staging PRs it opens on the fork, which Bugen
/// reviews, and the upstream PRs promoted from the approved ones.
enum Parity {
    static let repo = "BugenZhao/vllm"
    /// The agent's GitHub App. GraphQL names it `richard-for-bugen`; its commits and REST show
    /// `richard-for-bugen[bot]`.
    static let bot = "richard-for-bugen"
    /// The fork search for the agent's staging PRs.
    static let qualifier = "is:pr author:app/\(bot)"

    static func isBot(_ login: String?) -> Bool {
        guard let login else { return false }
        return sameLogin(login, bot) || sameLogin(login, "\(bot)[bot]")
    }

    private static let stagingPrefix = "richard/parity-"
    private static let upstreamPrefix = "bz/rust-parity-"

    /// What pairs a staging branch with its upstream one: `richard/parity-fix-<slug>` and
    /// `richard/parity-impl-<slug>` give `<slug>`; run PRs keep their `run-` prefix on both sides.
    static func stagingSlug(_ headRef: String?) -> String? {
        guard let headRef, headRef.hasPrefix(stagingPrefix) else { return nil }
        let rest = headRef.dropFirst(stagingPrefix.count)
        for kind in ["fix-", "impl-"] where rest.hasPrefix(kind) {
            return String(rest.dropFirst(kind.count))
        }
        return String(rest)
    }

    /// `bz/rust-parity-<slug>` gives `<slug>`.
    static func upstreamSlug(_ headRef: String?) -> String? {
        guard let headRef, headRef.hasPrefix(upstreamPrefix) else { return nil }
        return String(headRef.dropFirst(upstreamPrefix.count))
    }

    /// The sections of the Parity tab, top to bottom.
    static let sections: [ListSection] = [.parityReview, .parityDiscussing, .parityApproved, .parityUpstream, .parityParked, .parityLanded, .parityRejected]

    /// Groups staging PRs and the upstream PRs promoted from them into the Parity tab's sections,
    /// each row paired with its other end. Rows keep their order within a section.
    static func sections(of rows: [ItemRow]) -> [ListSection: [ItemRow]] {
        let upstreamRows = rows.filter(\.item.isParityUpstream)
        let (upstreamOf, stagingOf) = pairs(staging: rows.map(\.item).filter(\.isParityStaging), upstream: upstreamRows.map(\.item))

        let upstreamIDs = Set(upstreamRows.map(\.item.id))
        var result: [ListSection: [ItemRow]] = [:]
        for var row in rows {
            let item = row.item
            let section: ListSection?
            if item.isParityStaging {
                let upstream = upstreamOf[item.id]
                row.paired = upstream
                if upstream != nil {
                    // Listed through its upstream PR, where the work is now (Upstream, then Landed).
                    section = nil
                } else if !item.isOpen {
                    section = .parityRejected
                } else if item.isDraft {
                    section = .parityParked
                } else if row.insight.isApprovedByMe {
                    section = .parityApproved
                } else {
                    section = row.insight.turn == .me ? .parityReview : .parityDiscussing
                }
            } else if upstreamIDs.contains(item.id), item.state != .closed {
                row.paired = stagingOf[item.id]
                section = item.isOpen ? .parityUpstream : .parityLanded
            } else {
                section = nil
            }
            if let section { result[section, default: []].append(row) }
        }
        return result
    }
    /// Pairs staging PRs with the upstream PRs promoted from them, by slug. Several upstream PRs can
    /// share a slug (one closed and promoted again): the open one wins, then the newest. Closed ones
    /// without a merge pair with nothing. An upstream PR pairs back with the newest staging PR of
    /// its slug.
    ///
    /// The agent sometimes shortens the slug when promoting (`parity-fix-drop-incomplete-call-markup`
    /// became `bz/rust-parity-drop-incomplete-call`), so a staging PR without an exact match takes an
    /// upstream PR no staging PR has the slug of, opened after it, with its title or with a slug
    /// that its own starts with up to a `-`: by title first, then the longest slug.
    static func pairs(staging: [Item], upstream: [Item]) -> (upstreamOf: [Item.ID: Item], stagingOf: [Item.ID: Item]) {
        var upstreamBySlug: [String: Item] = [:]
        for item in upstream where item.state != .closed {
            guard let slug = upstreamSlug(item.headRef) else { continue }
            if let current = upstreamBySlug[slug], current.isOpen || (!item.isOpen && current.createdAt > item.createdAt) {
                continue
            }
            upstreamBySlug[slug] = item
        }
        var stagingBySlug: [String: Item] = [:]
        for item in staging {
            if let slug = stagingSlug(item.headRef), stagingBySlug[slug].map({ $0.createdAt < item.createdAt }) ?? true {
                stagingBySlug[slug] = item
            }
        }

        var upstreamOf: [Item.ID: Item] = [:]
        var stagingOf: [Item.ID: Item] = [:]
        var unmatched: [(item: Item, slug: String)] = []
        for item in staging {
            guard let slug = stagingSlug(item.headRef) else { continue }
            if let upstream = upstreamBySlug[slug] {
                upstreamOf[item.id] = upstream
                stagingOf[upstream.id] = stagingBySlug[slug]
            } else {
                unmatched.append((item, slug))
            }
        }
        var unclaimed = upstreamBySlug.filter { stagingBySlug[$0.key] == nil }
        for (item, slug) in unmatched.sorted(by: { $0.item.createdAt > $1.item.createdAt }) {
            let candidates = unclaimed.filter { upstreamSlug, upstream in
                upstream.createdAt >= item.createdAt && (upstream.title == item.title || slug.hasPrefix(upstreamSlug + "-"))
            }
            let rank = { (candidate: (key: String, value: Item)) in (candidate.value.title == item.title ? 1 : 0, candidate.key.count) }
            guard let (upstreamSlug, upstream) = candidates.max(by: { rank($0) < rank($1) }) else { continue }
            unclaimed[upstreamSlug] = nil
            upstreamOf[item.id] = upstream
            stagingOf[upstream.id] = item
        }
        return (upstreamOf, stagingOf)
    }
}
