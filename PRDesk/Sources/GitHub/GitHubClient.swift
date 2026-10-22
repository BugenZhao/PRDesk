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
}

enum GraphQLClientError: LocalizedError {
    case http(status: Int, body: String)
    case emptyData([GraphQLError])

    var errorDescription: String? {
        switch self {
        case let .http(status, body):
            "GitHub returned HTTP \(status): \(body.prefix(200))"
        case let .emptyData(errors):
            errors.map(\.message).joined(separator: "\n")
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

    init(session: URLSession = .shared) {
        self.session = session
    }

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
        let body = try JSONEncoder().encode(Body(query: query, variables: variables))
        var attempt = 0
        var envelope: Envelope<Response>
        while true {
            attempt += 1
            let data = try await perform(method: "POST", url: Self.endpoint, body: body)
            do {
                envelope = try await Self.decode(Envelope<Response>.self, from: data)
                break
            } catch DecodingError.dataCorrupted where attempt < 3 {
                // GitHub sometimes cuts off a slow response mid-body; treat it like a 502.
                logger.info("Truncated GraphQL response, retrying")
                try await Task.sleep(for: .seconds(attempt * 2))
            }
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

    /// Calls a REST endpoint, e.g. `rest("GET", "/orgs/NVIDIA/public_members")`, and returns the raw body.
    @discardableResult
    func rest(_ method: String, _ path: String, query: [URLQueryItem] = [], json: (any Encodable & Sendable)? = nil) async throws -> Data {
        var components = URLComponents(string: "https://api.github.com" + path)!
        if !query.isEmpty { components.queryItems = query }
        let body = try json.map { try JSONEncoder().encode($0) }
        return try await perform(method: method, url: components.url!, body: body)
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

    /// Sends a request with auth, retrying transient failures and rate limiting.
    private func perform(method: String, url: URL, body: Data?) async throws -> Data {
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
            recordRateLimit(response)

            switch status {
            case 200 ..< 300:
                return data
            case 401 where attempt == 1:
                // The token may have been rotated (e.g. `gh auth refresh`); resolve it again.
                token = nil
            case 403 where attempt < 4 && Self.isRateLimited(response), 429 where attempt < 4, 500 ... 599 where attempt < 4:
                let delay = retryDelay(response, attempt: attempt)
                logger.info("HTTP \(status), retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
            default:
                throw GraphQLClientError.http(status: status, body: String(decoding: data, as: UTF8.self))
            }
        }
    }

    private func recordRateLimit(_ response: URLResponse) {
        // REST calls draw from a separate budget; only the GraphQL one is shown.
        guard let http = response as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "x-ratelimit-resource") == "graphql",
              let limit = http.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init),
              let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init),
              let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
        else { return }
        rateLimit = RateLimit(limit: limit, remaining: remaining, resetAt: Date(timeIntervalSince1970: reset))
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
