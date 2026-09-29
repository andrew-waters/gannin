import SwiftUI

/// A dashboard section's title with a link to the section's own page.
struct SummaryHeader: View {
    @Environment(\.showSidebarItem) private var showSidebarItem
    let title: String
    let link: String
    let item: SidebarItem

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            if let showSidebarItem {
                Button("Open \(link)") { showSidebarItem(item) }
                    .linkButton()
                    .font(.body)
            }
        }
    }
}

/// Issues completed in the window by investment category: the split as a
/// bar, then each category, opening its issues.
struct InvestmentsSummary: View {
    @Environment(IssueStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let windowDays: Int
    @Binding var selection: DetailSelection?

    /// The window to the minute, so the drills it opens stay equal across
    /// redraws.
    private var range: DateInterval {
        let now = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        return DateInterval(start: Calendar.current.date(byAdding: .day, value: -windowDays, to: now) ?? now, end: now)
    }

    var body: some View {
        let range = range
        Group {
            if let history = store.history(for: org), history.coveredFrom <= range.start || !store.syncing.contains(org) {
                let balance = InvestmentBalance(history: history, config: configs.config(for: org), team: nil, range: range, granularity: .week)
                content(balance, range: range)
                    .updating(store.syncing.contains(org))
            } else if let error = store.errors[org] {
                Banner(message: "Couldn't load issues: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                    Task { await store.sync(org, windowDays: windowDays, force: true) }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching issues for the last \(windowDays) days.").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(org) \(windowDays)") { await store.sync(org, windowDays: windowDays) }
    }

    private func content(_ balance: InvestmentBalance, range: DateInterval) -> some View {
        let shares = balance.completed()
        let total = shares.map(\.issues.count).reduce(0, +)
        let uncategorised = shares.last?.issues.count ?? 0
        let inProgress = balance.inProgress.map(\.issues.count).reduce(0, +)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text(total == 1 ? "1 issue completed" : "\(total) issues completed").font(.callout.weight(.medium))
                if total > 0 {
                    Text("· \(ActionsView.percent(Double(total - uncategorised) / Double(total))) categorised")
                }
                Text("· \(inProgress) in progress now")
            }
            .font(.callout)
            if total > 0 {
                ShareBar(shares: shares)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 4) {
                    ForEach(shares.filter { !$0.issues.isEmpty }) { share in
                        row(share, total: total, range: range)
                    }
                }
            } else {
                Text("Nothing completed in the window.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ share: InvestmentBalance.Share, total: Int, range: DateInterval) -> some View {
        let drill = MetricDrill.investment(InvestmentBalance.Drill(
            key: share.key,
            scope: .completed,
            range: range,
            period: .week,
            bucket: nil,
            title: "\(share.name) · completed"
        ))
        return Button {
            selection = .metric(drill)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(ChartPalette.slot(share.slot))
                    .frame(width: 12, height: 12)
                Text(share.name).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(share.issues.count)").monospacedDigit().foregroundStyle(.secondary)
                Text(ActionsView.percent(Double(share.issues.count) / Double(max(total, 1))))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opensElsewhere(.metric(drill))
    }
}

/// The Actions headline numbers against the period before, and what needs
/// attention, each opening its workflow.
struct ActionsSummary: View {
    @Environment(ActionsStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let windowDays: Int
    @Binding var selection: DetailSelection?

    var body: some View {
        Group {
            if let history = store.history(for: org) {
                let metrics = ActionsMetrics(history: history, windowDays: windowDays, config: configs.config(for: org))
                content(metrics)
                    .updating(store.syncing.contains(org))
            } else if let error = store.errors[org] {
                Banner(message: "Couldn't load workflow runs: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                    Task { await sync(force: true) }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching workflow runs, repo by repo. The first sync of a large org takes a few minutes.").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(org) \(windowDays)") { await sync(force: false) }
    }

    private func sync(force: Bool) async {
        await store.sync(org, windowDays: windowDays, excluding: configs.config(for: org).excludedRepos, force: force)
    }

    @ViewBuilder
    private func content(_ metrics: ActionsMetrics) -> some View {
        if metrics.workflows.isEmpty {
            Text("No workflow runs in the last \(windowDays) days.").foregroundStyle(.secondary)
        } else {
            let previous = metrics.hasPrevious ? metrics.previous : nil
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], alignment: .leading, spacing: 12) {
                    StatTile(title: "Run time", value: metrics.runTime.compactDuration, detail: "\(metrics.runCount) runs in \(metrics.repoCount) repos",
                             change: previous.flatMap { StatChange.percent(metrics.runTime, $0.runTime, higherIsWorse: true) })
                    StatTile(title: "Failure rate", value: ActionsView.percent(metrics.counts.failureRate), detail: "All runs, PRs included",
                             change: previous.flatMap { StatChange.points(metrics.counts.failureRate, $0.counts.failureRate, higherIsWorse: true) })
                    StatTile(title: "Typical run (p90)", value: metrics.duration.p90?.compactDuration ?? "-", detail: metrics.duration.median.map { "Median \($0.compactDuration)" },
                             change: previous.flatMap { before in metrics.duration.p90.flatMap { now in before.duration.p90.flatMap { StatChange.percent(now, $0, higherIsWorse: true) } } })
                    StatTile(title: "Red now", value: "\(metrics.red.count)", detail: metrics.red.isEmpty ? "Every default branch green" : "Failing on a default branch")
                }
                if !metrics.attention.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(metrics.attention.count > 4 ? "Needs attention · top 4 of \(metrics.attention.count)" : "Needs attention")
                            .font(.headline)
                        AttentionList(items: Array(metrics.attention.prefix(4))) { selection = .workflow($0) }
                    }
                }
            }
        }
    }
}
