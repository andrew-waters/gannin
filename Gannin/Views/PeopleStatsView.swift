import SwiftUI

/// The People page: authoring and reviewing stats per person for the chosen
/// window (a row opens that person's PRs and reviews in the next column).
/// The work log, threads and punchcards are pages of their own.
struct PeopleStatsView: View {
    @Environment(MetricsStore.self) private var store
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let workload: Workload?
    let metrics: OrgMetrics?
    @Binding var selection: DetailSelection?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        if metrics?.isTeamScoped == true {
                            Text("Scoped to the selected team.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let metrics {
                            PeopleStatsTable(org: org, metrics: metrics, selection: $selection)
                                .updating(store.syncing.contains(org))
                        } else if store.syncing.contains(org) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Fetching merged PRs for the last \(windowDays) days. The first sync of a large org can take a minute.")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = store.errors[org] {
                            Banner(message: "Metrics sync failed: \(error)", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                                Task { await store.sync(org, windowDays: windowDays, force: true) }
                            }
                        } else {
                            Text("No metrics yet.").foregroundStyle(.secondary)
                        }
                    }
                    .sectionContent()
                } header: {
                    PinnedHeader {
                        HStack(spacing: 12) {
                            Text("People")
                            MetricsSyncIndicator(org: org)
                            Spacer(minLength: 8)
                            Picker("Window", selection: $windowDays) {
                                ForEach(MetricsStore.windowOptions, id: \.self) { Text("\($0) days").tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .font(.body)
                            .help("Window for the people stats")
                            ColumnGuideButton.people
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The Repositories page: merged PRs and cycle time per repo for the chosen
/// window. A row opens that repo's merged PRs in the next column.
struct RepositoryStatsView: View {
    @Environment(MetricsStore.self) private var store
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let metrics: OrgMetrics?
    @Binding var selection: DetailSelection?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    Group {
                        if let metrics {
                            RepoStatsTable(org: org, metrics: metrics, selection: $selection)
                                .updating(store.syncing.contains(org))
                        } else if store.syncing.contains(org) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Fetching merged PRs for the last \(windowDays) days.").foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No metrics yet.").foregroundStyle(.secondary)
                        }
                    }
                    .sectionContent()
                } header: {
                    PinnedHeader {
                        HStack(spacing: 12) {
                            Text("Repositories")
                            MetricsSyncIndicator(org: org)
                            Spacer(minLength: 8)
                            Picker("Window", selection: $windowDays) {
                                ForEach(MetricsStore.windowOptions, id: \.self) { Text("\($0) days").tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .font(.body)
                            .help("Window for the repo stats")
                            ColumnGuideButton.repos
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
