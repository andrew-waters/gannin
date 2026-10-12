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

    @Test func evictsInOrderAfterEntriesWereReplaced() async {
        let cache = RESTCache(byteLimit: 90)
        await cache.store(bytes(20), etag: "1", for: "a")
        await cache.store(bytes(20), etag: "2", for: "b")
        await cache.store(bytes(20), etag: "3", for: "a")
        await cache.store(bytes(20), etag: "4", for: "c")
        await cache.store(bytes(20), etag: "5", for: "d")
        await cache.store(bytes(20), etag: "6", for: "e")
        #expect(await cache.entry(for: "b") == nil)
        #expect(await cache.entry(for: "a")?.etag == "3")
        #expect(await cache.entry(for: "e")?.etag == "6")
    }

    @Test func removeAllEmptiesIt() async {
        let cache = RESTCache(byteLimit: 100)
        await cache.store(bytes(10), etag: "1", for: "a")
        await cache.removeAll()
        #expect(await cache.entry(for: "a") == nil)
    }
}

/// `GitHubAPI.rest` against a stubbed session.
@Suite(.serialized)
struct RESTRequestTests {
    nonisolated final class Stub: @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
        nonisolated(unsafe) static var requests: [URLRequest] = []

        static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let (status, headers, body) = handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (body, response)
        }
    }

    private struct Item: Decodable, Equatable { let name: String }

    private func api(cache: RESTCache, costs: CostLog = CostLog()) -> GitHubAPI {
        var api = GitHubAPI(token: "t")
        api.restCache = cache
        api.restLimiter = RequestLimiter(limit: 4, send: Stub.send)
        api.onRESTRateLimit = { costs.values.append($0.cost) }
        Stub.requests = []
        return api
    }

    @MainActor final class CostLog { var values: [Int] = [] }

    private let limitHeaders = ["X-RateLimit-Remaining": "4000", "X-RateLimit-Limit": "5000", "X-RateLimit-Reset": "4102444800"]

    @Test @MainActor func sendsTheETagBackAndReusesTheBodyOn304() async throws {
        let costs = CostLog()
        let api = api(cache: RESTCache(), costs: costs)
        let headers = limitHeaders.merging(["ETag": "\"v1\""]) { $1 }
        Stub.handler = { request in
            request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\""
                ? (304, self.limitHeaders, Data())
                : (200, headers, Data(#"{"name":"a"}"#.utf8))
        }
        let first: Item = try await api.rest("repos/o/r/thing")
        let second: Item = try await api.rest("repos/o/r/thing")
        #expect(first == Item(name: "a"))
        #expect(second == first)
        #expect(Stub.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(Stub.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(costs.values == [1, 0])
    }

    @Test func keepsNothingWithoutAnETag() async throws {
        let cache = RESTCache()
        let api = api(cache: cache)
        Stub.handler = { _ in (200, self.limitHeaders, Data(#"{"name":"a"}"#.utf8)) }
        let _: Item = try await api.rest("repos/o/r/thing")
        let _: Item = try await api.rest("repos/o/r/thing")
        #expect(Stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
    }

    @Test func uncachedRequestsAreNeitherSentWithNorStoredAsAnETag() async throws {
        let cache = RESTCache()
        let api = api(cache: cache)
        Stub.handler = { _ in (200, self.limitHeaders.merging(["ETag": "\"v1\""]) { $1 }, Data(#"{"name":"a"}"#.utf8)) }
        let _: Item = try await api.rest("repos/o/r/thing", cached: false)
        let _: Item = try await api.rest("repos/o/r/thing", cached: false)
        #expect(Stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
    }
}
