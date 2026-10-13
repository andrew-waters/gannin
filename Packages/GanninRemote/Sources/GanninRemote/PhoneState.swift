import Foundation

/// What the phone knows of a Mac's sessions, built up from what the Mac sends.
public struct RemoteSessionsState: Sendable, Equatable {
    public private(set) var macName: String?
    public private(set) var sessions: [RemoteSession] = []

    public init() {}

    public mutating func apply(_ message: ServerMessage) {
        switch message {
        case .hello(let name):
            macName = name
        case .snapshot(let list):
            sessions = list
        case .sessionChanged(let session):
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }
        case .sessionRemoved(let id):
            sessions.removeAll { $0.id == id }
        case .result, .heartbeat:
            break
        }
    }

    public func session(id: String) -> RemoteSession? {
        sessions.first { $0.id == id }
    }

    public var needsYou: [RemoteSession] {
        sessions.filter { $0.state == .needsYou }
    }

    /// Waiting on you first, then working, then the rest, each keeping the order the Mac sent.
    public var ordered: [RemoteSession] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                let (l, r) = (Self.rank(lhs.element.state), Self.rank(rhs.element.state))
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    private static func rank(_ state: RemoteSessionState) -> Int {
        switch state {
        case .needsYou: 0
        case .working, .starting: 1
        case .idle: 2
        case .exited, .stopped: 3
        }
    }
}

/// When the app asks for Face ID or the passcode again: at launch, and after it has been
/// in the background for `grace`.
public struct AppLockPolicy: Sendable {
    public var grace: TimeInterval

    public init(grace: TimeInterval = 60) {
        self.grace = grace
    }

    /// Whether to lock on coming back to the foreground. Never having left means no.
    public func shouldLock(backgroundedAt: Date?, now: Date) -> Bool {
        guard let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) >= grace
    }
}

extension RemoteRefusal {
    /// What to tell the person when the Mac declined something.
    public var explanation: String {
        switch self {
        case .promptGone: "That prompt has already been answered. It's been refreshed."
        case .notRunning: "Claude isn't running in that session."
        case .autoUnavailable: "Unattended isn't available in this session's Claude Code."
        case .unknownSession: "That session no longer exists."
        case .tooLarge: "That's too long to send."
        case .invalid: "The Mac couldn't use that."
        case .rateLimited: "Too many requests. Wait a moment."
        case .busy: "Answer the prompt first, then change the mode."
        case .modeNotChanged: "Claude didn't change mode. The Mac has the details."
        }
    }
}
