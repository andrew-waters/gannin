import Charts
import SwiftUI

/// Agents › Metrics: how Claude's reviews land, from the records each
/// review commits to the harness (`ReviewRecord`), so it's the team's, not
/// only this Mac's: who reviews with Gannin, how many findings are posted
/// and dismissed, how many of those posted were acted on (their threads
/// resolved), by severity and category, in the spirit of CodeRabbit's
/// analytics. Reviews on this Mac not recorded yet count too.
struct AgentMetricsPage: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(AuthStore.self) private var auth
    @Environment(\.openWindow) private var openWindow
    let org: String
    /// Days back, or 0 for all time.
    @SceneStorage("agentMetricsDays") private var days = 30
    /// One reviewer's, or everyone's when empty.
    @SceneStorage("agentMetricsReviewer") private var reviewer = ""
    @State private var reviewerSort: StatsSort?
    @State private var reviewSort: StatsSort?

    private static let ranges = [(7, "Last 7 days"), (30, "Last 30 days"), (90, "Last 90 days"), (0, "All time")]

    var body: some View {
        let all = records()
        let inRange = all.records.filter { record in
            (days == 0 || record.date >= Calendar.current.date(byAdding: .day, value: -days, to: .now)!)
                && (reviewer.isEmpty || record.record.reviewer.caseInsensitiveCompare(reviewer) == .orderedSame)
        }
        VStack(spacing: 0) {
            bar(reviewers: Set(all.records.map(\.record.reviewer)).sorted())
            Divider()
            if inRange.isEmpty {
                ContentUnavailableView {
                    Label("No reviews", systemImage: "chart.bar.xaxis")
                } description: {
                    Text(all.records.isEmpty
                         ? "Review a PR with Claude and post it. Each review is recorded in the project's harness (Settings › General › Agent), so everyone's show here: who reviews with Gannin, and how its findings land."
                         : "Nothing in this range. Try a longer one.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        tiles(inRange.map(\.record))
                        HStack(alignment: .top, spacing: 16) {
                            severityChart(inRange.map(\.record))
                            categoryChart(inRange.map(\.record))
                        }
                        weeklyChart(inRange.map(\.record))
                        section("Reviewers", help: "Who reviews with Gannin, and how their reviews land") {
                            StatsTable(rows: reviewerRows(inRange.map(\.record)), columns: reviewerColumns, sort: $reviewerSort, selectedID: nil, onSelect: { row in
                                reviewer = reviewer == row.id ? "" : row.id
                            })
                        }
                        section("Reviews", help: "Every review in the range, newest first") {
                            StatsTable(rows: inRange.sorted { $0.date > $1.date }, columns: reviewColumns, sort: $reviewSort, selectedID: nil, onSelect: { row in
                                open(row)
                            })
                        }
                        footnote(all, shown: inRange)
                    }
                    .padding(20)
                }
            }
        }
        .loadsHarness(org: org)
    }

    // MARK: Data

    /// A record, and whether it's only on this Mac so far.
    struct Row: Identifiable {
        let record: ReviewRecord
        let isLocal: Bool
        var id: String { record.id }
        var date: Date { record.postedAt ?? record.startedAt }
    }

    private func records() -> (records: [Row], harnesses: Int) {
        let config = configs.config(for: org)
        var rows: [String: Row] = [:]
        for setup in config.harnesses {
            for file in harness.index(for: org, setup)?.dataFiles ?? [] where ReviewRecord.isRecord(file.path) {
                guard let record = ReviewRecord.read(file.text) else { continue }
                if let existing = rows[record.id], existing.record.updatedAt >= record.updatedAt { continue }
                rows[record.id] = Row(record: record, isLocal: false)
            }
        }
        if let me = auth.viewer?.login {
            for session in sessions.sessions(for: org) where session.reviewOf != nil {
                guard let record = ReviewRecord.local(session, reviewer: me), rows[record.id] == nil else { continue }
                rows[record.id] = Row(record: record, isLocal: true)
            }
        }
        return (Array(rows.values), config.harnesses.count)
    }

    // MARK: Bar

    private func bar(reviewers: [String]) -> some View {
        HStack(spacing: 10) {
            Picker("Range", selection: $days) {
                ForEach(Self.ranges, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("Everyone") { reviewer = "" }
                Divider()
                ForEach(reviewers, id: \.self) { login in
                    Toggle("@\(login)", isOn: Binding(get: { reviewer == login }, set: { reviewer = $0 ? login : "" }))
                }
            } label: {
                Label(reviewer.isEmpty ? "Everyone" : "@\(reviewer)", systemImage: "person")
            }
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Tiles

    private func tiles(_ records: [ReviewRecord]) -> some View {
        let posted = records.flatMap(\.posted)
        let accepted = records.flatMap(\.accepted)
        let decided = records.flatMap(\.findings)
        let dismissed = records.flatMap(\.dismissed)
        let reviewers = Set(records.map { $0.reviewer.lowercased() })
        let automatic = records.filter { $0.postedAutomatically == true }.count
        let wasPosted = records.filter { $0.postedAt != nil }
        let efforts = records.compactMap(\.effort).sorted()
        let toMerge = records.compactMap { record -> TimeInterval? in
            guard let posted = record.postedAt, let merged = record.mergedAt, merged > posted else { return nil }
            return merged.timeIntervalSince(posted)
        }.sorted()
        return TileGrid {
            StatTile(title: "Reviews", value: "\(records.count)", detail: "\(wasPosted.count) posted\(automatic > 0 ? ", \(automatic) by themselves" : "")")
            StatTile(title: "Reviewers", value: "\(reviewers.count)", detail: reviewers.sorted().prefix(3).map { "@\($0)" }.joined(separator: ", ") + (reviewers.count > 3 ? " and more" : ""))
            StatTile(title: "Findings posted", value: "\(posted.count)", detail: wasPosted.isEmpty ? nil : String(format: "%.1f a review posted", Double(posted.count) / Double(wasPosted.count)))
            StatTile(title: "Acted on", value: Self.percent(accepted.count, of: posted.count), detail: "\(accepted.count) of \(posted.count) threads resolved")
            StatTile(title: "Dismissed before posting", value: Self.percent(dismissed.count, of: decided.count), detail: "\(dismissed.count) of \(decided.count) findings")
            if !efforts.isEmpty {
                StatTile(title: "Review effort", value: "\(efforts[efforts.count / 2]) of 5", detail: "Median, as the reviewer judged")
            }
            if !toMerge.isEmpty {
                StatTile(title: "Posted to merge", value: Duration.seconds(toMerge[toMerge.count / 2]).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)), detail: "Median, \(toMerge.count) merged")
            }
        }
    }

    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "None" }
        return "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }

    // MARK: Charts

    private struct Bar: Identifiable {
        let group: String
        let series: String
        let count: Int
        var id: String { group + series }
    }

    private func severityChart(_ records: [ReviewRecord]) -> some View {
        let findings = records.flatMap(\.posted)
        let bars = ReviewSeverity.allCases.flatMap { severity -> [Bar] in
            let posted = findings.filter { (ReviewSeverity($0.severity) ?? .minor) == severity }
            return [Bar(group: severity.title, series: "Posted", count: posted.count),
                    Bar(group: severity.title, series: "Acted on", count: posted.filter { $0.resolvedAt != nil }.count)]
        }
        return chartCard("By severity", help: "Findings posted, and those whose threads were resolved", bars: bars, rates: ReviewSeverity.allCases.map { severity in
            let posted = findings.filter { (ReviewSeverity($0.severity) ?? .minor) == severity }
            return (severity.title, Self.percent(posted.filter { $0.resolvedAt != nil }.count, of: posted.count), posted.count)
        })
    }

    private func categoryChart(_ records: [ReviewRecord]) -> some View {
        let findings = records.flatMap(\.posted)
        let groups: [(String, [ReviewRecord.Finding])] = ReviewCategory.allCases.map { category in
            (category.shortTitle, findings.filter { ReviewCategory($0.category) == category })
        } + [("Other", findings.filter { ReviewCategory($0.category) == nil })]
        let shown = groups.filter { !$0.1.isEmpty }
        let bars = shown.flatMap { name, posted in
            [Bar(group: name, series: "Posted", count: posted.count),
             Bar(group: name, series: "Acted on", count: posted.filter { $0.resolvedAt != nil }.count)]
        }
        return chartCard("By category", help: "Findings posted, and those whose threads were resolved. Reviews before categories were asked for count as Other.", bars: bars, rates: shown.map { name, posted in
            (name, Self.percent(posted.filter { $0.resolvedAt != nil }.count, of: posted.count), posted.count)
        })
    }

    private func chartCard(_ title: String, help: String, bars: [Bar], rates: [(String, String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(help).font(.caption).foregroundStyle(.secondary)
            Chart(bars) { bar in
                BarMark(x: .value("Kind", bar.group), y: .value("Findings", bar.count))
                    .foregroundStyle(by: .value("", bar.series))
                    .position(by: .value("", bar.series))
            }
            .chartForegroundStyleScale(["Posted": ChartPalette.orange, "Acted on": ChartPalette.blue])
            .frame(height: 200)
            HStack(spacing: 14) {
                ForEach(rates.filter { $0.2 > 0 }, id: \.0) { name, rate, _ in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                        Text(rate).font(.callout.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .help("The share of each kind's posted findings that were acted on")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private struct WeekBar: Identifiable {
        let week: Date
        let reviewer: String
        let count: Int
        var id: String { "\(week.timeIntervalSince1970)\(reviewer)" }
    }

    private func weeklyChart(_ records: [ReviewRecord]) -> some View {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let grouped = Dictionary(grouping: records) { record in
            WeekKey(week: calendar.dateInterval(of: .weekOfYear, for: record.postedAt ?? record.startedAt)?.start ?? .now, reviewer: record.reviewer.lowercased())
        }
        let bars = grouped.map { WeekBar(week: $0.key.week, reviewer: "@\($0.key.reviewer)", count: $0.value.count) }.sorted { $0.week < $1.week }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Reviews a week").font(.headline)
            Text("By who ran them").font(.caption).foregroundStyle(.secondary)
            Chart(bars) { bar in
                BarMark(x: .value("Week", bar.week, unit: .weekOfYear), y: .value("Reviews", bar.count))
                    .foregroundStyle(by: .value("Reviewer", bar.reviewer))
            }
            .chartForegroundStyleScale(range: ChartPalette.categorical.map { AnyShapeStyle($0) })
            .frame(height: 180)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private struct WeekKey: Hashable {
        let week: Date
        let reviewer: String
    }

    // MARK: Tables

    struct ReviewerRow: Identifiable {
        let id: String
        let reviews: Int
        let automatic: Int
        let posted: Int
        let dismissed: Int
        let findings: Int
        let accepted: Int
        let last: Date
    }

    private func reviewerRows(_ records: [ReviewRecord]) -> [ReviewerRow] {
        let byReviewer: [String: [ReviewRecord]] = Dictionary(grouping: records) { $0.reviewer.lowercased() }
        var rows: [ReviewerRow] = []
        for (login, mine) in byReviewer {
            let automatic = mine.filter { $0.postedAutomatically == true }.count
            let posted = mine.flatMap(\.posted).count
            let dismissed = mine.flatMap(\.dismissed).count
            let findings = mine.flatMap(\.findings).count
            let accepted = mine.flatMap(\.accepted).count
            let last = mine.map { $0.postedAt ?? $0.startedAt }.max() ?? .distantPast
            rows.append(ReviewerRow(id: login, reviews: mine.count, automatic: automatic, posted: posted, dismissed: dismissed, findings: findings, accepted: accepted, last: last))
        }
        return rows.sorted { $0.reviews > $1.reviews }
    }

    private var reviewerColumns: [StatsColumn<ReviewerRow>] {
        let who = StatsColumn<ReviewerRow>(
            id: "who", title: "Reviewer", help: "Who ran the review", minWidth: 180,
            sortKey: { .text($0.id) }, cell: { row in AnyView(Text("@\(row.id)").fontWeight(.medium)) })
        let accepted = StatsColumn<ReviewerRow>(
            id: "accepted", title: "Acted on", help: "Posted findings whose threads were resolved", width: 90, alignment: .trailing,
            sortKey: { row in .number(row.posted == 0 ? -1 : Double(row.accepted) / Double(row.posted)) },
            cell: { row in AnyView(Text(Self.percent(row.accepted, of: row.posted)).monospacedDigit()) })
        let last = StatsColumn<ReviewerRow>(
            id: "last", title: "Last review", help: "When they last reviewed", width: 130,
            sortKey: { row in .number(row.last.timeIntervalSince1970) },
            cell: { row in AnyView(Text(row.last.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)) })
        let reviews = number("reviews", "Reviews", "Reviews run") { $0.reviews }
        let automatic = number("automatic", "By themselves", "Posted automatically, from review requests") { $0.automatic }
        let posted = number("posted", "Posted", "Findings posted") { $0.posted }
        let dismissed = number("dismissed", "Dismissed", "Findings dismissed before posting") { $0.dismissed }
        return [who, reviews, automatic, posted, dismissed, accepted, last]
    }

    private func number(_ id: String, _ title: String, _ help: String, _ value: @escaping (ReviewerRow) -> Int) -> StatsColumn<ReviewerRow> {
        StatsColumn(id: id, title: title, help: help, width: 100, alignment: .trailing,
                    sortKey: { .number(Double(value($0))) },
                    cell: { row in AnyView(Text("\(value(row))").monospacedDigit()) })
    }

    private var reviewColumns: [StatsColumn<Row>] {
        let pr = StatsColumn<Row>(
            id: "pr", title: "Pull request", help: "The PR reviewed", minWidth: 280,
            sortKey: { row in .text(row.record.title) }, cell: { row in AnyView(Self.pullRequestCell(row.record)) })
        let reviewer = StatsColumn<Row>(
            id: "reviewer", title: "Reviewer", help: "Who ran it", width: 130,
            sortKey: { row in .text(row.record.reviewer) }, cell: { row in AnyView(Self.reviewerCell(row)) })
        let verdict = StatsColumn<Row>(
            id: "verdict", title: "Verdict", help: "What the reviewer would do", width: 120,
            sortKey: { row in .text(row.record.verdict ?? "") },
            cell: { row in AnyView(Text(Self.verdict(row.record.verdict)).foregroundStyle(.secondary)) })
        let effort = StatsColumn<Row>(
            id: "effort", title: "Effort", help: "Review effort, 1 to 5", width: 70, alignment: .trailing,
            sortKey: { row in .number(Double(row.record.effort ?? 0)) },
            cell: { row in AnyView(Text(row.record.effort.map(String.init) ?? "").monospacedDigit()) })
        let posted = StatsColumn<Row>(
            id: "posted", title: "Posted", help: "Findings posted, of those it raised", width: 80, alignment: .trailing,
            sortKey: { row in .number(Double(row.record.posted.count)) }, cell: { row in AnyView(Self.postedCell(row.record)) })
        let accepted = StatsColumn<Row>(
            id: "accepted", title: "Acted on", help: "Posted findings whose threads were resolved, when last looked at", width: 80, alignment: .trailing,
            sortKey: { row in .number(Double(row.record.accepted.count)) },
            cell: { row in AnyView(Text(row.record.posted.isEmpty ? "" : "\(row.record.accepted.count)").monospacedDigit()) })
        let state = StatsColumn<Row>(
            id: "state", title: "PR", help: "The PR's state when last looked at", width: 80,
            sortKey: { row in .text(row.record.state ?? "") },
            cell: { row in AnyView(Text(row.record.state?.capitalized ?? "").foregroundStyle(.secondary)) })
        let when = StatsColumn<Row>(
            id: "when", title: "When", help: "Posted, else started", width: 120,
            sortKey: { row in .number(row.date.timeIntervalSince1970) },
            cell: { row in AnyView(Text(row.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)) })
        return [pr, reviewer, verdict, effort, posted, accepted, state, when]
    }

    private static func pullRequestCell(_ record: ReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.title).lineLimit(1)
            Text("\(record.repo)#\(record.number)\(record.author.map { " by @\($0)" } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private static func reviewerCell(_ row: Row) -> some View {
        HStack(spacing: 4) {
            Text("@\(row.record.reviewer)").lineLimit(1)
            if row.isLocal {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(.secondary)
                    .help("On this Mac, not recorded in the harness yet")
            }
        }
    }

    private static func postedCell(_ record: ReviewRecord) -> some View {
        Text(record.postedAt == nil ? "Not yet" : "\(record.posted.count) of \(record.findings.count)")
            .monospacedDigit()
            .foregroundStyle(record.postedAt == nil ? .secondary : .primary)
    }

    static func verdict(_ verdict: String?) -> String {
        switch verdict {
        case "approve": "Approve"
        case "request_changes": "Request changes"
        case "comment": "Comment"
        default: ""
        }
    }

    private func section<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(help).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func footnote(_ all: (records: [Row], harnesses: Int), shown: [Row]) -> some View {
        let local = shown.filter(\.isLocal).count
        var lines = ["\"Acted on\" is a posted finding whose GitHub thread was resolved (fixed, or answered), as last looked at: when the review was posted again, finished, or its PR merged or closed while watched."]
        if local > 0 {
            lines.append("\(local) review\(local == 1 ? " is" : "s are") on this Mac only, not recorded in the harness yet; \(local == 1 ? "its" : "their") threads haven't been looked at.")
        }
        lines.append("Time to first review and the PR stages are on Delivery › PR flow.")
        return Text(lines.joined(separator: " "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ row: Row) {
        if let session = sessions.sessions(for: org).first(where: { $0.reviewOf?.repo == row.record.repo && $0.reviewOf?.number == row.record.number }),
           row.record.reviewer.caseInsensitiveCompare(auth.viewer?.login ?? "") == .orderedSame {
            sessions.show(session.id, with: openWindow)
        } else if let url = URL(string: "https://github.com/\(row.record.repo)/pull/\(row.record.number)") {
            NSWorkspace.shared.open(url)
        }
    }
}
