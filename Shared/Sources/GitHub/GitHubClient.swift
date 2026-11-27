import Foundation
import os

struct RateLimit: Sendable, Equatable {
    var limit: Int
    var remaining: Int
    var resetAt: Date
}

struct GraphQLError: Decodable, Sendable, LocalizedError {
    let message: String
    let type: String?

    var errorDescription: String? { message }

    /// GitHub's hourly budget ("API rate limit already exceeded"), RATE_LIMIT or RATE_LIMITED.
    var isRateLimit: Bool { type?.hasPrefix("RATE_LIMIT") == true }
}

enum GraphQLClientError: LocalizedError {
    case http(status: Int, body: String)
    case emptyData([GraphQLError])
    /// GitHub refused a query for its GraphQL budget, which is back at `until`.
    case rateLimited(until: Date)
    /// The app's own guard against loops didn't send it (`RequestGuard`).
    case refused(RequestGuard.Refusal)

    var errorDescription: String? {
        switch self {
        case let .http(status, _) where (500 ... 599).contains(status):
            // The body is GitHub's HTML error page.
            "GitHub didn't answer in time (HTTP \(status))."
        case let .http(status, body):
            "GitHub returned HTTP \(status): \(body.prefix(200))"
        case let .emptyData(errors):
            errors.map(\.message).joined(separator: "\n")
        case let .rateLimited(until):
            "GitHub refused this for its API limit (back by \(until.formatted(date: .omitted, time: .shortened))). Trying again often works."
        case let .refused(.held(label, until)):
            "Not sent: PR Desk sent this request (\(label)) too often, as a loop would, and holds it until \(until.formatted(date: .omitted, time: .shortened))."
        case .refused(.paused):
            "Not sent: PR Desk has stopped sending requests to GitHub after its budget fell fast. Resume from the sync status."
        }
    }
}

