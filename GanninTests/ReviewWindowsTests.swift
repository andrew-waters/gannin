import Foundation
import Testing
@testable import Gannin

/// Review windows: the person's synced ones, this Mac's override, and the
/// person file that keeps them.
struct ReviewWindowsTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "ReviewWindowsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func window(_ name: String, _ start: Int, _ end: Int, days: [Int]? = [2, 3, 4, 5, 6], atOnce: Int = 1) -> ReviewWindow {
        var routine = Routine.new(org: "acme", harnessRepo: "", kind: .reviewQueue, name: name,
                                  schedule: .window(RoutineWindow(start: TimeOfDay(hour: start), end: TimeOfDay(hour: end), days: days.map(Set.init))))
        routine.concurrency = atOnce
        return ReviewWindow(routine)
    }

    @Test func aWindowRoundTripsThroughItsRoutine() {
        let lunch = window("Lunch", 12, 13, days: [6, 2, 4], atOnce: 2)
        #expect(lunch.days == [2, 4, 6])
        let routine = lunch.routine(org: "acme")
        #expect(routine.kind == .reviewQueue)
        #expect(routine.concurrency == 2)
        #expect(routine.schedule == .window(RoutineWindow(start: TimeOfDay(hour: 12), end: TimeOfDay(hour: 13), days: [2, 4, 6])))
        #expect(ReviewWindow(routine) == lunch)
    }

    @Test func theSyncedWindowsApplyUnlessThisMacOverridesThem() {
        let synced = [window("Lunch", 12, 13), window("Evening", 18, 20)]
        let mine = Routine.new(org: "acme", harnessRepo: "", kind: .reviewQueue, name: "Night")
        let others = [
            Routine.new(org: "other", harnessRepo: "", kind: .reviewQueue, name: "Theirs"),
            Routine.new(org: "acme", harnessRepo: "acme/harness", kind: .issueQueue, name: "Queue"),
        ]

        let shared = ReviewWindows.resolved(org: "acme", overridden: false, local: [mine] + others, synced: synced)
        #expect(shared.map(\.id) == synced.map(\.id))
        #expect(shared.allSatisfy { $0.org == "acme" && $0.kind == .reviewQueue })

        let overridden = ReviewWindows.resolved(org: "acme", overridden: true, local: [mine] + others, synced: synced)
        #expect(overridden.map(\.id) == [mine.id])
    }

    @Test func anOverrideIsKeptOnDiskWithTheOtherState() {
        let store = RoutineStore(directory: folder)
        store.setPaused(true)
        store.setOverridesReviewWindows("acme", true)
        let again = RoutineStore(directory: folder)
        #expect(again.overridesReviewWindows("acme"))
        #expect(!again.overridesReviewWindows("other"))
        #expect(again.isPaused)
    }

    @Test func anOlderPersonFileWithoutWindowsStillReads() throws {
        let old = #"{"absences":[],"timeZone":"Europe/London"}"#
        let dates = try #require(TeamCoding.decode(PersonDates.self, old))
        #expect(dates.reviewWindows == nil)
        #expect(dates.timeZone == "Europe/London")
    }

    @Test func aPersonFileKeepsItsWindows() throws {
        var dates = PersonDates()
        dates.reviewWindows = [window("Lunch", 12, 13), window("Evening", 18, 20, days: nil, atOnce: 3)]
        #expect(!dates.isEmpty)
        let text = try #require(HarnessTeamData.personFile(dates))
        let read = try #require(TeamCoding.decode(PersonDates.self, text))
        #expect(read.reviewWindows == dates.reviewWindows)
    }
}
