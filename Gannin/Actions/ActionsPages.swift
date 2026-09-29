import Charts
import SwiftUI

// MARK: - Workflow

/// One workflow: its numbers against the period before, its typical run
/// time week by week, every run's duration, example runs at the median and
/// slow tail, the default branch's breakages, its jobs (fetched on opening,
/// every run in the window unless Settings limits it) and recent runs. Runs
/// and jobs open deeper.
struct WorkflowPage: View {
    @Environment(ActionsStore.self) private var store
    @AppStorage(ActionsStore.jobRunLimitKey) private var jobRunLimit = 0
    let org: String
    let workflow: WorkflowStats
    let windowStart: Date
    let hasPrevious: Bool
    let navigate: (DetailSelection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                tiles
                if workflow.duration.count > 1 {
                    PercentileTrendChart(title: "Typical run time", buckets: workflow.weeks, granularity: .week)
                    ActionsSection("Every run") {
                        DurationScatter(runs: workflow.runs, median: workflow.duration.median) { navigate(.workflowRun($0.id)) }
                        exemplars
                    }
                }
                if let health = workflow.defaultBranch {
                    ActionsSection("Default branch") { branch(health) }
                }
                ActionsSection("Jobs") { jobs }
                ActionsSection("Recent runs") {
                    RunList(runs: Array(workflow.runs.prefix(40)), navigate: navigate)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(workflow.id) \(windowStart) \(jobRunLimit)") {
            await store.loadJobs(org: org, workflowKey: workflow.id, since: windowStart)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workflow.name).font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Text(workflow.repo)
                Text("·")
                Text(workflow.path).lineLimit(1).truncationMode(.middle)
                Text("·")
                Text(workflow.events.map(EventStats.title).joined(separator: ", ")).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let url = workflow.url {
                Link("Open on GitHub", destination: url).font(.callout)
            }
        }
    }

    private var tiles: some View {
        let previous = hasPrevious ? workflow.previous : nil
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
            StatTile(title: "Run time", value: workflow.runTime.compactDuration, detail: "Wall clock, summed",
                     change: previous.flatMap { StatChange.percent(workflow.runTime, $0.runTime, higherIsWorse: true) })
            StatTile(title: "Runs", value: "\(workflow.runs.count)", detail: "\(workflow.counts.failed) failed",
                     change: previous.flatMap { StatChange.percent(Double(workflow.runs.count), Double($0.runs), higherIsWorse: nil) })
            StatTile(title: "Typical run (p90)", value: workflow.duration.p90?.compactDuration ?? "-", detail: workflow.duration.median.map { "Median \($0.compactDuration)" },
                     change: previous.flatMap { before in workflow.duration.p90.flatMap { now in before.duration.p90.flatMap { StatChange.percent(now, $0, higherIsWorse: true) } } })
            StatTile(title: "Failure rate", value: ActionsView.percent(workflow.counts.failureRate), detail: "\(workflow.counts.cancelled) cancelled",
                     change: previous.flatMap { StatChange.points(workflow.counts.failureRate, $0.counts.failureRate, higherIsWorse: true) })
            StatTile(title: "Re-run", value: "\(workflow.retried)", detail: "\(workflow.passedOnRetry) passed only on a re-run")
            StatTile(title: "Flaky commits", value: "\(workflow.mixedCommits)", detail: "Both failed and passed")
        }
    }

    // MARK: Exemplars

    /// A real run near the median, near p90 and the slowest, to open and see
    /// what a typical and a slow run look like.
    private var exemplars: some View {
        let timed = workflow.runs.filter { $0.duration != nil }
        let picks: [(String, WorkflowRun?)] = [
            ("Typical", nearest(timed, to: workflow.duration.median)),
            ("Slow (p90)", nearest(timed, to: workflow.duration.p90)),
            ("Slowest", timed.max { ($0.duration ?? 0) < ($1.duration ?? 0) }),
        ]
        return HStack(spacing: 18) {
            ForEach(picks, id: \.0) { title, run in
                if let run {
                    Button {
                        navigate(.workflowRun(run.id))
                    } label: {
                        HStack(spacing: 6) {
                            Text(title).foregroundStyle(.secondary)
                            Text("#\(run.runNumber)").foregroundStyle(.link)
                            Text(run.duration?.compactDuration ?? "-").monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open run #\(run.runNumber) on \(run.branch ?? "?")")
                    .opensElsewhere(.workflowRun(run.id))
                }
            }
        }
        .font(.callout)
    }

    private func nearest(_ runs: [WorkflowRun], to value: TimeInterval?) -> WorkflowRun? {
        guard let value else { return nil }
        return runs.min { abs(($0.duration ?? 0) - value) < abs(($1.duration ?? 0) - value) }
    }

    // MARK: Default branch

    private func branch(_ health: BranchHealth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if health.isRed, let since = health.redSince {
                Label("Failing since \(since.formatted(date: .abbreviated, time: .shortened)) (\(Date.now.timeIntervalSince(since).compactDuration))", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(ChartPalette.critical)
            } else {
                Label("Passing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ChartPalette.good)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Success rate").foregroundStyle(.secondary)
                    Text(ActionsView.percent(health.counts.successRate)).monospacedDigit()
                }
                GridRow {
                    Text("Breakages").foregroundStyle(.secondary)
                    Text("\(health.recoveries.count) fixed in the window").monospacedDigit()
                }
                GridRow {
                    Text("Back to green").foregroundStyle(.secondary)
                    Text(health.timeToGreen.map { "\($0.compactDuration) median, first failure to next success" } ?? "-").monospacedDigit()
                }
            }
            .font(.callout)
            OutcomeStrip(runs: Array(health.recent.prefix(60)), tick: 5)
        }
    }

    // MARK: Jobs

    /// The runs whose jobs count: completed ones that ran, all of the
    /// window or the latest up to the limit in Settings.
    private var jobRuns: [WorkflowRun] {
        let runs = workflow.runs.filter { $0.isCompleted && $0.outcome != .skipped }
        return jobRunLimit > 0 ? Array(runs.prefix(jobRunLimit)) : runs
    }

    @ViewBuilder
    private var jobs: some View {
        let runs = jobRuns
        let allJobs = store.history(for: org)?.jobs ?? [:]
        let stats = JobStats.stats(runs: runs, jobs: allJobs, from: windowStart)
        let fetched = runs.filter { allJobs[$0.id] != nil }.count
        VStack(alignment: .leading, spacing: 14) {
            if let progress = store.jobProgress[workflow.id] {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.of, 1)))
                        .frame(width: 160)
                    Text("Fetching jobs: \(progress.done) of \(progress.of) runs").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
            }
            if let notice = store.jobNotices[workflow.id] {
                Banner(message: notice, systemImage: "gauge.with.dots.needle.33percent", tint: .orange)
            }
            if stats.isEmpty {
                if store.jobProgress[workflow.id] == nil {
                    Text("No jobs fetched.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                let jobRunCount = stats.reduce(0) { $0 + $1.counts.ran }
                let jobCounts = stats.reduce(into: OutcomeCounts()) { total, stat in
                    total.succeeded += stat.counts.succeeded
                    total.failed += stat.counts.failed
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                    StatTile(title: "Job runs", value: "\(jobRunCount)", detail: "From \(fetched) of \(workflow.runs.count) runs")
                    StatTile(title: "Job failure rate", value: ActionsView.percent(jobCounts.failureRate), detail: "\(jobCounts.failed) failed")
                    StatTile(title: "Job time", value: stats.reduce(0) { $0 + $1.runTime }.compactDuration, detail: "Summed over jobs")
                }
                DistributionChart(
                    title: "Job run time distribution",
                    items: runs.flatMap { run in
                        (allJobs[run.id] ?? [])
                            .filter { $0.runAttempt == run.attempt }
                            .compactMap { job in job.duration.map { (group: job.baseName, duration: $0) } }
                    }
                )
                Text(jobRunLimit > 0
                     ? "Jobs of the latest \(jobRunLimit) runs, as set in Settings. Queue is the wait for a runner. Click a job for its runs and steps."
                     : "Jobs of every run in the window. Queue is the wait for a runner. Click a job for its runs and steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                JobsTable(jobs: stats, open: { navigate(.workflowJob(workflow: workflow.id, name: $0.name)) }, destination: { .workflowJob(workflow: workflow.id, name: $0.name) })
            }
        }
    }
}

