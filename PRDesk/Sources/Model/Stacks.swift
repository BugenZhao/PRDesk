import Foundation

/// Where a row sits on its stack's rail in the list: which neighbors it joins.
struct StackRail: Hashable, Sendable {
    /// How a row joins the next one along the rail: through a GitHub stack, or a base branch that
    /// is another PR's head branch (a stack GitHub doesn't know of).
    enum Link: Hashable, Sendable { case stack, branch }

    var above: Link?
    var below: Link?
}

/// Keeps PR stacks together in the list (SPEC §4.1): the members of one stack within a section
/// follow one another, the base first, where the base itself sorts.
enum Stacks {
    /// The repository's default branch, which a stack's base targets.
    private static let defaultBranch = "main"

    /// `rows`, already in their section's order, with each stack's members gathered at the place
    /// of the one closest to the base, and their rails set. Stacks are GitHub's stacks, and chains
    /// of PRs whose base branch is another PR's head branch in the same repository.
    static func grouped(_ rows: [ItemRow]) -> [ItemRow] {
        // Most sections have no stacks at all.
        guard rows.count > 1, rows.contains(where: { $0.item.stackNumber != nil || ($0.item.baseRef ?? defaultBranch) != defaultBranch }) else {
            return rows.map(clearingRail)
        }
        let count = rows.count
        var root = Array(0 ..< count)
        func find(_ i: Int) -> Int {
            var i = i
            while root[i] != i {
                root[i] = root[root[i]]
                i = root[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let (x, y) = (find(a), find(b))
            if x != y { root[max(x, y)] = min(x, y) }
        }

        // Members of one GitHub stack.
        var byStack: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            guard let key = stackKey(row.item) else { continue }
            if let other = byStack[key] { union(index, other) } else { byStack[key] = index }
        }
        // PRs on another PR's branch.
        var byHead: [String: Int] = [:]
        for (index, row) in rows.enumerated() where row.item.kind == .pullRequest {
            guard let head = row.item.headRef else { continue }
            byHead["\(row.item.repo.lowercased()):\(head)"] = index
        }
        var parent = [Int?](repeating: nil, count: count)
        for (index, row) in rows.enumerated() where row.item.kind == .pullRequest {
            guard let base = row.item.baseRef, base != defaultBranch,
                  let other = byHead["\(row.item.repo.lowercased()):\(base)"], other != index
            else { continue }
            parent[index] = other
            union(index, other)
        }

        var members: [Int: [Int]] = [:]
        for index in 0 ..< count {
            members[find(index), default: []].append(index)
        }
        guard members.count < count else { return rows.map(clearingRail) }

        // Depth along the stack: GitHub's position, or one more than the PR it is based on.
        var depths = [Int?](repeating: nil, count: count)
        func depth(_ i: Int, _ seen: Int = 0) -> Int {
            if let known = depths[i] { return known }
            let value: Int = if let position = rows[i].item.stackPosition {
                position
            } else if let parent = parent[i], seen < count {
                depth(parent, seen + 1) + 1
            } else {
                0
            }
            depths[i] = value
            return value
        }

        var result: [ItemRow] = []
        result.reserveCapacity(count)
        var placed: Set<Int> = []
        // Each group goes where its base sorts.
        let order: [Int: [Int]] = members.mapValues { group in
            // At one depth, a stack's own member before a PR based on a branch beside it.
            group.sorted { a, b in
                let (x, y) = (rows[a].item, rows[b].item)
                return (depth(a), x.stackNumber == nil ? 1 : 0, x.number) < (depth(b), y.stackNumber == nil ? 1 : 0, y.number)
            }
        }
        for index in 0 ..< count {
            let group = order[find(index)]!
            if group.count == 1 {
                result.append(clearingRail(rows[index]))
                continue
            }
            guard group[0] == index, placed.insert(find(index)).inserted else { continue }
            for (offset, member) in group.enumerated() {
                var row = rows[member]
                row.rail = StackRail(
                    above: offset > 0 ? link(rows[group[offset - 1]].item, row.item) : nil,
                    below: offset < group.count - 1 ? link(row.item, rows[group[offset + 1]].item) : nil
                )
                result.append(row)
            }
        }
        return result
    }

    private static func stackKey(_ item: Item) -> String? {
        item.stackNumber.map { "\(item.repo.lowercased())#\($0)" }
    }

    private static func link(_ a: Item, _ b: Item) -> StackRail.Link {
        stackKey(a) != nil && stackKey(a) == stackKey(b) ? .stack : .branch
    }

    private static func clearingRail(_ row: ItemRow) -> ItemRow {
        guard row.rail != nil else { return row }
        var row = row
        row.rail = nil
        return row
    }
}

/// A GitHub stack as the detail query returns it.
struct PRStack: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var position: Int
        var number: Int
        var title: String
        var state: Item.State
        var isDraft: Bool
        /// When it was merged, or closed without merging.
        var closedAt: Date?
        var baseRef: String
        var headRef: String
    }

    var number: Int
    /// Base first.
    var entries: [Entry]
}

