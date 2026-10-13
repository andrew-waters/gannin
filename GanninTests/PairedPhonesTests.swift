import Foundation
import GanninRemote
import Testing
@testable import Gannin

@MainActor
private func store() -> (PairedPhones, UserDefaults) {
    let defaults = UserDefaults(suiteName: "paired-phones-tests-\(UUID().uuidString)")!
    return (PairedPhones(defaults: defaults), defaults)
}

@Test @MainActor func aPairedPhoneIsFoundByItsKeyAndSurvivesRelaunch() {
    let (phones, defaults) = store()
    phones.add(name: "Alex's iPhone", fingerprint: Data([1, 2]))
    #expect(phones.isPaired(Data([1, 2])))
    #expect(!phones.isPaired(Data([1, 3])))
    #expect(PairedPhones(defaults: defaults).phones.map(\.name) == ["Alex's iPhone"])
}

@Test @MainActor func pairingTheSameKeyAgainRenamesRatherThanDuplicates() {
    let (phones, _) = store()
    phones.add(name: "Old", fingerprint: Data([1]))
    phones.add(name: "New", fingerprint: Data([1]))
    #expect(phones.phones.map(\.name) == ["New"])
}

@Test @MainActor func revokingRemovesThePhoneAndTellsTheHost() throws {
    let (phones, defaults) = store()
    let phone = phones.add(name: "Lost", fingerprint: Data([7]))
    var revoked: [String] = []
    phones.onRevoke = { revoked.append($0.name) }
    phones.revoke(phone)
    #expect(!phones.isPaired(Data([7])))
    #expect(revoked == ["Lost"])
    #expect(PairedPhones(defaults: defaults).phones.isEmpty)
    phones.revoke(phone)
    #expect(revoked == ["Lost"])
}

@Test @MainActor func seenTimesAreRecordedForKnownPhonesOnly() {
    let (phones, _) = store()
    let start = Date(timeIntervalSince1970: 100)
    phones.add(name: "A", fingerprint: Data([1]), now: start)
    phones.noteSeen(Data([1]), now: start.addingTimeInterval(60))
    phones.noteSeen(Data([2]), now: start)
    #expect(phones.phone(for: Data([1]))?.lastSeen == start.addingTimeInterval(60))
    #expect(phones.phones.count == 1)
}
