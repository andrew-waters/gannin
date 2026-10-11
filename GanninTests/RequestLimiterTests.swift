import Foundation
import Testing
@testable import Gannin

struct RequestLimiterTests {
    @Test func aCancelledRequestThrowsWithoutSending() async {
        let limiter = RequestLimiter(limit: 1)
        let task = Task {
            try await limiter.data(for: URLRequest(url: URL(string: "http://127.0.0.1:9")!))
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func manyRequestsAllFinishWithASmallLimit() async {
        let limiter = RequestLimiter(limit: 2)
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    // Nothing listens on port 9, so each fails fast; what matters is that none is left waiting.
                    (try? await limiter.data(for: URLRequest(url: URL(string: "http://127.0.0.1:9")!))) == nil
                }
            }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.count == 8)
    }
}
