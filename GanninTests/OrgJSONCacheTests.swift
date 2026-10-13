import Foundation
import Testing
@testable import Gannin

struct OrgJSONCacheTests {
    private struct Sample: Codable, Equatable {
        var name: String
        var at: Date
    }

    private func makeCache() -> OrgJSONCache {
        OrgJSONCache(folder: "OrgJSONCacheTests-\(UUID().uuidString)")
    }

    @Test func savesAndLoadsAnOrgsFile() {
        let cache = makeCache()
        defer { cache.clear() }
        let sample = Sample(name: "acme", at: Date(timeIntervalSince1970: 1_791_590_400))
        cache.save(sample, org: "acme")
        #expect(cache.load(Sample.self, org: "acme") == sample)
    }

    @Test func keepsOrgsApart() {
        let cache = makeCache()
        defer { cache.clear() }
        cache.save(Sample(name: "one", at: .distantPast), org: "one")
        #expect(cache.load(Sample.self, org: "two") == nil)
    }

    @Test func listsTheOrgsWithAFile() {
        let cache = makeCache()
        defer { cache.clear() }
        cache.save(Sample(name: "one", at: .distantPast), org: "one")
        cache.save(Sample(name: "two", at: .distantPast), org: "two words")
        #expect(cache.orgs().sorted() == ["one", "two words"])
    }

    @Test func clearRemovesEveryFile() {
        let cache = makeCache()
        cache.save(Sample(name: "one", at: .distantPast), org: "one")
        cache.clear()
        #expect(cache.load(Sample.self, org: "one") == nil)
    }

    @Test func anUnreadableFileLoadsAsNothing() throws {
        let cache = makeCache()
        defer { cache.clear() }
        cache.save(Sample(name: "one", at: .distantPast), org: "one")
        try Data("not json".utf8).write(to: cache.directory.appending(path: "one.json"))
        #expect(cache.load(Sample.self, org: "one") == nil)
    }

    @Test func loadingAnOrgWithNothingSavedDoesntCreateTheFolder() {
        let cache = makeCache()
        defer { cache.clear() }
        _ = cache.load(Sample.self, org: "acme")
        #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
    }

    @Test func anOrgNameCantEscapeTheFolder() {
        let cache = makeCache()
        defer { cache.clear() }
        let escaping = "../escaped"
        cache.save(Sample(name: "one", at: .distantPast), org: escaping)
        #expect(cache.load(Sample.self, org: escaping) != nil)
        let escapedFile = cache.directory.deletingLastPathComponent().appending(path: "escaped.json")
        #expect(!FileManager.default.fileExists(atPath: escapedFile.path))
    }
}
