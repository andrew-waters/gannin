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

    /// The settings' sections, each a few sources: rows beneath another
    /// are its parts, not indented under it.
    private struct SourceGroup: Identifiable {
        let title: String
        let sources: [SyncSource]
        let footer: String?

        var id: String { title }

        init(_ title: String, _ sources: [SyncSource], _ footer: String?) {
            self.title = title
            self.sources = sources
            self.footer = footer
        }
    }

    private static let groups: [SourceGroup] = [
        SourceGroup("Workload", [.workload, .members, .fullSearch], "Open PRs and issues: what changed since the last fetch, its members, and now and then everything again. Always on."),
        SourceGroup("Issues", [.issues, .openIssues, .issueText], nil),
        SourceGroup("Pages", [.metrics, .workLog, .boards, .releases, .actions, .harness], "Fetched when a page that shows them opens and they're older than this. Off means not fetched at all, Refresh included: pages show what was fetched before."),
        SourceGroup("In the background", [.reviewRequests, .watchedReviews, .sessionPullRequests, .sessionChecks], "Checked on these intervals while Gannin runs, and held off when the budget is low."),
    ]

    var body: some View {
        // Redrawn now and then so "the last hour" keeps moving.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            form(at: context.date)
        }
    }

    private func form(at now: Date) -> some View {
        let usage = APIUsage.shared.totals(since: now.addingTimeInterval(-span.seconds))
        let lastHour = span == .hour ? usage : APIUsage.shared.totals(since: now.addingTimeInterval(-3600))
        return Form {
                budget(lastHour: lastHour.all)
                spent(usage.bySource)
                ForEach(Self.groups) { group in
                    Section {
                        ForEach(group.sources) { SyncSourceRow(source: $0) }
                    } header: {
                        Text(group.title)
                    } footer: {
                        if let footer = group.footer {
                            Text(footer)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Stepper(value: $lookbackDays, in: 1...90) {
                        LabeledContent("Merged work from the last", value: "\(lookbackDays) days")
                    }
                    Picker("Actions jobs per workflow", selection: $jobRunLimit) {
                        ForEach(ActionsStore.jobRunLimitOptions, id: \.self) { limit in
                            Text(limit == 0 ? "Every run in the window" : "Latest \(limit) runs").tag(limit)
                        }
                    }
                } header: {
                    Text("How much")
                } footer: {
                    Text("The lookback applies on the next refresh. Each Actions run's jobs are a REST request when you open a workflow; jobs already fetched are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
    }

    /// What each source spent, most first; those that spent nothing left out.
    private func spent(_ bySource: [SyncSource: APIUsage.Total]) -> some View {
        let rows = SyncSource.ledger
            .compactMap { source in bySource[source].map { (source, $0) } }
            .filter { $0.1.points > 0 || $0.1.restRequests > 0 }
            .sorted { ($0.1.points + $0.1.restRequests) > ($1.1.points + $1.1.restRequests) }
        return Section {
            if rows.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(rows.map(\.0)) { source in
                LabeledContent(source.title) {
                    Text(Self.describe(bySource[source] ?? .init(), rest: source.usesREST))
                        .monospacedDigit()
                }
            }
        } header: {
            HStack {
                Text("Spent")
                Spacer()
                Picker("Spent", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// "120 points" or "40 REST requests".
    static func describe(_ total: APIUsage.Total, rest: Bool) -> String {
        if rest || (total.points == 0 && total.restRequests > 0) {
            return "\(total.restRequests.formatted()) REST request\(total.restRequests == 1 ? "" : "s")"
        }
        return "\(total.points.formatted()) point\(total.points == 1 ? "" : "s")"
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

/// One source: what it is, and a menu of how often, with Off first for
/// those that can be turned off.
private struct SyncSourceRow: View {
    let source: SyncSource
    @AppStorage private var off: Bool
    @AppStorage private var parentOff: Bool
    @AppStorage private var interval: Double

    /// The menu's tag for Off.
    private static let offTag: TimeInterval = -1

    init(source: SyncSource) {
        self.source = source
        _off = AppStorage(wrappedValue: false, source.offKey)
        _parentOff = AppStorage(wrappedValue: false, source.parent?.offKey ?? "sync.none.off")
        _interval = AppStorage(wrappedValue: 0, source.intervalKey)
    }

    var body: some View {
        Picker(selection: Binding(
            get: { source.canTurnOff && off ? Self.offTag : current },
            set: { picked in
                if picked == Self.offTag {
                    off = true
                } else {
                    off = false
                    interval = picked
                }
            }
        )) {
            if source.canTurnOff {
                Text("Off").tag(Self.offTag)
                Divider()
            }
            ForEach(options, id: \.self) { option in
                Text("\(isPolled ? "Every" : "After") \(SyncSettings.describe(option))").tag(option)
            }
        } label: {
            Text(source.title)
            Text(parentOff ? "Off with \(source.parent?.title ?? "")." : source.detail)
        }
        .disabled(parentOff)
    }

    private var current: TimeInterval { interval > 0 ? interval : source.defaultInterval }

    /// Background checks run every so often; the rest are fetched when a
    /// page wants them and they're older than this.
    private var isPolled: Bool {
        [.reviewRequests, .watchedReviews, .sessionPullRequests, .sessionChecks].contains(source)
    }

    /// The choices, with the one stored kept even if it isn't among them.
    private var options: [TimeInterval] {
        Set(source.intervalOptions + [current]).sorted()
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