private struct JobsTable: View {
    let jobs: [JobStats]
    let open: (JobStats) -> Void
    let destination: (JobStats) -> DetailSelection?
    @State private var sort: StatsSort?

    var body: some View {
        let durationScale = BarScale(jobs.compactMap(\.duration.median))
        StatsTable(
            rows: jobs,
            columns: [
                StatsColumn(
                    id: "job", title: "Job", help: "Jobs, with matrix variants together",
                    width: nil, minWidth: 200,
                    sortKey: { .text($0.name.lowercased()) },
                    cell: { job in
                        AnyView(HStack(spacing: 6) {
                            Text(job.name).lineLimit(1)
                            Text(job.labels.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                        })
                    }
                ),
                StatsColumn(
                    id: "time", title: "Run time", help: "Job time summed over runs",
                    width: 76,
                    sortKey: { .number($0.runTime) },
                    cell: { AnyView(NumberCell(text: $0.runTime.compactDuration, dimmed: false)) }
                ),
                StatsColumn(
                    id: "share", title: "Share", help: "Share of the workflow's job time",
                    width: 56,
                    sortKey: { .number($0.share) },
                    cell: { AnyView(NumberCell(text: $0.share < 0.005 ? "~0%" : ActionsView.percent($0.share), dimmed: false)) }
                ),
                StatsColumn(
                    id: "runs", title: "Runs", help: "Times the job ran",
                    width: 56,
                    sortKey: { .number(Double($0.counts.ran)) },
                    cell: { AnyView(NumberCell(text: "\($0.counts.ran)", dimmed: false)) }
                ),
                StatsColumn(
                    id: "distribution", title: "Distribution", help: "Jobs by how long they took: up to 60s, 5, 10, 20, 60 minutes, and longer",
                    width: 96,
                    sortKey: { .number($0.duration.median ?? -1) },
                    cell: { AnyView(HistogramCell(histogram: $0.histogram)) }
                ),
                StatsColumn(
                    id: "median", title: "Median", help: "Median job duration",
                    width: 170,
                    sortKey: { .number($0.duration.median ?? -1) },
                    cell: { AnyView(BarCell(value: $0.duration.median, scale: durationScale)) }
                ),
                StatsColumn(
                    id: "p90trend", title: "p90 trend", help: "90th percentile job duration, week by week",
                    width: 110,
                    sortKey: { .number($0.duration.p90 ?? -1) },
                    cell: { job in
                        AnyView(SparkLine(values: job.weeks.map(\.duration.p90), help: job.weeks.map { "\($0.start.formatted(.dateTime.day().month())): \($0.duration.p90?.compactDuration ?? "-")" }.joined(separator: "\n")))
                    }
                ),
                StatsColumn(
                    id: "p90", title: "p90", help: "90th percentile job duration",
                    width: 60,
                    sortKey: { .number($0.duration.p90 ?? -1) },
                    cell: { AnyView(NumberCell(text: $0.duration.p90?.compactDuration ?? "-", dimmed: $0.duration.p90 == nil)) }
                ),
                StatsColumn(
                    id: "queue", title: "Queue", help: "Median wait for a runner",
                    width: 64,
                    sortKey: { .number($0.queue.median ?? -1) },
                    cell: { job in
                        AnyView(NumberCell(text: job.queue.median?.compactDuration ?? "-", dimmed: job.queue.median == nil)
                            .help(job.queue.p90.map { "p90 wait \($0.compactDuration)" } ?? ""))
                    }
                ),
                StatsColumn(
                    id: "failed", title: "Failed", help: "Share of jobs that failed, of those that passed or failed",
                    width: 64,
                    sortKey: { .number($0.counts.failureRate ?? -1) },
                    cell: { AnyView(NumberCell(text: ActionsView.percent($0.counts.failureRate), dimmed: ($0.counts.failureRate ?? 0) == 0)) }
                ),
                StatsColumn(
                    id: "retry", title: "Re-run", help: "Failed, then passed when the run was re-run",
                    width: 64,
                    sortKey: { .number(Double($0.passedOnRetry)) },
                    cell: { AnyView(NumberCell(text: "\($0.passedOnRetry)", dimmed: $0.passedOnRetry == 0)) }
                ),
            ],
            sort: $sort,
            selectedID: nil,
            onSelect: open,
            destination: destination
        )
    }
}

// MARK: - Repository

/// One repo's workflows: its numbers against the period before, run time by
/// workflow, how long runs take by workflow, and the workflows table.
struct ActionsRepositoryPage: View {
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @AppStorage("actionsGranularity") private var granularity: IssueMetrics.Granularity = .week
    @State private var sort: StatsSort?
    let org: String
    let repo: RepoStats
    let metrics: ActionsMetrics
    let navigate: (DetailSelection) -> Void

