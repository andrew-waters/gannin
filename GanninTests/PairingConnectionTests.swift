import CryptoKit
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

    func messages() throws -> [ServerMessage] {
        var decoder = FrameDecoder()
        frames.forEach { decoder.append($0) }
        var out: [ServerMessage] = []
        while let payload = try decoder.next() { out.append(try FrameCodec.decode(payload, as: ServerMessage.self)) }
        return out
    }
}

private let macKey = Data(SHA256.hash(data: Data("mac".utf8)))
private let phoneKey = Data(SHA256.hash(data: Data("phone".utf8)))

/// A Mac's pairing side and a phone's, joined by a fake link.
@MainActor
private final class Exchange {
    let link = FakeLink()
    /// The code the Mac has on offer; nil when it isn't offering one.
    var window: PairingWindow?
    /// Names `onPaired` was called with.
    private(set) var paired: [String] = []
    private var connection: PairingConnection!
    private var initiator: PairingInitiator
    private var decoded = 0

    /// `shown` is the code the phone was given, which may not be the Mac's.
    init(window: PairingWindow? = PairingWindow(), shown: PairingSecret? = nil, phoneName: String = "Alex's iPhone", confirm: @escaping @MainActor (String) async -> Bool = { _ in true }) {
        self.window = window
        initiator = PairingInitiator(
            secret: shown ?? window?.secret ?? .generate(), name: phoneName,
            phoneFingerprint: phoneKey, macFingerprint: macKey, expectedMacFingerprint: macKey
        )
        connection = PairingConnection(
            link: link, macFingerprint: macKey, phoneFingerprint: phoneKey,
            isOpen: { [unowned self] in self.window?.isOpen() ?? false },
            consume: { [unowned self] in self.window?.consume() },
            confirm: confirm,
            onPaired: { [unowned self] name in self.paired.append(name) }
        )
    }

    /// Plays the phone: sends each message and feeds back the Mac's replies, until the phone has an outcome.
    func run() async -> PairingInitiator.Outcome {
        var outcome = initiator.start()
        while case .send(let message) = outcome {
            connection.receive(try! FrameCodec.encode(message))
            // The confirmation runs in a task of its own.
            for _ in 0..<50 { await Task.yield() }
            let replies = try! link.messages()
            guard replies.count > decoded else { return .failed(.unexpected) }
            let reply = replies[decoded]
            decoded += 1
            outcome = initiator.handle(reply)
        }
        return outcome
    }

    func closeConnection() { connection.close() }

    /// A device that asks to pair and then goes quiet.
    func sendRequestOnly() {
        guard case .send(let request) = initiator.start() else { return }
        connection.receive(try! FrameCodec.encode(request))
    }
}

@Test @MainActor func aPhoneWithTheCodeIsConfirmedSavedAndTold() async throws {
    let exchange = Exchange()
    #expect(await exchange.run() == .paired)
    #expect(exchange.paired == ["Alex's iPhone"])
}

@Test @MainActor func theWrongCodeIsRefusedAndNothingIsSaved() async {
    let exchange = Exchange(shown: .generate())
    #expect(await exchange.run() == .failed(.refused(.wrongCode)))
    #expect(exchange.paired.isEmpty)
}

@Test @MainActor func withNoCodeOnOfferAPairingAttemptIsRefused() async {
    let exchange = Exchange(window: nil)
    #expect(await exchange.run() == .failed(.refused(.expired)))
    #expect(exchange.paired.isEmpty)
}

@Test @MainActor func aSecondAttemptWithTheSameCodeIsRefused() async {
    let first = Exchange()
    #expect(await first.run() == .paired)
    let second = Exchange(window: first.window, shown: first.window?.secret)
    #expect(await second.run() == .failed(.refused(.expired)))
}

@Test @MainActor func aDeviceThatOnlyAsksToPairDoesNotUseUpTheCode() async {
    let idler = Exchange()
    idler.sendRequestOnly()
    #expect(idler.window?.isOpen() == true)
    let real = Exchange(window: idler.window)
    #expect(await real.run() == .paired)
}

@Test @MainActor func decliningSavesNothing() async {
    let exchange = Exchange(confirm: { _ in false })
    #expect(await exchange.run() == .failed(.refused(.declined)))
    #expect(exchange.paired.isEmpty)
}

@Test @MainActor func aConnectionClosedWhileTheMacAsksSavesNothing() async {
    // The confirmation stays open until the connection has gone.
    let gate = Gate()
    let exchange = Exchange(confirm: { _ in await gate.wait(); return true })
    _ = await exchange.run()
    #expect(exchange.paired.isEmpty)
    exchange.closeConnection()
    gate.open()
    for _ in 0..<50 { await Task.yield() }
    #expect(exchange.paired.isEmpty)
}

@Test @MainActor func theMacAsksAboutTheNameItWillSave() async {
    var asked: [String] = []
    let exchange = Exchange(phoneName: "  Alex\n\u{202E}'s iPhone  ", confirm: { name in asked.append(name); return true })
    _ = await exchange.run()
    #expect(asked == ["Alex's iPhone"])
    #expect(exchange.paired == asked)
}

@Test func phoneNamesAreCleanedAndCapped() {
    #expect(PairingConnection.displayName("") == "iPhone")
    #expect(PairingConnection.displayName(" \n ") == "iPhone")
    #expect(PairingConnection.displayName(String(repeating: "x", count: 200)).count == 60)
}

@Test @MainActor func aPhoneThatSaysNothingIsDroppedAfterTheHandshakeTime() async throws {
    let link = FakeLink()
    let connection = PairingConnection(link: link, macFingerprint: macKey, phoneFingerprint: phoneKey, isOpen: { false }, consume: { nil }, confirm: { _ in false }, onPaired: { _ in })
    connection.start()
    #expect(!link.closed)
    connection.close()
    #expect(link.closed && connection.isClosed)
}

@Test @MainActor func garbageClosesAPairingConnection() {
    let link = FakeLink()
    let connection = PairingConnection(link: link, macFingerprint: macKey, phoneFingerprint: phoneKey, isOpen: { false }, consume: { nil }, confirm: { _ in false }, onPaired: { _ in })
    connection.receive(Data([0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3]))
    #expect(link.closed)
}

@Test @MainActor func aConnectionThatIsNotPairingCannotAskForSessions() throws {
    let link = FakeLink()
    let connection = PairingConnection(link: link, macFingerprint: macKey, phoneFingerprint: phoneKey, isOpen: { true }, consume: { PairingSecret.generate() }, confirm: { _ in true }, onPaired: { _ in })
    connection.receive(try FrameCodec.encode(ClientMessage.subscribe))
    #expect(try link.messages() == [.pairRejected(reason: .invalid)])
}

/// Holds an async caller until `open()`.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
