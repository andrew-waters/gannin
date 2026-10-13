import Foundation
import Testing
@testable import GanninRemote

@Test func hexRoundTrips() {
    let data = Data([0x00, 0x0f, 0xa0, 0xff])
    #expect(data.hexString == "000fa0ff")
    #expect(Data(hex: "000fa0ff") == data)
    #expect(Data(hex: "0") == nil)
    #expect(Data(hex: "zz") == nil)
    #expect(Data(hex: "") == Data())
}

@Test func anInviteSurvivesItsURL() throws {
    let invite = PairingInvite(secret: .generate(), macFingerprint: Data(repeating: 0xAB, count: 32), macName: "Alex's Mac Studio")
    #expect(PairingInvite(url: invite.url) == invite)
    let reparsed = try #require(URL(string: invite.url.absoluteString))
    #expect(PairingInvite(url: reparsed) == invite)
}

@Test func incompleteOrForeignInvitesAreRefused() throws {
    let good = PairingInvite(secret: .generate(), macFingerprint: Data([1, 2, 3]), macName: "Mac")
    #expect(PairingInvite(url: try #require(URL(string: "https://example.com/pair"))) == nil)
    #expect(PairingInvite(url: try #require(URL(string: "gannin-remote://other?c=x"))) == nil)
    #expect(PairingInvite(url: try #require(URL(string: "gannin-remote://pair?c=\(good.secret.code)"))) == nil)
    #expect(PairingInvite(url: try #require(URL(string: "gannin-remote://pair?c=nope&f=0102&n=Mac"))) == nil)
    #expect(PairingInvite(url: try #require(URL(string: "gannin-remote://pair?c=\(good.secret.code)&f=&n=Mac"))) == nil)
}