    var body: some View {
        let previous = metrics.hasPrevious ? repo.previous : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(repo.shortName).font(.title2.weight(.semibold))
                    HStack(spacing: 10) {
                        Text(repo.repo).foregroundStyle(.secondary)
                        if let url = URL(string: "https://github.com/\(repo.repo)/actions") {
                            Link("Open on GitHub", destination: url)
                        }
                    }
                    .font(.callout)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                    StatTile(title: "Run time", value: repo.current.runTime.compactDuration, detail: "\(ActionsView.percent(repo.share)) of the org's",
                             change: previous.flatMap { StatChange.percent(repo.current.runTime, $0.runTime, higherIsWorse: true) })
                    StatTile(title: "Runs", value: "\(repo.current.runs)", detail: "\(repo.workflows.count) workflows",
                             change: previous.flatMap { StatChange.percent(Double(repo.current.runs), Double($0.runs), higherIsWorse: nil) })
                    StatTile(title: "Typical run (p90)", value: repo.current.duration.p90?.compactDuration ?? "-", detail: repo.current.duration.median.map { "Median \($0.compactDuration)" },
                             change: previous.flatMap { before in repo.current.duration.p90.flatMap { now in before.duration.p90.flatMap { StatChange.percent(now, $0, higherIsWorse: true) } } })
                    StatTile(title: "Failure rate", value: ActionsView.percent(repo.current.counts.failureRate), detail: "\(repo.current.counts.failed) failed",
                             change: previous.flatMap { StatChange.points(repo.current.counts.failureRate, $0.counts.failureRate, higherIsWorse: true) })
                    StatTile(title: "Red now", value: "\(repo.red)", detail: repo.red == 0 ? "Default branch green" : "Failing on the default branch")
                }
                HStack {
                    Spacer()
                    Picker("Per", selection: $granularity) {
                        ForEach([IssueMetrics.Granularity.day, .week]) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        runTimeChart.frame(minWidth: 420)
                        distributionChart.frame(minWidth: 420)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        runTimeChart
                        distributionChart
                    }
                }
                ActionsSection("Workflows") {
                    WorkflowsTable(org: org, workflows: repo.workflows, hasPrevious: metrics.hasPrevious, grouped: false, sort: $sort) { navigate(.workflow($0)) }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runTimeChart: some View {
        StackedRunTimeChart(title: "Run time by workflow", data: metrics.runTimeByWorkflow(granularity, repo: repo.repo), granularity: granularity)
    }

    private var distributionChart: some View {
        DistributionChart(
            title: "Run time distribution",
            items: repo.workflows.flatMap { workflow in workflow.runs.compactMap { run in run.duration.map { (group: workflow.name, duration: $0) } } }
        )
    }
}

// MARK: - Run

/// One run: what it was, and its jobs on a timeline from the first queued,
/// with the wait for a runner drawn faintly before each. Click a job for its
/// steps. Earlier attempts are listed after.
struct RunPage: View {
    @Environment(ActionsStore.self) private var store
    let org: String
    let run: WorkflowRun
    let navigate: (DetailSelection) -> Void
    @State private var selectedJob: Int?

