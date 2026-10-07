import Charts
import SwiftUI
import AppKit

// MARK: - What changed

/// Why a window's numbers moved from the period before, in plain lines:
/// throughput and which repos it came from, which stages made cycle time
/// longer or shorter, and the repos and people whose PRs changed most.
struct DeliveryExplanation {
    struct Line: Identifiable, Hashable {
        let id = UUID()
        let text: String
        /// True when it's for the worse, false for the better, nil neither.
        let isWorse: Bool?
    }

    let lines: [Line]

    init(current: DeliverySummary, previous: DeliverySummary, members: [String: Person] = [:]) {
        var lines: [Line] = []
        func duration(_ value: TimeInterval?) -> String { value?.compactDuration ?? "-" }
        func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }

        // Throughput, and the repos it moved in.
        if current.merged != previous.merged {
            let change = previous.merged > 0 ? " (\(current.merged > previous.merged ? "+" : "")\(percent(Double(current.merged) / Double(previous.merged) - 1)))" : ""
            let movers = Set(current.repos.keys).union(previous.repos.keys)
                .map { ($0, (current.repos[$0]?.count ?? 0) - (previous.repos[$0]?.count ?? 0)) }
                .filter { $0.1 != 0 }
                .sorted { abs($0.1) > abs($1.1) }
                .prefix(3)
                .map { "\(Self.short($0.0)) \($0.1 > 0 ? "+" : "")\($0.1)" }
            lines.append(Line(
                text: "\(current.merged) PRs merged, \(current.merged > previous.merged ? "up" : "down") from \(previous.merged)\(change)\(movers.isEmpty ? "" : ": " + movers.joined(separator: ", "))",
                isWorse: nil
            ))
        }

        // Cycle time, by the stages that moved it.
        if let now = current.cycleTime.median, let before = previous.cycleTime.median, abs(now - before) >= 3600 {
            lines.append(Line(text: "Cycle time median \(duration(now)), was \(duration(before))", isWorse: now > before))
            let stages = CycleStage.allCases.compactMap { stage -> (CycleStage, TimeInterval, TimeInterval, TimeInterval)? in
                guard let a = current.stages[stage]?.overall.median, let b = previous.stages[stage]?.overall.median else { return nil }
                return (stage, a - b, a, b)
            }
            .filter { abs($0.1) >= 1800 }
            .sorted { abs($0.1) > abs($1.1) }
            for (stage, delta, a, b) in stages.prefix(2) {
                lines.append(Line(text: "\(stage.rawValue) \(delta > 0 ? "longer" : "shorter") by \(abs(delta).compactDuration): median \(duration(a)), was \(duration(b))", isWorse: delta > 0))
            }
        }
        if let a = current.stages[.rework]?.share, let b = previous.stages[.rework]?.share, abs(a - b) >= 0.1, current.merged >= 5, previous.merged >= 5 {
            lines.append(Line(text: "Rework on \(percent(a)) of PRs, was \(percent(b))", isWorse: a > b))
        }
        if let now = current.timeToFirstReview.median, let before = previous.timeToFirstReview.median, abs(now - before) >= 1800 {
            lines.append(Line(text: "First review median \(duration(now)), was \(duration(before))", isWorse: now > before))
        }
        if let a = current.prSizeMedian, let b = previous.prSizeMedian, b > 0, abs(Double(a) / Double(b) - 1) >= 0.25 {
            lines.append(Line(text: "PRs are \(a > b ? "bigger" : "smaller"): median \(a) lines, was \(b)", isWorse: a > b))
        }

        // Where cycle time moved most, by repo then by author: three PRs or
        // more each side.
        func movers(_ now: [String: (count: Int, cycleTime: TimeInterval?)], _ before: [String: (count: Int, cycleTime: TimeInterval?)], name: (String) -> String) -> [Line] {
            now.compactMap { key, value -> (String, TimeInterval, TimeInterval, TimeInterval, Int)? in
                guard !key.isEmpty, value.count >= 3, let old = before[key], old.count >= 3,
                      let a = value.cycleTime, let b = old.cycleTime else { return nil }
                return (key, a - b, a, b, value.count)
            }
            .filter { abs($0.1) >= 6 * 3600 }
            .sorted { abs($0.1) > abs($1.1) }
            .prefix(2)
            .map { key, delta, a, b, count in
                Line(text: "\(name(key)): cycle time \(duration(a)), was \(duration(b)) (\(count) PRs)", isWorse: delta > 0)
            }
        }
        lines += movers(current.repos, previous.repos) { Self.short($0) }
        lines += movers(current.authors, previous.authors) { members[$0]?.displayName ?? $0 }
        self.lines = lines
    }

    private static func short(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
}

