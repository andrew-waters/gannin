import Foundation

/// Keeps the caller's priority order while fitting both snapshots and individual updates.
public enum RemoteSnapshot {
    public static let maxSessions = 60

    public static func fitting(_ sessions: [RemoteSession]) -> [RemoteSession] {
        var fitted: [RemoteSession] = []
        guard let empty = try? FrameCodec.encode(ServerMessage.snapshot(sessions: [])) else { return [] }
        // The empty envelope includes the array brackets; each element adds its encoded
        // JSON bytes and, after the first, a comma. Exclude the four-byte length prefix.
        var bytes = empty.count - 4
        let encoder = JSONEncoder()
        for session in sessions.prefix(maxSessions) {
            // Do not shorten question text or options: answers must match the original
            // question, and permission choices must describe what the terminal offers.
            guard (try? FrameCodec.encode(ServerMessage.sessionChanged(session: session))) != nil else { continue }
            guard let encoded = try? encoder.encode(session) else { continue }
            let added = encoded.count + (fitted.isEmpty ? 0 : 1)
            guard bytes + added <= RemoteProtocol.maxFrameBytes else { break }
            fitted.append(session)
            bytes += added
        }
        return fitted
    }
}
