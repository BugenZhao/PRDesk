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
    private let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "GraphQL")
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

    func query<Variables: Encodable & Sendable, Response: Decodable & Sendable>(
        _ query: String,
        variables: Variables,
        as _: Response.Type = Response.self
    ) async throws -> Response {
        let body = try JSONEncoder().encode(Body(query: query, variables: variables))
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await send(body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            recordRateLimit(response)

            switch status {
            case 200:
                let envelope = try Self.decoder.decode(Envelope<Response>.self, from: data)
                if let errors = envelope.errors, !errors.isEmpty {
                    logger.warning("GraphQL errors: \(errors.map(\.message).joined(separator: "; "), privacy: .public)")
                }
                guard let result = envelope.data else {
                    throw GraphQLClientError.emptyData(envelope.errors ?? [])
                }
                return result
            case 401 where attempt == 1:
                // The token may have been rotated (e.g. `gh auth refresh`); resolve it again.
                token = nil
            case 403, 429, 500 ... 599 where attempt < 4:
                let delay = retryDelay(response, attempt: attempt)
                logger.info("HTTP \(status), retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
            default:
                throw GraphQLClientError.http(status: status, body: String(decoding: data, as: UTF8.self))
            }
        }
    }

    private func send(_ body: Data) async throws -> (Data, URLResponse) {
        if token == nil {
            token = try await GitHubAuth.resolveToken()
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await session.data(for: request)
    }

    private func recordRateLimit(_ response: URLResponse) {
        guard let http = response as? HTTPURLResponse,
              let limit = http.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init),
              let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init),
              let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
        else { return }
        rateLimit = RateLimit(limit: limit, remaining: remaining, resetAt: Date(timeIntervalSince1970: reset))
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

    private struct Envelope<Response: Decodable>: Decodable {
        let data: Response?
        let errors: [GraphQLError]?
    }
}
