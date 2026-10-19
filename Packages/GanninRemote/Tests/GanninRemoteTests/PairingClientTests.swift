import CryptoKit
import Foundation
import Network
import Testing
@testable import GanninRemote

/// A Mac's pairing side on a real TLS listener: `PairingResponder` for each connection, spending
/// `window`, and answering the confirmation with `confirm`.
private final class PairingMac: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var window: PairingWindow
    private var port: NWEndpoint.Port?
    private var connections: [NWConnection] = []
    let identity: DeviceIdentity
    let confirm: @Sendable (String) -> Bool

    init(identity: DeviceIdentity, window: PairingWindow, confirm: @escaping @Sendable (String) -> Bool = { _ in true }) async throws {
        self.identity = identity
        self.window = window
        self.confirm = confirm
        listener = try NWListener(using: PinnedTLS.parameters(identity: identity) { _ in true })
        listener.newConnectionHandler = { [unowned self] connection in serve(connection) }
        let ready = AsyncStream.makeStream(of: NWEndpoint.Port.self)
        listener.stateUpdateHandler = { [unowned self] in
            if case .ready = $0, let port = listener.port { ready.continuation.yield(port) }
        }
        listener.start(queue: .global())
        var iterator = ready.stream.makeAsyncIterator()
        port = await iterator.next()
    }

    deinit { listener.cancel(); connections.forEach { $0.cancel() } }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: port!) }

    func isOpen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return window.isOpen()
    }

    func consume() -> PairingSecret? {
        lock.lock(); defer { lock.unlock() }
        return window.consume()
    }

    private func serve(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        let session = ServedConnection(connection: connection, macFingerprint: identity.fingerprint, isOpen: isOpen, consume: consume, confirm: confirm)
        connection.stateUpdateHandler = { state in
            if case .ready = state { session.begin() }
        }
        connection.start(queue: .global())
    }
}

/// One accepted connection: a `PairingResponder` fed by what arrives, its answers sent back.
private final class ServedConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let macFingerprint: Data
    private let isOpen: @Sendable () -> Bool
    private let consume: @Sendable () -> PairingSecret?
    private let confirm: @Sendable (String) -> Bool
    private var responder: PairingResponder?
    private var decoder = FrameDecoder()

    init(connection: NWConnection, macFingerprint: Data, isOpen: @escaping @Sendable () -> Bool, consume: @escaping @Sendable () -> PairingSecret?, confirm: @escaping @Sendable (String) -> Bool) {
        self.connection = connection
        self.macFingerprint = macFingerprint
        self.isOpen = isOpen
        self.consume = consume
        self.confirm = confirm
    }

    func begin() {
        guard let phone = PinnedTLS.peerFingerprint(of: connection) else { return }
        responder = PairingResponder(macFingerprint: macFingerprint, phoneFingerprint: phone)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            guard let data else { return }
            decoder.append(data)
            while let payload = try? decoder.next(), let message = try? FrameCodec.decode(payload, as: ClientMessage.self) {
                run(responder!.handle(message, isOpen: isOpen, consume: consume))
            }
            if error == nil, !done { read() }
        }
    }

    private func run(_ action: PairingResponder.Action) {
        switch action {
        case .send(let message): send(message)
        case .reject(let reason): send(.pairRejected(reason: reason))
        case .confirm(let name): run(responder!.confirmed(confirm(name)))
        }
    }

    private func send(_ message: ServerMessage) {
        connection.send(content: try? FrameCodec.encode(message), completion: .contentProcessed { _ in })
    }
}

private func identities() throws -> (mac: DeviceIdentity, phone: DeviceIdentity, cleanup: @Sendable () -> Void) {
    let labels = ["mac", "phone"].map { "dev.andon.gannin.tests.\($0).\(UUID().uuidString)" }
    return (try DeviceIdentity.loadOrCreate(label: labels[0]), try DeviceIdentity.loadOrCreate(label: labels[1]), { labels.forEach(DeviceIdentity.delete) })
}

