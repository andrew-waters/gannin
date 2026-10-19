import Foundation
import Network
import os

/// The phone's side of pairing, over the network: connects to a Mac, runs `PairingInitiator`
/// against it and returns the Mac's key fingerprint once the Mac has proved it knows the code.
/// The caller pins that fingerprint; nothing here stores anything.
public enum PairingClient {
    /// Long enough for the person to confirm on the Mac, short enough not to hang a screen.
    public static let timeoutSeconds = 60

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case closed
        case timedOut
        case failed(PairingInitiator.Failure)

        public var errorDescription: String? {
            switch self {
            case .closed: "The Mac closed the connection."
            case .timedOut: "The Mac didn't answer."
            case .failed(.wrongMac): "That isn't the Mac whose code you scanned."
            case .failed(.macNotProven): "The Mac didn't prove it knows the code. Try again, and check you're on your own network."
            case .failed(.refused(.expired)): "That code has expired or been used. Start again on the Mac."
            case .failed(.refused(.wrongCode)): "That code isn't right."
            case .failed(.refused(.declined)): "The Mac declined."
            case .failed(.refused(.invalid)), .failed(.unexpected): "The Mac didn't understand. Update Gannin on both devices."
            }
        }
    }

    /// `expectedMacFingerprint` is the key the scanned QR code named, nil for a typed code.
    ///
    /// For a scanned code the TLS handshake itself is pinned to that key, so no message reaches a
    /// different Mac. For a typed code any key is accepted for this one connection, and what ties
    /// the key to the Mac showing the code is that Mac's proof of the code, which covers the key
    /// this phone saw (`PairingInitiator`). A device in between presents its own key, so its proof
    /// can't match.
    public static func pair(
        identity: DeviceIdentity,
        secret: PairingSecret,
        name: String,
        expectedMacFingerprint: Data?,
        via endpoint: NWEndpoint,
        timeoutSeconds: Int = PairingClient.timeoutSeconds
    ) async throws -> Data {
        let parameters = PinnedTLS.parameters(identity: identity) { presented in
            expectedMacFingerprint.map { $0 == presented } ?? true
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "dev.andon.gannin.remote.pairing")

        // One deadline for the whole attempt, handshake included: a Mac that accepts the connection and
        // never finishes TLS would otherwise leave the caller waiting for ever. Cancelling the connection
        // makes whatever is waiting on it finish, so `endedError` is what tells a timeout from a close.
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            timedOut.withLock { $0 = true }
            connection.cancel()
        }
        defer {
            timeout.cancel()
            connection.cancel()
        }
        let endedError = { timedOut.withLock { $0 } ? Error.timedOut : Error.closed }

        let incoming: Incoming
        do {
            incoming = try await Incoming.open(connection, on: queue)
        } catch let error as NWError {
            // Pinned to the scanned key, a handshake that fails in TLS means the Mac presented a different key.
            if expectedMacFingerprint != nil, case .tls = error { throw Error.failed(.wrongMac) }
            throw timedOut.withLock { $0 } ? Error.timedOut : error
        } catch Error.closed {
            throw endedError()
        }

        guard let macFingerprint = PinnedTLS.peerFingerprint(of: connection) else { throw endedError() }
        var initiator = PairingInitiator(
            secret: secret, name: name,
            phoneFingerprint: identity.fingerprint, macFingerprint: macFingerprint,
            expectedMacFingerprint: expectedMacFingerprint
        )
        var decoder = FrameDecoder()
        var chunks = incoming.stream.makeAsyncIterator()

        var outcome = initiator.start()
        while true {
            switch outcome {
            case .paired:
                return macFingerprint
            case .failed(let failure):
                throw Error.failed(failure)
            case .send(let message):
                connection.send(content: try FrameCodec.encode(message), completion: .contentProcessed { _ in })
            }
            // One reply per message sent.
            var reply: ServerMessage?
            while reply == nil {
                if let payload = try decoder.next() {
                    reply = try FrameCodec.decode(payload, as: ServerMessage.self)
                } else if let chunk = try await chunks.next() {
                    decoder.append(chunk)
                } else {
                    throw endedError()
                }
            }
            outcome = initiator.handle(reply!)
        }
    }
}

/// The bytes a connection receives, as a stream that ends when the connection does.
private struct Incoming {
    let stream: AsyncThrowingStream<Data, Swift.Error>

    /// Starts `connection`, returns once its TLS handshake has completed, and from then on feeds `stream`.
    static func open(_ connection: NWConnection, on queue: DispatchQueue) async throws -> Incoming {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Swift.Error>) in
            // Handlers run on `queue`, so this flag needs no lock.
            nonisolated(unsafe) var settled = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !settled else { return }
                    settled = true
                    ready.resume()
                case .failed(let error):
                    if !settled { settled = true; ready.resume(throwing: error) }
                    continuation.finish(throwing: error)
                case .waiting(let error):
                    // Network.framework reports a handshake our verify block refused (a TLS error) and a
                    // refused connection (ECONNREFUSED) as `.waiting`, and would retry when the network
                    // changes. A pairing attempt is one try, so give up and report the error.
                    if !settled { settled = true; ready.resume(throwing: error) }
                    connection.cancel()
                case .cancelled:
                    if !settled { settled = true; ready.resume(throwing: PairingClient.Error.closed) }
                    continuation.finish()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        receive(on: connection, into: continuation)
        return Incoming(stream: stream)
    }

    private static func receive(on connection: NWConnection, into continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty { continuation.yield(data) }
            if let error {
                continuation.finish(throwing: error)
            } else if isComplete {
                continuation.finish()
            } else {
                receive(on: connection, into: continuation)
            }
        }
    }
}
