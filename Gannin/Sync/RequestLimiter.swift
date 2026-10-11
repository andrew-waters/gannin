import Foundation

/// Caps how many GitHub requests are in flight at once across the whole
/// app, GraphQL and REST together. Each store runs its own searches several
/// at a time, so a Refresh that starts them all could otherwise send dozens
/// at once and trip GitHub's secondary rate limit.
actor RequestLimiter {
    static let shared = RequestLimiter(limit: 8)

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Runs `request` as soon as fewer than `limit` are in flight.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await URLSession.shared.data(for: request)
    }

    private func acquire() async {
        if running < limit {
            running += 1
        } else {
            // The slot is handed over by `release`, which leaves `running` as it is.
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
