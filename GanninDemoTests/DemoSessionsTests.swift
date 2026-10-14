import Foundation
import Testing
@testable import Gannin_Demo

/// The fixture's sessions show in their states, on fixture issues, with
/// terminals that count as running though nothing was started.
@MainActor
struct DemoSessionsTests {
    @Test func onFixtureIssues() {
        let issues = Set(DemoFixture.issues.map(\.id))
        #expect(DemoSessions.fixtures.allSatisfy { issues.contains($0.session.issue.id) && $0.session.org == DemoFixture.org })
    }

    @Test func oneInEachState() {
        #expect(DemoSessions.fixtures.map(\.state) == [.working, .needsYou, .idle])
        #expect(DemoSessions.fixtures[1].transcript.question != nil)
    }

    @Test func shownWithNothingStarted() {
        let store = SessionStore(harness: HarnessStore(auth: AuthStore()))
        DemoSessions.show(in: store)
        for fixture in DemoSessions.fixtures {
            let id = fixture.session.id
            #expect(store.state(id) == fixture.state)
            #expect(store.isRunning(id))
            #expect(store.transcripts[id] == fixture.transcript)
        }
        #expect(store.selectedTab == DemoSessions.workingID)
    }
}
