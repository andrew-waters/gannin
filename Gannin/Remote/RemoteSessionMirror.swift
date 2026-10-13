import Foundation
import GanninRemote

/// Turns the store's sessions into what the phone is shown. Reads only.
@MainActor
struct RemoteSessionMirror {
    /// A snapshot has to fit in one frame.
    static let maxSessions = 60
    static let maxTitle = 200
    static let maxMessage = 280

    let store: SessionStore

    /// Sessions waiting on you first, then working, then the rest, newest activity first.
    func sessions() -> [RemoteSession] {
        store.sessions.values
            .map { (session: $0, mirrored: remoteSession($0)) }
            .sorted { lhs, rhs in
                let (l, r) = (Self.rank(lhs.mirrored.state), Self.rank(rhs.mirrored.state))
                if l != r { return l < r }
                return store.transcripts[lhs.session.id]?.lastActivity ?? lhs.session.createdAt
                    > store.transcripts[rhs.session.id]?.lastActivity ?? rhs.session.createdAt
            }
            .prefix(Self.maxSessions)
            .map(\.mirrored)
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
