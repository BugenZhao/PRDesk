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
    static let sections: [ListSection] = [.parityReview, .parityDiscussing, .parityApproved, .parityUpstream, .parityParked, .parityClosed]

    /// Groups staging PRs and the viewer's upstream parity PRs into the Parity tab's sections,
    /// each row linked to its other end. Rows keep their order within a section.
    static func sections(of rows: [ItemRow], viewer: String?) -> [ListSection: [ItemRow]] {
        let upstreamRows = rows.filter { row in
            row.item.isUpstream && row.item.kind == .pullRequest && sameLogin(row.item.author, viewer)
                && upstreamSlug(row.item.headRef) != nil
        }
        // Several upstream PRs can share a slug (one closed and promoted again): the open one wins,
        // then the newest. Closed ones without a merge pair with nothing.
        var upstreamBySlug: [String: Item] = [:]
        for row in upstreamRows where row.item.state != .closed {
            guard let slug = upstreamSlug(row.item.headRef) else { continue }
            if let current = upstreamBySlug[slug], current.isOpen || (!row.item.isOpen && current.createdAt > row.item.createdAt) {
                continue
            }
            upstreamBySlug[slug] = row.item
        }
        var stagingBySlug: [String: Item] = [:]
        for row in rows where row.item.isParityStaging {
            if let slug = stagingSlug(row.item.headRef), stagingBySlug[slug].map({ $0.createdAt < row.item.createdAt }) ?? true {
                stagingBySlug[slug] = row.item
            }
        }

        let upstreamIDs = Set(upstreamRows.map(\.item.id))
        var result: [ListSection: [ItemRow]] = [:]
        for var row in rows {
            let item = row.item
            let section: ListSection?
            if item.isParityStaging {
                let upstream = stagingSlug(item.headRef).flatMap { upstreamBySlug[$0] }
                if upstream?.state == .merged {
                    row.parityLink = ParityLink(kind: .landed, number: upstream!.number)
                    section = .parityClosed
                } else if !item.isOpen {
                    section = .parityClosed
                } else if item.isDraft {
                    section = .parityParked
                } else if upstream != nil {
                    // Listed through its upstream PR, where the work is now.
                    section = nil
                } else if row.insight.isApprovedByMe {
                    section = .parityApproved
                } else {
                    section = row.insight.turn == .me ? .parityReview : .parityDiscussing
                }
            } else if upstreamIDs.contains(item.id), item.isOpen {
                if let staging = upstreamSlug(item.headRef).flatMap({ stagingBySlug[$0] }) {
                    row.parityLink = ParityLink(kind: .staging, number: staging.number)
                }
                section = .parityUpstream
            } else {
                section = nil
            }
            if let section { result[section, default: []].append(row) }
        }
        return result
    }
}

/// The other end of a parity row: the staging PR of an upstream PR, or the merged upstream PR of a
/// staging one.
struct ParityLink: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// On an upstream PR: the staging PR it was promoted from.
        case staging
        /// On a staging PR: the upstream PR that merged it.
        case landed
    }

    var kind: Kind
    var number: Int

    var label: String {
        switch kind {
        case .staging: "staging #\(number)"
        case .landed: "landed #\(number)"
        }
    }
}
