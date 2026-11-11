import Foundation

/// Where a row sits on its stack's rail: its node's lane and the lines through the row. A stack
/// is a tree, since several PRs can be based on one branch (GitHub's own stacks are chains): each
/// PR's first child continues its lane, the others fork into lanes of their own to the right.
struct StackRail: Hashable, Sendable {
    /// How a PR joins the one it is based on: through a GitHub stack, or a base branch that is the
    /// other PR's head branch (a stack GitHub doesn't know of).
    enum Link: Hashable, Sendable { case stack, branch }

    enum Segment: Hashable, Sendable {
        /// From the top of the row down to the node, from the PR this one is based on.
        case up(lane: Int, Link)
        /// From the node down to the bottom of the row, to the PR's first child.
        case down(lane: Int, Link)
        /// Straight through the row, on the way to a PR further down.
        case through(lane: Int, Link)
        /// From the node out to another lane and down, to a child forking off.
        case fork(to: Int, Link)
        /// A short line fading out from the node toward the top or bottom of the row, short of
        /// it: the PR it is based on (`up`) or one based on it is in another section.
        case elsewhereUp(lane: Int)
        case elsewhereDown(lane: Int)
    }

    var lane: Int
    /// Lanes the whole tree uses, so its rows lay their lanes out alike.
    var laneCount: Int
    var segments: [Segment]
    /// Members of the stack in other sections, for the tooltip: the PR it is based on, and those
    /// based on it.
    var belowElsewhere: Int? = nil
    var aboveElsewhere: [Int] = []

    var hasUp: Bool { segments.contains { if case .up = $0 { true } else { false } } }
    var hasDown: Bool { segments.contains { if case .down = $0 { true } else { false } } }
    /// Only the lines in and out of its own node on its own lane.
    var isPlain: Bool {
        segments.allSatisfy { segment in
            switch segment {
            case .up, .down: true
            default: false
            }
        }
    }
}

/// Lays a forest of PRs out as rows: each tree base first, depth first, a PR's first child right
/// after it on its lane, other children after that child's whole subtree, each on a new lane.
enum StackLayout {
    /// `parents[i]`: the node `i` is based on and how. `before` orders siblings, the one to
    /// continue the parent's lane first. Returns nodes in row order with their rails.
    static func layout(parents: [(node: Int, link: StackRail.Link)?], before: (Int, Int) -> Bool) -> [(node: Int, rail: StackRail)] {
        let count = parents.count
        var children = [[Int]](repeating: [], count: count)
        for (node, parent) in parents.enumerated() {
            if let parent, parent.node != node { children[parent.node].append(node) }
        }
        for node in 0 ..< count { children[node].sort(by: before) }

        var order: [Int] = []
        var lanes = [Int](repeating: 0, count: count)
        var visited = [Bool](repeating: false, count: count)
        var nextLane = 1
        func visit(_ node: Int, lane: Int) {
            guard !visited[node] else { return }
            visited[node] = true
            lanes[node] = lane
            order.append(node)
            for (index, child) in children[node].enumerated() {
                if index == 0 {
                    visit(child, lane: lane)
                } else {
                    let forked = nextLane
                    nextLane += 1
                    visit(child, lane: forked)
                }
            }
        }
        let roots = (0 ..< count).filter { parents[$0] == nil }.sorted(by: before)
        for root in roots { visit(root, lane: 0) }
        // A cycle of base branches has no root; break it anywhere.
        for node in 0 ..< count where !visited[node] { visit(node, lane: 0) }

        var rowOf = [Int](repeating: 0, count: count)
        for (row, node) in order.enumerated() { rowOf[node] = row }
        var segments = [[StackRail.Segment]](repeating: [], count: count)
        for (node, parent) in parents.enumerated() {
            guard let parent, parent.node != node, rowOf[parent.node] < rowOf[node] else { continue }
            let (from, to) = (rowOf[parent.node], rowOf[node])
            let lane = lanes[node]
            segments[from].append(lane == lanes[parent.node] ? .down(lane: lane, parent.link) : .fork(to: lane, parent.link))
            for row in from + 1 ..< to { segments[row].append(.through(lane: lane, parent.link)) }
            segments[to].append(.up(lane: lane, parent.link))
        }
        let laneCount = (lanes.max() ?? 0) + 1
        return order.enumerated().map { row, node in
            (node, StackRail(lane: lanes[node], laneCount: laneCount, segments: segments[row]))
        }
    }
}

/// Keeps PR stacks together in the list (SPEC §4.1): the members of one stack within a section
/// follow one another, the base first, where the base itself sorts.
enum Stacks {
    /// The repository's default branch, which a stack's base targets.
    static let defaultBranch = "main"

