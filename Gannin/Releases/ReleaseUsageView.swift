import Charts
import SwiftUI

/// The Releases part of the Releases page: downloads and stars across the
/// repos with releases (or the one picked), over time, then those repos,
/// every release and their stargazers as tables.
struct ReleasesOverview: View {
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let usage: ReleaseUsage
    /// Every release in view, for the repos' numbers.
    let releases: [RepoRelease]
    /// Those the bar's search and toggles leave.
    let shown: [RepoRelease]
    let groups: [MilestoneGroup]
    /// The bar's search, which narrows the stargazers too.
    let search: String
    /// The repo picked in the bar, empty for all of them.
    @Binding var repo: String
    @State private var repoSort: StatsSort? = StatsSort(columnID: "downloads", ascending: false)
    @State private var releaseSort: StatsSort? = StatsSort(columnID: "published", ascending: false)
    @State private var stargazerSort: StatsSort? = StatsSort(columnID: "starred", ascending: false)

    /// The stargazers table lists at most this many, after the search and sort.
    static let stargazerLimit = 500
    /// Release marks on the stars line past this many would hide it, so
    /// they show for one repo, or for all while there are no more than this.
    static let releaseMarkLimit = 30

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    tiles.sectionContent()
                }
                Section {
                    VStack(alignment: .leading, spacing: 24) {
                        DownloadsOverTimeChart(points: usage.downloadsOverTime)
                        UsageBarChart(
                            title: "Downloads by release month", points: usage.downloadsByMonth, unit: .month,
                            noun: "downloads of releases published", suffix: " then",
                            caption: "Each release's downloads so far, by the month it came out. Hover for values.",
                            empty: "No published releases yet."
                        )
                        UsageLineChart(title: "Stars", points: usage.starsOverTime, noun: "stars", note: starsNote, marks: releaseMarks)
                        UsageBarChart(
                            title: usage.newStarsBucket == .week ? "New stars by week" : "New stars by month",
                            points: usage.newStars, unit: usage.newStarsBucket == .week ? .weekOfYear : .month,
                            noun: "new stars", suffix: "",
                            caption: "Stars from those still starring, by when they starred. Hover for values.",
                            empty: "No stars yet."
                        )
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
                let stargazers = shownStargazers
                Section {
                    stargazersTable(stargazers).sectionContent()
                } header: {
                    PinnedHeader { SectionHeader(title: "Stargazers", count: stargazers.count) }
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

    /// Published releases (not pre-releases) since the first star, to mark
    /// on the stars line.
    private var releaseMarks: [UsageLineChart.Mark] {
        guard let first = usage.starsOverTime.first?.date else { return [] }
        let marked = releases.filter { !$0.isDraft && !$0.isPrerelease && $0.date >= first }
        guard !repo.isEmpty || marked.count <= Self.releaseMarkLimit else { return [] }
        return marked.map { release in
            UsageLineChart.Mark(
                date: Calendar.current.startOfDay(for: release.date),
                label: repo.isEmpty ? "\(ReleasesView.repoName(release.repo)) \(release.tagName)" : release.tagName
            )
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
                        id: "repo", title: "Repository", help: "Click one to show it alone, and again to show them all",
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
                onSelect: { row in repo = repo == row.repository.name ? "" : row.repository.name },
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

// MARK: - Stargazers

extension ReleasesOverview {
    /// Those the search leaves, every word in their login, name, company,
    /// location or repo.
    var shownStargazers: [RepoStargazer] {
        let words = search.lowercased().split(separator: " ")
        guard !words.isEmpty else { return usage.stargazers }
        return usage.stargazers.filter { row in
            let person = row.stargazer
            let text = [person.login, person.name ?? "", person.company ?? "", person.location ?? "", row.repo]
                .joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private var stargazerColumns: [StatsColumn<RepoStargazer>] {
        [
            StatsColumn(
                id: "who", title: "Stargazer", help: "Their login and name. Click one to open their profile on GitHub",
                width: nil, minWidth: 220,
                sortKey: { .text($0.stargazer.login.lowercased()) },
                cell: { row in
                    AnyView(
                        HStack(spacing: 8) {
                            Avatar(url: row.stargazer.avatarURL, size: 20)
                            Text(row.stargazer.login).fontWeight(.medium).lineLimit(1)
                            if let name = row.stargazer.name, !name.isEmpty {
                                Text(name).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    )
                }
            ),
            StatsColumn(
                id: "repo", title: "Repository", help: "The repository they starred",
                width: 140,
                sortKey: { .text($0.repo.lowercased()) },
                cell: { AnyView(Text(ReleasesView.repoName($0.repo)).lineLimit(1).help($0.repo)) }
            ),
            StatsColumn(
                id: "company", title: "Company", help: "As their GitHub profile has it",
                width: 140,
                sortKey: { .text($0.stargazer.company?.lowercased() ?? "") },
                cell: { AnyView(OptionalText(text: $0.stargazer.company)) }
            ),
            StatsColumn(
                id: "location", title: "Location", help: "As their GitHub profile has it",
                width: 140,
                sortKey: { .text($0.stargazer.location?.lowercased() ?? "") },
                cell: { AnyView(OptionalText(text: $0.stargazer.location)) }
            ),
            StatsColumn(
                id: "followers", title: "Followers", help: "Their followers on GitHub when they were fetched",
                width: 80,
                sortKey: { .number(Double($0.stargazer.followers)) },
                cell: { AnyView(NumberCell(text: $0.stargazer.followers.formatted(), dimmed: $0.stargazer.followers == 0)) }
            ),
            StatsColumn(
                id: "starred", title: "Starred", help: "When they starred it",
                width: 110,
                sortKey: { .number($0.stargazer.starredAt.timeIntervalSince1970) },
                cell: { row in
                    AnyView(
                        Text(row.stargazer.starredAt.formatted(date: .abbreviated, time: .omitted))
                            .help(row.stargazer.starredAt.formatted(date: .complete, time: .shortened))
                    )
                }
            ),
        ]
    }

    /// The first `stargazerLimit` in the table's order, so sorting by
    /// followers finds the most followed of all of them, not of the newest.
    @ViewBuilder
    func stargazersTable(_ stargazers: [RepoStargazer]) -> some View {
        if stargazers.isEmpty {
            Text(usage.stargazers.isEmpty ? "Who starred the repositories with releases shows here." : "No matching stargazers. Try another search.")
                .foregroundStyle(.secondary)
        } else {
            let columns = stargazerColumns
            let sorted = stargazerSort.flatMap { sort in
                columns.first { $0.id == sort.columnID }.map { column in
                    stargazers.sorted { sort.ascending ? column.sortKey($0) < column.sortKey($1) : column.sortKey($0) > column.sortKey($1) }
                }
            } ?? stargazers
            VStack(alignment: .leading, spacing: 8) {
                StatsTable(
                    rows: Array(sorted.prefix(Self.stargazerLimit)),
                    columns: columns,
                    sort: $stargazerSort,
                    selectedID: nil,
                    onSelect: { row in row.stargazer.profileURL.map { openURL($0) } },
                    contextMenu: { row in
                        AnyView(Button("Open Profile on GitHub") { row.stargazer.profileURL.map { openURL($0) } })
                    }
                )
                if sorted.count > Self.stargazerLimit {
                    Text("Showing the first \(Self.stargazerLimit.formatted()) of \(sorted.count.formatted()). Search or pick a repository to narrow them.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// A profile field, or a dash when it's empty.
private struct OptionalText: View {
    let text: String?

    var body: some View {
        if let text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(text).lineLimit(1).help(text)
        } else {
            Text("-").foregroundStyle(.tertiary)
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

/// A running total by day, one series, with any marks (releases) as
/// dashed rules that hovering names.
private struct UsageLineChart: View {
    struct Mark: Hashable {
        /// The day's start.
        let date: Date
        let label: String
    }

    let title: String
    let points: [ReleaseUsage.Point]
    let noun: String
    var note: String?
    var marks: [Mark] = []
    @State private var hovered: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if points.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(marks, id: \.self) { mark in
                        RuleMark(x: .value("Day", mark.date, unit: .day))
                            .foregroundStyle(.secondary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
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
                .chartOverlay { proxy in
                    ActionsBucketHover(proxy: proxy, starts: Array(Set(points.map(\.date) + marks.map(\.date))).sorted(), hovered: $hovered)
                }
                .frame(height: 170)
                if let hovered, let point = points.last(where: { $0.date <= hovered }) {
                    let released = marks.filter { $0.date == hovered }.map(\.label)
                    Text("\(hovered.formatted(date: .abbreviated, time: .omitted)): \(point.value.formatted()) \(noun)\(released.isEmpty ? "" : " · released \(released.joined(separator: ", "))")")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(note ?? "Hover for values.").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// A count by week or month, one series.
private struct UsageBarChart: View {
    let title: String
    let points: [ReleaseUsage.Point]
    /// `.weekOfYear` or `.month`.
    let unit: Calendar.Component
    let noun: String
    /// After the value when hovering.
    let suffix: String
    let caption: String
    let empty: String
    @State private var hovered: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if points.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points, id: \.date) { point in
                        BarMark(x: .value(unit == .month ? "Month" : "Week", point.date, unit: unit, calendar: Calendar.metrics), y: .value(title, point.value))
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
                    let when = unit == .month
                        ? point.date.formatted(.dateTime.month(.wide).year())
                        : "Week of \(point.date.formatted(date: .abbreviated, time: .omitted))"
                    Text("\(when): \(point.value.formatted()) \(noun)\(suffix)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(caption).font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
