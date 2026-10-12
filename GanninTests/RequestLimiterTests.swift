import Foundation
import Testing
@testable import Gannin

/// Stands in for the network: records how many requests are being sent at
/// once, in what order they started, and holds each one until `open()`.
private actor Probe {
    private(set) var inFlight = 0
    private(set) var peak = 0
    private(set) var started: [String] = []
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func send(_ name: String) async {
        started.append(name)
        inFlight += 1
        peak = max(peak, inFlight)
        if !isOpen {
            await withCheckedContinuation { held.append($0) }
        }
        inFlight -= 1
    }

    func open() {
        isOpen = true
        held.forEach { $0.resume() }
        held = []
    }

    func waitForInFlight(_ count: Int) async {
        for _ in 0..<400 where inFlight < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func limiter(_ probe: Probe, limit: Int, reserved: Int = 0) -> RequestLimiter {
    RequestLimiter(limit: limit, reservedForInteractive: reserved) { request in
        await probe.send(request.url!.lastPathComponent)
        return (Data(), URLResponse())
    }
}

private func request(_ name: String) -> URLRequest {
    URLRequest(url: URL(string: "https://example.test/\(name)")!)
}

/// Gives queued requests time to reach the limiter, so a test can assert
/// that something did not start.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

struct RequestLimiterTests {
    @Test func neverSendsMoreThanTheLimitAtOnce() async throws {
        let probe = Probe()
        let limiter = limiter(probe, limit: 3)
        let tasks = (0..<20).map { index in
            Task { try await limiter.data(for: request("r\(index)")) }
        }
        await probe.waitForInFlight(3)
        await settle()
        #expect(await probe.inFlight == 3)

        await probe.open()
        for task in tasks { _ = try await task.value }
        #expect(await probe.peak == 3)
        #expect(await probe.started.count == 20)
    }

    @Test func aRequestCancelledBeforeItStartsIsNeverSent() async {
        let probe = Probe()
        let limiter = limiter(probe, limit: 1)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await limiter.data(for: request("cancelled"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.started.isEmpty)
    }

    @Test func aCancelledWaiterIsWokenWhileEverySlotIsStillHeld() async throws {
        let probe = Probe()
        let limiter = limiter(probe, limit: 1)
        let holder = Task { try await limiter.data(for: request("holder")) }
        await probe.waitForInFlight(1)

        let waiter = Task { try await limiter.data(for: request("waiter")) }
        await settle()
        waiter.cancel()

        let outcome = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    _ = try await waiter.value
                    return "finished"
                } catch is CancellationError {
                    return "cancelled"
                } catch {
                    return "failed"
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return "still waiting"
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        #expect(outcome == "cancelled")

        // It never took the slot, so the next request gets it once the holder is done.
        await probe.open()
        _ = try await holder.value
        _ = try await limiter.data(for: request("after"))
        #expect(await probe.started == ["holder", "after"])
    }

    @Test func backgroundRequestsLeaveTheReservedSlotsForInteractiveOnes() async throws {
        let probe = Probe()
        let limiter = limiter(probe, limit: 4, reserved: 2)
        let background = (0..<6).map { index in
            Task { try await limiter.data(for: request("background\(index)")) }
        }
        await probe.waitForInFlight(2)
        await settle()
        #expect(await probe.inFlight == 2)

        let interactive = RequestLimiter.$lane.withValue(.interactive) {
            Task { try await limiter.data(for: request("interactive")) }
        }
        await probe.waitForInFlight(3)
        #expect(await probe.inFlight == 3)
        #expect(await probe.started.contains("interactive"))

        await probe.open()
        _ = try await interactive.value
        for task in background { _ = try await task.value }
        #expect(await probe.started.count == 7)
    }

    @Test func anInteractiveWaiterGoesBeforeBackgroundOnesQueuedEarlier() async throws {
        let probe = Probe()
        let limiter = limiter(probe, limit: 1)
        let holder = Task { try await limiter.data(for: request("holder")) }
        await probe.waitForInFlight(1)

        let background = Task { try await limiter.data(for: request("background")) }
        await settle()
        let interactive = RequestLimiter.$lane.withValue(.interactive) {
            Task { try await limiter.data(for: request("interactive")) }
        }
        await settle()

        await probe.open()
        _ = try await holder.value
        _ = try await background.value
        _ = try await interactive.value
        #expect(await probe.started == ["holder", "interactive", "background"])
    }
}
