import Foundation

/// What changed between two lists of sessions, for sending the phone only that.
public enum RemoteSessionDiff {
    public static func between(old: [RemoteSession], new: [RemoteSession]) -> (changed: [RemoteSession], removed: [String]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let changed = new.filter { before[$0.id] != $0 }
        let now = Set(new.map(\.id))
        let removed = old.map(\.id).filter { !now.contains($0) }
        return (changed, removed)
    }
}

/// At most `limit` intents in any `window`, per connection.
public struct IntentRateLimiter: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var times: [Date] = []

    public init(limit: Int = 20, window: TimeInterval = 10) {
        self.limit = limit
        self.window = window
    }

    /// Whether an intent at `now` is allowed; an allowed one is counted.
    public mutating func allow(at now: Date = Date()) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= window }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }
}
