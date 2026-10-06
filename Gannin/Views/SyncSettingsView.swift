import SwiftUI

/// The Sync pane of the app's settings: everything that decides what Gannin
/// fetches from GitHub and how often, with what each source spent, so the
/// hourly budget lasts. App-wide: the budget is the token's, across orgs.
struct SyncSettingsView: View {
    @Environment(AuthStore.self) private var auth
    @AppStorage(SyncSettings.reserveKey) private var reserve = SyncSettings.defaultReserve
    @AppStorage(OrgStore.lookbackDaysKey) private var lookbackDays = OrgStore.defaultLookbackDays
    @AppStorage(ActionsStore.jobRunLimitKey) private var jobRunLimit = 0
    @State private var span: Span = .hour

    enum Span: String, CaseIterable, Identifiable {
        case hour = "Last hour"
        case day = "Last day"

        var id: Self { self }

        var seconds: TimeInterval { self == .hour ? 60 * 60 : 24 * 60 * 60 }
    }

    var body: some View {
        // Redrawn now and then so "the last hour" keeps moving.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let usage = APIUsage.shared.totals(since: context.date.addingTimeInterval(-span.seconds))
            let lastHour = span == .hour ? usage : APIUsage.shared.totals(since: context.date.addingTimeInterval(-3600))
            Form {
                budget(lastHour: lastHour.all)
                Section {
                    ForEach(SyncSource.settings) { source in
                        SyncSourceRow(source: source, spent: source.parent == nil ? usage.bySource[source] ?? .init() : nil)
                    }
                } header: {
                    HStack {
                        Text("What's fetched")
                        Spacer()
                        Picker("Spent", selection: $span) {
                            ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                } footer: {
                    Text("Pages fetch what they show when it's older than its interval; the background checks run on theirs. Off means not fetched at all, Refresh included: pages show what was fetched before.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("How much") {
                    Stepper(value: $lookbackDays, in: 1...90) {
                        LabeledContent("Merged work from the last", value: "\(lookbackDays) days")
                    }
                    Text("The workload's merged PRs. Applies on the next refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Actions jobs per workflow", selection: $jobRunLimit) {
                        ForEach(ActionsStore.jobRunLimitOptions, id: \.self) { limit in
                            Text(limit == 0 ? "Every run in the window" : "Latest \(limit) runs").tag(limit)
                        }
                    }
                    Text("When you open a workflow on the Actions page, each run's jobs are one REST request, so a busy workflow over 90 days can take thousands. Lower this to fetch fewer; jobs already fetched are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Not on a schedule") {
                    ForEach(SyncSource.ledger.filter { !$0.isSetting }) { source in
                        LabeledContent {
                            Text(SyncSourceRow.describe(usage.bySource[source] ?? .init(), rest: false))
                                .monospacedDigit()
                        } label: {
                            Text(source.title)
                            Text(source.detail)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func budget(lastHour: APIUsage.Total) -> some View {
        Section {
            if let until = auth.pausedUntil, until > .now {
                Label("GitHub refused a request for its rate limit. Nothing is asked until \(until.formatted(date: .omitted, time: .shortened)).", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            }
            LabeledContent("GraphQL") {
                if let rateLimit = auth.rateLimit {
                    Text("\(rateLimit.remaining.formatted()) of \(rateLimit.limit.formatted()) points left, resets at \(rateLimit.resetAt.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Not known until the next request")
                }
            }
            if let rest = auth.restRateLimit {
                LabeledContent("REST") {
                    Text("\(rest.remaining.formatted()) of \(rest.limit.formatted()) requests left, resets at \(rest.resetAt.formatted(date: .omitted, time: .shortened))")
                }
            }
            LabeledContent("Spent in the last hour") {
                Text(lastHour.restRequests > 0
                     ? "\(lastHour.points.formatted()) points, \(lastHour.restRequests.formatted()) REST requests"
                     : "\(lastHour.points.formatted()) points")
                    .monospacedDigit()
            }
            if let limit = auth.rateLimit?.limit, lastHour.points > limit / 2 {
                Label("That's more than half the hourly budget. Space out or turn off the sources spending most.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Picker("Keep in reserve", selection: $reserve) {
                ForEach(SyncSettings.reserveOptions, id: \.self) { Text("\($0.formatted()) points").tag($0) }
            }
            Text("Automatic fetches and background checks wait for the reset once fewer are left, so what you open or Refresh still has budget.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("GitHub's budget")
        }
    }
}

/// One source: its switch, what it is, how often, and what it spent.
private struct SyncSourceRow: View {
    let source: SyncSource
    /// Nil for a sub-row, whose spend is its parent's.
    let spent: APIUsage.Total?
    @AppStorage private var off: Bool
    @AppStorage private var parentOff: Bool
    @AppStorage private var interval: Double

    init(source: SyncSource, spent: APIUsage.Total?) {
        self.source = source
        self.spent = spent
        _off = AppStorage(wrappedValue: false, source.offKey)
        _parentOff = AppStorage(wrappedValue: false, source.parent?.offKey ?? "sync.none.off")
        _interval = AppStorage(wrappedValue: 0, source.intervalKey)
    }

    private var isOn: Bool { !parentOff && (!source.canTurnOff || !off) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if source.canTurnOff {
                    Toggle(source.title, isOn: Binding(get: { !off }, set: { off = !$0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(parentOff)
                } else {
                    Color.clear
                }
            }
            .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                Text(source.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker(source.title, selection: Binding(
                get: { interval > 0 ? interval : source.defaultInterval },
                set: { interval = $0 }
            )) {
                ForEach(options, id: \.self) { option in
                    Text("\(isPolled ? "Every" : "After") \(SyncSettings.describe(option))").tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn)
            Text(spent.map { Self.describe($0, rest: source.usesREST) } ?? "")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.leading, source.parent == nil ? 0 : 24)
        .opacity(isOn ? 1 : 0.6)
    }

    /// Background checks run every so often; the rest are fetched when a
    /// page wants them and they're older than this.
    private var isPolled: Bool {
        [.reviewRequests, .watchedReviews, .sessionPullRequests, .sessionChecks].contains(source)
    }

    /// The choices, with the one stored kept even if it isn't among them.
    private var options: [TimeInterval] {
        let current = interval > 0 ? interval : source.defaultInterval
        return Set(source.intervalOptions + [current]).sorted()
    }

    /// "120 points", "40 requests", or a dash for nothing.
    static func describe(_ total: APIUsage.Total, rest: Bool) -> String {
        if rest || (total.points == 0 && total.restRequests > 0) {
            return total.restRequests == 0 ? "None" : "\(total.restRequests.formatted()) req"
        }
        return total.points == 0 ? "None" : "\(total.points.formatted()) pts"
    }
}

/// Says at the top of a page when what it shows is turned off in
/// Settings › Sync, so cached data isn't taken for current.
private struct SyncOffNotice: ViewModifier {
    let source: SyncSource
    @AppStorage private var off: Bool
    @AppStorage private var parentOff: Bool

    init(source: SyncSource) {
        self.source = source
        _off = AppStorage(wrappedValue: false, source.offKey)
        _parentOff = AppStorage(wrappedValue: false, source.parent?.offKey ?? "sync.none.off")
    }

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if (source.canTurnOff && off) || parentOff {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle")
                    Text("\(source.title) \(source.title.hasSuffix("s") ? "are" : "is") turned off, so this shows what was fetched before.")
                    Spacer()
                    SettingsLink { Text("Sync Settings") }
                        .linkButton()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }
}

extension View {
    /// A bar at the top while `source` is off in Settings › Sync.
    func syncOffNotice(_ source: SyncSource) -> some View {
        modifier(SyncOffNotice(source: source))
    }
}
