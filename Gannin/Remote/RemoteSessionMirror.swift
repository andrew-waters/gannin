import Foundation
import GanninRemote

/// Turns the store's sessions into what the phone is shown. Reads only.
@MainActor
struct RemoteSessionMirror {
    /// A snapshot has to fit in one frame.
    static let maxSessions = RemoteSnapshot.maxSessions
    static let maxTitle = 200
    static let maxMessage = 280

    let store: SessionStore

    /// Sessions waiting on you first, then working, then the rest, newest activity first.
    func sessions() -> [RemoteSession] {
        let ordered = store.sessions.values
            .map { (session: $0, mirrored: remoteSession($0), active: lastActive($0)) }
            .sorted { lhs, rhs in
                let (l, r) = (Self.rank(lhs.mirrored.state), Self.rank(rhs.mirrored.state))
                return l == r ? lhs.active > rhs.active : l < r
            }
            .prefix(Self.maxSessions)
            .map(\.mirrored)
        return RemoteSnapshot.fitting(ordered)
    }

    private func lastActive(_ session: CodeSession) -> Date {
        store.transcripts[session.id]?.lastActivity ?? session.createdAt
    }

    func remoteSession(_ session: CodeSession) -> RemoteSession {
        let id = session.id
        let kind = TabKind(session)
        let state = Self.state(store.state(id))
        // Read from what each poll recorded, not the terminal's screen, as this runs for every session.
        let mode = store.modes[id]
        return RemoteSession(
            id: id.uuidString,
            reference: kind.reference ?? session.shortReference,
            title: String(kind.title.prefix(Self.maxTitle)),
            kind: kind.name,
            state: state,
            mode: Self.mode(mode),
            modeLabel: mode?.label ?? "Unknown",
            canGoUnattended: store.remoteCanGoUnattended(id),
            prompt: store.remotePrompt(for: id),
            lastMessage: store.transcripts[id]?.lastReply.map { String($0.prefix(Self.maxMessage)) }
        )
    }

    static func state(_ state: SessionState) -> RemoteSessionState {
        switch state {
        case .starting: .starting
        case .working: .working
        case .needsYou: .needsYou
        case .idle: .idle
        case .exited: .exited
        case .stopped: .stopped
        }
    }

    static func mode(_ mode: ClaudeMode?) -> RemoteMode {
        switch mode {
        case .default: .attended
        case .auto: .unattended
        default: .other
        }
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
