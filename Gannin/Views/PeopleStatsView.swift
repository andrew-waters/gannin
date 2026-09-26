import SwiftUI

/// The People page: authoring and reviewing stats per person for the chosen
/// window. A row opens that person's PRs and reviews in the next column.
struct PeopleStatsView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
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
                            Spacer(minLength: 8)
                            ColumnGuideButton.people
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
