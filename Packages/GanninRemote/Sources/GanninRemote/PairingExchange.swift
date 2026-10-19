import Foundation

#if canImport(CryptoKit)
import CryptoKit

public enum PairingNonce {
    public static let byteCount = 32

    public static func generate() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

/// The Mac's side of the pairing exchange on one unpaired connection, as a state machine
/// with no network in it. Both fingerprints are the ones the TLS handshake observed, never
/// ones a message states, so a device relaying the exchange proves itself under its own keys
/// and fails.
///
/// The code is spent when the phone's proof is checked, right or wrong: one guess per code. A
/// request alone doesn't spend it, so a device that connects and sends nothing, or only a request,
/// can't use up the code before the real phone has tried it.
public struct PairingResponder: Sendable {
    public enum Action: Equatable, Sendable {
        case send(ServerMessage)
        /// The phone proved it has the code. Ask the person, then call `confirmed(_:)`.
        case confirm(phoneName: String)
        /// Tell the phone and close the connection.
        case reject(PairingRefusal)
    }

    private enum Phase {
        case awaitingRequest
        case awaitingProof(name: String, phoneNonce: Data)
        case awaitingConfirmation(secret: PairingSecret, phoneNonce: Data)
        case finished
    }

    private let macFingerprint: Data
    private let phoneFingerprint: Data
    private let macNonce: Data
    private var phase = Phase.awaitingRequest

    public init(macFingerprint: Data, phoneFingerprint: Data, nonce: Data = PairingNonce.generate()) {
        self.macFingerprint = macFingerprint
        self.phoneFingerprint = phoneFingerprint
        self.macNonce = nonce
    }

    /// `isOpen` says whether the Mac still has a code on offer, as `PairingWindow.isOpen`, without spending it.
    /// `consume` spends it, as `PairingWindow.consume`, and is called once, when the proof arrives. Two
    /// connections can both see the code open; only the first to reach its proof gets the secret.
    public mutating func handle(_ message: ClientMessage, isOpen: () -> Bool, consume: () -> PairingSecret?) -> Action {
        switch (phase, message) {
        case (.awaitingRequest, .pairRequest(let name, let nonce)):
            guard nonce.count == PairingNonce.byteCount, !name.isEmpty else { return fail(.invalid) }
            guard isOpen() else { return fail(.expired) }
            phase = .awaitingProof(name: name, phoneNonce: nonce)
            return .send(.pairChallenge(nonce: macNonce))
        case (.awaitingProof(let name, let phoneNonce), .pairProof(let proof)):
            guard let secret = consume() else { return fail(.expired) }
            guard PairingProof.verify(
                proof, role: .phone, secret: secret,
                macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint,
                macNonce: macNonce, phoneNonce: phoneNonce
            ) else { return fail(.wrongCode) }
            phase = .awaitingConfirmation(secret: secret, phoneNonce: phoneNonce)
            return .confirm(phoneName: name)
        default:
            return fail(.invalid)
        }
    }

    /// The person's answer. On yes, the phone is sent the Mac's proof, which it checks before pinning this Mac.
    public mutating func confirmed(_ accepted: Bool) -> Action {
        guard case .awaitingConfirmation(let secret, let phoneNonce) = phase else { return fail(.invalid) }
        guard accepted else { return fail(.declined) }
        phase = .finished
        return .send(.pairAccepted(proof: PairingProof.make(
            role: .mac, secret: secret,
            macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint,
            macNonce: macNonce, phoneNonce: phoneNonce
        )))
    }

    public var isFinished: Bool {
        if case .finished = phase { true } else { false }
    }

    private mutating func fail(_ reason: PairingRefusal) -> Action {
        phase = .finished
        return .reject(reason)
    }
}

/// The phone's side. `macFingerprint` is the key the Mac presented in TLS. When the code came
/// from a scanned QR, `expectedMacFingerprint` is the key the QR carried and must match it;
/// for a typed code there's none, and the Mac's proof of the code is what ties it to the person
/// at the screen.
public struct PairingInitiator: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The Mac answering isn't the one whose QR code was scanned.
        case wrongMac
        /// The Mac's proof didn't match: it doesn't know the code, or something sat between.
        case macNotProven
        case refused(PairingRefusal)
        case unexpected
    }

    public enum Outcome: Equatable, Sendable {
        case send(ClientMessage)
        /// The Mac proved it knows the code. Pin `macFingerprint`.
        case paired
        case failed(Failure)
    }

    private enum Phase {
        case start
        case awaitingChallenge
        case awaitingAcceptance(macNonce: Data)
        case finished
    }

    private let secret: PairingSecret
    private let name: String
    private let phoneFingerprint: Data
    private let macFingerprint: Data
    private let expectedMacFingerprint: Data?
    private let phoneNonce: Data
    private var phase = Phase.start

    public init(secret: PairingSecret, name: String, phoneFingerprint: Data, macFingerprint: Data, expectedMacFingerprint: Data?, nonce: Data = PairingNonce.generate()) {
        self.secret = secret
        self.name = name
        self.phoneFingerprint = phoneFingerprint
        self.macFingerprint = macFingerprint
        self.expectedMacFingerprint = expectedMacFingerprint
        self.phoneNonce = nonce
    }

    /// Nothing is sent to a Mac whose key isn't the one the QR code named.
    public mutating func start() -> Outcome {
        guard case .start = phase else { return fail(.unexpected) }
        if let expected = expectedMacFingerprint, expected != macFingerprint { return fail(.wrongMac) }
        phase = .awaitingChallenge
        return .send(.pairRequest(name: name, nonce: phoneNonce))
    }

    public mutating func handle(_ message: ServerMessage) -> Outcome {
        if case .pairRejected(let reason) = message { return fail(.refused(reason)) }
        switch (phase, message) {
        case (.awaitingChallenge, .pairChallenge(let nonce)):
            guard nonce.count == PairingNonce.byteCount else { return fail(.unexpected) }
            phase = .awaitingAcceptance(macNonce: nonce)
            return .send(.pairProof(PairingProof.make(
                role: .phone, secret: secret,
                macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint,
                macNonce: nonce, phoneNonce: phoneNonce
            )))
        case (.awaitingAcceptance(let macNonce), .pairAccepted(let proof)):
            guard PairingProof.verify(
                proof, role: .mac, secret: secret,
                macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint,
                macNonce: macNonce, phoneNonce: phoneNonce
            ) else { return fail(.macNotProven) }
            phase = .finished
            return .paired
        default:
            return fail(.unexpected)
        }
    }

    private mutating func fail(_ failure: Failure) -> Outcome {
        phase = .finished
        return .failed(failure)
    }
}
#endif