    var body: some View {
        let all = store.history(for: org)?.jobs[run.id] ?? []
        let current = all.filter { $0.runAttempt == run.attempt }.sorted { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                ActionsSection("Jobs") {
                    if current.isEmpty {
                        if store.loadingJobs.contains(ActionsStore.jobsKey(run)) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Fetching jobs.").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        } else {
                            Text("No jobs.").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        JobTimeline(jobs: current, selected: $selectedJob)
                    }
                }
                if let job = current.first(where: { $0.id == selectedJob }) {
                    ActionsSection("Steps in \(job.name)") { StepList(job: job) }
                }
                let earlier = Dictionary(grouping: all.filter { $0.runAttempt < run.attempt }, by: \.runAttempt)
                if !earlier.isEmpty {
                    ActionsSection("Earlier attempts") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(earlier.keys.sorted(by: >), id: \.self) { attempt in
                                let jobs = earlier[attempt] ?? []
                                let failed = jobs.filter { $0.outcome == .failure }.map(\.name)
                                HStack(spacing: 8) {
                                    Text("Attempt \(attempt)").fontWeight(.medium)
                                    Text(failed.isEmpty ? "\(jobs.count) jobs, none failed" : "Failed: \(failed.joined(separator: ", "))")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(run.id)-\(run.attempt)-\(run.status)") { await store.loadJobs(org: org, run: run) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: RunList.icon(run.outcome))
                    .foregroundStyle(OutcomeStrip.color(run.outcome))
                Text("\(run.name) #\(run.runNumber)").font(.title2.weight(.semibold))
                Pill(text: run.outcome.rawValue, color: OutcomeStrip.color(run.outcome))
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Repository").foregroundStyle(.secondary)
                    Text(run.repo)
                }
                GridRow {
                    Text("Branch").foregroundStyle(.secondary)
                    Text("\(run.branch ?? "-") at \(String(run.headSha.prefix(7)))").textSelection(.enabled)
                }
                GridRow {
                    Text("Trigger").foregroundStyle(.secondary)
                    Text([EventStats.title(run.event), run.actor.map { "by \($0)" }].compactMap { $0 }.joined(separator: " "))
                }
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    Text((run.startedAt ?? run.createdAt).formatted(date: .abbreviated, time: .shortened))
                }
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    Text(run.duration?.compactDuration ?? "-").monospacedDigit()
                }
                if run.attempt > 1 {
                    GridRow {
                        Text("Attempt").foregroundStyle(.secondary)
                        Text("\(run.attempt)").monospacedDigit()
                    }
                }
            }
            .font(.callout)
            HStack(spacing: 14) {
                Link("Open on GitHub", destination: run.url)
                Button("Workflow") { navigate(.workflow(run.workflowKey)) }
                    .linkButton()
            }
            .font(.callout)
        }
    }
}

/// Jobs as bars against time since the first was queued: the wait for a
/// runner faint, the job itself in its outcome's colour.
private struct JobTimeline: View {
    let jobs: [WorkflowJob]
    @Binding var selected: Int?

