import SwiftUI

/// One person's working day, for the standup: the PRs they pushed to,
/// opened, merged or closed (with each commit and the issues the PR closes),
/// the PRs they reviewed, and the issues assigned to them that moved on a
/// board or closed.
struct StandupEntry: Identifiable {
    struct PullRequestWork: Identifiable {
        let pr: WorkLogPullRequest
        /// Their commits that day, oldest first.
        var commits: [WorkLogCommit] = []
        var opened = false
        var merged = false
        var closedUnmerged = false

        var id: String { pr.id }
    }

    struct ReviewWork: Identifiable {
        let pr: WorkLogPullRequest
        /// Their reviews that day, oldest first.
        var reviews: [WorkLogReview] = []

        var id: String { pr.id }
    }

    struct IssueWork: Identifiable {
        let record: IssueRecord
        /// They opened it that day.
        var opened = false
        var closed = false
        /// Board status changes that day, in order.
        var moves: [IssueStatusChange] = []

        var id: String { record.id }
    }

    let person: Person
    var pullRequests: [PullRequestWork] = []
    var reviews: [ReviewWork] = []
    var issues: [IssueWork] = []
    /// Time off, a bank holiday or not yet started, that day.
    var mark: TimelineMark?

    var id: String { person.login }
    var isEmpty: Bool { pullRequests.isEmpty && reviews.isEmpty && issues.isEmpty }
    var commitCount: Int { pullRequests.reduce(0) { $0 + $1.commits.count } }