/// The stack an item is in, as the detail header shows it: base first, merged runs folded.
struct StackLadder: Equatable {
    struct Rung: Equatable, Identifiable {
        var entry: PRStack.Entry
        /// For a parity staging PR: the upstream PR promoted from it.
        var upstream: Item?
        var id: Int { entry.number }
    }

    /// A line of the ladder: one PR, or PRs merged together (one stack merge) folded into one.
    enum Line: Equatable, Identifiable {
        case rung(Rung)
        case merged([Rung])

        var id: String {
            switch self {
            case let .rung(rung): "#\(rung.id)"
            case let .merged(rungs): "merged-\(rungs.first?.id ?? 0)"
            }
        }
    }

    var repo: String
    /// GitHub's stack number; nil for a chain of PRs on one another's branches.
    var number: Int?
    /// Base first.
    var rungs: [Rung]

    /// Merges a few seconds apart are one stack merge.
    private static let mergeWindow: TimeInterval = 60

    /// Rungs with each run of PRs merged together folded into one line. A PR merged on its own
    /// stays a rung.
    var lines: [Line] {
        var lines: [Line] = []
        var run: [Rung] = []
        func flush() {
            if run.count > 1 { lines.append(.merged(run)) } else { lines += run.map(Line.rung) }
            run = []
        }
        for rung in rungs {
            if rung.entry.state == .merged, let at = rung.entry.closedAt,
               let last = run.last?.entry.closedAt, abs(at.timeIntervalSince(last)) <= Self.mergeWindow
            {
                run.append(rung)
                continue
            }
            flush()
            if rung.entry.state == .merged { run = [rung] } else { lines.append(.rung(rung)) }
        }
        flush()
        return lines
    }

    var mergedCount: Int { rungs.count { $0.entry.state == .merged || $0.upstream?.state == .merged } }

    /// The number of the PR before or after `number` along the stack (`offset` -1 toward the base).
    func neighbor(of number: Int, offset: Int) -> Int? {
        guard let index = rungs.firstIndex(where: { $0.entry.number == number }) else { return nil }
        let target = index + offset
        return rungs.indices.contains(target) ? rungs[target].entry.number : nil
    }

    /// The ladder for `item`: its GitHub stack from the detail, or else the chain of PRs on one
    /// another's branches among `items`. Nil when the item isn't in a stack of two or more.
    static func of(_ item: Item, stack: PRStack?, items: [Item], upstreamOf: (Item) -> Item?) -> StackLadder? {
        guard item.kind == .pullRequest else { return nil }
        let local = items.filter { $0.kind == .pullRequest && $0.repo.caseInsensitiveCompare(item.repo) == .orderedSame }
        let byNumber = Dictionary(local.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        func rung(_ entry: PRStack.Entry) -> Rung {
            Rung(entry: entry, upstream: byNumber[entry.number].flatMap(upstreamOf))
        }
        if let stack, stack.entries.count > 1 {
            return StackLadder(repo: item.repo, number: stack.number, rungs: stack.entries.map(rung))
        }
        func entry(_ item: Item, position: Int) -> PRStack.Entry {
            PRStack.Entry(
                position: position, number: item.number, title: item.title, state: item.state, isDraft: item.isDraft,
                closedAt: item.closedAt, baseRef: item.baseRef ?? "", headRef: item.headRef ?? ""
            )
        }
        // Until the detail comes, the members of its GitHub stack that are here.
        if stack == nil, let number = item.stackNumber {
            let members = local.filter { $0.stackNumber == number }.sorted { ($0.stackPosition ?? 0) < ($1.stackPosition ?? 0) }
            if members.count > 1 {
                return StackLadder(repo: item.repo, number: number, rungs: members.map { rung(entry($0, position: $0.stackPosition ?? 0)) })
            }
        }
        // A chain by branch: down through base branches, up through PRs based on the head branch.
        func pick(_ candidates: [Item]) -> Item? {
            candidates.max { ($0.isOpen ? 1 : 0, $0.number) < ($1.isOpen ? 1 : 0, $1.number) }
        }
        var chain = [item]
        var seen: Set = [item.number]
        while chain.count < 30, let base = chain[0].baseRef, base != "main",
              let below = pick(local.filter { $0.headRef == base && !seen.contains($0.number) })
        {
            chain.insert(below, at: 0)
            seen.insert(below.number)
        }
        while chain.count < 30, let head = chain.last?.headRef,
              let above = pick(local.filter { $0.baseRef == head && $0.isOpen && !seen.contains($0.number) })
        {
            chain.append(above)
            seen.insert(above.number)
        }
        guard chain.count > 1 else { return nil }
        return StackLadder(repo: item.repo, number: nil, rungs: chain.enumerated().map { rung(entry($1, position: $0 + 1)) })
    }
}
