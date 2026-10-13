import Foundation
import Testing
@testable import GanninRemote

private func make(_ id: String, _ state: RemoteSessionState) -> RemoteSession {
    RemoteSession(id: id, reference: id, title: id, kind: "Code", state: state, mode: .attended, modeLabel: "Attended", canGoUnattended: true)
}

@Test func stateFollowsWhatTheMacSends() {
    var state = RemoteSessionsState()
    state.apply(.hello(macName: "Studio"))
    state.apply(.snapshot(sessions: [make("A", .working), make("B", .idle)]))
    #expect(state.macName == "Studio")
    state.apply(.sessionChanged(session: make("B", .needsYou)))
    state.apply(.sessionChanged(session: make("C", .working)))
    state.apply(.sessionRemoved(id: "A"))
    #expect(state.sessions.map(\.id) == ["B", "C"])
    #expect(state.needsYou.map(\.id) == ["B"])
    #expect(state.session(id: "C")?.state == .working)
    state.apply(.heartbeat)
    state.apply(.result(id: "1", result: .ok))
    #expect(state.sessions.count == 2)
}

@Test func aNewSnapshotReplacesEverything() {
    var state = RemoteSessionsState()
    state.apply(.snapshot(sessions: [make("A", .working)]))
    state.apply(.snapshot(sessions: [make("Z", .idle)]))
    #expect(state.sessions.map(\.id) == ["Z"])
}

@Test func sessionsAreOrderedByNeedThenAsSent() {
    var state = RemoteSessionsState()
    state.apply(.snapshot(sessions: [make("stopped", .stopped), make("idle", .idle), make("w1", .working), make("ask1", .needsYou), make("w2", .starting), make("ask2", .needsYou)]))
    #expect(state.ordered.map(\.id) == ["ask1", "ask2", "w1", "w2", "idle", "stopped"])
}

@Test func theLockComesBackAfterTheGracePeriodOnly() {
    let policy = AppLockPolicy(grace: 60)
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(!policy.shouldLock(backgroundedAt: nil, now: start))
    #expect(!policy.shouldLock(backgroundedAt: start, now: start.addingTimeInterval(59)))
    #expect(policy.shouldLock(backgroundedAt: start, now: start.addingTimeInterval(60)))
}

@Test func everyRefusalHasAnExplanation() {
    for reason in [RemoteRefusal.promptGone, .notRunning, .autoUnavailable, .unknownSession, .tooLarge, .invalid, .rateLimited, .busy, .modeNotChanged] {
        #expect(!reason.explanation.isEmpty)
    }
}
