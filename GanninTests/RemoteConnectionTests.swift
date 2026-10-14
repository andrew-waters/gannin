import Foundation
import GanninRemote
import Testing
@testable import Gannin

@MainActor
private final class FakeLink: RemoteLink {
    private(set) var frames: [Data] = []
    private(set) var closed = false

    func send(_ data: Data) { frames.append(data) }
    func close() { closed = true }

    /// What the Mac has sent, decoded.
    func messages() throws -> [ServerMessage] {
        var decoder = FrameDecoder()
        frames.forEach { decoder.append($0) }
        var out: [ServerMessage] = []
        while let payload = try decoder.next() { out.append(try FrameCodec.decode(payload, as: ServerMessage.self)) }
        return out
    }
}

private let phoneKey = Data([1, 2, 3, 4])

private func session(_ id: String, state: RemoteSessionState = .working) -> RemoteSession {
    RemoteSession(id: id, reference: "acme/app#1", title: "Fix", kind: "Code", state: state, mode: .attended, modeLabel: "Attended", canGoUnattended: true)
}

@MainActor
private struct Fixture {
    let link = FakeLink()
    let phones: PairedPhones
    let control = FakeControl()
    let connection: RemoteConnection
    let defaults: UserDefaults

    init(limit: Int = 20, sessions: @escaping @MainActor () -> [RemoteSession] = { [session("A")] }) {
        defaults = UserDefaults(suiteName: "remote-connection-tests-\(UUID().uuidString)")!
        phones = PairedPhones(defaults: defaults)
        let phone = phones.add(name: "Alex's iPhone", fingerprint: phoneKey)
        connection = RemoteConnection(
            phone: phone, fingerprint: phoneKey, link: link,
            handler: RemoteIntentHandler(control: control), phones: phones, macName: "Studio",
            limiter: IntentRateLimiter(limit: limit, window: 60), snapshot: sessions
        )
    }

    func receive(_ message: ClientMessage) throws {
        connection.receive(try FrameCodec.encode(message))
    }

    /// Intents finish in a task of their own.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }
}

@Test @MainActor func aConnectionStartsByNamingTheMac() throws {
    let f = Fixture()
    f.connection.start()
    #expect(try f.link.messages() == [.hello(macName: "Studio")])
}

@Test @MainActor func subscribingSendsEverySession() throws {
    let f = Fixture(sessions: { [session("A"), session("B")] })
    try f.receive(.subscribe)
    #expect(try f.link.messages() == [.snapshot(sessions: [session("A"), session("B")])])
}

@Test @MainActor func onlyChangesAreSentAfterTheSnapshot() throws {
    let f = Fixture()
    f.connection.push([session("A"), session("B")])
    #expect(try f.link.messages().isEmpty)
    try f.receive(.subscribe)
    f.connection.push([session("A"), session("B", state: .needsYou)])
    f.connection.push([session("A"), session("B", state: .needsYou)])
    f.connection.push([session("B", state: .needsYou)])
    #expect(try f.link.messages() == [
        .snapshot(sessions: [session("A")]),
        .sessionChanged(session: session("B", state: .needsYou)),
        .sessionRemoved(id: "A"),
    ])
}

@Test @MainActor func anIntentIsHandledAndAnswered() async throws {
    let f = Fixture()
    let id = UUID().uuidString
    try f.receive(.intent(id: "1", session: id, promptID: nil, intent: .interrupt))
    await f.settle()
    #expect(try f.link.messages() == [.result(id: "1", result: .ok)])
    #expect(f.control.calls == ["interrupt"])
}

@Test @MainActor func aRefusalIsReportedNotSwallowed() async throws {
    let f = Fixture()
    f.control.prompt = nil
    try f.receive(.intent(id: "9", session: UUID().uuidString, promptID: "tool-1", intent: .deny))
    await f.settle()
    #expect(try f.link.messages() == [.result(id: "9", result: .refused(reason: .promptGone))])
}