    /// `rows`, already in their section's order, with each stack's members gathered at the place
    /// of its base, and their rails set. Stacks are GitHub's stacks, and PRs whose base branch is
    /// another PR's head branch in the same repository, which can branch out into trees. Members
    /// among `pool` (the tab's other items) but not in `rows` show as stubs on the rail.
    static func grouped(_ rows: [ItemRow], among pool: [Item] = []) -> [ItemRow] {
        let items = rows.map(\.item)
        // Most sections have no stacks at all.
        func related(_ item: Item) -> Bool { item.stackNumber != nil || (item.baseRef ?? defaultBranch) != defaultBranch }
        let others = elsewhere(of: items, among: pool)
        guard items.contains(where: related) || !others.isEmpty else { return rows.map(clearingRail) }
        let parents = parents(of: items)

        // Stack members in other sections: the PR each row is based on, and those based on it.
        var below = [Int?](repeating: nil, count: rows.count)
        var above = [[Int]](repeating: [], count: rows.count)
        if !others.isEmpty {
            let all = Self.parents(of: items + others)
            for (index, parent) in all.enumerated() {
                guard let parent else { continue }
                if index < rows.count {
                    if parent.node >= rows.count, parents[index] == nil { below[index] = others[parent.node - rows.count].number }
                } else if parent.node < rows.count {
                    above[parent.node].append(others[index - rows.count].number)
                }
            }
        }

        var root = Array(0 ..< rows.count)
        func find(_ i: Int) -> Int {
            var i = i
            while root[i] != i {
                root[i] = root[root[i]]
                i = root[i]
            }
            return i
        }
        for (node, parent) in parents.enumerated() {
            guard let parent else { continue }
            let (x, y) = (find(node), find(parent.node))
            if x != y { root[max(x, y)] = min(x, y) }
        }
        var groups: [Int: [Int]] = [:]
        for index in rows.indices { groups[find(index), default: []].append(index) }

        // Each tree, laid out, goes where its base sorts.
        var laidOut: [Int: [(node: Int, rail: StackRail)]] = [:]
        for (key, members) in groups where members.count > 1 {
            let local = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
            let layout = StackLayout.layout(
                parents: members.map { member in parents[member].flatMap { parent in local[parent.node].map { ($0, parent.link) } } },
                before: { siblingOrder(items[members[$0]], items[members[$1]]) }
            )
            laidOut[key] = layout.map { (members[$0.node], $0.rail) }
        }

        /// Adds stubs for the members elsewhere, where the rail has no line of its own that way.
        func withStubs(_ rail: StackRail?, _ index: Int) -> StackRail? {
            guard below[index] != nil || !above[index].isEmpty else { return rail }
            var rail = rail ?? StackRail(lane: 0, laneCount: 1, segments: [])
            if below[index] != nil, !rail.hasUp { rail.segments.append(.elsewhereUp(lane: rail.lane)) }
            if !above[index].isEmpty, !rail.hasDown { rail.segments.append(.elsewhereDown(lane: rail.lane)) }
            rail.belowElsewhere = below[index]
            rail.aboveElsewhere = above[index].sorted()
            return rail
        }

        var result: [ItemRow] = []
        result.reserveCapacity(rows.count)
        for index in rows.indices {
            guard let tree = laidOut[find(index)] else {
                var row = rows[index]
                row.rail = withStubs(nil, index)
                result.append(row)
                continue
            }
            guard tree.first?.node == index else { continue }
            for (member, rail) in tree {
                var row = rows[member]
                row.rail = withStubs(rail, member)
                result.append(row)
            }
        }
        return result
    }

    /// The items of `pool` not among `items` that could be in a stack with one of them: in the
    /// same GitHub stack, based on one's branch, or holding the branch one is based on.
    private static func elsewhere(of items: [Item], among pool: [Item]) -> [Item] {
        guard !pool.isEmpty else { return [] }
        var stacks: Set<String> = []
        var heads: Set<String> = []
        var bases: Set<String> = []
        var ids: Set<Item.ID> = []
        for item in items {
            ids.insert(item.id)
            guard item.kind == .pullRequest else { continue }
            let repo = item.repo.lowercased()
            if let key = stackKey(item) { stacks.insert(key) }
            if let head = item.headRef { heads.insert("\(repo):\(head)") }
            if let base = item.baseRef, base != defaultBranch { bases.insert("\(repo):\(base)") }
        }
        return pool.filter { item in
            guard item.kind == .pullRequest, !ids.contains(item.id) else { return false }
            let repo = item.repo.lowercased()
            if let key = stackKey(item), stacks.contains(key) { return true }
            if let base = item.baseRef, base != defaultBranch, heads.contains("\(repo):\(base)") { return true }
            if let head = item.headRef, bases.contains("\(repo):\(head)") { return true }
            return false
        }
    }

