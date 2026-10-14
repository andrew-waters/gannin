import Foundation
import GanninRemote

/// Somewhere bytes go to a phone and are closed: a network connection, or a fake in tests.
@MainActor
protocol RemoteLink: AnyObject {
    func send(_ data: Data)
    func close()
}

/// One phone's session with this Mac, over a link that has already authenticated it.
/// It frames what arrives, checks the phone is still paired on every message, sends the
/// sessions and what changes in them, and hands intents to `RemoteIntentHandler`.
@MainActor
final class RemoteConnection {
    let phone: RemotePhone
    private let fingerprint: Data
    private let link: any RemoteLink
    private let handler: RemoteIntentHandler
    private let phones: PairedPhones
    private let macName: String
    private let snapshot: @MainActor () -> [RemoteSession]
    private var decoder = FrameDecoder()
    private var limiter: IntentRateLimiter
    private var subscribed = false
    private var sent: [RemoteSession] = []
    private(set) var isClosed = false
    var onClose: ((RemoteConnection) -> Void)?

    init(
        phone: RemotePhone,
        fingerprint: Data,
        link: any RemoteLink,
        handler: RemoteIntentHandler,
        phones: PairedPhones,
        macName: String,
        limiter: IntentRateLimiter = IntentRateLimiter(),
        snapshot: @escaping @MainActor () -> [RemoteSession]
    ) {
        self.phone = phone
        self.fingerprint = fingerprint
        self.link = link
        self.handler = handler
        self.phones = phones
        self.macName = macName
        self.limiter = limiter
        self.snapshot = snapshot
    }

    func start() {
        send(.hello(macName: macName))
    }

    func receive(_ data: Data) {
        guard !isClosed else { return }
        // Revoking a phone takes effect on its next message, whatever else closes it.
        guard phones.isPaired(fingerprint) else { return close() }
        decoder.append(data)
        do {
            while let payload = try decoder.next() {
                dispatch(try FrameCodec.decode(payload, as: ClientMessage.self))
            }
        } catch {
            close()
        }
    }

    /// Sends what differs from the last thing this phone was sent.
    func push(_ sessions: [RemoteSession]) {
        guard subscribed, !isClosed else { return }
        let sessions = RemoteSnapshot.fitting(sessions)
        let diff = RemoteSessionDiff.between(old: sent, new: sessions)
        for session in diff.changed { send(.sessionChanged(session: session)) }
        for id in diff.removed { send(.sessionRemoved(id: id)) }
        if !isClosed { sent = sessions }
    }

    func heartbeat() {
        guard !isClosed else { return }
        send(.heartbeat)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        link.close()
        onClose?(self)
    }

    /// The link ended on its own.
    func linkClosed() {
        guard !isClosed else { return }
        isClosed = true
        onClose?(self)
    }

    private func dispatch(_ message: ClientMessage) {
        switch message {
        case .hello:
            phones.noteSeen(fingerprint)
        case .subscribe:
            subscribed = true
            let sessions = RemoteSnapshot.fitting(snapshot())
            send(.snapshot(sessions: sessions))
            if !isClosed { sent = sessions }
        case .intent(let id, let session, let promptID, let intent):
            guard limiter.allow() else {
                send(.result(id: id, result: .refused(reason: .rateLimited)))
                return
            }
            Task { [handler] in
                guard !self.isClosed else { return }
                guard self.phones.isPaired(self.fingerprint) else { return self.close() }
                let result = await handler.handle(session: session, promptID: promptID, intent: intent)
                self.send(.result(id: id, result: result))
            }
        }
    }

    private func send(_ message: ServerMessage) {
        guard !isClosed else { return }
        do {
            link.send(try FrameCodec.encode(message))
        } catch {
            close()
        }
    }
}
