import Foundation
import Testing
@testable import GanninRemote

@Test func secretsAreSixteenRandomBytes() {
    #expect(PairingSecret.generate().bytes.count == 16)
    #expect(PairingSecret.generate() != PairingSecret.generate())
    #expect(PairingSecret(bytes: Data(count: 15)) == nil)
}

@Test func codesRoundTrip() throws {
    for _ in 0..<200 {
        let secret = PairingSecret.generate()
        #expect(PairingSecret(code: secret.code) == secret)
    }
    let fixed = try #require(PairingSecret(bytes: Data(repeating: 0xFF, count: 16)))
    #expect(PairingSecret(code: fixed.code) == fixed)
    let zero = try #require(PairingSecret(bytes: Data(count: 16)))
    #expect(zero.code == "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AA")
}

@Test func typedCodesIgnoreCaseDashesAndSpaces() throws {
    let secret = PairingSecret.generate()
    let sloppy = secret.code.lowercased().replacingOccurrences(of: "-", with: " ")
    #expect(PairingSecret(code: sloppy) == secret)
}

@Test func badCodesAreRefused() {
    #expect(PairingSecret(code: "") == nil)
    #expect(PairingSecret(code: "ABCD-EFGH") == nil)
    // The right length and alphabet, so the zero padding passes: this one is valid.
    #expect(PairingSecret(code: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AA") != nil)
    // 1, 0, I and O are not in the alphabet.
    #expect(PairingSecret(code: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-A1") == nil)
    // The last character carries two padding bits that must be zero.
    #expect(PairingSecret(code: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AB") == nil)
}

@Test func aWindowWorksOnceAndOnlyBeforeItExpires() {
    let start = Date(timeIntervalSince1970: 1_000)
    var window = PairingWindow(now: start)
    #expect(window.consume(at: start.addingTimeInterval(5)) == window.secret)
    #expect(window.consume(at: start.addingTimeInterval(6)) == nil)

    var late = PairingWindow(now: start)
    #expect(late.consume(at: start.addingTimeInterval(PairingWindow.lifetime)) == nil)
}

#if canImport(CryptoKit)
private let mac = Data("mac-key".utf8)
private let phone = Data("phone-key".utf8)
private let macNonce = Data("mn".utf8)
private let phoneNonce = Data("pn".utf8)

@Test func aProofVerifiesForTheSameSecretAndFields() {
    let secret = PairingSecret.generate()
    let proof = PairingProof.make(role: .phone, secret: secret, macFingerprint: mac, phoneFingerprint: phone, macNonce: macNonce, phoneNonce: phoneNonce)
    #expect(PairingProof.verify(proof, role: .phone, secret: secret, macFingerprint: mac, phoneFingerprint: phone, macNonce: macNonce, phoneNonce: phoneNonce))
}

@Test func aProofFailsForAnythingElse() {
    let secret = PairingSecret.generate()
    let proof = PairingProof.make(role: .phone, secret: secret, macFingerprint: mac, phoneFingerprint: phone, macNonce: macNonce, phoneNonce: phoneNonce)
    #expect(!PairingProof.verify(proof, role: .phone, secret: .generate(), macFingerprint: mac, phoneFingerprint: phone, macNonce: macNonce, phoneNonce: phoneNonce))
    #expect(!PairingProof.verify(proof, role: .mac, secret: secret, macFingerprint: mac, phoneFingerprint: phone, macNonce: macNonce, phoneNonce: phoneNonce))
    #expect(!PairingProof.verify(proof, role: .phone, secret: secret, macFingerprint: Data("other".utf8), phoneFingerprint: phone, macNonce: macNonce, phoneNonce: phoneNonce))
    #expect(!PairingProof.verify(proof, role: .phone, secret: secret, macFingerprint: mac, phoneFingerprint: Data("other".utf8), macNonce: macNonce, phoneNonce: phoneNonce))
    #expect(!PairingProof.verify(proof, role: .phone, secret: secret, macFingerprint: mac, phoneFingerprint: phone, macNonce: Data("zz".utf8), phoneNonce: phoneNonce))
    #expect(!PairingProof.verify(Data(), role: .phone, secret: secret, macFingerprint: mac, phoneFingerprint: phone, macNonce: macNonce, phoneNonce: phoneNonce))
}

@Test func movingBytesBetweenFieldsChangesTheProof() {
    let secret = PairingSecret.generate()
    let a = PairingProof.make(role: .mac, secret: secret, macFingerprint: Data("ab".utf8), phoneFingerprint: Data("c".utf8), macNonce: macNonce, phoneNonce: phoneNonce)
    let b = PairingProof.make(role: .mac, secret: secret, macFingerprint: Data("a".utf8), phoneFingerprint: Data("bc".utf8), macNonce: macNonce, phoneNonce: phoneNonce)
    #expect(a != b)
}
#endif
