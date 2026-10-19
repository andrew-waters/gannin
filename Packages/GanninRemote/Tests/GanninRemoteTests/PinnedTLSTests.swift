import Foundation
import Network
import Security
import Testing
@testable import GanninRemote

private func makeIdentity() throws -> (DeviceIdentity, label: String) {
    let label = "dev.andon.gannin.tests.\(UUID().uuidString)"
    return (try DeviceIdentity.loadOrCreate(label: label), label)
}

/// Waits for a connection to leave setup: ready, or anything that means it won't be.
private func settle(_ connection: NWConnection) async -> NWConnection.State {
    await withCheckedContinuation { (done: CheckedContinuation<NWConnection.State, Never>) in
        let box = Once(done)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled, .waiting: box.resume(state)
            default: break
            }
        }
        connection.start(queue: .global())
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWConnection.State, Never>?
    init(_ continuation: CheckedContinuation<NWConnection.State, Never>) { self.continuation = continuation }
    func resume(_ state: NWConnection.State) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: state)
    }
}

/// A TLS listener on localhost. It starts each connection it accepts, as the real host does, and
/// reports the connection with the state it settled in.
private final class TestServer: @unchecked Sendable {
    let listener: NWListener
    let accepted: AsyncStream<(connection: NWConnection, state: NWConnection.State)>
    private(set) var port: NWEndpoint.Port!

    init(identity: DeviceIdentity, accept: @escaping @Sendable (Data) -> Bool = { _ in true }) async throws {
        listener = try NWListener(using: PinnedTLS.parameters(identity: identity, accept: accept))
        let (stream, continuation) = AsyncStream.makeStream(of: (connection: NWConnection, state: NWConnection.State).self)
        accepted = stream
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled, .waiting:
                    connection.stateUpdateHandler = nil
                    continuation.yield((connection, state))
                default: break
                }
            }
            connection.start(queue: .global())
        }
        port = await withCheckedContinuation { (done: CheckedContinuation<NWEndpoint.Port, Never>) in
            let box = PortOnce(done)
            listener.stateUpdateHandler = { if case .ready = $0, let port = self.listener.port { box.resume(port) } }
            listener.start(queue: .global())
        }
    }

    deinit { listener.cancel() }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: port) }
}

private final class PortOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint.Port, Never>?
    init(_ continuation: CheckedContinuation<NWEndpoint.Port, Never>) { self.continuation = continuation }
    func resume(_ port: NWEndpoint.Port) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: port)
    }
}

@Test func anIdentityIsMadeOnceAndLoadedAfter() throws {
    let (first, label) = try makeIdentity()
    defer { DeviceIdentity.delete(label: label) }
    #expect(first.fingerprint.count == 32)
    #expect(try DeviceIdentity.loadOrCreate(label: label).fingerprint == first.fingerprint)
    let (other, otherLabel) = try makeIdentity()
    defer { DeviceIdentity.delete(label: otherLabel) }
    #expect(other.fingerprint != first.fingerprint)
}

@Test func theCertificateParsesAndCarriesTheKey() throws {
    let (identity, label) = try makeIdentity()
    defer { DeviceIdentity.delete(label: label) }
    var certificate: SecCertificate?
    SecIdentityCopyCertificate(identity.identity, &certificate)
    let cert = try #require(certificate)
    #expect(PinnedTLS.fingerprint(of: SecCertificateCopyKey(cert)) == identity.fingerprint)
    // The certificate's own signature must verify, or a strict peer could reject it.
    let key = try #require(SecCertificateCopyKey(cert))
    let der = SecCertificateCopyData(cert) as Data
    #expect(der.count > 100)
    #expect(SecCertificateCopySubjectSummary(cert) as String? == label)
    _ = key
}

@Test func pinnedPeersSeeEachOthersKeys() async throws {
    let (macIdentity, macLabel) = try makeIdentity()
    let (phoneIdentity, phoneLabel) = try makeIdentity()
    defer { DeviceIdentity.delete(label: macLabel); DeviceIdentity.delete(label: phoneLabel) }
    let server = try await TestServer(identity: macIdentity)
    let macPin = macIdentity.fingerprint
    let client = NWConnection(to: server.endpoint, using: PinnedTLS.parameters(identity: phoneIdentity) { $0 == macPin })
    #expect(await settle(client) == .ready)
    var incoming = server.accepted.makeAsyncIterator()
    let (served, servedState) = try #require(await incoming.next())
    #expect(servedState == .ready)
    #expect(PinnedTLS.peerFingerprint(of: client) == macIdentity.fingerprint)
    #expect(PinnedTLS.peerFingerprint(of: served) == phoneIdentity.fingerprint)
    client.cancel(); served.cancel()
}

@Test func aMacWithAnotherKeyIsRefused() async throws {
    let (macIdentity, macLabel) = try makeIdentity()
    let (phoneIdentity, phoneLabel) = try makeIdentity()
    defer { DeviceIdentity.delete(label: macLabel); DeviceIdentity.delete(label: phoneLabel) }
    let server = try await TestServer(identity: macIdentity)
    let pinnedElsewhere = Data(repeating: 7, count: 32)
    let client = NWConnection(to: server.endpoint, using: PinnedTLS.parameters(identity: phoneIdentity) { $0 == pinnedElsewhere })
    #expect(await settle(client) != .ready)
    client.cancel()
}

@Test func aServerThatRefusesThePhoneKeyNeverCompletes() async throws {
    let (macIdentity, macLabel) = try makeIdentity()
    let (phoneIdentity, phoneLabel) = try makeIdentity()
    defer { DeviceIdentity.delete(label: macLabel); DeviceIdentity.delete(label: phoneLabel) }
    let server = try await TestServer(identity: macIdentity, accept: { _ in false })
    let client = NWConnection(to: server.endpoint, using: PinnedTLS.parameters(identity: phoneIdentity) { _ in true })
    // With TLS 1.3 the client finishes first and learns of the refusal from the server's alert, so the
    // connection that matters is the one the server accepted.
    _ = await settle(client)
    var incoming = server.accepted.makeAsyncIterator()
    if let (served, state) = await incoming.next() {
        #expect(state != .ready)
        served.cancel()
    }
    client.cancel()
}
