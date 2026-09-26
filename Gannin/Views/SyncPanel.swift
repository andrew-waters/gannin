import SwiftUI

/// Bottom of the sidebar: sync status and the refresh button, with the
/// step-by-step detail sliding up above it while a sync runs.
struct SyncFooter: View {
    @Environment(SyncActivity.self) private var activity
    @Environment(OrgStore.self) private var orgs
    @Environment(MetricsStore.self) private var metricsStore
    @AppStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
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

    private func statusRow(runs: [SyncRun], syncing: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
                openedForSync = false
            } label: {
                status(runs: runs, syncing: syncing)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide sync details" : "Show sync details")

            refreshButton(syncing: syncing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func status(runs: [SyncRun], syncing: Bool) -> some View {
        if syncing {
            let steps = runs.filter(\.isRunning).flatMap(\.steps)
            let done = steps.filter { $0.state == .done }.count
            Text("Syncing \(done) of \(steps.count)")
                .monospacedDigit()
                .font(.callout)
        } else if let failed = runs.first(where: { $0.failure != nil }) {
            Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .help(failed.failure ?? "")
        } else if let fetchedAt = orgs.snapshot(for: org)?.fetchedAt {
            // Re-rendered each minute so the age keeps up.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text("Updated \(Self.age(of: fetchedAt))")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Text("Not synced yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 0-1 through the running syncs' steps.
    private static func fraction(of runs: [SyncRun]) -> Double {
        let steps = runs.filter(\.isRunning).flatMap(\.steps)
        guard !steps.isEmpty else { return 0 }
        return steps.map(\.fraction).reduce(0, +) / Double(steps.count)
    }

    /// "just now", "4m ago", "2h ago".
    private static func age(of date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Fetches changes; Option-click (or the context menu) searches
    /// everything again.
    private func refreshButton(syncing: Bool) -> some View {
        Button {
            refresh(NSEvent.modifierFlags.contains(.option) ? .full : .manual)
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("r")
        .disabled(syncing)
        .contextMenu {
            Button("Full Refresh") { refresh(.full) }
        }
        .help("Fetch what's changed on GitHub (⌘R). Option-click for a full refresh.")
    }

    /// Workload and metrics in parallel, so both sections are in the panel
    /// from the start and it doesn't grow part way through.
    private func refresh(_ mode: OrgStore.RefreshMode) {
        Task {
            async let workload: Void = orgs.refresh(org, mode: mode)
            async let metrics: Void = metricsStore.sync(org, windowDays: windowDays, force: true)
            _ = await (workload, metrics)
        }
    }
}

/// The API budget and each resource the latest syncs fetched, checked off
/// as they complete.
private struct SyncPanel: View {
    @Environment(AuthStore.self) private var auth
    let runs: [SyncRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let rateLimit = auth.rateLimit {
                RateLimitSection(rateLimit: rateLimit)
            }
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

/// A sidebar-style section heading.
private struct PanelHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// GitHub's hourly GraphQL budget.
private struct RateLimitSection: View {
    let rateLimit: RateLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading(title: "GitHub API") {
                Text("\(rateLimit.remaining.formatted()) left")
                    .monospacedDigit()
            }
            ProgressView(value: Double(rateLimit.remaining), total: Double(max(rateLimit.limit, 1)))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(rateLimit.isLow ? .orange : .accentColor)
            if rateLimit.isLow {
                Label("Auto refresh paused", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .help("\(rateLimit.remaining.formatted()) of \(rateLimit.limit.formatted()) points left this hour. Resets at \(rateLimit.resetAt.formatted(date: .omitted, time: .shortened)).\(rateLimit.isLow ? " Automatic refreshes wait until then." : "")")
    }
}

private struct SyncRunSection: View {
    let run: SyncRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelHeading(title: run.kind.rawValue) {
                if run.isRunning {
                    Text(run.startedAt, style: .timer)
                        .monospacedDigit()
                } else if let finishedAt = run.finishedAt {
                    Text(SyncDuration.format(finishedAt.timeIntervalSince(run.startedAt)))
                        .monospacedDigit()
                        .help("Finished \(finishedAt.formatted(date: .omitted, time: .shortened)), \(SyncCost.format(run.cost))")
                }
            }
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
