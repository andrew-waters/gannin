import CryptoKit
import Foundation
import Testing
@testable import GanninRemote

private let macKey = Data(SHA256.hash(data: Data("mac".utf8)))
private let phoneKey = Data(SHA256.hash(data: Data("phone".utf8)))
private let relayKey = Data(SHA256.hash(data: Data("relay".utf8)))

private struct Exchange {
    var responder: PairingResponder
    var initiator: PairingInitiator
    var window: PairingWindow
    /// What the phone was shown, which can differ from the Mac's secret.
    var phoneSecret: PairingSecret

    init(
        macSeen: Data = macKey,
        phoneSeen: Data = phoneKey,
        phoneSecret: PairingSecret? = nil,
        expected: Data? = macKey,
        window: PairingWindow = PairingWindow()
    ) {
        self.window = window
        self.phoneSecret = phoneSecret ?? window.secret
        responder = PairingResponder(macFingerprint: macKey, phoneFingerprint: phoneSeen)
        initiator = PairingInitiator(secret: self.phoneSecret, name: "Alex's iPhone", phoneFingerprint: phoneKey, macFingerprint: macSeen, expectedMacFingerprint: expected)
    }

    /// Runs the exchange to its end, confirming on the Mac with `accept`. Returns what the phone concluded.
    mutating func run(accept: Bool = true, at now: Date = Date()) -> PairingInitiator.Outcome {
        var outcome = initiator.start()
        while true {
            guard case .send(let message) = outcome else { return outcome }
            let action = responder.handle(message, isOpen: { window.isOpen(at: now) }, consume: { window.consume(at: now) })
            let reply: ServerMessage
            switch action {
            case .send(let m): reply = m
            case .reject(let reason): reply = .pairRejected(reason: reason)
            case .confirm:
                switch responder.confirmed(accept) {
                case .send(let m): reply = m
                case .reject(let reason): reply = .pairRejected(reason: reason)
                case .confirm: Issue.record("confirm twice"); return .failed(.unexpected)
                }
            }
            outcome = initiator.handle(reply)
        }
    }
}

@Test func pairingSucceedsWithTheRightCode() {
    var exchange = Exchange()
    #expect(exchange.run() == .paired)
    #expect(exchange.responder.isFinished)
}

@Test func aTypedCodeNeedsNoExpectedFingerprint() {
    var exchange = Exchange(expected: nil)
    #expect(exchange.run() == .paired)
}

@Test func theWrongCodeFailsAndSpendsTheWindow() {
    var exchange = Exchange(phoneSecret: PairingSecret.generate())
    #expect(exchange.run() == .failed(.refused(.wrongCode)))
    #expect(exchange.window.consume() == nil)
}

@Test func anExpiredCodeIsRefusedBeforeAnyProof() {
    let start = Date(timeIntervalSince1970: 1_000)
    var exchange = Exchange(window: PairingWindow(now: start))
    #expect(exchange.run(at: start.addingTimeInterval(PairingWindow.lifetime + 1)) == .failed(.refused(.expired)))
}

@Test func aSecondAttemptFindsTheCodeSpent() {
    var window = PairingWindow()
    let secret = window.secret
    var first = Exchange(phoneSecret: secret, window: window)
    #expect(first.run() == .paired)
    window = first.window
    var second = Exchange(phoneSecret: secret, window: window)
    #expect(second.run() == .failed(.refused(.expired)))
}

@Test func decliningOnTheMacFailsThePhone() {
    var exchange = Exchange()
    #expect(exchange.run(accept: false) == .failed(.refused(.declined)))
}

@Test func aPhoneThatSawADifferentMacKeyIsNotSentAnything() {
    var exchange = Exchange(macSeen: relayKey)
    #expect(exchange.initiator.start() == .failed(.wrongMac))
}

@Test func aTypedCodeThroughARelayFailsOnTheProofs() {
    // The phone talks to a relay under the relay's key; the Mac sees the relay's key as the phone's.
    // Neither proof can match the other side's view, so the exchange fails even with the right code.
    var exchange = Exchange(macSeen: relayKey, phoneSeen: relayKey, expected: nil)
    let outcome = exchange.run()
    #expect(outcome == .failed(.refused(.wrongCode)))
}

@Test func aRelayThatOnlyHidesThePhoneKeyFails() {
    var exchange = Exchange(phoneSeen: relayKey)
    #expect(exchange.run() == .failed(.refused(.wrongCode)))
}

