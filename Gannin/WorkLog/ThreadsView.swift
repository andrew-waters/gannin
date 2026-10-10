import SwiftUI

/// The Threads page's content: each person's PRs as bars from first commit
/// to merge (or to now while open), stacked when they overlap, with their
/// reviews of other people's PRs on a line beneath. Shows what someone is
/// juggling, what's dragging, and who is carrying the reviews.
struct ThreadsContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.navigate) private var navigate
    @Environment(PeopleDatesStore.self) private var peopleDates

    let org: String
    let pullRequests: [WorkLogPullRequest]
    let columns: [WorkLogGrid.Column]
    let scale: WorkLogScale
    let people: [Person]
    /// Each person's working days, bank holidays included.
    let calendars: [String: WorkingCalendar]
    let week: WorkWeek

    var body: some View {
        let lanes = ThreadLanes(pullRequests: pullRequests, people: people, from: range.lowerBound, to: range.upperBound)
        VStack(spacing: 0) {
            ForEach(lanes.lanes, id: \.person.login) { lane in
                laneView(lane)
                Divider()
            }
            legend
        }
    }

    /// Every day on the page, for bank holidays in either scale.
    private var columnsDays: [Date] {
        let calendar = Calendar.current
        var days: [Date] = []
        var day = range.lowerBound
        while day < range.upperBound {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    private var range: ClosedRange<Date> {
        let start = columns.first?.start ?? .now
        return start...max(columns.last?.end ?? .now, start.addingTimeInterval(1))
    }

    private func laneView(_ lane: ThreadLanes.Lane) -> some View {
        let height = ThreadLayout.height(rows: lane.rowCount)
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Avatar(url: lane.person.avatarUrl, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.person.displayName).lineLimit(1)
                    if let summary = lane.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, 16)
            .frame(width: WorkLogPage.nameWidth, alignment: .leading)
            .contentShape(Rectangle())
            .personDatesMenu(lane.person, org: org)
            GeometryReader { geometry in
                let x = XScale(range: range, width: geometry.size.width)
                ZStack(alignment: .topLeading) {
                    let working = calendars[lane.person.login] ?? WorkingCalendar(week: week)
                    daysOff(working, x: x, height: height)
                    dateBands(peopleDates.dates(for: lane.person.login, in: org), working: working, x: x, height: height)
                    ForEach(lane.bars) { bar in
                        ThreadBarView(bar: bar, x: x)
                            .frame(width: max(x.width(bar.start, bar.end), 6), height: ThreadLayout.barHeight)
                            .offset(x: x(bar.start), y: ThreadLayout.top + CGFloat(bar.row) * (ThreadLayout.barHeight + ThreadLayout.spacing))
                            .onTapGesture { open(bar.pullRequest) }
                            .opensElsewhere(.pullRequestReference(PullRequestReference(org: org, pullRequest: bar.pullRequest)))
                    }
                    ForEach(lane.reviews) { review in
                        Circle()
                            .fill(ChartPalette.slot(WorkLogEvent.Kind.review.slot))
                            .frame(width: 9, height: 9)
                            .contentShape(Rectangle().inset(by: -3))
                            .help(review.summary)
                            .offset(x: x(review.at) - 4.5, y: height - ThreadLayout.reviewRow + 3)
                            .onTapGesture {
                                // Reviews are only ever on PRs.
                                if case .pullRequest(let pr) = review.subject { open(pr) }
                            }
                    }
                    if lane.bars.isEmpty && lane.reviews.isEmpty {
                        Text("Nothing in this range")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 10)
                            .frame(height: height)
                    }
                }
                .frame(width: geometry.size.width, height: height, alignment: .topLeading)
                .clipped()
            }
            .overlay(alignment: .leading) { Divider() }
        }
        .frame(height: height)
    }

    /// Time off, and the stretches before they started or after they left.
    @ViewBuilder
    private func dateBands(_ dates: PersonDates, working: WorkingCalendar, x: XScale, height: CGFloat) -> some View {
        let calendar = Calendar.current
        let holidays: [(id: String, from: Date, to: Date, mark: TimelineMark)] = columnsDays.compactMap { day in
            guard working.week.isWorkingDay(day, in: calendar), let name = working.holiday(on: day, calendar: calendar),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return ("bank \(day.timeIntervalSince1970)", day, end, TimelineMark(label: name, color: TimelineMark.bankHoliday))
        }
        let bands: [(id: String, from: Date, to: Date, mark: TimelineMark)] =
            dates.absences.flatMap { absence in
                Self.workingRuns(absence, working: working, calendar: calendar).enumerated().map { index, run in
                    ("\(absence.id.uuidString) \(index)", run.0, run.1, TimelineMark(label: absence.label, color: absence.kind.color))
                }
            }
            + holidays
            + [dates.startDate.map { ("start", range.lowerBound, calendar.startOfDay(for: $0), TimelineMark(label: "Not started", color: nil)) },
               dates.endDate.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }.map { ("end", $0, range.upperBound, TimelineMark(label: "Left", color: nil)) }]
            .compactMap { $0 }
        ForEach(bands.filter { $0.from < range.upperBound && $0.to > range.lowerBound }, id: \.id) { band in
            TimelineMarkView(mark: band.mark)
                .frame(width: max(x.width(band.from, band.to), 1), height: height)
                .offset(x: x(band.from))
        }
    }

    /// The stretches of an absence that fall on working days, so a band
    /// breaks over the weekend and bank holidays inside it.
    private static func workingRuns(_ absence: Absence, working: WorkingCalendar, calendar: Calendar) -> [(Date, Date)] {
        let (from, to) = absence.interval(calendar: calendar)
        guard absence.halfDay(calendar: calendar) == nil else {
            return working.isWorkingDay(from, calendar: calendar) ? [(from, to)] : []
        }
        var runs: [(Date, Date)] = []
        var runStart: Date?
        var day = from
        while day < to {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? to
            if working.isWorkingDay(day, calendar: calendar) {
                if runStart == nil { runStart = day }
            } else if let start = runStart {
                runs.append((start, day))
                runStart = nil
            }
            day = next
        }
        if let runStart { runs.append((runStart, to)) }
        return runs
    }

    /// Days off shaded as in the work log, when columns are days.
    @ViewBuilder
    private func daysOff(_ working: WorkingCalendar, x: XScale, height: CGFloat) -> some View {
        if scale != .weeks {
            ForEach(columns.filter { !working.isWorkingDay($0.start) }) { column in
                Rectangle()
                    .fill(.quaternary.opacity(0.35))
                    .frame(width: x.width(column.start, column.end), height: height)
                    .offset(x: x(column.start))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(ChartPalette.slot(WorkLogEvent.Kind.opened.slot).opacity(0.3)).frame(width: 18, height: 10)
                Text("PR")
            }
            ForEach([WorkLogEvent.Kind.commit, .review, .merged], id: \.self) { kind in
                HStack(spacing: 6) {
                    Circle().fill(ChartPalette.slot(kind.slot)).frame(width: 9, height: 9)
                    Text(kind.rawValue)
                }
            }
            Text("Bars are PRs they opened, from first commit to merge, or to now while open. Reviews on a bar are ones it received; the line beneath is the person reviewing others.")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// Over this page, or in a window of its own outside a main window.
    private func open(_ pr: WorkLogPullRequest) {
        let reference = PullRequestReference(org: org, pullRequest: pr)
        if let navigate { navigate(.pullRequestReference(reference)) } else { openWindow(value: reference) }
    }
}

// MARK: - Layout

private enum ThreadLayout {
    static let barHeight: CGFloat = 28
    static let spacing: CGFloat = 4
    static let top: CGFloat = 8
    static let reviewRow: CGFloat = 18

    static func height(rows: Int) -> CGFloat {
        let bars = CGFloat(max(rows, 1)) * (barHeight + spacing)
        return max(top + bars + reviewRow + 4, 56)
    }
}

/// Dates to points across the lane.
nonisolated struct XScale {
    let range: ClosedRange<Date>
    let width: CGFloat

    func callAsFunction(_ date: Date) -> CGFloat {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let clamped = min(max(date, range.lowerBound), range.upperBound)
        return CGFloat(clamped.timeIntervalSince(range.lowerBound) / span) * width
    }

    func width(_ start: Date, _ end: Date) -> CGFloat { self(end) - self(start) }
}

// MARK: - Model

/// Each person's PRs in the range, packed into rows so none overlap.
struct ThreadLanes {
    struct Bar: Identifiable {
        let pullRequest: WorkLogPullRequest
        let start: Date
        let end: Date
        let isOpen: Bool
        var row = 0

        var id: String { pullRequest.id }
        var isMerged: Bool { pullRequest.mergedAt != nil }
        /// Reviews it received from anyone but its author.
        var reviews: [WorkLogReview] { pullRequest.reviews.filter { $0.author != pullRequest.author } }

        var help: String {
            let pr = pullRequest
            var lines = ["\(pr.repo)#\(pr.number) \(pr.title)"]
            var dates = "Started \(start.formatted(date: .abbreviated, time: .omitted))"
            if let merged = pr.mergedAt {
                dates += ", merged \(merged.formatted(date: .abbreviated, time: .omitted))"
            } else if let closed = pr.closedAt {
                dates += ", closed unmerged \(closed.formatted(date: .abbreviated, time: .omitted))"
            } else {
                dates += ", still open"
            }
            let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
            dates += days == 1 ? " (1 day)" : " (\(days) days)"
            lines.append(dates)
            let commits = pr.commits.count == 1 ? "1 commit" : "\(pr.commits.count) commits"
            let reviews = reviews.count == 1 ? "1 review" : "\(reviews.count) reviews"
            lines.append("\(commits) · \(reviews)")
            return lines.joined(separator: "\n")
        }
    }

    struct Lane {
        let person: Person
        let bars: [Bar]
        let rowCount: Int
        /// Their reviews of other people's PRs.
        let reviews: [WorkLogEvent]

        /// PRs and reviews in the range, under their name.
        var summary: String? {
            guard !bars.isEmpty || !reviews.isEmpty else { return nil }
            var parts: [String] = []
            if !bars.isEmpty { parts.append(bars.count == 1 ? "1 PR" : "\(bars.count) PRs") }
            if !reviews.isEmpty { parts.append(reviews.count == 1 ? "1 review" : "\(reviews.count) reviews") }
            return parts.joined(separator: " · ")
        }
    }

    let lanes: [Lane]

    init(pullRequests: [WorkLogPullRequest], people: [Person], from: Date, to: Date, now: Date = .now) {
        // Leaves a little room between bars sharing a row.
        let gap = to.timeIntervalSince(from) * 0.01
        var bars: [String: [Bar]] = [:]
        var reviews: [String: [WorkLogEvent]] = [:]
        for pr in pullRequests {
            let firstCommit = pr.commits.map(\.authoredAt).min() ?? pr.createdAt
            let start = min(firstCommit, pr.createdAt)
            let end = pr.mergedAt ?? pr.closedAt ?? now
            if start < to && end >= from {
                // Authors only: "Update branch" and merges from main put
                // other people's commits on a PR, which would give reviewers
                // and maintainers a bar for nearly everything.
                if let author = pr.author {
                    bars[author, default: []].append(Bar(
                        pullRequest: pr,
                        start: start,
                        end: max(end, start),
                        isOpen: pr.mergedAt == nil && pr.closedAt == nil
                    ))
                }
            }
            for event in pr.events where event.kind == .review && event.at >= from && event.at < to {
                reviews[event.login, default: []].append(event)
            }
        }
        lanes = people.map { person in
            var rowEnds: [Date] = []
            var placed: [Bar] = []
            for var bar in (bars[person.login] ?? []).sorted(by: { $0.start < $1.start }) {
                if let row = rowEnds.firstIndex(where: { $0.addingTimeInterval(gap) <= max(bar.start, from) }) {
                    bar.row = row
                    rowEnds[row] = bar.end
                } else {
                    bar.row = rowEnds.count
                    rowEnds.append(bar.end)
                }
                placed.append(bar)
            }
            return Lane(person: person, bars: placed, rowCount: rowEnds.count, reviews: reviews[person.login] ?? [])
        }
    }
}

// MARK: - Bar

/// One PR: its label, commits sized by lines changed, the reviews it
/// received and, when merged, a mark at the end.
private struct ThreadBarView: View {
    let bar: ThreadLanes.Bar
    let x: XScale

    var body: some View {
        let tint = bar.isMerged || bar.isOpen ? ChartPalette.slot(WorkLogEvent.Kind.opened.slot) : ChartPalette.neutral
        let origin = x(bar.start)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(0.18))
                .strokeBorder(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: bar.isOpen ? [3, 2] : []))
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .padding(.leading, 6)
                .padding(.top, 2)
                .padding(.trailing, 4)
            Canvas { context, size in
                let y = size.height - 7
                func dot(_ date: Date, radius: Double, color: Color) {
                    let cx = min(max(x(date) - origin, radius), size.width - radius)
                    context.fill(Path(ellipseIn: CGRect(x: cx - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
                for commit in bar.pullRequest.commits where x.range.contains(commit.authoredAt) {
                    let lines = Double(commit.additions + commit.deletions)
                    dot(commit.authoredAt, radius: min(4.5, 1.8 + 0.9 * log10(1 + lines)), color: ChartPalette.slot(WorkLogEvent.Kind.commit.slot))
                }
                for review in bar.reviews where x.range.contains(review.submittedAt) {
                    dot(review.submittedAt, radius: 3, color: ChartPalette.slot(WorkLogEvent.Kind.review.slot))
                }
                if let merged = bar.pullRequest.mergedAt, x.range.contains(merged) {
                    dot(merged, radius: 4, color: ChartPalette.slot(WorkLogEvent.Kind.merged.slot))
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .help(bar.help)
    }

    private var label: String {
        let repo = bar.pullRequest.repo.split(separator: "/").last.map(String.init) ?? bar.pullRequest.repo
        return "\(repo)#\(bar.pullRequest.number) \(bar.pullRequest.title)"
    }
}