// MARK: - Dashboard sections

/// The window's goals, each on track or not, with where it was before.
struct GoalsSection: View {
    let results: [GoalResult]
    @Binding var selection: DetailSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Goals").font(.headline)
                let met = results.filter { $0.onTrack == true }.count
                Text("\(met) of \(results.count) on track")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(results) { result in
                    Button {
                        if let drill = result.drill { selection = .metric(drill) }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.onTrack == nil ? "circle.dashed" : result.onTrack == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(result.onTrack == nil ? .secondary : result.onTrack == true ? ChartPalette.good : ChartPalette.critical)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name).font(.callout.weight(.medium))
                                Text("\(result.actual) against \(result.target)")
                                    .font(.callout.monospacedDigit())
                                if let previous = result.previous {
                                    Text("Was \(previous)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Why the numbers moved, against the period before.
struct WhatChangedSection: View {
    let explanation: DeliveryExplanation
    let previousPhrase: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What changed").font(.headline)
            Text("Against \(previousPhrase).")
                .font(.callout)
                .foregroundStyle(.secondary)
            if explanation.lines.isEmpty {
                Text("Nothing moved much.")
                    .foregroundStyle(.secondary)
            }
            ForEach(explanation.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.isWorse == nil ? "circle.fill" : line.isWorse == true ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(line.isWorse == nil ? .secondary : line.isWorse == true ? ChartPalette.critical : ChartPalette.good)
                    Text(line.text)
                }
            }
        }
    }
}

/// PR size, the large ones, and repos where large PRs got through review
/// quickly (approved within 15 minutes with nothing asked for) or with
/// none.
struct SizeRiskSection: View {
    let metrics: OrgMetrics
    @Binding var selection: DetailSelection?

