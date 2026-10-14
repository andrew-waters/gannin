import Foundation
import Network

/// The TLS and key-pinning half of a connection, kept behind a seam so the rest of remote
/// control doesn't depend on it. It owns this Mac's identity, the listener's mutual-TLS
/// parameters, and the key a connected phone proved it holds. Nothing here is implemented
/// yet: until something other than `UnconfiguredTransportSecurity` is passed to `RemoteHost`,
/// the host refuses to start rather than listening without it.
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
