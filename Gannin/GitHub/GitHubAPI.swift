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

    /// GitHub error bodies are JSON with a `message`; fall back to the raw text.
    private static func message(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String else {
            return body
        }
        return message
    }
}

/// Thin GitHub GraphQL client. Every call is a read.
struct GitHubAPI {
    let token: String

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

    private func send<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
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
        guard let result = envelope.data else {
            throw APIError.graphQL(envelope.errors?.map(\.message) ?? ["Empty response"])
        }
        return result
    }

    private struct Envelope<T: Decodable>: Decodable {
        let data: T?
        let errors: [Message]?
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
        _ page: (String?) async throws -> PagedConnection<Node>?
    ) async throws -> [Node] {
        var collected: [Node] = []
        var cursor: String?
        while collected.count < limit {
            guard let connection = try await page(cursor) else { break }
            collected.append(contentsOf: connection.nodes)
            guard connection.pageInfo.hasNextPage, let next = connection.pageInfo.endCursor else { break }
            cursor = next
        }
        return Array(collected.prefix(limit))
    }
}
