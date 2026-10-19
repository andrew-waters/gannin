import Foundation
import GanninRemote
import Network

/// The TLS and key-pinning half of a connection, kept behind a seam so the rest of remote
/// control doesn't depend on it. It owns this Mac's identity, the listener's mutual-TLS
/// parameters, and the key a connected phone proved it holds. `RemoteHost` refuses to start
/// without one that is available, rather than listening without it.
nonisolated protocol RemoteTransportSecurity: Sendable {
    /// False while there's nothing to secure the connection with.
    var isAvailable: Bool { get }
    /// This Mac's key fingerprint, which the pairing QR code carries.
    var macFingerprint: Data? { get }
    func listenerParameters() throws -> NWParameters
    /// The fingerprint of the phone's key as the TLS handshake authenticated it; nil until
    /// the handshake has completed.
    func peerFingerprint(of connection: NWConnection) -> Data?
}

/// Pinned mutual TLS (`PinnedTLS`) under a key kept in the login keychain.
///
/// The key is made the first time the host starts, not at launch, so a Mac that never turns remote
/// control on never gets one. It then lasts: phones pair to this key, and a new one would unpair them all.
nonisolated final class KeychainTransportSecurity: RemoteTransportSecurity, @unchecked Sendable {  // `identity` is only touched under `lock`.
    static let label = "dev.andon.gannin.remote"

    private let label: String
    private let lock = NSLock()
    private var identity: DeviceIdentity?

    init(label: String = KeychainTransportSecurity.label) {
        self.label = label
    }

    var isAvailable: Bool { true }

    var macFingerprint: Data? { try? loadIdentity().fingerprint }

    /// The listener accepts any key the phone presents. An unpaired phone has to get as far as the
    /// pairing exchange, so who may do what is decided afterwards, by `RemoteHost.accept`: a key
    /// in `PairedPhones` gets sessions, any other gets pairing and nothing else.
    func listenerParameters() throws -> NWParameters {
        PinnedTLS.parameters(identity: try loadIdentity()) { _ in true }
    }

    func peerFingerprint(of connection: NWConnection) -> Data? {
        PinnedTLS.peerFingerprint(of: connection)
    }

    private func loadIdentity() throws -> DeviceIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let identity { return identity }
        let loaded = try DeviceIdentity.loadOrCreate(label: label)
        identity = loaded
        return loaded
    }
}

nonisolated struct UnconfiguredTransportSecurity: RemoteTransportSecurity {
    var isAvailable: Bool { false }
    var macFingerprint: Data? { nil }

    func listenerParameters() throws -> NWParameters {
        throw RemoteHostError.securityNotConfigured
    }

    func peerFingerprint(of connection: NWConnection) -> Data? { nil }
}

nonisolated enum RemoteHostError: Error, LocalizedError {
    case securityNotConfigured

    var errorDescription: String? {
        switch self {
        case .securityNotConfigured: "Remote control isn't available in this build yet."
        }
    }
}