@Test func aPhonePairsOverRealTLSAndLearnsTheMacsKey() async throws {
    let (mac, phone, cleanup) = try identities()
    defer { cleanup() }
    let window = PairingWindow()
    let server = try await PairingMac(identity: mac, window: window)
    let pinned = try await PairingClient.pair(identity: phone, secret: window.secret, name: "Alex's iPhone", expectedMacFingerprint: mac.fingerprint, via: server.endpoint)
    #expect(pinned == mac.fingerprint)
}

@Test func aTypedCodePairsWithoutAnExpectedKey() async throws {
    let (mac, phone, cleanup) = try identities()
    defer { cleanup() }
    let window = PairingWindow()
    let server = try await PairingMac(identity: mac, window: window)
    let pinned = try await PairingClient.pair(identity: phone, secret: window.secret, name: "P", expectedMacFingerprint: nil, via: server.endpoint)
    #expect(pinned == mac.fingerprint)
}

@Test func theWrongCodeIsRefusedAndTheCodeIsSpent() async throws {
    let (mac, phone, cleanup) = try identities()
    defer { cleanup() }
    let window = PairingWindow()
    let server = try await PairingMac(identity: mac, window: window)
    await #expect(throws: PairingClient.Error.failed(.refused(.wrongCode))) {
        try await PairingClient.pair(identity: phone, secret: PairingSecret.generate(), name: "P", expectedMacFingerprint: nil, via: server.endpoint)
    }
    // The right code, afterwards, finds the window spent.
    await #expect(throws: PairingClient.Error.failed(.refused(.expired))) {
        try await PairingClient.pair(identity: phone, secret: window.secret, name: "P", expectedMacFingerprint: nil, via: server.endpoint)
    }
}

@Test func aDeclinedPairingFails() async throws {
    let (mac, phone, cleanup) = try identities()
    defer { cleanup() }
    let window = PairingWindow()
    let server = try await PairingMac(identity: mac, window: window, confirm: { _ in false })
    await #expect(throws: PairingClient.Error.failed(.refused(.declined))) {
        try await PairingClient.pair(identity: phone, secret: window.secret, name: "P", expectedMacFingerprint: nil, via: server.endpoint)
    }
}

@Test func aScannedCodeForAnotherMacNeverReachesIt() async throws {
    let (mac, phone, cleanup) = try identities()
    defer { cleanup() }
    let window = PairingWindow()
    let server = try await PairingMac(identity: mac, window: window)
    await #expect(throws: PairingClient.Error.failed(.wrongMac)) {
        try await PairingClient.pair(identity: phone, secret: window.secret, name: "P", expectedMacFingerprint: Data(repeating: 9, count: 32), via: server.endpoint)
    }
    // The phone stopped before sending anything, so the Mac's code is still unspent.
    #expect(server.consume() == window.secret)
}

@Test func aMacThatNeverFinishesTheHandshakeTimesOut() async throws {
    let (_, phone, cleanup) = try identities()
    defer { cleanup() }
    // Accepts the TCP connection and says nothing, so the TLS handshake never completes.
    let silent = try NWListener(using: .tcp)
    silent.newConnectionHandler = { $0.start(queue: .global()) }
    let ready = AsyncStream.makeStream(of: NWEndpoint.Port.self)
    silent.stateUpdateHandler = { if case .ready = $0, let port = silent.port { ready.continuation.yield(port) } }
    silent.start(queue: .global())
    defer { silent.cancel() }
    var ports = ready.stream.makeAsyncIterator()
    let port = try #require(await ports.next())
    let started = Date()
    await #expect(throws: PairingClient.Error.timedOut) {
        try await PairingClient.pair(identity: phone, secret: .generate(), name: "P", expectedMacFingerprint: nil, via: .hostPort(host: "127.0.0.1", port: port), timeoutSeconds: 1)
    }
    #expect(Date().timeIntervalSince(started) < 10)
}
