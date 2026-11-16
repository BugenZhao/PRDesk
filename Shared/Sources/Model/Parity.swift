import Foundation

/// The Rust parity agent's pipeline (SPEC §3.2): staging PRs it opens on the fork, which Bugen
/// reviews, and the upstream PRs promoted from the approved ones. An adoption's staging PR is built
/// on someone else's upstream PR, which promoting pushes the fixes onto (`Adoption`).
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

    private static let adoptPrefix = "richard/adopt-"

    /// `richard/adopt-<n>-<slug>` gives `<n>`, the upstream PR the staging PR adopts.
    static func adoptedNumber(_ headRef: String?) -> Int? {
        guard let headRef, headRef.hasPrefix(adoptPrefix) else { return nil }
        return Int(headRef.dropFirst(adoptPrefix.count).prefix(while: \.isNumber))
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
    static func sections(of rows: [ItemRow], adoptions: Adoptions = Adoptions()) -> [ListSection: [ItemRow]] {
        let upstreamRows = rows.filter(\.item.isParityUpstream)
        let (upstreamOf, stagingOf) = pairs(staging: rows.map(\.item).filter(\.isParityStaging), upstream: upstreamRows.map(\.item))

        let upstreamIDs = Set(upstreamRows.map(\.item.id))
        var result: [ListSection: [ItemRow]] = [:]
        for var row in rows {
            let item = row.item
            let section: ListSection?
            if item.isParityStaging {
                let adoption = adoptions.byStaging[item.id]
                let upstream = adoption?.upstream ?? upstreamOf[item.id]
                row.paired = upstream
                if adoption.map({ !$0.isPromoted }) ?? false {
                    // Before the promote, the adopted PR is still its author's alone; the staging PR
                    // goes through review like any other.
                    section = Self.stagingSection(of: row)
                } else if upstream != nil {
                    // Listed through its upstream PR, where the work is now (Upstream, then Landed).
                    section = nil
                } else {
                    section = Self.stagingSection(of: row)
                }
            } else if let adoption = adoptions.byUpstream[item.id], adoption.isPromoted {
                // A promoted adoption is listed as its upstream PR, which stays on the dashboard too.
                row.paired = adoption.staging
                section = item.isOpen ? .parityUpstream : .parityLanded
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
    /// Where a staging PR not (or no longer) listed through its upstream PR goes.
    private static func stagingSection(of row: ItemRow) -> ListSection {
        let item = row.item
        if !item.isOpen { return .parityRejected }
        if item.isDraft { return .parityParked }
        if row.insight.isApprovedByMe { return .parityApproved }
        return row.insight.turn == .me ? .parityReview : .parityDiscussing
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

    /// A staging PR that adopts someone else's upstream PR (the runbook's §8b): built from that PR's
    /// head, reviewed on the fork, and promoted by pushing the fixes onto the author's branch under
    /// the viewer's name, rather than by opening a PR of the viewer's own.
    struct Adoption: Hashable, Sendable {
        var staging: Item
        /// The adopted PR, when it is stored (`label:rust` brings in all of them).
        var upstream: Item?
        /// The fixes are on the upstream PR: it carries a commit by the viewer (who never commits to
        /// someone else's PR otherwise) and isn't closed unmerged.
        var isPromoted: Bool
        /// The viewer's comments on the upstream PR from this on count as posting the comment the
        /// agent drafted: since the staging PR was opened, or the viewer approved it.
        var since: Date
    }

    struct Adoptions: Sendable {
        var byStaging: [Item.ID: Adoption] = [:]
        var byUpstream: [Item.ID: Adoption] = [:]

        func of(_ item: Item) -> Adoption? { byStaging[item.id] ?? byUpstream[item.id] }
    }

    /// The comment for the viewer to post on an adopted PR, which the agent drafts in the staging
    /// PR's body: under a heading that names a draft comment, the first fenced block, or else the
    /// blockquote, up to the next heading.
    static func draftedComment(inBody body: String) -> String? {
        let lines = body.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { line in
            let lower = line.lowercased()
            return line.hasPrefix("#") && lower.contains("draft") && lower.contains("comment")
        }) else { return nil }
        let section = lines[(start + 1)...].prefix { !$0.hasPrefix("#") }

        if let open = section.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            let fence = String(section[open].trimmingCharacters(in: .whitespaces).prefix { $0 == "`" })
            let content = section[(open + 1)...].prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(fence) }
            return nonEmpty(content.joined(separator: "\n"))
        }
        guard let first = section.firstIndex(where: { $0.hasPrefix(">") }) else { return nil }
        let quote = section[first...].prefix { $0.hasPrefix(">") }.map { line in
            let rest = line.dropFirst()
            return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
        }
        return nonEmpty(quote.joined(separator: "\n"))
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The adoptions among `items`. An upstream PR adopted more than once (closed and staged again)
    /// goes with the open staging PR, then the newest.
    static func adoptions(in items: [Item], viewer: String?) -> Adoptions {
        let staged = items.filter { $0.isParityStaging && adoptedNumber($0.headRef) != nil }
        guard !staged.isEmpty else { return Adoptions() }
        var upstreamByNumber: [Int: Item] = [:]
        for item in items where item.isUpstream && item.kind == .pullRequest {
            upstreamByNumber[item.number] = item
        }
        var result = Adoptions()
        for staging in staged {
            let upstream = adoptedNumber(staging.headRef).flatMap { upstreamByNumber[$0] }
            let promoted = upstream.map { upstream in
                upstream.state != .closed && (upstream.commitAuthors ?? []).contains { sameLogin($0, viewer) }
            } ?? false
            let approval = viewer.flatMap(staging.review(by:)).flatMap { $0.state == "APPROVED" ? $0.submittedAt : nil }
            let adoption = Adoption(staging: staging, upstream: upstream, isPromoted: promoted, since: max(staging.createdAt, approval ?? .distantPast))
            result.byStaging[staging.id] = adoption
            if let upstream {
                if let current = result.byUpstream[upstream.id],
                   current.staging.isOpen && !staging.isOpen || current.staging.isOpen == staging.isOpen && current.staging.createdAt > staging.createdAt
                {
                    continue
                }
                result.byUpstream[upstream.id] = adoption
            }
        }
        return result
    }
}
