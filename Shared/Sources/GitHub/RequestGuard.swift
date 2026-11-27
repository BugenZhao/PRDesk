import Foundation

/// The last line against a bug that spends GitHub's budget in a loop: every request passes
/// through here before it is sent, wherever it comes from, so no fetch path has to get it right
/// on its own.
///
/// - The same request (method, URL and body: the same query with the same variables) sent too
///   often in a minute is held for a while. A loop re-triggering a fetch sends the same request
///   again and again, where the app's own rhythm (a sync a minute at the most, a detail every
///   two) repeats one a few times a minute at the most. Writes are held sooner.
/// - The GraphQL budget falling fast while the app is sending many requests stops all of them
///   until the viewer resumes: a loop whose requests differ (a cursor that never ends, a walk over
///   items) gets past the first rule, not this one. Others spend the same budget (the viewer's
///   own `gh`, the other devices), so the app's own count has to be high too.
///
/// A pure value, so its rules can be checked without the network; `GitHubClient` owns one.
struct RequestGuard: Sendable {
    struct Limits: Sendable {
        /// How long a request's sends are counted for.
        var repeatWindow: TimeInterval = 60
        /// Sends of one read within `repeatWindow` that are let through; the next is held.
        var repeatedReads = 12
        /// The same for a write (a mutation, or a REST call other than GET).
        var repeatedWrites = 4
        /// How long a request is held once it repeated too often.
        var holdFor: TimeInterval = 600
        /// How far back the budget's fall is measured.
        var spendWindow: TimeInterval = 600
        /// The share of the hour's budget that may go within `spendWindow`.
        var spendShare = 0.3
        /// GraphQL requests of the app's own within `spendWindow` without which a fall is put
        /// down to others.
        var ownRequests = 60
    }

    /// Why requests were stopped, for the viewer and the log.
    struct Trip: Sendable, Equatable, Identifiable {
        enum Kind: Sendable, Equatable {
            /// One request repeated: `count` sends within `window` seconds; held until `until`.
            case repeated(label: String, count: Int, window: TimeInterval, until: Date)
            /// The budget fell by `points` within `window` seconds while the app sent `requests`;
            /// everything is stopped until the viewer resumes.
            case spending(points: Int, requests: Int, window: TimeInterval)
        }

        let id = UUID()
        let kind: Kind
        let at: Date

        var isPause: Bool { if case .spending = kind { true } else { false } }

        /// What happened, in a sentence or two for an alert.
        var message: String {
            switch kind {
            case let .repeated(label, count, window, until):
                "PR Desk sent the same request (\(label)) \(count) times in \(Int(window)) seconds, which is "
                    + "a bug, not something it does on purpose. It is held until "
                    + "\(until.formatted(date: .omitted, time: .shortened)); everything else goes on."
            case let .spending(points, requests, window):
                "GitHub's GraphQL budget fell by \(points.formatted()) points in \(Int(window / 60)) minutes, "
                    + "while PR Desk sent \(requests.formatted()) requests. PR Desk has stopped sending any "
                    + "until you resume, so a loop can't spend the rest of the hour."
            }
        }

        static func == (a: Trip, b: Trip) -> Bool { a.id == b.id }
    }

    enum Refusal: Error, Sendable, Equatable {
        /// This request is held after repeating; `until` is when it may go again.
        case held(label: String, until: Date)
        /// All requests are stopped until the viewer resumes.
        case paused
    }

    var limits = Limits()

    /// Each request's recent sends, by its key.
    private var sends: [Int: [Date]] = [:]
    /// Requests held, by key, until when.
    private var held: [Int: Date] = [:]
    /// When GraphQL requests were sent, for the app's own count.
    private var graphQLSends: [Date] = []
    /// The budget as responses reported it, oldest first, within one reset window.
    private var budget: [(at: Date, remaining: Int, resetAt: Date)] = []
    private(set) var isPaused = false

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// The key a request is counted under: the same query with the same variables is the same
    /// request.
    static func key(method: String, url: URL, body: Data?) -> Int {
        var hasher = Hasher()
        hasher.combine(method)
        hasher.combine(url)
        hasher.combine(body)
        return hasher.finalize()
    }

    /// Counts a request about to be sent, or refuses it (`refusal`). `trip` is set when this send
    /// is the one that held its request.
    mutating func admit(key: Int, label: @autoclosure () -> String, isWrite: Bool, isGraphQL: Bool, now: Date = Date()) -> (refusal: Refusal?, trip: Trip?) {
        if isPaused { return (.paused, nil) }
        if let until = held[key] {
            if now < until { return (.held(label: label(), until: until), nil) }
            held[key] = nil
            sends[key] = nil
        }
        let recent = (sends[key] ?? []).filter { now.timeIntervalSince($0) < limits.repeatWindow }
        let allowed = isWrite ? limits.repeatedWrites : limits.repeatedReads
        if recent.count >= allowed {
            let until = now.addingTimeInterval(limits.holdFor)
            held[key] = until
            sends[key] = recent
            let label = label()
            let trip = Trip(kind: .repeated(label: label, count: recent.count + 1, window: limits.repeatWindow, until: until), at: now)
            return (.held(label: label, until: until), trip)
        }
        sends[key] = recent + [now]
        if isGraphQL { graphQLSends.append(now) }
        prune(now: now)
        return (nil, nil)
    }

    /// Takes in the budget a response reported. Returns a trip when the budget's fall stops all
    /// requests.
    mutating func observe(remaining: Int, limit: Int, resetAt: Date, now: Date = Date()) -> Trip? {
        // A new window starts the count again.
        if let last = budget.last, abs(last.resetAt.timeIntervalSince(resetAt)) > 1 { budget.removeAll() }
        budget.append((now, remaining, resetAt))
        prune(now: now)
        guard !isPaused, let first = budget.first else { return nil }
        let fall = first.remaining - remaining
        let own = graphQLSends.count
        guard Double(fall) >= limits.spendShare * Double(limit), own >= limits.ownRequests else { return nil }
        isPaused = true
        return Trip(kind: .spending(points: fall, requests: own, window: limits.spendWindow), at: now)
    }

    /// Lets requests go again after a pause, and forgets what was counted toward it.
    mutating func resume() {
        isPaused = false
        budget.removeAll()
        graphQLSends.removeAll()
    }

    private mutating func prune(now: Date) {
        graphQLSends.removeAll { now.timeIntervalSince($0) >= limits.spendWindow }
        budget.removeAll { now.timeIntervalSince($0.at) >= limits.spendWindow }
        // Keys not sent within the window and not held are forgotten, so the table stays small.
        if sends.count > 500 {
            sends = sends.filter { key, dates in held[key] != nil || dates.contains { now.timeIntervalSince($0) < limits.repeatWindow } }
        }
        held = held.filter { now < $0.value }
    }
}

/// The cursor for a connection's next page, or nil to stop: when there is none, when it is the
/// cursor just used (a page that doesn't move on would be asked for again and again), or after
/// `limit` pages. Every loop over pages goes through it, so none is bound only by what GitHub
/// sends back.
func nextPageCursor(hasNextPage: Bool, endCursor: String?, after: String?, pages: inout Int, limit: Int) -> String? {
    pages += 1
    guard hasNextPage, let endCursor, endCursor != after, pages < limit else { return nil }
    return endCursor
}