@Test @MainActor func tooManyIntentsAreRefusedWithoutReachingTheStore() async throws {
    let f = Fixture(limit: 1)
    let id = UUID().uuidString
    try f.receive(.intent(id: "1", session: id, promptID: nil, intent: .interrupt))
    try f.receive(.intent(id: "2", session: id, promptID: nil, intent: .interrupt))
    await f.settle()
    let messages = try f.link.messages()
    #expect(messages.contains(.result(id: "2", result: .refused(reason: .rateLimited))))
    #expect(f.control.calls == ["interrupt"])
}

@Test @MainActor func aRevokedPhoneIsDisconnectedOnItsNextMessage() throws {
    let f = Fixture()
    f.phones.revoke(try #require(f.phones.phone(for: phoneKey)))
    try f.receive(.subscribe)
    #expect(f.link.closed)
    #expect(f.connection.isClosed)
    #expect(try f.link.messages().isEmpty)
}

@Test @MainActor func revocationPreventsAnAlreadyQueuedIntent() async throws {
    let f = Fixture()
    try f.receive(.intent(id: "1", session: UUID().uuidString, promptID: nil, intent: .interrupt))
    f.phones.revoke(try #require(f.phones.phone(for: phoneKey)))
    await f.settle()
    #expect(f.control.calls.isEmpty)
    #expect(f.connection.isClosed)
    #expect(try f.link.messages().isEmpty)
}

@Test @MainActor func closingPreventsAnAlreadyQueuedIntent() async throws {
    let f = Fixture()
    try f.receive(.intent(id: "1", session: UUID().uuidString, promptID: nil, intent: .interrupt))
    f.connection.close()
    await f.settle()
    #expect(f.control.calls.isEmpty)
    #expect(try f.link.messages().isEmpty)
}

@Test @MainActor func oversizedSessionsAreOmittedAndLaterUpdatesAreDelivered() throws {
    var huge = session("A")
    huge.lastMessage = String(repeating: "x", count: RemoteProtocol.maxFrameBytes)
    let f = Fixture(sessions: { [huge, session("B")] })
    try f.receive(.subscribe)
    f.connection.push([session("A"), session("B")])
    f.connection.push([huge, session("B")])
    #expect(try f.link.messages() == [
        .snapshot(sessions: [session("B")]),
        .sessionChanged(session: session("A")),
        .sessionRemoved(id: "A"),
    ])
}

@Test @MainActor func garbageClosesTheConnection() {
    let f = Fixture()
    f.connection.receive(Data([0, 0, 0, 3, 0x6e, 0x6f, 0x70]))
    #expect(f.link.closed)
}

@Test @MainActor func hostileLengthClosesTheConnection() {
    let f = Fixture()
    f.connection.receive(Data([0xFF, 0xFF, 0xFF, 0xFF]))
    #expect(f.link.closed)
}

@Test @MainActor func framesSplitAcrossReadsAreHandled() throws {
    let f = Fixture()
    let data = try FrameCodec.encode(ClientMessage.subscribe)
    for byte in data { f.connection.receive(Data([byte])) }
    #expect(try f.link.messages().count == 1)
}

@Test @MainActor func helloNotesWhenThePhoneWasSeen() throws {
    let f = Fixture()
    try f.receive(.hello(name: "Alex's iPhone"))
    #expect(f.phones.phone(for: phoneKey)?.lastSeen != nil)
}

@Test @MainActor func nothingIsSentAfterClose() throws {
    let f = Fixture()
    try f.receive(.subscribe)
    f.connection.close()
    f.connection.push([session("Z")])
    f.connection.heartbeat()
    #expect(try f.link.messages().count == 1)
}

@Test @MainActor func closingReportsOnce() {
    let f = Fixture()
    var closes = 0
    f.connection.onClose = { _ in closes += 1 }
    f.connection.close()
    f.connection.linkClosed()
    f.connection.close()
    #expect(closes == 1)
}
