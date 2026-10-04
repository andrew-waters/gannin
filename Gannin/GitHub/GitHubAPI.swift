import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case http(status: Int, body: String)
    case network(String)
    case graphQL([String])
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your GitHub session has expired. Sign in again."
        case .http(502...504, _): "GitHub timed out. Try again in a moment."
        case .http(let status, let body): "GitHub returned HTTP \(status): \(Self.message(from: body))"
        case .network(let message): "Network error: \(message)"
        case .graphQL(let messages): messages.joined(separator: "\n")
        case .decoding(let reason): "Could not read GitHub's response: \(reason)"
        }
    }

    /// GitHub error bodies are JSON with a `message`, and often `errors`
    /// saying why (a 422's message is only "Unprocessable Entity"): strings,
    /// or objects with their own `message` or else a `field` and `code`
    /// (`Issue title missing_field`). The message leads, then the reasons; fall
    /// back to the raw text.
    private static func message(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String else {
            return body
        }
        let reasons = (json["errors"] as? [Any] ?? []).compactMap { error -> String? in
            if let text = error as? String { return text }
            guard let error = error as? [String: Any] else { return nil }
            if let text = error["message"] as? String { return text }
            let parts = [error["resource"], error["field"], error["code"]].compactMap { $0 as? String }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return reasons.isEmpty ? message : "\(message): \(reasons.joined(separator: "; "))"
    }
}

/// GitHub's GraphQL budget, as of the latest query.
nonisolated struct RateLimit: Decodable, Equatable, Sendable {
    /// Points the query that reported this cost.
    let cost: Int
    let remaining: Int
    let limit: Int
    let resetAt: Date

    /// Low enough that automatic refreshes should wait for the reset.
    var isLow: Bool { remaining < max(250, limit / 10) && resetAt > .now }
}

/// Thin GitHub GraphQL client. Every call is a read, except the confirmed
/// writes: project boards (`ProjectFields.swift`), investments
/// (`InvestmentWrites.swift`) and commits to the harness
/// (`HarnessWrites.swift`). Actions runs and jobs are REST only
/// (`ActionsQueries.swift`).
struct GitHubAPI {
    let token: String
    /// Told the budget after every query.
    var onRateLimit: (@MainActor @Sendable (RateLimit) -> Void)?
    /// Told the token's OAuth scopes (GitHub's `X-OAuth-Scopes` header).
    var onScopes: (@MainActor @Sendable (Set<String>) -> Void)?
    /// Told the REST budget after every REST request (Actions runs and jobs).
    var onRESTRateLimit: (@MainActor @Sendable (RateLimit) -> Void)?

    private static let endpoint = URL(string: "https://api.github.com/graphql")!

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Runs a query and decodes `data`. Partial results (data plus errors, as
    /// GitHub returns when some repos are hidden by org OAuth restrictions)
    /// are returned as data; errors only throw when there is no data at all.
    func query<T: Decodable>(_ query: String, variables: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        // Search over a big org regularly times out on GitHub's side; a
        // retry or two usually gets through.
        var attempt = 0
        while true {
            do {
                return try await send(query, variables: variables)
            } catch APIError.http(let status, _) where (502...504).contains(status) && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt * 2))
            }
        }
    }

    /// A read whose variables aren't all strings (an `Int!` number, say).
    func query<T: Decodable>(_ query: String, values: [String: Any], as type: T.Type = T.self) async throws -> T {
        try await send(query, variables: values)
    }

    /// A mutation whose variables aren't all strings (an input object, a
    /// list). A write: not retried, since it may have gone through.
    func mutate<T: Decodable>(_ query: String, variables: [String: Any], as type: T.Type = T.self) async throws -> T {
        try await send(query, variables: variables)
    }

    private func send<T: Decodable>(_ query: String, variables: [String: Any]) async throws -> T {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": Self.askingForRateLimit(query),
            "variables": variables,
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw APIError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let scopes = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            onScopes?(Set(scopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }))
        }
        if status == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        let envelope: Envelope<T>
        do {
            envelope = try Self.decoder.decode(Envelope<T>.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
        if let rateLimit = envelope.data?.rateLimit {
            onRateLimit?(rateLimit)
            if let step = SyncContext.step {
                step.run.addCost(rateLimit.cost, to: step.id)
            }
        }
        guard let result = envelope.data?.value else {
            throw APIError.graphQL(envelope.errors?.map(\.message) ?? ["Empty response"])
        }
        return result
    }

    /// Adds `rateLimit` to the query's top-level selection. Variable
    /// definitions never contain braces, so the first one opens it.
    private static func askingForRateLimit(_ query: String) -> String {
        // `rateLimit` is a query field; a mutation can't select it.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("mutation"),
              let brace = query.firstIndex(of: "{") else { return query }
        var query = query
        query.insert(contentsOf: " rateLimit { cost remaining limit resetAt } ", at: query.index(after: brace))
        return query
    }

    private struct Envelope<T: Decodable>: Decodable {
        let data: Payload<T>?
        let errors: [Message]?
    }

    /// The query's own data plus the `rateLimit` sitting alongside it.
    private struct Payload<T: Decodable>: Decodable {
        let value: T
        let rateLimit: RateLimit?

        private enum CodingKeys: String, CodingKey { case rateLimit }

        init(from decoder: Decoder) throws {
            value = try T(from: decoder)
            rateLimit = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        }
    }

    private struct Message: Decodable {
        let message: String
    }
}

// MARK: - Shared GraphQL shapes

struct Connection<Node: Decodable>: Decodable {
    let nodes: [Node]
}

struct PagedConnection<Node: Decodable>: Decodable {
    let pageInfo: PageInfo
    let nodes: [Node]
    /// Set when the query asks for it: `totalCount` on most connections,
    /// `issueCount` on search.
    let totalCount: Int?
    let issueCount: Int?

    var total: Int? { totalCount ?? issueCount }
}

struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

extension GitHubAPI {
    /// Follows `pageInfo` cursors until exhausted or `limit` nodes collected.
    /// `page` receives the cursor for the next request (nil on the first).
    func paginate<Node>(
        limit: Int = 1000,
        onPage: (_ fetched: Int, _ total: Int?) -> Void = { _, _ in },
        _ page: (String?) async throws -> PagedConnection<Node>?
    ) async throws -> [Node] {
        var collected: [Node] = []
        var cursor: String?
        while collected.count < limit {
            guard let connection = try await page(cursor) else { break }
            collected.append(contentsOf: connection.nodes)
            onPage(min(collected.count, limit), connection.total.map { min($0, limit) })
            guard connection.pageInfo.hasNextPage, let next = connection.pageInfo.endCursor else { break }
            cursor = next
        }
        return Array(collected.prefix(limit))
    }
}
