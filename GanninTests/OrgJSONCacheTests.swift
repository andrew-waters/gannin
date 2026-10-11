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
}