    var body: some View {
        let size = metrics.prSize
        VStack(alignment: .leading, spacing: 10) {
            Text("PR size and risk").font(.headline)
            TileGrid {
                StatTile(
                    title: "Median PR size",
                    value: size.median.map { "\($0)" } ?? "-",
                    detail: size.p75.map { "Lines changed · p75 \($0)" },
                    change: metrics.previous.flatMap { previous in
                        previous.prSizeMedian.flatMap { before in size.median.flatMap { StatChange.percent(Double($0), Double(before), higherIsWorse: true) } }
                    }
                )
                StatTile(
                    title: "Large PRs",
                    value: "\(size.large.count)",
                    detail: "Over \(SizeStat.largeLines) lines" + (metrics.merged.isEmpty ? "" : ", \((Double(size.large.count) / Double(metrics.merged.count)).formatted(.percent.precision(.fractionLength(0)))) of merged")
                )
                StatTile(
                    title: "Rushed large PRs",
                    value: "\(size.large.filter(\.isRushed).count)",
                    detail: "Approved within 15 minutes, or unreviewed"
                )
            }
            if !metrics.merged.isEmpty {
                PRSizeDistribution(size: size)
            }
            if !metrics.repoRisks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(metrics.repoRisks.prefix(5)) { risk in
                        HStack(spacing: 10) {
                            Text(risk.repo.split(separator: "/").last.map(String.init) ?? risk.repo)
                                .frame(width: 160, alignment: .leading)
                                .lineLimit(1)
                            Text("\(risk.large) large")
                                .foregroundStyle(.secondary)
                            if !risk.rushed.isEmpty {
                                Text("\(risk.rushed.count) rushed")
                                    .foregroundStyle(ChartPalette.critical)
                            }
                            Text("median \(risk.medianSize) lines")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .font(.callout)
                    }
                }
            }
            if !size.large.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Largest").font(.callout.weight(.medium))
                    ForEach(size.large.prefix(5)) { pr in
                        Button {
                            selection = .pullRequestReference(pr.reference)
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(pr.size)")
                                    .font(.callout.monospacedDigit())
                                    .frame(width: 50, alignment: .trailing)
                                Text(pr.title).lineLimit(1)
                                Text("\(pr.repo.split(separator: "/").last ?? "")#\(pr.number)")
                                    .foregroundStyle(.secondary)
                                if pr.isRushed {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .help(pr.firstReviewAt == nil ? "Merged without review" : "Approved within 15 minutes of being ready")
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// PR size in short, for the Overview: the median against the period
/// before, the smallest and largest (each opening the PR), median files,
/// and how sizes spread.
struct PRSizeSummary: View {
    let metrics: OrgMetrics
    @Binding var selection: DetailSelection?

    var body: some View {
        let size = metrics.prSize
        VStack(alignment: .leading, spacing: 12) {
            Text("PR size").font(.headline)
            TileGrid {
                StatTile(
                    title: "Median PR size",
                    value: size.median.map { $0.formatted() } ?? "-",
                    detail: size.p75.map { "Lines changed · p75 \($0.formatted())" },
                    change: metrics.previous.flatMap { previous in
                        previous.prSizeMedian.flatMap { before in size.median.flatMap { StatChange.percent(Double($0), Double(before), higherIsWorse: true) } }
                    }
                )
                pullRequestTile("Smallest", size.smallest)
                pullRequestTile("Largest", size.largest)
                StatTile(
                    title: "Median files changed",
                    value: size.medianFiles.map { $0.formatted() } ?? "-",
                    detail: size.medianFiles == nil ? "Not known for these PRs yet" : "Per PR"
                )
            }
            if !metrics.merged.isEmpty {
                PRSizeDistribution(size: size)
            }
        }
    }

    /// A PR's lines changed, opening it when clicked.
    @ViewBuilder
    private func pullRequestTile(_ title: String, _ pr: MetricPullRequest?) -> some View {
        let tile = StatTile(
            title: title,
            value: pr.map { $0.size.formatted() } ?? "-",
            detail: pr.map { "Lines · \($0.repo.split(separator: "/").last ?? "")#\($0.number) \($0.title)" }
        )
        if let pr {
            Button {
                selection = .pullRequestReference(pr.reference)
            } label: {
                tile
            }
            .buttonStyle(.plain)
            .help(pr.title)
        } else {
            tile
        }
    }
}

/// How merged PRs spread by lines changed and by files changed, side by
/// side.
struct PRSizeDistribution: View {
    let size: SizeStat

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            SizeDistributionChart(
                title: "Lines changed per PR", unit: "lines", labels: SizeStat.bucketLabels, counts: size.buckets,
                note: "Over \(SizeStat.largeLines) lines counts as large."
            )
            SizeDistributionChart(
                title: "Files changed per PR", unit: "files", labels: SizeStat.fileBucketLabels, counts: size.fileBuckets,
                note: size.fileBuckets.reduce(0, +) < size.buckets.reduce(0, +) ? "Only PRs whose files changed are known." : nil
            )
        }
    }
}

/// How many merged PRs fall in each bucket, one series; hover a bar for
/// its count and share.
struct SizeDistributionChart: View {
    let title: String
    let unit: String
    let labels: [String]
    let counts: [Int]
    var note: String?
    @State private var hovered: String?

    var body: some View {
        let total = counts.reduce(0, +)
        let rows = Array(zip(labels, counts))
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            if total == 0 {
                Text("Not known for these PRs yet.").font(.callout).foregroundStyle(.secondary)
                    .frame(height: 140, alignment: .topLeading)
            } else {
                Chart {
                    ForEach(rows, id: \.0) { label, count in
                        BarMark(x: .value(title, label), y: .value("PRs", count))
                            .foregroundStyle(ChartPalette.blue.opacity(hovered == nil || hovered == label ? 1 : 0.5))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                }
                .chartOverlay { proxy in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = proxy.value(atX: location.x, as: String.self)
                            case .ended: hovered = nil
                            }
                        }
                }
                .frame(height: 140)
                .accessibilityLabel("Merged PRs by \(unit) changed")
                .accessibilityValue(rows.map { "\($0.0) \(unit): \($0.1)" }.joined(separator: ", "))
            }
            if let hovered, let index = labels.firstIndex(of: hovered), total > 0 {
                let count = counts[index]
                Text("\(hovered) \(unit): \(count) PR\(count == 1 ? "" : "s"), \((Double(count) / Double(total)).formatted(.percent.precision(.fractionLength(0))))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text([note, "Hover for values."].compactMap { $0 }.joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MetricPullRequest {
    /// For opening it in a drawer, outside the snapshot.
    var reference: PullRequestReference {
        PullRequestReference(org: repo.split(separator: "/").first.map(String.init) ?? "", id: id, number: number, title: title, repo: repo, url: url)
    }
}

// MARK: - Weekly digest

/// The week in a page of Markdown: delivery against the week before and the
/// goals, what shipped by investment category, notable PRs, CI, and who's
/// off next week. Copied, committed to the harness, or rewritten by Claude.
enum WeeklyDigest {
    static func markdown(
        org: String,
        metrics: OrgMetrics,
        issues: IssueHistory?,
        config: OrgConfig,
        actions: ActionsMetrics?,
        people: [String: PersonDates],
        members: [Person],
        goals: [GoalResult],
        now: Date = .now
    ) -> String {
        let calendar = Calendar.current
        let start = metrics.interval.start
        var lines = ["# \(org): the week to \(now.formatted(date: .abbreviated, time: .omitted))", ""]
        func duration(_ value: TimeInterval?) -> String { value?.compactDuration ?? "-" }

        lines += ["## Delivery", ""]
        let previous = metrics.previous
        lines.append("- \(metrics.merged.count) PRs merged\(previous.map { ", \($0.merged) the week before" } ?? "")")
        lines.append("- Cycle time median \(duration(metrics.cycleTime.median))\(previous.map { ", was \(duration($0.cycleTime.median))" } ?? "")")
        lines.append("- First review median \(duration(metrics.timeToFirstReview.median))\(previous.map { ", was \(duration($0.timeToFirstReview.median))" } ?? "")")
        if !metrics.mergedWithoutReview.isEmpty { lines.append("- \(metrics.mergedWithoutReview.count) merged without review") }
        for goal in goals {
            lines.append("- Goal, \(goal.name.lowercased()): \(goal.actual) against \(goal.target)\(goal.onTrack == false ? " (off track)" : goal.onTrack == true ? " (on track)" : "")")
        }
        if let previous {
            let explanation = DeliveryExplanation(current: metrics.current, previous: previous, members: Dictionary(members.map { ($0.login, $0) }, uniquingKeysWith: { a, _ in a }))
            for line in explanation.lines.prefix(4) where !line.text.hasPrefix("\(metrics.merged.count) PRs") {
                lines.append("- \(line.text)")
            }
        }
        lines.append("")

        if let issues {
            let completed = issues.issues.values.filter { $0.isCompleted && ($0.closedAt ?? .distantPast) >= start && ($0.closedAt ?? .distantPast) < now && !config.repoExclusion.contains($0.repo) }
            if !completed.isEmpty {
                lines += ["## Shipped", ""]
                let investments = config.investmentConfig
                let grouped = Dictionary(grouping: completed) { record in
                    investments.categorise(record, parent: record.parentID.flatMap { issues.issues[$0] })?.category.name ?? "Uncategorised"
                }
                for (category, records) in grouped.sorted(by: { $0.value.count > $1.value.count }) {
                    lines.append("### \(category) (\(records.count))")
                    for record in records.sorted(by: { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) }) {
                        lines.append("- [\(record.repo.split(separator: "/").last ?? "")#\(record.number)](\(record.url.absoluteString)) \(record.title)")
                    }
                    lines.append("")
                }
            }
        }

        if !metrics.merged.isEmpty {
            lines += ["## Notable PRs", ""]
            for pr in metrics.merged.sorted(by: { $0.size > $1.size }).prefix(3) {
                lines.append("- Largest: [\(pr.title)](\(pr.url.absoluteString)), \(pr.size) lines\(pr.isRushed ? ", reviewed quickly" : "")")
            }
            for pr in metrics.merged.sorted(by: { $0.cycleTime > $1.cycleTime }).prefix(3) {
                lines.append("- Slowest: [\(pr.title)](\(pr.url.absoluteString)), \(pr.cycleTime.compactDuration) from first commit to merge")
            }
            lines.append("")
        }

        if let actions {
            var ci: [String] = []
            for workflow in actions.red {
                ci.append("- \(workflow.repo.split(separator: "/").last ?? "") \(workflow.name) is failing on the default branch")
            }
            let flaky = actions.workflows.filter { $0.passedOnRetry > 0 || $0.mixedCommits > 0 }
            if !flaky.isEmpty { ci.append("- \(flaky.count) workflow\(flaky.count == 1 ? " looks" : "s look") flaky") }
            if actions.counts.ran > 0 {
                ci.append("- \(actions.counts.ran) runs, \(actions.runTime.compactDuration) of run time")
            }
            if !ci.isEmpty { lines += ["## CI", ""] + ci + [""] }
        }

        // Who's off in the coming week.
        let weekAhead = DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)
        let names = Dictionary(members.map { ($0.login, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var off: [String] = []
        for (login, dates) in people.sorted(by: { $0.key < $1.key }) {
            for absence in dates.absences where absence.end >= weekAhead.start && absence.start < weekAhead.end {
                let span = absence.start == absence.end
                    ? absence.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    : "\(absence.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) to \(absence.end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
                off.append("- \(names[login] ?? login): \(absence.kind.rawValue.lowercased()), \(span)\(absence.isRequested ? " (requested)" : "")")
            }
        }
        if !off.isEmpty { lines += ["## Off next week", ""] + off + [""] }
        return lines.joined(separator: "\n")
    }
}

/// A page of Markdown Gannin wrote (a digest, standup notes) to read, edit,
/// copy, have Claude rewrite, or commit to the harness at `path`.
struct NotesSheet: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(\.dismiss) private var dismiss
    let title: String
    let org: String
    /// Where it goes in the harness, and the commit's message.
    let path: String
    let message: String
    /// What Claude is asked to do with it.
    let rewrite: String
    let build: () -> String
    @State private var text = ""
    @State private var editing = false
    @State private var status: String?
    @State private var working = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Picker("", selection: $editing) {
                    Text("Preview").tag(false)
                    Text("Edit").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(12)
            Divider()
            if editing {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
            } else {
                ScrollView {
                    MarkdownText(source: text, reading: 14)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rewrite with Claude") { rewriteWithClaude() }
                    .disabled(working)
                    .help("Ask Claude to make it a short, readable update, keeping every fact")
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    status = "Copied"
                }
                if configs.config(for: org).harness != nil {
                    Button("Commit to Harness") { commit() }
                        .disabled(working)
                        .help("Commit it to the harness as \(path)")
                }
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 720)
        .onAppear { text = build() }
    }

    private func commit() {
        guard let setup = configs.config(for: org).harness else { return }
        working = true
        let content = text + "\n"
        Task {
            do {
                _ = try await harness.commit(org: org, setup: setup) { _ in
                    HarnessChange(message: message, files: [path: content])
                }
                status = "Committed \(path)"
            } catch {
                status = "Couldn't commit: \(error.localizedDescription)"
            }
            working = false
        }
    }

    private func rewriteWithClaude() {
        working = true
        status = "Claude is rewriting it"
        let prompt = rewrite + " Keep every fact, number and link. Use Markdown headings and bullets. Reply with the text only, no preamble.\n\n" + text
        Task {
            do {
                text = try await ClaudeRunner.ask(prompt, org: org)
                status = "Rewritten by Claude"
            } catch {
                status = error.localizedDescription
            }
            working = false
        }
    }
}

/// The weekly digest in a `NotesSheet`, committed as `digests/<date>.md`.
struct DigestSheet: View {
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(IssueStore.self) private var issueStore
    @Environment(ActionsStore.self) private var actionsStore
    @Environment(PeopleDatesStore.self) private var peopleDates
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(HiddenStore.self) private var hidden
    let org: String
    let team: Team?

    var body: some View {
        let day = Date.now.formatted(.iso8601.year().month().day())
        NotesSheet(
            title: "Weekly digest", org: org, path: "digests/\(day).md", message: "Gannin: weekly digest, \(day)",
            rewrite: "Rewrite this weekly engineering digest as a short, readable update for the team and leadership, leading with what matters most.",
            build: build
        )
    }

    private func build() -> String {
        guard let history = metricsStore.history(for: org) else { return "No metrics yet." }
        let snapshot = orgs.snapshot(for: org)
        let config = configs.config(for: org)
        let metrics = OrgMetrics(history: history, window: MetricsWindow(code: 7), team: team, members: snapshot?.members ?? [], hidden: hidden.keys, config: config)
        let actions = actionsStore.history(for: org).map { ActionsMetrics(history: $0, window: MetricsWindow(code: 7), config: config) }
        return WeeklyDigest.markdown(
            org: orgs.org(login: org)?.displayName ?? org, metrics: metrics, issues: issueStore.history(for: org), config: config,
            actions: actions, people: peopleDates.all(in: org), members: snapshot?.members ?? [],
            goals: config.goals?.targets(for: team).results(for: metrics) ?? []
        )
    }
}

// MARK: - Settings

/// The org's Settings › Goals: targets for the org, and for any team that
/// wants its own (an empty one uses the org's, shown as its prompt).
struct GoalsSettingsSection: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let teams: [Team]
    @State private var team = ""

    var body: some View {
        let goals = configs.config(for: org).goals ?? MetricGoals()
        let targets = team.isEmpty ? goals.org : goals.teams[team] ?? .init()
        let fallback: MetricGoals.Targets? = team.isEmpty ? nil : goals.org
        Section {
            Picker("Goals for", selection: $team) {
                Text("The whole org").tag("")
                if !teams.isEmpty {
                    Divider()
                    ForEach(teams.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { Text($0.name).tag($0.slug) }
                }
            }
        } footer: {
            Text(team.isEmpty
                 ? "Shown on the Dashboard as on track or not, for the window picked, with where each was in the period before. Leave one empty for no goal. The Scorecard keeps its own measurables and targets for each cadence, starting from these as weekly ones."
                 : "A team's empty goals use the org's, shown greyed in the box.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Velocity") {
            row("PRs merged", "A week; a longer window is held to as many weeks' worth", unit: "a week", at: "at least",
                value: targets.mergedPerWeek, fallback: fallback?.mergedPerWeek) { value in update { $0.mergedPerWeek = value } }
            row("Cycle time", "Median, first commit to merge", unit: "hours", at: "at most",
                value: targets.cycleTimeHours, fallback: fallback?.cycleTimeHours) { value in update { $0.cycleTimeHours = value } }
            row("First review", "Median wait for the first review once ready", unit: "hours", at: "at most",
                value: targets.firstReviewHours, fallback: fallback?.firstReviewHours) { value in update { $0.firstReviewHours = value } }
        }
        Section("Quality") {
            row("PRs with rework", "Changes asked for after the first review", unit: "%", at: "at most",
                value: targets.reworkShare.map { $0 * 100 }, fallback: fallback?.reworkShare.map { $0 * 100 }) { value in update { $0.reworkShare = value.map { min($0, 100) / 100 } } }
            row("Merged without review", "In repos that need one", unit: "%", at: "at most",
                value: targets.unreviewedShare.map { $0 * 100 }, fallback: fallback?.unreviewedShare.map { $0 * 100 }) { value in update { $0.unreviewedShare = value.map { min($0, 100) / 100 } } }
            row("PR size", "Median lines changed", unit: "lines", at: "at most",
                value: targets.prSizeLines.map(Double.init), fallback: fallback?.prSizeLines.map(Double.init)) { value in update { $0.prSizeLines = value.map { Int($0.rounded()) } } }
            row("Files changed", "Median files changed per PR", unit: "files", at: "at most",
                value: targets.prSizeFiles.map(Double.init), fallback: fallback?.prSizeFiles.map(Double.init)) { value in update { $0.prSizeFiles = value.map { Int($0.rounded()) } } }
        }
        Section("Reviewing") {
            row("Review requests answered", "Before the PR merged, or the request was withdrawn", unit: "%", at: "at least",
                value: targets.answeredShare.map { $0 * 100 }, fallback: fallback?.answeredShare.map { $0 * 100 }) { value in update { $0.answeredShare = value.map { min($0, 100) / 100 } } }
        }
    }

    /// A goal: its name and what it measures, then the target with its unit.
    private func row(_ title: String, _ detail: String, unit: String, at: String, value: Double?, fallback: Double?, set: @escaping (Double?) -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(at)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("", value: Binding(get: { value }, set: { set($0.flatMap { $0 > 0 ? $0 : nil }) }), format: .number.precision(.fractionLength(0...1)),
                          prompt: Text(fallback.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "None"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Button {
                    set(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .opacity(value == nil ? 0 : 1)
                .disabled(value == nil)
                .help("No goal")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func update(_ change: (inout MetricGoals.Targets) -> Void) {
        configs.update(org) { config in
            var goals = config.goals ?? MetricGoals()
            if team.isEmpty {
                change(&goals.org)
            } else {
                var targets = goals.teams[team] ?? .init()
                change(&targets)
                goals.teams[team] = targets.isEmpty ? nil : targets
            }
            config.goals = goals.isEmpty ? nil : goals
        }
    }
}
