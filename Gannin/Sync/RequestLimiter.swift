import Foundation

/// Caps how many GitHub requests are in flight at once across the whole
/// app, GraphQL and REST together. Each store runs its own searches several
/// at a time, so a Refresh that starts them all could otherwise send dozens
/// at once and trip GitHub's secondary rate limit.
///
/// Background requests (syncs, the default) leave `reservedForInteractive`
/// slots free, and interactive ones (a read started by opening something,
/// see `lane`) are served first, so a drawer opening doesn't wait behind a
/// Full Refresh's queue of searches.
actor RequestLimiter {
    enum Lane: Sendable {
        case background
        case interactive
    }

    /// The lane for requests made in this task; set it around a read you
    /// started by hand with `interactive`.
    @TaskLocal static var lane: Lane = .background

    /// Runs `operation` with its requests in the interactive lane.
    nonisolated(nonsending) static func interactive<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await $lane.withValue(.interactive, operation: operation)
    }

    static let defaultLimit = 8
    static let defaultReservedForInteractive = 2

    static let shared = RequestLimiter(limit: defaultLimit, reservedForInteractive: defaultReservedForInteractive)

    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private let backgroundLimit: Int
    private let send: Sender
    private var running = 0
    private var runningBackground = 0
    private var interactiveWaiting: [Waiter] = []
    private var backgroundWaiting: [Waiter] = []

    init(
        limit: Int,
        reservedForInteractive: Int = 0,
        send: @escaping Sender = { try await URLSession.shared.data(for: $0) }
    ) {
        self.limit = limit
        self.backgroundLimit = max(1, limit - reservedForInteractive)
        self.send = send
    }

    /// Runs `request` as soon as its lane has a free slot.
    func data(for request: URLRequest, lane: Lane = RequestLimiter.lane) async throws -> (Data, URLResponse) {
        try NetworkGate.check(request.url)
        try await acquire(lane)
        defer { release(lane) }
        // A slot handed over as the task was cancelled still has to be given back, above.
        try Task.checkCancellation()
        return try await send(request)
    }

    private func acquire(_ lane: Lane) async throws {
        try Task.checkCancellation()
        if canStart(lane), !hasWaiters(lane) {
            claim(lane)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(id: id, continuation: continuation)
                switch lane {
                case .interactive: interactiveWaiting.append(waiter)
                case .background: backgroundWaiting.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func canStart(_ lane: Lane) -> Bool {
        guard running < limit else { return false }
        return lane == .interactive || runningBackground < backgroundLimit
    }

    private func hasWaiters(_ lane: Lane) -> Bool {
        switch lane {
        case .interactive: !interactiveWaiting.isEmpty
        case .background: !interactiveWaiting.isEmpty || !backgroundWaiting.isEmpty
        }
    }

    private func claim(_ lane: Lane) {
        running += 1
        if lane == .background { runningBackground += 1 }
    }

    private func release(_ lane: Lane) {
        running -= 1
        if lane == .background { runningBackground -= 1 }
        handOverSlots()
    }

    /// Gives free slots to waiters, interactive first. The slot is claimed
    /// here, before the waiter resumes, so another request can't take it.
    private func handOverSlots() {
        while running < limit {
            if !interactiveWaiting.isEmpty {
                claim(.interactive)
                interactiveWaiting.removeFirst().continuation.resume()
            } else if !backgroundWaiting.isEmpty, canStart(.background) {
                claim(.background)
                backgroundWaiting.removeFirst().continuation.resume()
            } else {
                return
            }
        }
    }

    /// Wakes a cancelled waiter at once rather than when a slot reaches it.
    private func cancelWaiter(_ id: UUID) {
        if let index = interactiveWaiting.firstIndex(where: { $0.id == id }) {
            interactiveWaiting.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = backgroundWaiting.firstIndex(where: { $0.id == id }) {
            backgroundWaiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
}