    /// For each item, the one it is based on among `items`: the member before it in its GitHub
    /// stack, or else the PR whose head branch is its base branch.
    static func parents(of items: [Item]) -> [(node: Int, link: StackRail.Link)?] {
        var byHead: [String: Int] = [:]
        var byStack: [String: [(position: Int, index: Int)]] = [:]
        for (index, item) in items.enumerated() where item.kind == .pullRequest {
            // A branch name can come back on a later PR; the open one, else the first listed.
            if let head = item.headRef {
                let key = "\(item.repo.lowercased()):\(head)"
                if byHead[key].map({ items[$0].isOpen || !item.isOpen }) != true { byHead[key] = index }
            }
            if let key = stackKey(item), let position = item.stackPosition { byStack[key, default: []].append((position, index)) }
        }
        return items.enumerated().map { index, item in
            guard item.kind == .pullRequest else { return nil }
            if let key = stackKey(item), let position = item.stackPosition,
               let below = byStack[key]?.filter({ $0.position < position }).max(by: { $0.position < $1.position })
            {
                return (below.index, .stack)
            }
            if let base = item.baseRef, base != defaultBranch,
               let other = byHead["\(item.repo.lowercased()):\(base)"], other != index
            {
                return (other, .branch)
            }
            return nil
        }
    }

    /// Siblings on one base: a GitHub stack's own next member first (it continues the lane), then
    /// by number.
    static func siblingOrder(_ a: Item, _ b: Item) -> Bool {
        ((a.stackNumber == nil ? 1 : 0), a.number) < ((b.stackNumber == nil ? 1 : 0), b.number)
    }