actor GitHubClient {
    private static let endpoint = URL(string: "https://api.github.com/graphql")!
    private let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "GitHub")
    private let session: URLSession
    private var token: String?

    /// Last rate limit seen in response headers.
    private(set) var rateLimit: RateLimit?
    /// Holds back requests a loop would send (`RequestGuard`).
    private var requestGuard = RequestGuard()
    /// Each time the guard stops something, for the viewer.
    nonisolated let trips: AsyncStream<RequestGuard.Trip>
    private let tripsContinuation: AsyncStream<RequestGuard.Trip>.Continuation

    init(session: URLSession = .shared) {
        self.session = session
        (trips, tripsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// Lets requests go again after the guard stopped them all.
    func resumeRequests() {
        requestGuard.resume()
        logger.notice("Requests resumed")
    }

    /// Counts a request with the guard before it is sent, or throws its refusal.
    private func admit(method: String, url: URL, body: Data?, label: @autoclosure () -> String, isWrite: Bool, isGraphQL: Bool) throws {
        let key = RequestGuard.key(method: method, url: url, body: body)
        let (refusal, trip) = requestGuard.admit(key: key, label: label(), isWrite: isWrite, isGraphQL: isGraphQL)
        if let trip { report(trip) }
        if let refusal { throw GraphQLClientError.refused(refusal) }
    }

    private func report(_ trip: RequestGuard.Trip) {
        logger.fault("Request guard: \(trip.message, privacy: .public)")
        tripsContinuation.yield(trip)
    }

    /// A GraphQL request in a few words: its first fields and the repository and number it names.
    private static func label(graphQL query: String, body: Data) -> String {
        let skipped: Set = ["query", "mutation", "fragment", "repository", "include", "skip"]
        var fields: [String] = []
        for match in query.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\s*[({]/) {
            let field = String(match.1)
            guard !skipped.contains(field), !fields.contains(field) else { continue }
            fields.append(field)
            if fields.count == 2 { break }
        }
        var label = fields.isEmpty ? "a GraphQL query" : fields.joined(separator: " › ")
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let variables = object["variables"] as? [String: Any],
           let owner = variables["owner"] as? String, let name = variables["name"] as? String
        {
            label += " of \(owner)/\(name)" + ((variables["number"] as? Int).map { "#\($0)" } ?? "")
        }
        return label
    }

    /// Keys sorted, so the same request is always the same bytes: `RequestGuard` tells requests
    /// apart by them, and JSONEncoder's own order varies from one encoding to the next.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Runs a GraphQL query. Partial errors are logged and tolerated (e.g. one missing user in a
    /// batch) unless `strict`, which mutations use so a failed write is never mistaken for success.
    func query<Variables: Encodable & Sendable, Response: Decodable & Sendable>(
        _ query: String,
        variables: Variables,
        as _: Response.Type = Response.self,
        strict: Bool = false
    ) async throws -> Response {
        let body = try Self.encoder.encode(Body(query: query, variables: variables))
        let isWrite = query.drop { $0.isWhitespace }.hasPrefix("mutation")
        try admit(method: "POST", url: Self.endpoint, body: body, label: Self.label(graphQL: query, body: body), isWrite: isWrite, isGraphQL: true)
        var attempt = 0
        var envelope: Envelope<Response>
        var limit: RateLimit?
        while true {
            attempt += 1
            let data: Data
            (data, limit) = try await perform(method: "POST", url: Self.endpoint, body: body, isWrite: isWrite)
            do {
                envelope = try await Self.decode(Envelope<Response>.self, from: data)
                break
            } catch DecodingError.dataCorrupted where attempt < 3 && !isWrite {
                // GitHub sometimes cuts off a slow response mid-body; treat it like a 502.
                logger.info("Truncated GraphQL response, retrying")
                try await Task.sleep(for: .seconds(attempt * 2))
            }
        }
        if let errors = envelope.errors, errors.contains(where: \.isRateLimit) {
            throw rateLimited(limit)
        }
        if let errors = envelope.errors, !errors.isEmpty {
            if strict { throw GraphQLClientError.emptyData(errors) }
            logger.warning("GraphQL errors: \(errors.map(\.message).joined(separator: "; "), privacy: .public)")
        }
        guard let result = envelope.data else {
            throw GraphQLClientError.emptyData(envelope.errors ?? [])
        }
        return result
    }

    /// Calls a REST endpoint, e.g. `rest("GET", "/orgs/NVIDIA/members")`, and returns the raw body.
    @discardableResult
    func rest(_ method: String, _ path: String, query: [URLQueryItem] = [], json: (any Encodable & Sendable)? = nil) async throws -> Data {
        var components = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty { components.queryItems = query }
        let body = try json.map { try Self.encoder.encode($0) }
        let isWrite = method != "GET"
        try admit(method: method, url: components.url!, body: body, label: "\(method) \(path)", isWrite: isWrite, isGraphQL: false)
        return try await perform(method: method, url: components.url!, body: body, isWrite: isWrite).data
    }

    /// When the budget that refused a query is back: the reset of the window that refused it, or a
    /// minute when the response says nothing usable (a secondary limit). Nothing is blocked here:
    /// the app holds back its own background work, while what the user does is always tried (GitHub
    /// can keep windows with different starts, so a refused query's retry may well go through).
    private func rateLimited(_ limit: RateLimit?) -> GraphQLClientError {
        let now = Date()
        let until = limit.flatMap { $0.remaining == 0 && $0.resetAt > now ? $0.resetAt : nil }
            ?? now.addingTimeInterval(60)
        logger.error("GraphQL rate limited until \(until, privacy: .public)")
        return .rateLimited(until: until)
    }

    func rest<Response: Decodable & Sendable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        json: (any Encodable & Sendable)? = nil,
        as _: Response.Type = Response.self
    ) async throws -> Response {
        try await Self.decode(Response.self, from: rest(method, path, query: query, json: json))
    }

    /// Decodes on the concurrent pool, so parallel fetches don't take turns decoding on the actor.
    @concurrent
    private static func decode<T: Decodable & Sendable>(_: T.Type, from data: Data) async throws -> T {
        try decoder.decode(T.self, from: data)
    }

    /// Sends a request with auth, retrying transient failures and rate limiting. A write isn't
    /// retried after a server error: GitHub may have made it before failing to answer, and a
    /// comment or review would go twice. Refused for its rate, it wasn't made, and is retried.
    private func perform(method: String, url: URL, body: Data?, isWrite: Bool) async throws -> (data: Data, limit: RateLimit?) {
        var attempt = 0
        while true {
            attempt += 1
            if token == nil {
                token = try await GitHubAuth.resolveToken()
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("bearer \(token!)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let limit = recordRateLimit(response)

            switch status {
            case 200 ..< 300:
                return (data, limit)
            case 403 where limit?.remaining == 0, 429 where limit?.remaining == 0:
                // The hour's GraphQL budget: retrying within seconds can't help.
                throw rateLimited(limit)
            case 401 where attempt == 1:
                // The token may have been rotated (e.g. `gh auth refresh`); resolve it again.
                token = nil
            case 403 where attempt < 4 && Self.isRateLimited(response), 429 where attempt < 4, 500 ... 599 where attempt < 4 && !isWrite:
                let delay = retryDelay(response, attempt: attempt)
                logger.info("HTTP \(status), retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
            default:
                throw GraphQLClientError.http(status: status, body: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// Notes the GraphQL budget from a response's headers and returns it.
    @discardableResult
    private func recordRateLimit(_ response: URLResponse) -> RateLimit? {
        // REST calls draw from a separate budget; only the GraphQL one is shown.
        guard let http = response as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "x-ratelimit-resource") == "graphql",
              let limit = http.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init),
              let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init),
              let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
        else { return nil }
        rateLimit = RateLimit(limit: limit, remaining: remaining, resetAt: Date(timeIntervalSince1970: reset))
        if let trip = requestGuard.observe(remaining: remaining, limit: limit, resetAt: Date(timeIntervalSince1970: reset)) {
            report(trip)
        }
        return rateLimit
    }

    /// A 403 is only worth retrying when it is (secondary) rate limiting, not a permission error.
    private static func isRateLimited(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.value(forHTTPHeaderField: "retry-after") != nil
            || http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
    }

    private func retryDelay(_ response: URLResponse, attempt: Int) -> Double {
        if let retryAfter = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "retry-after")
            .flatMap(Double.init)
        {
            return min(retryAfter, 60)
        }
        return pow(2, Double(attempt))
    }

    private struct Body<Variables: Encodable>: Encodable {
        let query: String
        let variables: Variables
    }

    private struct Envelope<Response: Decodable & Sendable>: Decodable, Sendable {
        let data: Response?
        let errors: [GraphQLError]?
    }
}
