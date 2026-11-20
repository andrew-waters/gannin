import Foundation
import Testing
@testable import Gannin

/// `OrgFileWriter` keeps the newest save for an org and lets a clear drop
/// what came before it without dropping what came after.
@MainActor
struct OrgFileWriterTests {
    private let cache = OrgJSONCache(folder: "OrgFileWriterTests-\(UUID().uuidString)")

    private func value(_ number: Int) -> [String: Int] { ["n": number] }

    @Test func theNewestSaveForAnOrgIsTheOneOnDisk() {
        defer { cache.clear() }
        let writer = OrgFileWriter(cache: cache)
        for number in 1...20 { writer.save(value(number), org: "acme") }
        writer.drain()
        #expect(cache.load([String: Int].self, org: "acme") == value(20))
    }

    @Test func orgsAreWrittenSeparately() {
        defer { cache.clear() }
        let writer = OrgFileWriter(cache: cache)
        writer.save(value(1), org: "acme")
        writer.save(value(2), org: "other")
        writer.drain()
        #expect(cache.load([String: Int].self, org: "acme") == value(1))
        #expect(cache.load([String: Int].self, org: "other") == value(2))
    }

    @Test func aResetLeavesNoFolderWhateverWasQueuedBeforeIt() {
        defer { cache.clear() }
        let writer = OrgFileWriter(cache: cache)
        for _ in 0..<100 {
            writer.save(value(1), org: "acme")
            writer.reset()
            writer.drain()
            #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
        }
    }

    /// The queue can't be held back, so the sequence that lost the save (a
    /// job queued before the reset taking the save made after it) is repeated
    /// until it has had every chance to happen.
    @Test func aSaveMadeAfterAResetIsWritten() {
        defer { cache.clear() }
        let writer = OrgFileWriter(cache: cache)
        for round in 0..<300 {
            writer.save(value(0), org: "acme")
            writer.reset()
            writer.save(value(round), org: "acme")
            writer.drain()
            #expect(cache.load([String: Int].self, org: "acme") == value(round))
        }
    }
}
