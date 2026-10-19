import Foundation
import GanninRemote

/// What a connection from an unpaired key may do: pair, and nothing else.
///
/// It wraps one `PairingResponder`. The code is spent when the phone's proof is checked, so there is
/// one guess per code, and a phone that only connects can't use the code up. The connection closes when the exchange ends and, if the phone goes quiet
/// before it has proved the code, after `handshakeSeconds`. No session data and no intent
/// is reachable from here: that needs `RemoteConnection`, which only a paired key gets.
@MainActor
final class PairingConnection {
    static let handshakeSeconds = 20
    /// Time for the last frame to reach the phone before the connection is closed.
    static let closeGraceSeconds = 2

    private let link: any RemoteLink
    private var responder: PairingResponder
    private var decoder = FrameDecoder()
    private let isOpen: @MainActor () -> Bool
    private let consume: @MainActor () -> PairingSecret?
    private let confirm: @MainActor (String) async -> Bool
    private let onPaired: @MainActor (String) -> Void
    private var timeout: Task<Void, Never>?
    private(set) var isClosed = false
    var onClose: (() -> Void)?

    /// `isOpen` says whether a pairing code is on offer; `consume` spends it. `confirm` asks the person to approve a phone by
    /// name. `onPaired` saves the phone; it runs before the phone is told it succeeded, so a phone
    /// that believes it is paired always is.
    init(
        link: any RemoteLink,
        macFingerprint: Data,
        phoneFingerprint: Data,
        isOpen: @escaping @MainActor () -> Bool,
        consume: @escaping @MainActor () -> PairingSecret?,
        confirm: @escaping @MainActor (String) async -> Bool,
        onPaired: @escaping @MainActor (String) -> Void
    ) {
        self.link = link
        self.responder = PairingResponder(macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint)
        self.isOpen = isOpen
        self.consume = consume
        self.confirm = confirm
        self.onPaired = onPaired
    }

    func start() {
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.handshakeSeconds))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func receive(_ data: Data) {
        guard !isClosed else { return }
        decoder.append(data)
        do {
            while let payload = try decoder.next() {
                perform(responder.handle(try FrameCodec.decode(payload, as: ClientMessage.self), isOpen: isOpen, consume: consume))
            }
        } catch {
            close()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        timeout?.cancel()
        link.close()
        onClose?()
    }

    /// The link ended on its own.
    func linkClosed() {
        guard !isClosed else { return }
        isClosed = true
        timeout?.cancel()
        onClose?()
    }

    /// What a phone calls itself, which anyone can set to anything: control characters are dropped and the length capped before the person reads it or it is saved.
    static func displayName(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !$0.properties.generalCategory.isControl }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "iPhone" : String(cleaned.prefix(60))
    }

    private func perform(_ action: PairingResponder.Action) {
        switch action {
        case .send(let message):
            send(message)
            if case .pairAccepted = message { finish() }
        case .reject(let reason):
            send(.pairRejected(reason: reason))
            finish()
        case .confirm(let phoneName):
            // The person may take as long as they need; only the phone's silence is timed.
            timeout?.cancel()
            let name = Self.displayName(phoneName)
            Task { [self] in
                let approved = await confirm(name)
                // Closed meanwhile, by the phone leaving or by `RemoteHost.stop()`: nothing to answer.
                guard !isClosed else { return }
                let next = responder.confirmed(approved)
                if case .send(.pairAccepted) = next { onPaired(name) }
                perform(next)
            }
        }
    }

    private func finish() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.closeGraceSeconds))
            self?.close()
        }
    }

    private func send(_ message: ServerMessage) {
        guard !isClosed, let data = try? FrameCodec.encode(message) else { return }
        link.send(data)
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool {
        switch self {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: true
        default: false
        }
    }
}
