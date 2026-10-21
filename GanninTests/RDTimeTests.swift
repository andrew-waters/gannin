import Foundation
import Testing
@testable import Gannin

/// R&D time: activity allocated to working hours, what counts, the report
/// and the CSV export.
struct RDTimeTests {
    private let calendar = Calendar.current

    /// Monday 5 October 2026, 10:00 local, and the days after it.
    private func day(_ offset: Int, hour: Int = 10) -> Date {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: hour))!
        return calendar.date(byAdding: .day, value: offset, to: monday)!
    }

    private var week: DateInterval {
        DateInterval(start: calendar.startOfDay(for: day(0)), end: calendar.startOfDay(for: day(7)))
    }

    private func linked(_ id: String) -> LinkedItem {
        LinkedItem(id: id, number: Int(id.dropFirst(2)) ?? 0, title: "Issue \(id)", url: URL(string: "https://github.com/acme/api/issues/\(id)")!, repo: "acme/api", state: "OPEN")
    }

    private func pr(_ id: String, author: String = "alex", closes: [String] = [], commits: [Int] = [], opened: Int = 0, closed: Int? = nil, reviews: [(String, Int)] = []) -> WorkLogPullRequest {
        WorkLogPullRequest(
            id: id, number: 100, title: "PR \(id)", url: URL(string: "https://github.com/acme/api/pull/\(id)")!, repo: "acme/api",
            author: author, createdAt: day(opened, hour: 9), mergedAt: nil, closedAt: closed.map { day($0, hour: 12) }, mergedBy: nil,
            commits: commits.map { WorkLogCommit(authoredAt: day($0), author: author, additions: 1, deletions: 0, utcOffset: nil) },
            reviews: reviews.map { WorkLogReview(submittedAt: day($0.1), author: $0.0, state: "APPROVED") },
            closingIssues: closes.map(linked)
        )
    }

    private func comments(on id: String, by login: String, days: [Int]) -> WorkLogIssue {
        WorkLogIssue(
            id: id, number: 2, title: "Issue \(id)", url: URL(string: "https://github.com/acme/api/issues/\(id)")!, repo: "acme/api",
            author: nil, createdAt: day(-30), comments: days.map { WorkLogIssueComment(createdAt: day($0), author: login, url: nil) }
        )
    }

    private func allocate(
        _ prs: [WorkLogPullRequest], issues: [WorkLogIssue] = [], people: Set<String> = ["alex"], range: DateInterval? = nil,
        holidays: [String: String] = [:], dates: [String: PersonDates] = [:], options: RDActivityOptions = RDActivityOptions()
    ) -> RDAllocations {
        RDActivityAllocator.allocate(.init(
            people: people, range: range ?? week, pullRequests: prs, issues: issues,
            calendars: [:], dates: dates, orgCalendar: WorkingCalendar(week: WorkWeek(), holidays: holidays), options: options, now: day(30)
        ))
    }

    private func hours(_ found: RDAllocations, _ id: String, on offset: Int) -> Double {
        found.allocations.filter { $0.item.id == id && calendar.isDate($0.day, inSameDayAs: day(offset)) }.reduce(0) { $0 + $1.hours }
    }

    // MARK: Allocation

    @Test func splitsEachDayEvenlyAcrossTheIssuesTouched() {
        let found = allocate([pr("P_1", closes: ["I_1"], commits: [0, 0, 0])], issues: [comments(on: "I_2", by: "alex", days: [0])],
                             options: RDActivityOptions(quietDays: .unallocated))
        #expect(hours(found, "I_1", on: 0) == 4)
        #expect(hours(found, "I_2", on: 0) == 4)
        // Five working days of eight hours; Tuesday to Friday had nothing.
        #expect(found.available["alex"] == 40)
        #expect(found.gaps.count == 4)
        #expect(found.pullRequests["I_1"] == [URL(string: "https://github.com/acme/api/pull/P_1")!])
    }

    @Test func splitsByActivityWhenAsked() {
        let found = allocate([pr("P_1", closes: ["I_1"], commits: [0, 0, 0])], issues: [comments(on: "I_2", by: "alex", days: [0])],
                             options: RDActivityOptions(weighting: .events, quietDays: .unallocated))
        // Opening the PR and three commits on I_1, one comment on I_2.
        #expect(hours(found, "I_1", on: 0) == 6.4)
        #expect(hours(found, "I_2", on: 0) == 1.6)
    }

    @Test func givesQuietDaysToOpenPullRequestsOrLeavesThemUnallocated() {
        let open = pr("P_1", closes: ["I_1"], commits: [0], closed: 2)
        let found = allocate([open])
        #expect(hours(found, "I_1", on: 1) == 8)
        #expect(found.allocations.first { calendar.isDate($0.day, inSameDayAs: day(1)) }?.events == 0)
        // Closed at noon on Wednesday: Thursday and Friday have nothing.
        #expect(hours(found, "I_1", on: 3) == 0)
        #expect(found.gaps.count == 2)

        let unallocated = allocate([open], options: RDActivityOptions(quietDays: .unallocated))
        #expect(hours(unallocated, "I_1", on: 1) == 0)
        #expect(unallocated.gaps.count == 4)
    }

    @Test func countsOnlyWorkingHours() {
        var dates = PersonDates()
        dates.absences = [
            Absence(kind: .holiday, start: calendar.startOfDay(for: day(1)), end: calendar.startOfDay(for: day(1))),
            Absence(kind: .sick, start: calendar.startOfDay(for: day(2)), end: calendar.startOfDay(for: day(2)), half: .morning),
        ]
        let holiday = WorkingCalendar.key(day(3))
        // Commits every day, Saturday included.
        let found = allocate([pr("P_1", closes: ["I_1"], commits: [0, 1, 2, 3, 4, 5])], holidays: [holiday: "Bank holiday"], dates: ["alex": dates])
        #expect(hours(found, "I_1", on: 0) == 8)
        #expect(hours(found, "I_1", on: 1) == 0)
        #expect(hours(found, "I_1", on: 2) == 4)
        #expect(hours(found, "I_1", on: 3) == 0)
        #expect(hours(found, "I_1", on: 5) == 0)
        #expect(found.available["alex"] == 20)
    }

    @Test func keepsAPullRequestClosingNoIssueAsItsOwnWork() {
        let found = allocate([pr("P_1", commits: [0])], options: RDActivityOptions(quietDays: .unallocated))
        #expect(found.allocations.map(\.item.kind) == [.pullRequest])
        #expect(hours(found, "P_1", on: 0) == 8)
    }

    @Test func creditsReviewersAndSkipsPeopleLeftOut() {
        let reviewed = pr("P_1", closes: ["I_1"], commits: [0], reviews: [("sam", 0), ("bot", 0)])
        let found = allocate([reviewed], people: ["alex", "sam"], options: RDActivityOptions(quietDays: .unallocated))
        #expect(found.allocations.filter { $0.login == "sam" }.map(\.hours) == [8])
        #expect(found.available["bot"] == nil)

        let noReviews = allocate([reviewed], people: ["alex", "sam"], options: RDActivityOptions(quietDays: .unallocated, countsReviews: false))
        #expect(noReviews.allocations.filter { $0.login == "sam" }.isEmpty)
    }

    // MARK: What counts

    private func issue(_ id: String, labels: [String] = [], parent: String? = nil) -> IssueRecord {
        IssueRecord(
            id: id, number: 1, title: "An issue", url: URL(string: "https://github.com/acme/api/issues/1")!, repo: "acme/api",
            author: "alex", assignees: [], labels: labels, issueType: nil, milestone: nil, parentID: parent,
            createdAt: .now, closedAt: nil, stateReason: nil, statusChanges: [], assignedAt: [], reopenedAt: [],
            subIssuesAddedAt: [], linkedPullRequests: [], mentionedInPullRequests: nil, projectFields: []
        )
    }

    @Test func marksWinOverMatchesAndParentsPassTheirsOn() {
        var config = RDConfig(qualification: .labels(["R&D"]))
        let investments = InvestmentConfig.default
        let parent = issue("I_9", labels: ["r&d"])

        #expect(config.status("I_1", record: issue("I_1", labels: ["R&D"]), parent: nil, investments: investments)?.basis == .matched)
        #expect(config.status("I_2", record: issue("I_2"), parent: nil, investments: investments) == nil)
        #expect(config.status("I_3", record: issue("I_3", parent: "I_9"), parent: parent, investments: investments)?.basis == .parent)

        config.marks = [
            "I_1": RDMark(counts: false, rationale: "Routine upkeep"),
            "I_2": RDMark(counts: true, share: 0.6, rationale: "New caching approach"),
            "I_3": RDMark(counts: false),
        ]
        #expect(config.status("I_1", record: issue("I_1", labels: ["R&D"]), parent: nil, investments: investments) == nil)
        let partial = config.status("I_2", record: issue("I_2"), parent: nil, investments: investments)
        #expect(partial == RDStatus(share: 0.6, basis: .marked, rationale: "New caching approach"))
        // A sub-issue marked as not counting stays out, whatever its parent.
        #expect(config.status("I_3", record: issue("I_3", parent: "I_9"), parent: parent, investments: investments) == nil)
        // A parent's mark carries its share to sub-issues.
        #expect(config.status("I_4", record: issue("I_4", parent: "I_2"), parent: issue("I_2"), investments: investments)?.share == 0.6)
    }

    @Test func countsChosenInvestmentCategories() {
        let investments = InvestmentConfig.default
        let newThings = investments.categories[0]
        let config = RDConfig(qualification: .categories([newThings.id]))
        #expect(config.status("I_1", record: issue("I_1", labels: ["feature"]), parent: nil, investments: investments) != nil)
        #expect(config.status("I_2", record: issue("I_2", labels: ["bug"]), parent: nil, investments: investments) == nil)
    }

    @Test func reportsHoursTimesShareByIssueAndPerson() {
        let found = allocate([pr("P_1", closes: ["I_1"], commits: [0]), pr("P_2", closes: ["I_2"], commits: [0])],
                             options: RDActivityOptions(quietDays: .unallocated))
        let report = RDReport(found) { item in
            item.id == "I_1" ? RDStatus(share: 0.5, basis: .marked, rationale: nil) : nil
        }
        #expect(report.hours == 8)
        #expect(report.rdHours == 2)
        #expect(report.rdWork.map(\.id) == ["I_1"])
        #expect(report.work.first?.id == "I_1")
        let alex = report.people.first { $0.login == "alex" }
        #expect(alex?.available == 40)
        #expect(alex?.unallocated == 32)
        #expect(alex?.rdShare == 0.05)
    }

    // MARK: Periods and export

    @Test func accountingYearsStartOnTheirDay() {
        let start = AccountingYearStart(month: 4, day: 6)
        let year = start.year(containing: calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!)
        #expect(year.start == calendar.date(from: DateComponents(year: 2025, month: 4, day: 6)))
        #expect(year.end == calendar.date(from: DateComponents(year: 2026, month: 4, day: 6)))
        // A day past the month's end is its last day.
        #expect(AccountingYearStart(month: 2, day: 31).start(in: 2026) == calendar.date(from: DateComponents(year: 2026, month: 2, day: 28)))

        // November to October: the quarter holding 21 October 2026 is August to October.
        let november = AccountingYearStart(month: 11, day: 1)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21))!
        let thisYear = RDRange.thisYear.interval(yearStart: november, now: now, customFrom: now, customTo: now)
        #expect(thisYear.start == calendar.date(from: DateComponents(year: 2025, month: 11, day: 1)))
        let quarter = RDRange.thisQuarter.interval(yearStart: november, now: now, customFrom: now, customTo: now)
        #expect(quarter.start == calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        #expect(quarter.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
    }

    @Test func periodsIncludeTheirLastDay() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 15))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 31))!
        let period = AccountingPeriod(name: "Claim", start: start, end: end)
        #expect(period.interval.start == calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        #expect(period.interval.end == calendar.date(from: DateComponents(year: 2026, month: 4, day: 1)))
    }

    @Test func quotesCSVFieldsAndDisarmsFormulas() {
        #expect(RDExport.field("plain") == "plain")
        #expect(RDExport.field("a, b") == "\"a, b\"")
        #expect(RDExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(RDExport.field("=SUM(A1)") == "'=SUM(A1)")
        #expect(RDExport.field("-2.5") == "-2.5")
        #expect(RDExport.csv([["a", "b"], ["1", "2"]]) == "a,b\r\n1,2\r\n")
    }

    // MARK: Fetch planning

    @Test func plansEveryWeekBackToTheStartWithNothingFetched() {
        let now = day(14)
        let plan = RDActivityStore.weeks(cache: nil, org: "acme", from: week.start, through: now, now: now)
        #expect(plan.topUp.isEmpty)
        #expect(plan.backfill.count == 3)
        // Newest first, the newest open-ended to now.
        #expect(plan.backfill.first?.end == nil)
        #expect(plan.backfill.last?.start == week.start)
    }

    @Test func plansOnlyWhatTheCacheLacks() {
        let now = day(28)
        var cache = RDActivityStore.Cache(org: "acme", coveredFrom: day(7, hour: 0), fetchedAt: day(14))
        cache.pullRequests["P_1"] = pr("P_1", closes: ["I_1"])
        // A range already covered and ending before the last fetch: nothing.
        let covered = RDActivityStore.weeks(cache: cache, org: "acme", from: day(7, hour: 0), through: day(10), now: now)
        #expect(covered.weeks.isEmpty)
        #expect(covered.missingRecords == 1)
        // Further back and up to now: a week back, and from the last fetch on.
        let both = RDActivityStore.weeks(cache: cache, org: "acme", from: week.start, through: now, now: now)
        #expect(both.backfill.count == 1)
        #expect(both.backfill.first?.start == week.start)
        #expect(!both.topUp.isEmpty)
        #expect(both.topUp.first?.end == nil)
        #expect(both.start == week.start)
    }

    @Test func pricesAPagePerTwentyPullRequestsAndFiftyIssues() {
        var plan = RDActivityStore.weeks(cache: nil, org: "acme", from: week.start, through: day(6), now: day(6))
        plan.backfill[0].pullRequests = 45
        plan.backfill[0].issues = 10
        // Three PR pages and one issue page, and a batch per 15 of the
        // (45 + 10) / 2 issues guessed to be looked up.
        #expect(plan.requests == 3 + 1 + 2)
        #expect(plan.points == plan.requests + 2)
        plan.backfill[0].pullRequests = 5000
        #expect(plan.pullRequests == RDActivityStore.Plan.searchCap)
    }
}
