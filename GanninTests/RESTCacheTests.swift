import Foundation
import Testing
@testable import Gannin

struct RESTCacheTests {
    private func bytes(_ count: Int) -> Data { Data(repeating: 1, count: count) }

    @Test func returnsWhatWasStoredWithItsETag() async {
        let cache = RESTCache(byteLimit: 1000)
        await cache.store(bytes(10), etag: "\"abc\"", for: "a")
        let entry = await cache.entry(for: "a")
        #expect(entry?.etag == "\"abc\"")
        #expect(entry?.data == bytes(10))
        #expect(await cache.entry(for: "b") == nil)
    }

    @Test func storingAgainReplacesTheEntry() async {
        let cache = RESTCache(byteLimit: 1000)
        await cache.store(bytes(10), etag: "1", for: "a")
        await cache.store(bytes(20), etag: "2", for: "a")
        let entry = await cache.entry(for: "a")
        #expect(entry?.etag == "2")
        #expect(entry?.data.count == 20)
    }

    @Test func dropsTheOldestOnceOverTheLimit() async {
        let cache = RESTCache(byteLimit: 100)
        await cache.store(bytes(25), etag: "1", for: "a")
        await cache.store(bytes(25), etag: "2", for: "b")
        await cache.store(bytes(25), etag: "3", for: "c")
        await cache.store(bytes(25), etag: "4", for: "d")
        await cache.store(bytes(25), etag: "5", for: "e")
        #expect(await cache.entry(for: "a") == nil)
        #expect(await cache.entry(for: "e")?.etag == "5")
    }

    @Test func doesNotKeepOneResponseTakingAQuarterOfTheRoom() async {
        let cache = RESTCache(byteLimit: 100)
        await cache.store(bytes(10), etag: "1", for: "a")
        await cache.store(bytes(60), etag: "2", for: "a")
        #expect(await cache.entry(for: "a") == nil)
    }

    @Test func removeAllEmptiesIt() async {
        let cache = RESTCache(byteLimit: 100)
        await cache.store(bytes(10), etag: "1", for: "a")
        await cache.removeAll()
        #expect(await cache.entry(for: "a") == nil)
    }
}
