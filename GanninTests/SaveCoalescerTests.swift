import Foundation
import Testing
@testable import Gannin

@MainActor
struct SaveCoalescerTests {
    @Test func manyRequestsShareOneWrite() async throws {
        var writes = 0
        let saver = SaveCoalescer(delay: .milliseconds(50)) { writes += 1 }
        for _ in 0..<10 { saver.request() }
        #expect(writes == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(writes == 1)
    }

    @Test func flushWritesAWaitingSaveOnce() async throws {
        var writes = 0
        let saver = SaveCoalescer(delay: .seconds(60)) { writes += 1 }
        saver.request()
        saver.flush()
        saver.flush()
        #expect(writes == 1)
    }

    @Test func flushWithNothingWaitingWritesNothing() {
        var writes = 0
        let saver = SaveCoalescer { writes += 1 }
        saver.flush()
        #expect(writes == 0)
    }

    @Test func cancelDropsAWaitingSave() async throws {
        var writes = 0
        let saver = SaveCoalescer(delay: .milliseconds(50)) { writes += 1 }
        saver.request()
        saver.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(writes == 0)
    }

    @Test func aRequestAfterCancelWaitsItsFullDelay() async throws {
        var writes = 0
        let saver = SaveCoalescer(delay: .milliseconds(400)) { writes += 1 }
        saver.request()
        try await Task.sleep(for: .milliseconds(250))
        saver.cancel()
        saver.request()
        // The first request's delay ends here; the second's hasn't.
        try await Task.sleep(for: .milliseconds(250))
        #expect(writes == 0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(writes == 1)
    }

    @Test func aRequestAfterAWriteSchedulesAnother() async throws {
        var writes = 0
        let saver = SaveCoalescer(delay: .milliseconds(50)) { writes += 1 }
        saver.request()
        try await Task.sleep(for: .milliseconds(300))
        saver.request()
        try await Task.sleep(for: .milliseconds(300))
        #expect(writes == 2)
    }
}
