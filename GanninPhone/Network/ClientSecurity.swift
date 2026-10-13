import Foundation
import GanninRemote
import Network
import SwiftUI

/// The phone's half of the TLS and key pinning, behind a seam like the Mac's
/// (`RemoteTransportSecurity`): the phone's identity, and connection parameters that
/// accept only the key a paired Mac is pinned to. Not implemented yet.
nonisolated protocol ClientTransportSecurity: Sendable {
    var isAvailable: Bool { get }
    func parameters(forMac mac: PairedMac) throws -> NWParameters
}

/// Pairing: proving the secret to a Mac and pinning each other's keys.
nonisolated protocol PairingHandshake: Sendable {
    /// `expectedMacFingerprint` is known when the secret came from a scanned code, nil when typed.
    func pair(secret: PairingSecret, expectedMacFingerprint: Data?, via endpoint: NWEndpoint) async throws -> PairedMac
}

nonisolated enum PhoneError: LocalizedError {
    case notAvailable
    case notConnected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Pairing isn't available in this build yet."
        case .notConnected: "Not connected to the Mac."
        case .timedOut: "The Mac didn't answer."
        }
    }
}

nonisolated struct UnconfiguredClientSecurity: ClientTransportSecurity, PairingHandshake {
    var isAvailable: Bool { false }

    func parameters(forMac mac: PairedMac) throws -> NWParameters {
        throw PhoneError.notAvailable
    }

    func pair(secret: PairingSecret, expectedMacFingerprint: Data?, via endpoint: NWEndpoint) async throws -> PairedMac {
        throw PhoneError.notAvailable
    }
}

/// What the views need that isn't the model: how to secure a connection and how to pair.
nonisolated struct PhoneServices: Sendable {
    var security: any ClientTransportSecurity = UnconfiguredClientSecurity()
    var pairing: any PairingHandshake = UnconfiguredClientSecurity()
}

private nonisolated struct PhoneServicesKey: EnvironmentKey {
    static let defaultValue = PhoneServices()
}

extension EnvironmentValues {
    var phoneServices: PhoneServices {
        get { self[PhoneServicesKey.self] }
        set { self[PhoneServicesKey.self] = newValue }
    }
}
