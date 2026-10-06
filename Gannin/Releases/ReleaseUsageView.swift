import Charts
import SwiftUI

/// The Releases part of the Releases page: downloads and stars across the
/// repos with releases, over time, then those repos and every release as
/// tables.
struct ReleasesOverview: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let usage: ReleaseUsage
    /// Every release in view, for the repos' numbers.
    let releases: [RepoRelease]
    /// Those the bar's search and toggles leave.
    let shown: [RepoRelease]
    let groups: [MilestoneGroup]
    @Binding var search: String
    @State private var repoSort: StatsSort? = StatsSort(columnID: "downloads", ascending: false)
    @State private var releaseSort: StatsSort? = StatsSort(columnID: "published", ascending: false)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    tiles.sectionContent()
                }
                Section {
                    VStack(alignment: .leading, spacing: 24) {
                        DownloadsOverTimeChart(points: usage.downloadsOverTime)
                        UsageBarChart(title: "Downloads by release month", points: usage.downloadsByMonth, noun: "downloads of releases published")
                        UsageLineChart(title: "Stars", points: usage.starsOverTime, noun: "stars", note: starsNote)
                    }
                    .sectionContent()
                } header: {
                    PinnedHeader { Text("Over time") }
                }
                Section {
                    repositoriesTable.sectionContent()
                } header: {
                    PinnedHeader { SectionHeader(title: "Repositories", count: usage.repositories.count) }
                }
                Section {
                    releasesTable.sectionContent()
                } header: {
                    PinnedHeader { SectionHeader(title: "Releases", count: shown.count) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tiles: some View {
        TileGrid {
            StatTile(
                title: "Downloads",
                value: usage.downloads.formatted(),
                detail: usage.downloadsLately.map { "\($0.formatted()) in the last 30 days" } ?? "Every release asset, as GitHub counts them"
            )
            StatTile(
                title: "Stars",
                value: usage.stars.formatted(),
                detail: "\(usage.starsLately.formatted()) in the last 30 days"
            )
            StatTile(
                title: "Releases",
                value: releases.filter { !$0.isDraft }.count.formatted(),
                detail: "\(usage.repositories.count) \(usage.repositories.count == 1 ? "repository" : "repositories")"
            )
            if let latest = releases.filter({ !$0.isDraft }).max(by: { $0.date < $1.date }) {
                StatTile(
                    title: "Latest",
                    value: latest.tagName,
                    detail: "\(ReleasesView.repoName(latest.repo)) · \(latest.date.formatted(.relative(presentation: .named)))"
                )
            }
        }
    }

    private var starsNote: String? {
        usage.starsBefore > 0
            ? "Starts at \(usage.starsBefore.formatted()) for stars older than the \(ReleaseStore.starReach.formatted()) newest of a repository."
            : nil
    }

    // MARK: Repositories

    private struct RepositoryRow: Identifiable {
        let repository: ReleaseRepository
        let latest: RepoRelease?
        let downloads: Int
        let starsLately: Int

        var id: String { repository.name }
    }

    private var repositoryRows: [RepositoryRow] {
        let byRepo = Dictionary(grouping: releases, by: \.repo)
        return usage.repositories.map { repository in
            let releases = byRepo[repository.name] ?? []
            return RepositoryRow(
                repository: repository,
                latest: releases.filter { !$0.isDraft }.max { $0.date < $1.date },
                downloads: releases.reduce(0) { $0 + $1.downloads },
                starsLately: usage.starsGained[repository.name] ?? 0
            )
        }
    }

    @ViewBuilder
    private var repositoriesTable: some View {
        let rows = repositoryRows
        if rows.isEmpty {
            Text("No repository in view has published a release.").foregroundStyle(.secondary)
        } else {
            StatsTable(
                rows: rows,
                columns: [
                    StatsColumn(
                        id: "repo", title: "Repository", help: "Click one to list its releases below",
                        width: nil, minWidth: 200,
                        sortKey: { .text($0.repository.name.lowercased()) },
                        cell: { AnyView(Text(ReleasesView.repoName($0.repository.name)).lineLimit(1).help($0.repository.name)) }
                    ),
                    StatsColumn(
                        id: "releases", title: "Releases", help: "Releases on GitHub, drafts included when you can see them",
                        width: 70,
                        sortKey: { .number(Double($0.repository.releaseCount)) },
                        cell: { AnyView(NumberCell(text: "\($0.repository.releaseCount)", dimmed: false)) }
                    ),
                    StatsColumn(
                        id: "latest", title: "Latest", help: "Its most recently published release",
                        width: 150,
                        sortKey: { .number($0.latest?.date.timeIntervalSince1970 ?? 0) },
                        cell: { row in
                            AnyView(
                                Text(row.latest.map { "\($0.tagName) · \($0.date.formatted(.relative(presentation: .named)))" } ?? "-")
                                    .lineLimit(1)
                                    .foregroundStyle(row.latest == nil ? .tertiary : .primary)
                            )
                        }
                    ),
                    StatsColumn(
                        id: "downloads", title: "Downloads", help: "Every release asset's downloads, as GitHub counts them",
                        width: 90,
                        sortKey: { .number(Double($0.downloads)) },
                        cell: { AnyView(NumberCell(text: $0.downloads.formatted(), dimmed: $0.downloads == 0)) }
                    ),
                    StatsColumn(
                        id: "stars", title: "Stars", help: "Stars now",
                        width: 70,
                        sortKey: { .number(Double($0.repository.stars)) },
                        cell: { AnyView(NumberCell(text: $0.repository.stars.formatted(), dimmed: $0.repository.stars == 0)) }
                    ),
                    StatsColumn(
                        id: "starsLately", title: "30 days", help: "Stars in the last 30 days, from those still starring it",
                        width: 70,
                        sortKey: { .number(Double($0.starsLately)) },
                        cell: { AnyView(NumberCell(text: $0.starsLately == 0 ? "0" : "+\($0.starsLately)", dimmed: $0.starsLately == 0)) }
                    ),
                ],
                sort: $repoSort,
                selectedID: nil,
                onSelect: { search = $0.repository.name },
                contextMenu: { row in
                    AnyView(Button("Open Releases on GitHub") {
                        if let url = URL(string: "https://github.com/\(row.repository.name)/releases") { openURL(url) }
                    })
                }
            )
        }
    }

    // MARK: Releases

    @ViewBuilder
    private var releasesTable: some View {
        if shown.isEmpty {
            Text(releases.isEmpty ? "GitHub Releases in the org's repositories show here." : "No matching releases. Try another search.")
                .foregroundStyle(.secondary)
        } else {
            StatsTable(
                rows: shown,
                columns: [
                    StatsColumn(
                        id: "release", title: "Release", help: "Its name, its tag when that differs, and how it's marked",
                        width: nil, minWidth: 260,
                        sortKey: { .text($0.title.lowercased()) },
                        cell: { release in
                            AnyView(
                                HStack(spacing: 6) {
                                    Text(release.title).fontWeight(.medium).lineLimit(1)
                                    if release.title != release.tagName {
                                        Text(release.tagName).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    ReleaseBadges(release: release)
                                }
                            )
                        }
                    ),
                    StatsColumn(
                        id: "repo", title: "Repository", help: "The repository it's in",
                        width: 140,
                        sortKey: { .text($0.repo.lowercased()) },
                        cell: { AnyView(Text(ReleasesView.repoName($0.repo)).lineLimit(1).help($0.repo)) }
                    ),
                    StatsColumn(
                        id: "published", title: "Published", help: "When it was published, or drafted for a draft",
                        width: 110,
                        sortKey: { .number($0.date.timeIntervalSince1970) },
                        cell: { release in
                            AnyView(
                                Text(release.isDraft ? "Draft" : release.date.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(release.isDraft ? .secondary : .primary)
                                    .help(release.date.formatted(date: .complete, time: .shortened))
                            )
                        }
                    ),
                    StatsColumn(
                        id: "author", title: "Author", help: "Who published it",
                        width: 110,
                        sortKey: { .text($0.author?.lowercased() ?? "") },
                        cell: { AnyView(Text($0.author ?? "-").lineLimit(1).foregroundStyle($0.author == nil ? .tertiary : .primary)) }
                    ),
                    StatsColumn(
                        id: "downloads", title: "Downloads", help: "Its assets' downloads, as GitHub counts them",
                        width: 90,
                        sortKey: { .number(Double($0.downloads)) },
                        cell: { release in
                            AnyView(
                                NumberCell(text: release.assets.isEmpty ? "-" : release.downloads.formatted(), dimmed: release.downloads == 0)
                                    .help(release.assets.isEmpty ? "No assets" : release.assets.map { "\($0.name): \($0.downloadCount.formatted())" }.joined(separator: "\n"))
                            )
                        }
                    ),
                    StatsColumn(
                        id: "milestone", title: "Milestone", help: "The milestone it shipped, titled as its tag or name",
                        width: 140,
                        sortKey: { .text(ReleaseLink.milestone(for: $0, in: groups)?.title.lowercased() ?? "") },
                        cell: { release in
                            if let milestone = ReleaseLink.milestone(for: release, in: groups) {
                                AnyView(
                                    Button {
                                        navigate?(.milestone(milestone.title))
                                    } label: {
                                        Label(milestone.title, systemImage: "flag.checkered").lineLimit(1)
                                    }
                                    .linkButton()
                                )
                            } else {
                                AnyView(Text("-").foregroundStyle(.tertiary))
                            }
                        }
                    ),
                ],
                sort: $releaseSort,
                selectedID: nil,
                onSelect: { navigate?(.release(repo: $0.repo, tag: $0.tagName)) },
                contextMenu: { release in AnyView(Button("Open on GitHub") { openURL(release.url) }) },
                destination: { .release(repo: $0.repo, tag: $0.tagName) }
            )
        }
    }
}

// MARK: - Charts

/// Downloads recorded once a day. GitHub keeps only running totals, so the
/// line starts from Gannin's first sync on this Mac.
private struct DownloadsOverTimeChart: View {
    let points: [ReleaseUsage.Point]

    var body: some View {
        if points.count >= 2 {
            UsageLineChart(
                title: "Downloads",
                points: points,
                noun: "downloads",
                note: "Recorded by Gannin once a day since \(points[0].date.formatted(date: .abbreviated, time: .omitted)), as GitHub keeps only the running total."
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloads").font(.headline)
                Text("GitHub keeps only each asset's running total, so Gannin records it once a day from today. The line starts once there are two days to draw.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A running total by day, one series.
private struct UsageLineChart: View {
    let title: String
    let points: [ReleaseUsage.Point]
    let noun: String
    var note: String?
    @State private var hovered: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if points.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points, id: \.date) { point in
                        AreaMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value))
                            .foregroundStyle(ChartPalette.blue.opacity(0.12))
                            .interpolationMethod(.stepEnd)
                        LineMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value))
                            .foregroundStyle(ChartPalette.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.stepEnd)
                    }
                    if let hovered, let point = points.last(where: { $0.date <= hovered }) {
                        RuleMark(x: .value("Day", point.date, unit: .day))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Day", point.date, unit: .day), y: .value(title, point.value))
                            .foregroundStyle(ChartPalette.blue)
                            .symbolSize(64)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                }
                .chartOverlay { proxy in ActionsBucketHover(proxy: proxy, starts: points.map(\.date), hovered: $hovered) }
                .frame(height: 170)
                if let hovered, let point = points.last(where: { $0.date <= hovered }) {
                    Text("\(point.date.formatted(date: .abbreviated, time: .omitted)): \(point.value.formatted()) \(noun)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(note ?? "Hover for values.").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// A count by month, one series.
private struct UsageBarChart: View {
    let title: String
    let points: [ReleaseUsage.Point]
    let noun: String
    @State private var hovered: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if points.isEmpty {
                Text("No published releases yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points, id: \.date) { point in
                        BarMark(x: .value("Month", point.date, unit: .month), y: .value(title, point.value))
                            .foregroundStyle(ChartPalette.blue.opacity(hovered == nil || hovered == point.date ? 1 : 0.5))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                }
                .chartOverlay { proxy in ActionsBucketHover(proxy: proxy, starts: points.map(\.date), hovered: $hovered) }
                .frame(height: 150)
                if let hovered, let point = points.first(where: { $0.date == hovered }) {
                    Text("\(point.date.formatted(.dateTime.month(.wide).year())): \(point.value.formatted()) \(noun) then")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Each release's downloads so far, by the month it came out. Hover for values.").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