@Test func theMacMustProveTheCodeToThePhone() {
    var initiator = PairingInitiator(secret: PairingSecret.generate(), name: "P", phoneFingerprint: phoneKey, macFingerprint: macKey, expectedMacFingerprint: nil)
    _ = initiator.start()
    _ = initiator.handle(.pairChallenge(nonce: PairingNonce.generate()))
    #expect(initiator.handle(.pairAccepted(proof: Data(count: 32))) == .failed(.macNotProven))
}

@Test func messagesOutOfOrderAreRefused() {
    var responder = PairingResponder(macFingerprint: macKey, phoneFingerprint: phoneKey)
    #expect(responder.handle(.pairProof(Data(count: 32)), isOpen: { true }, consume: { nil }) == .reject(.invalid))
    var again = PairingResponder(macFingerprint: macKey, phoneFingerprint: phoneKey)
    #expect(again.handle(.subscribe, isOpen: { true }, consume: { PairingSecret.generate() }) == .reject(.invalid))
    var short = PairingResponder(macFingerprint: macKey, phoneFingerprint: phoneKey)
    #expect(short.handle(.pairRequest(name: "P", nonce: Data(count: 4)), isOpen: { true }, consume: { PairingSecret.generate() }) == .reject(.invalid))
}

@Test func aRequestAloneDoesNotSpendTheCode() {
    var window = PairingWindow()
    var idler = PairingResponder(macFingerprint: macKey, phoneFingerprint: phoneKey)
    // A device that connects and asks to pair, then says nothing more.
    let action = idler.handle(.pairRequest(name: "P", nonce: PairingNonce.generate()), isOpen: { window.isOpen() }, consume: { window.consume() })
    guard case .send(.pairChallenge) = action else {
        Issue.record("expected a challenge, got \(action)")
        return
    }
    #expect(window.isOpen())
    // So the real phone still gets its one attempt.
    var real = Exchange(window: window)
    #expect(real.run() == .paired)
}

@Test func twoConnectionsShareOneGuessAtTheCode() {
    var window = PairingWindow()
    var macA = PairingResponder(macFingerprint: macKey, phoneFingerprint: phoneKey)
    var macB = PairingResponder(macFingerprint: macKey, phoneFingerprint: phoneKey)
    var phoneA = PairingInitiator(secret: window.secret, name: "A", phoneFingerprint: phoneKey, macFingerprint: macKey, expectedMacFingerprint: nil)
    var phoneB = PairingInitiator(secret: window.secret, name: "B", phoneFingerprint: phoneKey, macFingerprint: macKey, expectedMacFingerprint: nil)

    func deliver(_ message: ClientMessage, to mac: inout PairingResponder) -> PairingResponder.Action {
        mac.handle(message, isOpen: { window.isOpen() }, consume: { window.consume() })
    }
    // Both requests find the code open.
    guard case .send(let requestA) = phoneA.start(), case .send(let requestB) = phoneB.start(),
          case .send(.pairChallenge(let nonceA)) = deliver(requestA, to: &macA),
          case .send(.pairChallenge(let nonceB)) = deliver(requestB, to: &macB),
          case .send(let proofA) = phoneA.handle(.pairChallenge(nonce: nonceA)),
          case .send(let proofB) = phoneB.handle(.pairChallenge(nonce: nonceB)) else {
        Issue.record("the exchanges didn't reach their proofs")
        return
    }
    // The first proof to arrive spends the code, and the second finds it gone, even though it is also right.
    #expect(deliver(proofA, to: &macA) == .confirm(phoneName: "A"))
    #expect(deliver(proofB, to: &macB) == .reject(.expired))
}

@Test func theProofSpendsTheCodeEvenWhenWrong() {
    var exchange = Exchange(phoneSecret: PairingSecret.generate())
    #expect(exchange.run() == .failed(.refused(.wrongCode)))
    #expect(!exchange.window.isOpen())
}

@Test func theMacRefusesToConfirmBeforeAProof() {
    var responder = PairingResponder(macFingerprint: macKey, phoneFingerprint: phoneKey)
    #expect(responder.confirmed(true) == .reject(.invalid))
}

@Test func pairingMessagesRoundTripTheWire() throws {
    let nonce = PairingNonce.generate()
    let client: [ClientMessage] = [.pairRequest(name: "P", nonce: nonce), .pairProof(nonce)]
    for message in client {
        #expect(try FrameCodec.decode(FrameCodec.encode(message).dropFirst(4), as: ClientMessage.self) == message)
    }
    let server: [ServerMessage] = [.pairChallenge(nonce: nonce), .pairAccepted(proof: nonce), .pairRejected(reason: .wrongCode)]
    for message in server {
        #expect(try FrameCodec.decode(FrameCodec.encode(message).dropFirst(4), as: ServerMessage.self) == message)
    }
}
