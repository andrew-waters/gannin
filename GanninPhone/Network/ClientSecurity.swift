import Foundation
import GanninRemote
import Network
import SwiftUI
import UIKit

/// The phone's half of the TLS and key pinning, behind a seam like the Mac's
/// (`RemoteTransportSecurity`): the phone's identity, and connection parameters that
/// accept only the key a paired Mac is pinned to.
nonisolated protocol ClientTransportSecurity: Sendable {
    func parameters(forMac mac: PairedMac) throws -> NWParameters
}

/// Pairing: proving the secret to a Mac and pinning each other's keys.
nonisolated protocol PairingHandshake: Sendable {
    /// `expectedMacFingerprint` is known when the secret came from a scanned code, nil when typed.
    func pair(secret: PairingSecret, expectedMacFingerprint: Data?, via endpoint: NWEndpoint) async throws -> PairedMac
}

nonisolated enum PhoneError: LocalizedError {
    case notConnected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Mac."
        case .timedOut: "The Mac didn't answer."
        }
    }
}

/// Pinned mutual TLS (`PinnedTLS`) under a key kept in this phone's keychain.
///
/// The key is made the first time it is needed and stays: every Mac paired to it would have to pair
/// again if it changed. It is usable only while the phone is unlocked and never leaves this phone
/// (`DeviceIdentity`).
nonisolated final class KeychainClientSecurity: ClientTransportSecurity, PairingHandshake, @unchecked Sendable {  // `identity` is only touched under `lock`.
    static let label = "dev.andon.gannin.remote.phone"

    private let lock = NSLock()
    private var identity: DeviceIdentity?

    /// Accepts only the key this Mac was paired under. A different Mac, or a device pretending to
    /// be this one, can't complete the handshake, so nothing is sent to it.
    func parameters(forMac mac: PairedMac) throws -> NWParameters {
        guard let pin = Data(hex: mac.fingerprint) else { throw IdentityError.keyUnavailable }
        return PinnedTLS.parameters(identity: try loadIdentity()) { $0 == pin }
    }

    func pair(secret: PairingSecret, expectedMacFingerprint: Data?, via endpoint: NWEndpoint) async throws -> PairedMac {
        let identity = try loadIdentity()
        let phoneName = await MainActor.run { UIDevice.current.name }
        let macFingerprint = try await PairingClient.pair(
            identity: identity, secret: secret, name: phoneName,
            expectedMacFingerprint: expectedMacFingerprint, via: endpoint
        )
        // The name the Mac advertises, which is how it is found again.
        var macName = "Mac"
        if case .service(let name, _, _, _) = endpoint { macName = name }
        return PairedMac(fingerprint: macFingerprint.hexString, name: macName, pairedAt: .now)
    }

    private func loadIdentity() throws -> DeviceIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let identity { return identity }
        let loaded = try DeviceIdentity.loadOrCreate(label: Self.label)
        identity = loaded
        return loaded
    }
}

/// What the views need that isn't the model: how to secure a connection and how to pair.
nonisolated struct PhoneServices: Sendable {
    var security: any ClientTransportSecurity
    var pairing: any PairingHandshake

    init(client: KeychainClientSecurity = KeychainClientSecurity()) {
        security = client
        pairing = client
    }
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