    var body: some View {
        let origin = jobs.compactMap { $0.createdAt ?? $0.startedAt }.min() ?? .now
        let rowHeight: CGFloat = 26
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(jobs) { job in
                    let label = job.name
                    if let queued = job.createdAt, let started = job.startedAt, started > queued {
                        BarMark(
                            xStart: .value("From", queued.timeIntervalSince(origin) / 60),
                            xEnd: .value("To", started.timeIntervalSince(origin) / 60),
                            y: .value("Job", label)
                        )
                        .foregroundStyle(ChartPalette.neutral.opacity(0.5))
                        .cornerRadius(3)
                    }
                    if let started = job.startedAt {
                        let end = job.completedAt ?? .now
                        BarMark(
                            xStart: .value("From", started.timeIntervalSince(origin) / 60),
                            xEnd: .value("To", max(end.timeIntervalSince(origin), started.timeIntervalSince(origin) + 1) / 60),
                            y: .value("Job", label)
                        )
                        .foregroundStyle(OutcomeStrip.color(job.outcome))
                        .opacity(selected == nil || selected == job.id ? 1 : 0.45)
                        .cornerRadius(3)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text((minutes * 60).compactDuration) } }
                }
            }
            .chartYAxis { AxisMarks { _ in AxisValueLabel() } }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plotFrame = proxy.plotFrame,
                                  let name: String = proxy.value(atY: location.y - geometry[plotFrame].origin.y) else { return }
                            let id = jobs.first { $0.name == name }?.id
                            selected = selected == id ? nil : id
                        }
                }
            }
            .frame(height: CGFloat(jobs.count) * rowHeight + 30)
            Text("Faint bars are the wait for a runner. Click a job for its steps.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct StepList: View {
    let job: WorkflowJob

    var body: some View {
        let longest = job.steps.compactMap(\.duration).max() ?? 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("Took \(job.duration?.compactDuration ?? "-")")
                Text("Waited \(job.queueTime?.compactDuration ?? "-") for a runner")
                if !job.labels.isEmpty { Text(job.labels.joined(separator: ", ")) }
                if let url = job.url { Link("Logs on GitHub", destination: url) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(job.steps, id: \.number) { step in
                    GridRow {
                        Image(systemName: Self.icon(step.conclusion))
                            .foregroundStyle(Self.color(step.conclusion))
                        Text(step.name).lineLimit(1)
                        Text(step.duration?.compactDuration ?? "-")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Capsule()
                            .fill(Self.color(step.conclusion).opacity(0.8))
                            .frame(width: max(2, 200 * (step.duration ?? 0) / longest), height: 6)
                            .frame(width: 200, alignment: .leading)
                    }
                }
            }
            .font(.callout)
        }
    }

    static func icon(_ conclusion: String?) -> String {
        switch conclusion {
        case "success": "checkmark.circle.fill"
        case "failure", "timed_out": "xmark.circle.fill"
        case "skipped": "minus.circle"
        case "cancelled": "slash.circle"
        case nil: "clock"
        default: "circle"
        }
    }

    static func color(_ conclusion: String?) -> Color {
        switch conclusion {
        case "success": ChartPalette.good
        case "failure", "timed_out": ChartPalette.critical
        case nil: ChartPalette.blue
        default: ChartPalette.neutral
        }
    }
}