    /// "3 commits · 1 merged · 2 reviews · 1 issue closed".
    var summary: String {
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
        return [
            count(commitCount, "commit", "commits"),
            count(pullRequests.filter(\.opened).count, "opened", "opened"),
            count(pullRequests.filter(\.merged).count, "merged", "merged"),
            count(reviews.count, "review", "reviews"),
            count(issues.filter(\.opened).count, "issue opened", "issues opened"),
            count(issues.filter(\.closed).count, "issue closed", "issues closed"),
            count(issues.filter { !$0.moves.isEmpty }.count, "issue moved", "issues moved"),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

/// Everyone's day, built from the work log (commits, reviews, PRs opened,
/// merged and closed) and the issue history (closes and board moves).
/// Commits count for their GitHub author when the email is linked, else
/// the PR author; issue activity counts for its assignees, since GitHub
/// doesn't say who moved or closed it.
struct Standup {
    let day: DateInterval
    let entries: [StandupEntry]

    init(day: DateInterval, people: [Person], pullRequests: [WorkLogPullRequest], issues: [IssueRecord], config: OrgConfig, marks: [String: TimelineMark]) {
        self.day = day
        var entries = Dictionary(uniqueKeysWithValues: people.map { ($0.login, StandupEntry(person: $0, mark: marks[$0.login])) })
        func counts(_ login: String) -> Bool { entries[login] != nil && !config.excludes(login) }

        for pr in pullRequests {
            var work: [String: StandupEntry.PullRequestWork] = [:]
            func touch(_ login: String?, _ change: (inout StandupEntry.PullRequestWork) -> Void) {
                guard let login, counts(login) else { return }
                change(&work[login, default: StandupEntry.PullRequestWork(pr: pr)])
            }
            for commit in pr.commits where day.contains(commit.authoredAt) {
                touch(commit.author ?? pr.author) { $0.commits.append(commit) }
            }
            if day.contains(pr.createdAt) { touch(pr.author) { $0.opened = true } }
            if let mergedAt = pr.mergedAt, day.contains(mergedAt) { touch(pr.mergedBy ?? pr.author) { $0.merged = true } }
            if pr.mergedAt == nil, let closedAt = pr.closedAt, day.contains(closedAt) { touch(pr.author) { $0.closedUnmerged = true } }
            for (login, var item) in work {
                item.commits.sort { $0.authoredAt < $1.authoredAt }
                entries[login]?.pullRequests.append(item)
            }

            var reviews: [String: StandupEntry.ReviewWork] = [:]
            for review in pr.reviews.sorted(by: { $0.submittedAt < $1.submittedAt })
            where day.contains(review.submittedAt) && review.author != pr.author && counts(review.author) {
                reviews[review.author, default: StandupEntry.ReviewWork(pr: pr)].reviews.append(review)
            }
            for (login, item) in reviews { entries[login]?.reviews.append(item) }
        }

        for record in issues where !config.excludedRepos.contains(record.repo) {
            let opened = day.contains(record.createdAt)
            let closed = record.closedAt.map(day.contains) ?? false
            let moves = record.statusChanges.filter { day.contains($0.at) }.sorted { $0.at < $1.at }
            var work: [String: StandupEntry.IssueWork] = [:]
            // Opening is its author's, exactly; moves and closes go to the
            // assignees, since GitHub doesn't say who did them.
            if opened, let author = record.author, counts(author) {
                work[author, default: StandupEntry.IssueWork(record: record)].opened = true
            }
            if closed || !moves.isEmpty {
                for login in record.assignees where counts(login) {
                    work[login, default: StandupEntry.IssueWork(record: record)].closed = closed
                    work[login, default: StandupEntry.IssueWork(record: record)].moves = moves
                }
            }
            for (login, item) in work { entries[login]?.issues.append(item) }
        }

        // Busiest first within each person; people in name order.
        self.entries = entries.values
            .map { entry in
                var entry = entry
                entry.pullRequests.sort { ($0.commits.count, $0.merged ? 1 : 0, $1.pr.number) > ($1.commits.count, $1.merged ? 1 : 0, $0.pr.number) }
                entry.issues.sort { $0.record.number < $1.record.number }
                return entry
            }
            .sorted { $0.person.displayName.localizedCaseInsensitiveCompare($1.person.displayName) == .orderedAscending }
    }
}

/// People › Standup: everything each person did on one day (today by
/// default, the arrows stepping through working days), on one page, with the PRs, commits and issues
/// behind it. People who did nothing recorded, or were off, are listed at
/// the end.
struct StandupPage: View {
    @Environment(WorkLogStore.self) private var workLog
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HiddenStore.self) private var hidden
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(BankHolidayStore.self) private var holidayStore

    let org: String
    let workload: Workload?
    /// The day picked with the arrows; nil is today.
    @State private var chosenDay: Date?
    /// Every PR's commits listed, rather than folded under it.
    @AppStorage("standupShowCommits") private var showCommits = false
    @AppStorage("standupLayout") private var layout: StandupLayout = .people

    var body: some View {
        let day = dayInterval
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    content(day)
                        .sectionContent()
                } header: {
                    PinnedHeader { header(day) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar { toolbar }
        .task(id: "\(org) \(day.start.timeIntervalSince1970)") {
            async let log: Void = workLog.sync(org, from: Calendar.current.date(byAdding: .day, value: -1, to: day.start))
            let days = max(14, Int(Date.now.timeIntervalSince(day.start) / 86_400) + 2)
            async let issues: Void = issueStore.sync(org, windowDays: days)
            _ = await (log, issues)
        }
        .task(id: "\(Calendar.current.component(.year, from: day.start)) \(regions.hashValue)") {
            let year = Calendar.current.component(.year, from: day.start)
            await holidayStore.load(regions, years: year...year)
        }
    }

    // MARK: Day

    private var week: WorkWeek { configs.config(for: org).week }

    /// The chosen day, or today.
    private var dayStart: Date {
        chosenDay ?? Calendar.current.startOfDay(for: .now)
    }

    private var dayInterval: DateInterval {
        let start = dayStart
        return DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    /// The nearest working day before `date` under the org's week (Friday,
    /// on a Monday).
    static func workingDay(before date: Date, week: WorkWeek) -> Date {
        var day = Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        for _ in 0..<7 where !week.isWorkingDay(day) {
            day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return day
    }

    /// The nearest working day after `date`, no later than today.
    private func workingDay(after date: Date) -> Date {
        let today = Calendar.current.startOfDay(for: .now)
        var day = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        for _ in 0..<7 where !week.isWorkingDay(day) && day < today {
            day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return min(day, today)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Layout", selection: $layout) {
                ForEach(StandupLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("A row per person, the whole team on one timeline, or the issues closed as a changelog")
        }
        ToolbarItem {
            Toggle(isOn: $showCommits) {
                Label("Commits", systemImage: "list.bullet.indent")
            }
            .help(showCommits ? "Fold each PR's commits" : "List each PR's commits")
            .disabled(layout == .changelog)
        }
        ToolbarItem {
            ControlGroup {
                Button { chosenDay = Self.workingDay(before: dayStart, week: week) } label: {
                    Label("Earlier", systemImage: "chevron.left")
                }
                .help("The working day before")
                Button("Today") { chosenDay = nil }
                    .disabled(chosenDay == nil)
                Button { chosenDay = workingDay(after: dayStart) } label: {
                    Label("Later", systemImage: "chevron.right")
                }
                .help("The next working day, up to today")
                .disabled(dayStart >= Calendar.current.startOfDay(for: .now))
            }
            .fixedSize()
        }
    }

    private func header(_ day: DateInterval) -> some View {
        HStack(spacing: 10) {
            Text(day.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            if Calendar.current.isDateInToday(day.start) {
                Text("today so far").foregroundStyle(.secondary).fontWeight(.regular)
            }
            if workLog.syncing.contains(org) || issueStore.syncing.contains(org) {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Content

    private var people: [Person] {
        workload?.people.map(\.person) ?? []
    }

    /// Everyone's bank holiday regions, the org's included.
    private var regions: Set<BankHolidayRegion> {
        let orgRegion = week.holidays
        return Set(people.compactMap { peopleDates.region(for: $0.login, in: org, default: orgRegion) })
    }

    /// The org's working hours that day, for the team's strip; nil on a
    /// day off.
    private func teamHours(_ day: DateInterval) -> WorkWeek.Hours? {
        guard week.isWorkingDay(day.start) else { return nil }
        return week.hours(on: Calendar.current.component(.weekday, from: day.start))
    }

    /// Each person's working calendar that day: their pattern or the org's
    /// week, less their bank holidays.
    private func calendars(_ day: DateInterval) -> [String: WorkingCalendar] {
        let year = Calendar.current.component(.year, from: day.start)
        return Dictionary(uniqueKeysWithValues: people.map { person in
            (person.login, peopleDates.workingCalendar(for: person.login, in: org, orgWeek: week, holidays: holidayStore, years: year...year))
        })
    }

    /// Who was off, on holiday or not yet started that day.
    private func marks(_ day: DateInterval, calendars: [String: WorkingCalendar]) -> [String: TimelineMark] {
        var marks: [String: TimelineMark] = [:]
        for person in people {
            let working = calendars[person.login] ?? WorkingCalendar(week: week)
            if let mark = peopleDates.dates(for: person.login, in: org).mark(from: day.start, to: day.end, isDay: true, working: working) {
                marks[person.login] = mark
            }
        }
        return marks
    }

    @ViewBuilder
    private func content(_ day: DateInterval) -> some View {
        if layout == .changelog {
            // Only the issue history; the work log needn't be in.
            if let history = issueStore.history(for: org) {
                StandupChangelog(org: org, day: day, history: history, config: configs.config(for: org), members: people)
            } else if let error = issueStore.errors[org] {
                Banner(message: "Couldn't load issues: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching the issue history.").foregroundStyle(.secondary)
                }
            }
        } else if let history = workLog.history(for: org) {
            let config = configs.config(for: org)
            let calendars = calendars(day)
            let standup = Standup(
                day: day,
                people: people,
                pullRequests: history.pullRequests(config: config, hidden: hidden.keys),
                issues: issueStore.history(for: org).map { Array($0.issues.values) } ?? [],
                config: config,
                marks: marks(day, calendars: calendars)
            )
            let active = standup.entries.filter { !$0.isEmpty }
            let quiet = standup.entries.filter(\.isEmpty)
            VStack(alignment: .leading, spacing: 20) {
                if active.isEmpty {
                    Text("Nothing recorded on this day.").foregroundStyle(.secondary)
                } else {
                    switch layout {
                    case .people:
                        StandupRows(org: org, day: day, entries: active, calendars: calendars, showCommits: showCommits)
                    case .team:
                        StandupTeam(org: org, day: day, entries: active, hours: teamHours(day), showCommits: showCommits)
                    case .changelog:
                        // Shown without the work log, above.
                        EmptyView()
                    }
                }
                if !quiet.isEmpty { quietList(quiet) }
                Text("From the work log and issue history. Commits count for their author when the email is linked to GitHub, else the PR's; issue closes and board moves count for the issue's assignees.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else if let error = workLog.errors[org] {
            Banner(message: "Couldn't load the work log: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                Task { await workLog.sync(org, force: true) }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching recent PRs with their commits and reviews.").foregroundStyle(.secondary)
            }
        }
    }

    /// Who's off, then who has nothing recorded.
    private func quietList(_ entries: [StandupEntry]) -> some View {
        let off = entries.filter { $0.mark != nil }
        let nothing = entries.filter { $0.mark == nil }
        return VStack(alignment: .leading, spacing: 10) {
            if !off.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Off").font(.headline)
                    FlowPeople(entries: off, org: org) { $0.mark?.label }
                }
            }
            if !nothing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing recorded").font(.headline)
                    FlowPeople(entries: nothing, org: org) { _ in nil }
                }
            }
        }
    }
}

/// People as small chips, each opening their view.
private struct FlowPeople: View {
    @Environment(\.navigate) private var navigate
    let entries: [StandupEntry]
    let org: String
    let note: (StandupEntry) -> String?

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(entries) { entry in
                Button {
                    navigate?(.person(entry.person.login))
                } label: {
                    HStack(spacing: 5) {
                        Avatar(url: entry.person.avatarUrl, size: 16)
                        Text(entry.person.displayName)
                        if let note = note(entry) {
                            Text(note).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .opensElsewhere(.person(entry.person.login))
            }
        }
        .font(.callout)
    }
}

// MARK: - Layouts

/// The standup by person (a row each), for the whole team (one timeline),
/// or as a changelog of the issues closed.
enum StandupLayout: String, CaseIterable {
    case people = "By Person"
    case team = "Team"
    /// The issues closed that day, by investment category.
    case changelog = "Changelog"
}

/// From 7:00 (or earlier, if anyone started earlier) to 19:00 (or later),
/// in hours after midnight, but no wider than 6:00 to 22:00: a stray
/// commit after midnight would squash everyone's day, so ticks outside sit
/// at the edge.
private func standupHourRange(_ entries: [StandupEntry], day: DateInterval) -> ClosedRange<Double> {
    let hours = entries.flatMap(\.times).map { $0.timeIntervalSince(day.start) / 3600 }
    let from = max(6, min(7, floor(hours.min() ?? 7)))
    let to = min(22, max(19, ceil((hours.max() ?? 19) + 0.01)))
    return from...to
}

/// A row per person, all on one time axis: the day strips line up, so
/// reading down the page compares when people worked.
private struct StandupRows: View {
    let org: String
    let day: DateInterval
    let entries: [StandupEntry]
    let calendars: [String: WorkingCalendar]
    let showCommits: Bool
    @State private var width: CGFloat = 1200

    var body: some View {
        let range = standupHourRange(entries, day: day)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                Divider()
                StandupRow(org: org, day: day, entry: entry, hours: hours(entry), range: range, isWide: width >= 1000, showAllCommits: showCommits)
                    .padding(.vertical, 16)
            }
            Divider()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func hours(_ entry: StandupEntry) -> WorkWeek.Hours? {
        guard let working = calendars[entry.person.login], working.isWorkingDay(day.start) else { return nil }
        return working.week.hours(on: Calendar.current.component(.weekday, from: day.start))
    }
}

/// Everyone's day as one timeline, each item after its person's avatar,
/// under the team's counts and a strip of the whole team's day.
private struct StandupTeam: View {
    let org: String
    let day: DateInterval
    let entries: [StandupEntry]
    let hours: WorkWeek.Hours?
    let showCommits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StandupLegend(entries: entries, isHorizontal: true)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            DayStrip(day: day, ticks: entries.flatMap(\.ticks), hours: hours, range: standupHourRange(entries, day: day))
            StandupTimelineList(org: org, items: StandupItem.items(entries), showAllCommits: showCommits, showAvatars: true)
        }
    }
}

extension StandupEntry {
    /// Every moment something happened, for the strip's range.
    var times: [Date] {
        var times: [Date] = []
        for work in pullRequests {
            times += work.commits.map(\.authoredAt)
            if work.opened { times.append(work.pr.createdAt) }
            if work.merged, let at = work.pr.mergedAt { times.append(at) }
            if work.closedUnmerged, let at = work.pr.closedAt { times.append(at) }
        }
        for work in reviews { times += work.reviews.map(\.submittedAt) }
        for work in issues {
            if work.opened { times.append(work.record.createdAt) }
            times += work.moves.map(\.at)
            if work.closed, let at = work.record.closedAt { times.append(at) }
        }
        return times
    }

    /// When each thing happened with its colour, for the strip.
    var ticks: [(at: Date, color: Color, label: String)] {
        var ticks: [(Date, Color, String)] = []
        for work in pullRequests {
            let number = StandupRow.number(work.pr.repo, work.pr.number)
            ticks += work.commits.map { ($0.authoredAt, StandupRow.commitColor, "Commit on \(number)") }
            if work.opened { ticks.append((work.pr.createdAt, StandupRow.openedColor, "Opened \(number)")) }
            if work.merged, let at = work.pr.mergedAt { ticks.append((at, StandupRow.mergedColor, "Merged \(number)")) }
            if work.closedUnmerged, let at = work.pr.closedAt { ticks.append((at, ChartPalette.neutral, "Closed \(number)")) }
        }
        for work in reviews {
            ticks += work.reviews.map { ($0.submittedAt, StandupRow.reviewColor, "Reviewed \(StandupRow.number(work.pr.repo, work.pr.number))") }
        }
        for work in issues {
            let number = StandupRow.number(work.record.repo, work.record.number)
            if work.opened { ticks.append((work.record.createdAt, StandupRow.issueColor, "Opened \(number)")) }
            ticks += work.moves.map { ($0.at, StandupRow.issueColor, "\(number) to \($0.status)") }
            if work.closed, let at = work.record.closedAt { ticks.append((at, StandupRow.issueColor, "Closed \(number)")) }
        }
        return ticks.map { (at: $0.0, color: $0.1, label: $0.2) }
    }
}

/// One thing that happened, for a person's timeline. Commits in a row on
/// the same PR are one item.
struct StandupItem: Identifiable {
    enum Kind {
        case commits([WorkLogCommit])
        case opened
        case merged
        case closed
        case review(WorkLogReview)
        case issueOpened
        case moved(String)
        case issueClosed
    }

    enum Subject {
        case pullRequest(WorkLogPullRequest)
        case issue(IssueRecord)

        var id: String {
            switch self {
            case .pullRequest(let pr): pr.id
            case .issue(let record): record.id
            }
        }
    }

    let at: Date
    let kind: Kind
    let subject: Subject
    /// Whose it is, for the team timeline's avatars.
    let person: Person

    var id: String { "\(person.login)-\(subject.id)-\(at.timeIntervalSince1970)-\(Self.rank(kind))" }

    /// Opening before a commit at the same minute, merging after.
    static func rank(_ kind: Kind) -> Int {
        switch kind {
        case .opened, .issueOpened: 0
        case .commits: 1
        case .review, .moved: 2
        case .merged, .closed, .issueClosed: 3
        }
    }

    /// The person's day in time order.
    static func items(_ entry: StandupEntry) -> [StandupItem] {
        var items: [StandupItem] = []
        for work in entry.pullRequests {
            let subject = Subject.pullRequest(work.pr)
            items += work.commits.map { StandupItem(at: $0.authoredAt, kind: .commits([$0]), subject: subject, person: entry.person) }
            if work.opened { items.append(StandupItem(at: work.pr.createdAt, kind: .opened, subject: subject, person: entry.person)) }
            if work.merged, let at = work.pr.mergedAt { items.append(StandupItem(at: at, kind: .merged, subject: subject, person: entry.person)) }
            if work.closedUnmerged, let at = work.pr.closedAt { items.append(StandupItem(at: at, kind: .closed, subject: subject, person: entry.person)) }
        }
        for work in entry.reviews {
            items += work.reviews.map { StandupItem(at: $0.submittedAt, kind: .review($0), subject: .pullRequest(work.pr), person: entry.person) }
        }
        for work in entry.issues {
            let subject = Subject.issue(work.record)
            if work.opened { items.append(StandupItem(at: work.record.createdAt, kind: .issueOpened, subject: subject, person: entry.person)) }
            items += work.moves.map { StandupItem(at: $0.at, kind: .moved($0.status), subject: subject, person: entry.person) }
            if work.closed, let at = work.record.closedAt { items.append(StandupItem(at: at, kind: .issueClosed, subject: subject, person: entry.person)) }
        }
        items.sort { ($0.at, rank($0.kind)) < ($1.at, rank($1.kind)) }

        // Runs of commits on one PR fold into one item.
        var folded: [StandupItem] = []
        for item in items {
            if case .commits(let new) = item.kind, let last = folded.last, last.subject.id == item.subject.id,
               case .commits(let earlier) = last.kind {
                folded[folded.count - 1] = StandupItem(at: last.at, kind: .commits(earlier + new), subject: last.subject, person: last.person)
            } else {
                folded.append(item)
            }
        }
        return folded
    }

    /// Everyone's days in one, in time order. Each person's commit runs
    /// are folded first, so a run stays one item among others' activity.
    static func items(_ entries: [StandupEntry]) -> [StandupItem] {
        entries.flatMap(items).sorted { ($0.at, rank($0.kind)) < ($1.at, rank($1.kind)) }
    }
}

/// One person's day across the page: who and how much on the left, then
/// their day strip and a timeline of what they did.
private struct StandupRow: View {
    @Environment(\.navigate) private var navigate
    let org: String
    let day: DateInterval
    let entry: StandupEntry
    let hours: WorkWeek.Hours?
    let range: ClosedRange<Double>
    let isWide: Bool
    let showAllCommits: Bool

    private static let nameWidth: CGFloat = 190

    var body: some View {
        let items = StandupItem.items(entry)
        if isWide {
            HStack(alignment: .top, spacing: 24) {
                person.frame(width: Self.nameWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) {
                    DayStrip(day: day, ticks: entry.ticks, hours: hours, range: range)
                    StandupTimelineList(org: org, items: items, showAllCommits: showAllCommits)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                person
                DayStrip(day: day, ticks: entry.ticks, hours: hours, range: range)
                StandupTimelineList(org: org, items: items, showAllCommits: showAllCommits)
            }
        }
    }

    private var person: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                navigate?(.person(entry.person.login))
            } label: {
                HStack(spacing: 8) {
                    Avatar(url: entry.person.avatarUrl, size: 28)
                    Text(entry.person.displayName)
                        .font(.headline)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            .opensElsewhere(.person(entry.person.login))
            if let mark = entry.mark {
                Pill(text: mark.label, color: mark.color ?? .secondary)
            }
            StandupLegend(entries: [entry])
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Words, icons and colours

    /// "mono#1050", with the repo's short name and no digit grouping.
    static func number(_ repo: String, _ number: Int) -> String {
        "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(String(number))"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func action(_ item: StandupItem) -> String {
        switch item.kind {
        case .commits(let commits): commits.count == 1 ? "Committed" : "\(commits.count) commits"
        case .opened: "Opened"
        case .merged: "Merged"
        case .closed: "Closed"
        case .review(let review):
            switch review.state {
            case "APPROVED": "Approved"
            case "CHANGES_REQUESTED": "Requested changes"
            case "DISMISSED": "Review dismissed"
            default: "Commented"
            }
        case .issueOpened: "Opened issue"
        case .moved(let status): "To \(status)"
        case .issueClosed: "Closed"
        }
    }

    /// The action's icon, in the work log's colours.
    static func icon(_ item: StandupItem) -> (name: String, color: Color, help: String) {
        switch item.kind {
        case .commits: ("smallcircle.filled.circle", commitColor, "Commits")
        case .opened: ("arrow.triangle.pull", openedColor, "PR opened")
        case .merged: ("arrow.triangle.merge", mergedColor, "PR merged")
        case .closed: ("xmark.circle", ChartPalette.neutral, "PR closed without merging")
        case .review(let review):
            switch review.state {
            case "APPROVED": ("checkmark.circle.fill", reviewColor, "Approved")
            case "CHANGES_REQUESTED": ("exclamationmark.bubble.fill", reviewColor, "Requested changes")
            default: ("text.bubble.fill", reviewColor, "Commented")
            }
        case .issueOpened: ("plus.circle.fill", issueColor, "Issue opened")
        case .moved: ("arrow.right.circle.fill", issueColor, "Issue moved on the board")
        case .issueClosed: ("checkmark.circle", issueColor, "Issue closed")
        }
    }

    /// The work log's colours for commits, reviews, PRs opened and merged,
    /// and the next slot for issue activity.
    static let commitColor = ChartPalette.slot(WorkLogEvent.Kind.commit.slot)
    static let reviewColor = ChartPalette.slot(WorkLogEvent.Kind.review.slot)
    static let openedColor = ChartPalette.slot(WorkLogEvent.Kind.opened.slot)
    static let mergedColor = ChartPalette.slot(WorkLogEvent.Kind.merged.slot)
    static let issueColor = ChartPalette.slot(4)
}

/// Counts of what happened, each with the icon its timeline items use, so
/// it reads as the timeline's legend; then the lines added and removed.
/// Down the side for one person, across the top for the team.
private struct StandupLegend: View {
    let entries: [StandupEntry]
    var isHorizontal = false

    var body: some View {
        if isHorizontal {
            FlowRow(spacing: 16) { rows }
        } else {
            VStack(alignment: .leading, spacing: 3) { rows }
        }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(counts, id: \.text) { count in
            HStack(spacing: 6) {
                Image(systemName: count.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(count.color)
                    .frame(width: 16)
                Text(count.text)
            }
        }
        let commits = entries.flatMap { $0.pullRequests.flatMap(\.commits) }
        if !commits.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "plusminus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                Text(verbatim: "+\(commits.reduce(0) { $0 + $1.additions }.formatted())").foregroundStyle(ChartPalette.good)
                Text(verbatim: "-\(commits.reduce(0) { $0 + $1.deletions }.formatted())").foregroundStyle(ChartPalette.critical)
            }
            .help("Lines added and removed across the day's commits")
        }
    }

    private var counts: [(icon: String, color: Color, text: String)] {
        func total(_ value: (StandupEntry) -> Int) -> Int { entries.reduce(0) { $0 + value($1) } }
        func count(_ n: Int, _ one: String, _ many: String, _ icon: String, _ color: Color) -> (icon: String, color: Color, text: String)? {
            n == 0 ? nil : (icon, color, "\(n.formatted()) \(n == 1 ? one : many)")
        }
        return [
            count(total(\.commitCount), "commit", "commits", "smallcircle.filled.circle", StandupRow.commitColor),
            count(total { $0.pullRequests.filter(\.opened).count }, "PR opened", "PRs opened", "arrow.triangle.pull", StandupRow.openedColor),
            count(total { $0.pullRequests.filter(\.merged).count }, "PR merged", "PRs merged", "arrow.triangle.merge", StandupRow.mergedColor),
            count(total { $0.pullRequests.filter(\.closedUnmerged).count }, "PR closed", "PRs closed", "xmark.circle", ChartPalette.neutral),
            count(total { $0.reviews.count }, "review", "reviews", "checkmark.circle.fill", StandupRow.reviewColor),
            count(total { $0.issues.filter(\.opened).count }, "issue opened", "issues opened", "plus.circle.fill", StandupRow.issueColor),
            count(total { $0.issues.filter { !$0.moves.isEmpty }.count }, "issue moved", "issues moved", "arrow.right.circle.fill", StandupRow.issueColor),
            count(total { $0.issues.filter(\.closed).count }, "issue closed", "issues closed", "checkmark.circle", StandupRow.issueColor),
        ].compactMap { $0 }
    }
}

/// A timeline of standup items: the time (after the person's avatar, on
/// the team timeline), the action's icon on a rail, and the title with its
/// context. Runs of commits unfold under their item.
private struct StandupTimelineList: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let org: String
    let items: [StandupItem]
    let showAllCommits: Bool
    var showAvatars = false
    /// Commit runs unfolded, when they aren't all.
    @State private var unfolded: Set<String> = []

    private static let avatarWidth: CGFloat = 30
    private static let timeWidth: CGFloat = 46
    private static let iconWidth: CGFloat = 26

    /// Room before the time: the avatar, on the team timeline.
    private var leading: CGFloat { showAvatars ? Self.avatarWidth : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                itemView(item)
            }
        }
        // The rail, through the middle of the icons.
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(Color.separatorLine)
                .frame(width: 1)
                .padding(.vertical, 10)
                .padding(.leading, leading + Self.timeWidth + Self.iconWidth / 2)
        }
    }

    @ViewBuilder
    private func itemView(_ item: StandupItem) -> some View {
        let isUnfolded = showAllCommits || unfolded.contains(item.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                if showAvatars {
                    Button {
                        navigate?(.person(item.person.login))
                    } label: {
                        Avatar(url: item.person.avatarUrl, size: 20)
                    }
                    .buttonStyle(.plain)
                    .help(item.person.displayName)
                    .opensElsewhere(.person(item.person.login))
                    .frame(width: Self.avatarWidth, alignment: .leading)
                }
                Text(StandupRow.clock(item.at))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Self.timeWidth, alignment: .leading)
                let icon = StandupRow.icon(item)
                Image(systemName: icon.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(icon.color)
                    .frame(width: 20, height: 20)
                    .background(Color.windowBackground, in: Circle())
                    .frame(width: Self.iconWidth)
                    .help(icon.help)
                content(item, isUnfolded: isUnfolded)
                    .padding(.leading, 8)
            }
            .padding(.vertical, 4)
            if isUnfolded, case .commits(let commits) = item.kind, commits.count > 1 || showAllCommits {
                ForEach(Array(commits.enumerated()), id: \.offset) { _, commit in
                    commitRow(commit)
                }
            }
        }
    }

    /// The action and the title, then the context, on one line.
    private func content(_ item: StandupItem, isUnfolded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(StandupRow.action(item))
                .fontWeight(.medium)
                .fixedSize()
            Button {
                navigate?(page(item.subject))
            } label: {
                Text(verbatim: title(item))
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title(item))
            .opensElsewhere(page(item.subject))
            Text(verbatim: context(item))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            if case .commits(let commits) = item.kind {
                LinesText(added: commits.reduce(0) { $0 + $1.additions }, removed: commits.reduce(0) { $0 + $1.deletions })
            }
            if case .commits(let commits) = item.kind, commits.count > 1, !showAllCommits {
                Button {
                    if unfolded.remove(item.id) == nil { unfolded.insert(item.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isUnfolded ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isUnfolded ? "Fold the commits" : "List the commits")
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    /// A commit's message in place of the PR's title when it's the only
    /// one; otherwise the PR's.
    private func title(_ item: StandupItem) -> String {
        if case .commits(let commits) = item.kind, commits.count == 1, !showAllCommits, let message = commits[0].message {
            return message
        }
        switch item.subject {
        case .pullRequest(let pr): return pr.title
        case .issue(let record): return record.title
        }
    }

    /// "clients#1872 · 8:11-10:39 · +847 -1440", "closes product#3031".
    private func context(_ item: StandupItem) -> String {
        var parts: [String] = []
        switch item.subject {
        case .pullRequest(let pr):
            parts.append(StandupRow.number(pr.repo, pr.number))
            switch item.kind {
            case .commits(let commits):
                if commits.count == 1 && !showAllCommits { parts.append("on \(pr.title)") }
                if let last = commits.last, commits.count > 1 { parts.append("to \(StandupRow.clock(last.authoredAt))") }
            case .opened where pr.isDraft == true:
                parts.append("draft")
            case .merged where !pr.closingIssues.isEmpty:
                parts.append("closes " + pr.closingIssues.map { StandupRow.number($0.repo, $0.number) }.joined(separator: ", "))
            default:
                break
            }
        case .issue(let record):
            parts.append(StandupRow.number(record.repo, record.number))
            if case .issueClosed = item.kind, !record.isCompleted { parts.append("not planned") }
        }
        return parts.joined(separator: " · ")
    }

    private func page(_ subject: StandupItem.Subject) -> DetailSelection {
        switch subject {
        case .pullRequest(let pr): .pullRequestReference(PullRequestReference(org: org, pullRequest: pr))
        case .issue(let record): .issueReference(IssueReference(org: org, record: record))
        }
    }

    private func commitRow(_ commit: WorkLogCommit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(StandupRow.clock(commit.authoredAt))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
            Button {
                if let url = commit.url { openURL(url) }
            } label: {
                Text(verbatim: commit.message ?? "Commit").lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(commit.url == nil ? (commit.message ?? "") : "Open the commit on GitHub")
            LinesText(added: commit.additions, removed: commit.deletions)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.leading, leading + Self.timeWidth + Self.iconWidth + 8)
        .padding(.vertical, 1)
    }

}

/// When things happened, as ticks along the shared hour range, over the
/// person's working hours (shaded). Hover a tick for what it was.
private struct DayStrip: View {
    let day: DateInterval
    let ticks: [(at: Date, color: Color, label: String)]
    let hours: WorkWeek.Hours?
    let range: ClosedRange<Double>

    var body: some View {
        let span = max(range.upperBound - range.lowerBound, 1)
        let hour = { (date: Date) in date.timeIntervalSince(day.start) / 3600 }
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                let x = { (h: Double) in geometry.size.width * (h - range.lowerBound) / span }
                ZStack(alignment: .topLeading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    if let hours {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: max(0, x(Double(hours.end)) - x(Double(hours.start))))
                            .offset(x: x(Double(hours.start)))
                    }
                    ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                        // Outside the range, at its edge.
                        let h = min(max(hour(tick.at), range.lowerBound + 0.05), range.upperBound - 0.05)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(tick.color)
                            .frame(width: 3, height: 12)
                            .offset(x: x(h) - 1.5, y: 2)
                            .help("\(StandupRow.clock(tick.at)) \(tick.label)")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 16)
            GeometryReader { geometry in
                let x = { (h: Double) in geometry.size.width * (h - range.lowerBound) / span }
                ForEach(Array(stride(from: Int(range.lowerBound), through: Int(range.upperBound), by: 3)), id: \.self) { h in
                    Text(WorkWeek.hourLabel(h % 24))
                        .fixedSize()
                        .position(x: min(max(x(Double(h)), 16), geometry.size.width - 16), y: 6)
                }
            }
            .frame(height: 12)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement()
        .accessibilityLabel("\(ticks.count) events")
    }
}

/// "+243 -14", added in green and removed in red.
private struct LinesText: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(added.formatted())").foregroundStyle(ChartPalette.good)
            Text(verbatim: "-\(removed.formatted())").foregroundStyle(ChartPalette.critical)
        }
        .font(.caption.monospacedDigit())
        .fixedSize()
    }
}

// MARK: - Changelog

/// The issues closed on the day, as a changelog: completed ones by
/// investment category (the Investments page's categories and colours),
/// newest last within each, then those closed as not planned.
private struct StandupChangelog: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let org: String
    let day: DateInterval
    let history: IssueHistory
    let config: OrgConfig
    let members: [Person]

    private struct Group: Identifiable {
        let name: String
        /// Palette slot; nil for uncategorised.
        let slot: Int?
        var issues: [IssueRecord]

        var id: String { name }
    }

    var body: some View {
        let closed = history.issues.values
            .filter { record in record.closedAt.map(day.contains) == true && !config.excludedRepos.contains(record.repo) }
            .sorted { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }
        let completed = closed.filter(\.isCompleted)
        let notPlanned = closed.filter { !$0.isCompleted }
        let groups = groups(completed)
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 6) {
                Text(completed.count == 1 ? "1 issue completed" : "\(completed.count) issues completed").fontWeight(.medium)
                if !notPlanned.isEmpty {
                    Text("· \(notPlanned.count) closed as not planned").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if closed.isEmpty {
                Text("No issues closed on this day.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                section(group.name, count: group.issues.count, color: ChartPalette.slot(group.slot)) {
                    ForEach(group.issues) { row($0) }
                }
            }
            if !notPlanned.isEmpty {
                section("Closed as not planned", count: notPlanned.count, color: nil) {
                    ForEach(notPlanned) { row($0) }
                }
            }
        }
    }

    /// Completed issues by category, in the categories' order, with the
    /// uncategorised last.
    private func groups(_ issues: [IssueRecord]) -> [Group] {
        let investments = config.investmentConfig
        var byCategory: [UUID: [IssueRecord]] = [:]
        var uncategorised: [IssueRecord] = []
        for record in issues {
            let parent = record.parentID.flatMap { history.issues[$0] }
            if let (category, _) = investments.categorise(record, parent: parent) {
                byCategory[category.id, default: []].append(record)
            } else {
                uncategorised.append(record)
            }
        }
        var groups = investments.categories.compactMap { category in
            byCategory[category.id].map { Group(name: category.name, slot: category.slot, issues: $0) }
        }
        if !uncategorised.isEmpty { groups.append(Group(name: "Uncategorised", slot: nil, issues: uncategorised)) }
        return groups
    }

    private func section<Content: View>(_ title: String, count: Int, color: Color?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let color {
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
                }
                Text(title).font(.headline)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }

    private func row(_ record: IssueRecord) -> some View {
        let reference = IssueReference(org: org, record: record)
        let assignees = record.assignees.map { login in
            members.first { $0.login == login } ?? Person(login: login, name: nil, avatarUrl: URL(string: "https://github.com/\(login).png?size=64"))
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: record.isCompleted ? "checkmark.circle.fill" : "slash.circle")
                .foregroundStyle(record.isCompleted ? Color.purple : Color.secondary)
                .frame(width: 18)
            Text(record.closedAt.map(StandupRow.clock) ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    navigate?(.issueReference(reference))
                } label: {
                    Text(verbatim: record.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opensElsewhere(.issueReference(reference))
                HStack(spacing: 6) {
                    Text(verbatim: StandupRow.number(record.repo, record.number))
                    if let type = record.issueType { Text(verbatim: "· \(type)") }
                    if let author = record.author { Text(verbatim: "· opened by \(author)") }
                    let merged = record.linkedPullRequests.filter { $0.mergedAt != nil }
                    if !merged.isEmpty {
                        Text("· via")
                        ForEach(merged, id: \.url) { pr in
                            Button {
                                openURL(pr.url)
                            } label: {
                                Text(verbatim: "#\(String(pr.number))").foregroundStyle(.link)
                            }
                            .buttonStyle(.plain)
                            .help("Open PR #\(String(pr.number)) on GitHub")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            AvatarStack(people: assignees)
        }
        .font(.callout)
        .padding(.vertical, 6)
    }
}
