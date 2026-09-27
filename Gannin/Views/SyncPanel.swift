import SwiftUI

/// Bottom of the sidebar: sync status and the refresh button, with the
/// step-by-step detail sliding up above it while a sync runs.
struct SyncFooter: View {
    @Environment(SyncActivity.self) private var activity
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(WorkLogStore.self) private var workLog
    @Environment(IssueStore.self) private var issueStore
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String

    @State private var isExpanded = false
    /// The panel's natural height, so opening can animate to it.
    @State private var panelHeight: CGFloat = 0
    /// Opened by a sync starting rather than by hand, so it closes itself.
    @State private var openedForSync = false

    private static let closeDelay: Duration = .seconds(3)

    var body: some View {
        let runs = activity.runs(for: org)
        let syncing = runs.contains(where: \.isRunning)
        VStack(spacing: 0) {
            // Grows from zero height with its top edge (and divider) rising
            // and the content riding up with it, clipped so it never draws
            // over the rows below.
            VStack(spacing: 0) {
                Divider()
                SyncPanel(runs: runs)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            .frame(height: isExpanded ? panelHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)

            // Progress runs along the divider, so the status row keeps one
            // line whether or not a sync is running.
            Divider()
                .overlay(alignment: .leading) {
                    if syncing {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geometry.size.width * Self.fraction(of: runs), height: 2)
                                .animation(.easeOut(duration: 0.3), value: Self.fraction(of: runs))
                        }
                        .frame(height: 2)
                    }
                }
            statusRow(runs: runs, syncing: syncing)
        }
        .animation(.easeOut(duration: 0.25), value: isExpanded)
        .animation(.easeOut(duration: 0.2), value: panelHeight)
        .onChange(of: syncing) {
            if syncing {
                if !isExpanded {
                    isExpanded = true
                    openedForSync = true
                }
            } else if openedForSync {
                Task {
                    try? await Task.sleep(for: Self.closeDelay)
                    guard !activity.isSyncing(org), openedForSync else { return }
                    isExpanded = false
                    openedForSync = false
                }
            }
        }
        .onChange(of: org) {
            isExpanded = false
            openedForSync = false
        }
    }

    /// Redrawn every 30 seconds so the ages in it keep up.
    private func statusRow(runs: [SyncRun], syncing: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            statusRowContent(runs: runs, syncing: syncing)
        }
    }

    private func statusRowContent(runs: [SyncRun], syncing: Bool) -> some View {
        HStack(spacing: 8) {
            status(runs: runs, syncing: syncing)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let rateLimit = auth.rateLimit {
                RateLimitBadge(rateLimit: rateLimit)
            }
            Button {
                isExpanded.toggle()
                openedForSync = false
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Hide sync details" : "Show sync details")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "Syncing 3 of 6" while a sync runs; otherwise a Refresh link (Retry
    /// after a failure) with the last update in its tooltip.
    @ViewBuilder
    private func status(runs: [SyncRun], syncing: Bool) -> some View {
        if syncing {
            let steps = Self.currentRuns(runs).flatMap(\.steps)
            let done = steps.filter { $0.state != .pending && $0.state != .running }.count
            Text("Syncing \(done) of \(steps.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            let failure = runs.compactMap(\.failure).first
            Button(failure == nil ? "Refresh" : "Retry") {
                refresh(NSEvent.modifierFlags.contains(.option) ? .full : .manual)
            }
            .buttonStyle(.link)
            .tint(failure == nil ? nil : .red)
            .foregroundStyle(failure == nil ? AnyShapeStyle(.link) : AnyShapeStyle(.red))
            .keyboardShortcut("r")
            .contextMenu {
                Button("Full Refresh") { refresh(.full) }
            }
            .help(refreshHelp(failure: failure))
        }
    }

    private func refreshHelp(failure: String?) -> String {
        var lines: [String] = []
        if let failure { lines.append("Last sync failed: \(failure)") }
        if let fetchedAt = orgs.snapshot(for: org)?.fetchedAt {
            lines.append("Updated \(Self.age(of: fetchedAt)).")
        } else {
            lines.append("Not synced yet.")
        }
        lines.append("Fetch what's changed on GitHub (⌘R). Option-click for a full refresh.")
        return lines.joined(separator: "\n")
    }

    /// The runs making up the sync in progress: those still running, and
    /// any that finished since the earliest of them started (workload
    /// usually finishes well before metrics).
    private static func currentRuns(_ runs: [SyncRun]) -> [SyncRun] {
        guard let start = runs.filter(\.isRunning).map(\.startedAt).min() else { return [] }
        return runs.filter { $0.isRunning || ($0.finishedAt ?? .distantPast) >= start }
    }

    /// 0-1 through every item of the sync in progress.
    private static func fraction(of runs: [SyncRun]) -> Double {
        let steps = currentRuns(runs).flatMap(\.steps)
        let total = steps.map(\.weight).reduce(0, +)
        guard total > 0 else { return 0 }
        return steps.map { $0.fraction * $0.weight }.reduce(0, +) / total
    }

    /// "just now", "4m ago", "2h ago".
    private static func age(of date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Workload and metrics in parallel, so both sections are in the panel
    /// from the start and it doesn't grow part way through.
    private func refresh(_ mode: OrgStore.RefreshMode) {
        Task {
            async let workload: Void = orgs.refresh(org, mode: mode)
            async let metrics: Void = metricsStore.sync(org, windowDays: windowDays, force: true)
            // The work log only once it's been opened for this org.
            async let log: Void = workLog.isTracking(org) ? workLog.sync(org, force: true) : ()
            async let issues: Void = issueStore.isTracking(org) ? issueStore.sync(org, windowDays: windowDays, force: true) : ()
            _ = await (workload, metrics, log, issues)
        }
    }
}

/// Each resource the latest syncs fetched, checked off
/// as they complete.
private struct SyncPanel: View {
    let runs: [SyncRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(runs) { run in
                SyncRunSection(run: run)
            }
            if runs.isEmpty {
                Text("Nothing synced yet this session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// GitHub's hourly GraphQL budget: share left and minutes to the reset,
/// with the detail in the tooltip.
private struct RateLimitBadge: View {
    let rateLimit: RateLimit

    var body: some View {
        Text("\(percent) · \(Self.untilReset(rateLimit.resetAt))")
        .help(tooltip)
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(rateLimit.isLow ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    private var percent: String {
        (Double(rateLimit.remaining) / Double(max(rateLimit.limit, 1))).formatted(.percent.precision(.fractionLength(0)))
    }

    private var tooltip: String {
        var text = "\(percent) of the GitHub API budget left (\(rateLimit.remaining.formatted()) of \(rateLimit.limit.formatted()) points). "
            + "Resets in \(Self.untilReset(rateLimit.resetAt)), at \(rateLimit.resetAt.formatted(date: .omitted, time: .shortened))."
        if rateLimit.isLow { text += " Automatic refreshes wait until then." }
        return text
    }

    /// "23m", or "<1m" in the last minute.
    private static func untilReset(_ date: Date) -> String {
        let minutes = Int((date.timeIntervalSinceNow / 60).rounded(.up))
        return minutes < 1 ? "<1m" : "\(minutes)m"
    }
}

private struct SyncRunSection: View {
    let run: SyncRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if run.steps.isEmpty {
                Text("Nothing to fetch")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(run.steps) { step in
                SyncStepRow(step: step)
            }
            if let failure = run.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
                    .help(failure)
            }
        }
    }
}

private struct SyncStepRow: View {
    let step: SyncStep

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 14)
            Text(step.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(step.state == .pending || step.state == .skipped ? .secondary : .primary)
            Spacer(minLength: 4)
            if let count = step.count {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        // Progress fills in behind the row, so rows never change height.
        .background(alignment: .leading) {
            if step.state == .running {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: geometry.size.width * step.fraction)
                        .animation(.easeOut(duration: 0.3), value: step.fraction)
                }
            }
        }
        .padding(.horizontal, -4)
        .help(tooltip)
    }

    private var tooltip: String {
        var lines = [step.title]
        if let detail = step.detail { lines.append(detail) }
        switch step.state {
        case .pending: lines.append("Waiting")
        case .running:
            if let parts = step.parts { lines.append("Week \(parts.done + 1) of \(parts.of)") }
            if let count = step.count { lines.append(step.total.map { "\(count) of \($0) so far" } ?? "\(count) so far") }
        case .done:
            var parts: [String] = []
            if let count = step.count { parts.append("\(count) fetched") }
            if let duration = step.duration { parts.append("in \(SyncDuration.format(duration))") }
            parts.append(SyncCost.format(step.cost))
            lines.append(parts.joined(separator: ", "))
        case .failed(let message): lines.append(message)
        case .skipped: lines.append("Skipped")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
        }
    }
}

private enum SyncCost {
    static func format(_ points: Int) -> String {
        points == 1 ? "1 pt" : "\(points) pts"
    }
}

private enum SyncDuration {
    static func format(_ interval: TimeInterval) -> String {
        if interval < 60 { return interval.formatted(.number.precision(.fractionLength(1))) + "s" }
        let seconds = Int(interval.rounded())
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