// MARK: - Job

/// One job across the workflow's recent runs: how long it takes and waits,
/// its slowest steps, and each time it ran.
struct JobPage: View {
    @Environment(ActionsStore.self) private var store
    let org: String
    let workflow: WorkflowStats
    let name: String
    let navigate: (DetailSelection) -> Void

    private struct Instance: Identifiable {
        let run: WorkflowRun
        let job: WorkflowJob
        var id: Int { job.id }
    }

    private struct StepSummary: Identifiable {
        let name: String
        let duration: PercentileStat
        let failed: Int
        var id: String { name }
    }

    var body: some View {
        let jobs = store.history(for: org)?.jobs ?? [:]
        let instances = workflow.runs.flatMap { run in
            (jobs[run.id] ?? [])
                .filter { $0.runAttempt == run.attempt && $0.baseName == name }
                .map { Instance(run: run, job: $0) }
        }
        let stats = JobStats.stats(runs: workflow.runs, jobs: jobs).first { $0.name == name }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Button(workflow.name) { navigate(.workflow(workflow.id)) }.linkButton()
                        Text("· \(workflow.repo)").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if let stats {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                        StatTile(title: "Runs", value: "\(stats.counts.ran)", detail: "\(stats.counts.failed) failed")
                        StatTile(title: "Duration", value: stats.duration.median?.compactDuration ?? "-", detail: stats.duration.p90.map { "Median · p90 \($0.compactDuration)" })
                        StatTile(title: "Queue", value: stats.queue.median?.compactDuration ?? "-", detail: stats.queue.p90.map { "Median · p90 \($0.compactDuration)" })
                        StatTile(title: "Re-run", value: "\(stats.passedOnRetry)", detail: "Failed, then passed")
                    }
                }
                ActionsSection("Slowest steps") { steps(instances) }
                ActionsSection("Runs") { instanceList(instances) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func steps(_ instances: [Instance]) -> some View {
        let byName = Dictionary(grouping: instances.flatMap(\.job.steps), by: \.name)
        let summaries = byName.map { name, steps in
            StepSummary(name: name, duration: PercentileStat(steps.compactMap(\.duration)), failed: steps.filter { $0.conclusion == "failure" }.count)
        }
        .sorted { ($0.duration.median ?? 0) > ($1.duration.median ?? 0) }
        .prefix(12)
        let longest = summaries.compactMap(\.duration.median).max() ?? 1
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("Step")
                Text("Median")
                Text("p90")
                Text("")
                Text("Failed")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(summaries) { step in
                GridRow {
                    Text(step.name).lineLimit(1)
                    Text(step.duration.median?.compactDuration ?? "-").monospacedDigit()
                    Text(step.duration.p90?.compactDuration ?? "-").monospacedDigit().foregroundStyle(.secondary)
                    Capsule()
                        .fill(ChartPalette.blue)
                        .frame(width: max(2, 200 * (step.duration.median ?? 0) / longest), height: 6)
                        .frame(width: 200, alignment: .leading)
                    Text("\(step.failed)").monospacedDigit().foregroundStyle(step.failed == 0 ? .tertiary : .primary)
                }
            }
        }
        .font(.callout)
    }