    private static func stackKey(_ item: Item) -> String? {
        item.stackNumber.map { "\(item.repo.lowercased())#\($0)" }
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

/// The stack an item is in, as the detail header shows it: its GitHub stack and the PRs based on
/// their branches, as a tree from the base, merged runs folded.
struct StackLadder: Equatable {
    struct Rung: Equatable, Identifiable {
        var entry: PRStack.Entry
        /// For a parity staging PR: the upstream PR promoted from it.
        var upstream: Item?
        var rail: StackRail
        /// The PR it is based on, if in the ladder.
        var parent: Int?
        var id: Int { entry.number }
    }

    /// A line of the ladder: one PR, or PRs merged together (one stack merge) folded into one.
    enum Line: Equatable, Identifiable {
        case rung(Rung)
        case merged([Rung], rail: StackRail)

        var id: String {
            switch self {
            case let .rung(rung): "#\(rung.id)"
            case let .merged(rungs, _): "merged-\(rungs.first?.id ?? 0)"
            }
        }
    }

    var repo: String
    /// GitHub's stack number; nil for PRs on one another's branches alone.
    var number: Int?
    /// In row order, the base first.
    var rungs: [Rung]

    /// Merges a few seconds apart are one stack merge.
    private static let mergeWindow: TimeInterval = 60

    /// Rungs with each run of PRs merged together folded into one line: one after another on a
    /// lane with nothing forking off. A PR merged on its own stays a rung.
    var lines: [Line] {
        var lines: [Line] = []
        var run: [Rung] = []
        func flush() {
            if run.count > 1, let first = run.first, let last = run.last {
                var segments: [StackRail.Segment] = []
                if first.rail.hasUp { segments.append(.up(lane: first.rail.lane, linkUp(first))) }
                if last.rail.hasDown { segments.append(.down(lane: last.rail.lane, linkDown(last))) }
                lines.append(.merged(run, rail: StackRail(lane: first.rail.lane, laneCount: first.rail.laneCount, segments: segments)))
            } else {
                lines += run.map(Line.rung)
            }
            run = []
        }
        for rung in rungs {
            let foldable = rung.entry.state == .merged && rung.rail.isPlain
            if foldable, let at = rung.entry.closedAt, let last = run.last, let lastAt = last.entry.closedAt,
               abs(at.timeIntervalSince(lastAt)) <= Self.mergeWindow, rung.parent == last.entry.number
            {
                run.append(rung)
                continue
            }
            flush()
            if foldable { run = [rung] } else { lines.append(.rung(rung)) }
        }
        flush()
        return lines
    }

    private func linkUp(_ rung: Rung) -> StackRail.Link {
        for case let .up(_, link) in rung.rail.segments { return link }
        return .stack
    }

    private func linkDown(_ rung: Rung) -> StackRail.Link {
        for case let .down(_, link) in rung.rail.segments { return link }
        return .stack
    }

    var mergedCount: Int { rungs.count { $0.entry.state == .merged || $0.upstream?.state == .merged } }

    /// The number of the PR before or after `number` in the ladder's rows (`offset` -1 toward the
    /// base).
    func neighbor(of number: Int, offset: Int) -> Int? {
        guard let index = rungs.firstIndex(where: { $0.entry.number == number }) else { return nil }
        let target = index + offset
        return rungs.indices.contains(target) ? rungs[target].entry.number : nil
    }

    /// Most PRs the ladder gathers by branch.
    private static let limit = 30

    /// The ladder for `item`: its GitHub stack (from the detail, or else its members here), the
    /// PRs below it by base branch, and the open PRs based on any of their branches, among
    /// `items`. Nil when the item stands alone.
    static func of(_ item: Item, stack: PRStack?, items: [Item], upstreamOf: (Item) -> Item?) -> StackLadder? {
        guard item.kind == .pullRequest else { return nil }
        let local = items.filter { $0.kind == .pullRequest && $0.repo.caseInsensitiveCompare(item.repo) == .orderedSame }
        let byNumber = Dictionary(local.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        func entry(_ item: Item, position: Int) -> PRStack.Entry {
            PRStack.Entry(
                position: position, number: item.number, title: item.title, state: item.state, isDraft: item.isDraft,
                closedAt: item.closedAt, baseRef: item.baseRef ?? "", headRef: item.headRef ?? ""
            )
        }

        // The GitHub stack, base first; its members are linked by position, not branch, since a
        // merged member keeps the base branch it had.
        var number: Int?
        var entries: [PRStack.Entry] = []
        if let stack, stack.entries.count > 1, stack.entries.contains(where: { $0.number == item.number }) {
            number = stack.number
            entries = stack.entries
        } else if stack == nil, let stackNumber = item.stackNumber {
            let members = local.filter { $0.stackNumber == stackNumber }.sorted { ($0.stackPosition ?? 0) < ($1.stackPosition ?? 0) }
            if members.count > 1 {
                number = stackNumber
                entries = members.map { entry($0, position: $0.stackPosition ?? 0) }
            }
        }
        let stacked = Set(entries.map(\.number))
        if entries.isEmpty { entries = [entry(item, position: 0)] }

        // Down by base branch from the lowest PR.
        var seen = Set(entries.map(\.number))
        func pick(_ candidates: [Item]) -> Item? {
            candidates.max { ($0.isOpen ? 1 : 0, $0.number) < ($1.isOpen ? 1 : 0, $1.number) }
        }
        while entries.count < limit, let base = entries.first?.baseRef, base != Stacks.defaultBranch,
              let below = pick(local.filter { $0.headRef == base && !seen.contains($0.number) })
        {
            entries.insert(entry(below, position: 0), at: 0)
            seen.insert(below.number)
        }
        // Up: open PRs based on any branch here, and on theirs.
        var frontier = entries.map(\.headRef)
        while !frontier.isEmpty, entries.count < limit {
            let heads = Set(frontier)
            let above = local.filter { $0.isOpen && !seen.contains($0.number) && heads.contains($0.baseRef ?? "") }
                .sorted { $0.number < $1.number }
                .prefix(limit - entries.count)
            entries += above.map { entry($0, position: 0) }
            seen.formUnion(above.map(\.number))
            frontier = above.compactMap(\.headRef)
        }
        guard entries.count > 1 else { return nil }

        // Each PR's GitHub stack and place in it: the detail's, or else as last fetched here.
        let places: [(stack: Int, position: Int)?] = entries.map { entry in
            if let number, stacked.contains(entry.number) { return (number, entry.position) }
            guard let item = byNumber[entry.number], let stack = item.stackNumber, let position = item.stackPosition else { return nil }
            return (stack, position)
        }
        // Parents: the stack member below, or the PR whose head branch is the base.
        let indexByHead = Dictionary(entries.enumerated().map { ($1.headRef, $0) }, uniquingKeysWith: { a, _ in a })
        let parents: [(node: Int, link: StackRail.Link)?] = entries.enumerated().map { index, entry in
            if let place = places[index],
               let below = entries.indices.filter({ places[$0]?.stack == place.stack && places[$0]!.position < place.position })
               .max(by: { places[$0]!.position < places[$1]!.position })
            {
                return (below, .stack)
            }
            if entry.baseRef != Stacks.defaultBranch, let other = indexByHead[entry.baseRef], other != index {
                return (other, .branch)
            }
            return nil
        }
        // Siblings: a stack's own next member first, as in the list.
        let layout = StackLayout.layout(parents: parents) { a, b in
            ((places[a] == nil ? 1 : 0), entries[a].number) < ((places[b] == nil ? 1 : 0), entries[b].number)
        }
        let rungs = layout.map { node, rail in
            Rung(
                entry: entries[node], upstream: byNumber[entries[node].number].flatMap(upstreamOf), rail: rail,
                parent: parents[node].map { entries[$0.node].number }
            )
        }
        return StackLadder(repo: item.repo, number: number, rungs: rungs)
    }
}