    private func instanceList(_ instances: [Instance]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(instances) { instance in
                Button {
                    navigate(.workflowRun(instance.run.id))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: RunList.icon(instance.job.outcome))
                            .foregroundStyle(OutcomeStrip.color(instance.job.outcome))
                            .frame(width: 16)
                        Text("#\(instance.run.runNumber)").monospacedDigit()
                        if instance.job.name != name {
                            Text(instance.job.name).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(instance.run.branch ?? "").foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("waited \(instance.job.queueTime?.compactDuration ?? "-")").foregroundStyle(.secondary)
                        Text(instance.job.duration?.compactDuration ?? "-").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                        RelativeDate(date: instance.run.createdAt).foregroundStyle(.secondary).frame(minWidth: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opensElsewhere(.workflowRun(instance.run.id))
            }
        }
        .font(.callout)
        .monospacedDigit()
    }
}

// MARK: - Shared

/// A titled block on an Actions page.
struct ActionsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content
        }
    }
}

/// Runs, newest first; each opens its run page.
struct RunList: View {
    let runs: [WorkflowRun]
    let navigate: (DetailSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(runs) { run in
                Button {
                    navigate(.workflowRun(run.id))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(run.outcome))
                            .foregroundStyle(OutcomeStrip.color(run.outcome))
                            .help(run.conclusion ?? run.status)
                            .frame(width: 16)
                        Text("#\(run.runNumber)").monospacedDigit()
                        Text(run.branch ?? "").lineLimit(1)
                        if run.attempt > 1 {
                            Text("attempt \(run.attempt)").foregroundStyle(.secondary)
                        }
                        Text(EventStats.title(run.event) + (run.actor.map { " · \($0)" } ?? ""))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(run.duration?.compactDuration ?? "").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                        RelativeDate(date: run.createdAt).foregroundStyle(.secondary).frame(minWidth: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opensElsewhere(.workflowRun(run.id))
            }
        }
        .font(.callout)
    }

    static func icon(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .cancelled: "slash.circle"
        case .skipped: "minus.circle"
        case .running: "clock"
        }
    }
}

/// Every timed run as a dot, when it started against how long it took, with
/// the median as a line. Failures are crosses, so they read without colour.
struct DurationScatter: View {
    let runs: [WorkflowRun]
    let median: TimeInterval?
    let onOpen: (WorkflowRun) -> Void
    @State private var hovered: WorkflowRun?

    var body: some View {
        let timed = runs.filter { $0.duration != nil && ($0.outcome == .success || $0.outcome == .failure) }
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(timed) { run in
                    PointMark(
                        x: .value("Started", run.createdAt),
                        y: .value("Minutes", (run.duration ?? 0) / 60)
                    )
                    .foregroundStyle(by: .value("Outcome", run.outcome.rawValue))
                    .symbol(by: .value("Outcome", run.outcome.rawValue))
                    .symbolSize(hovered?.id == run.id ? 80 : 30)
                }
                if let median {
                    RuleMark(y: .value("Median", median / 60))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartForegroundStyleScale(domain: [RunOutcome.success.rawValue, RunOutcome.failure.rawValue], range: [ChartPalette.good, ChartPalette.critical])
            .chartSymbolScale(domain: [RunOutcome.success.rawValue, RunOutcome.failure.rawValue], range: [.circle, .cross])
            .chartLegend(position: .bottom, alignment: .leading)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let minutes = value.as(Double.self) { Text((minutes * 60).compactDuration) } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = nearest(location, proxy: proxy, geometry: geometry, runs: timed)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in
                            if let run = nearest(location, proxy: proxy, geometry: geometry, runs: timed) { onOpen(run) }
                        }
                }
            }
            .frame(height: 180)
            if let hovered {
                Text("#\(hovered.runNumber) on \(hovered.branch ?? "?"), \(hovered.createdAt.formatted(date: .abbreviated, time: .shortened)): \(hovered.duration?.compactDuration ?? "-"), \(hovered.outcome.rawValue.lowercased())")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Hover a run for details, click to open it. Dashed line is the median.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The run whose dot is closest to the pointer, within 20 points.
    private func nearest(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, runs: [WorkflowRun]) -> WorkflowRun? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let point = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        var best: (WorkflowRun, CGFloat)?
        for run in runs {
            guard let x = proxy.position(forX: run.createdAt), let y = proxy.position(forY: (run.duration ?? 0) / 60) else { continue }
            let distance = hypot(x - point.x, y - point.y)
            if distance < (best?.1 ?? 20) { best = (run, distance) }
        }
        return best?.0
    }
}
