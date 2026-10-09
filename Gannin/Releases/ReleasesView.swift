import SwiftUI

/// Delivery › Releases: the org's GitHub Releases, with downloads and stars
/// over time, the repos with releases, every release (each linked to the
/// milestone it shipped) and their stargazers, for every repo or one; and its
/// milestones, grouped by title across repos, with GitHub's progress (closed
/// of all issues) and what the issue history says is in progress and merged.
/// Releases (first) and Milestones are picked in the toolbar.
struct ReleasesView: View {
    enum Part: String, CaseIterable {
        case releases = "Releases"
        case milestones = "Milestones"
    }

    @Environment(ReleaseStore.self) private var store
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    @SceneStorage("releasesPart") private var part: Part = .releases
    /// The repo the Releases part shows, empty for all of them.
    @SceneStorage("releasesRepo") private var repo = ""
    let org: String
    @State private var search = ""
    @State private var showsClosed = false
    @State private var showsPrereleases = true

    var body: some View {
        let config = configs.config(for: org)
        let history = store.history(for: org)
        let groups = MilestoneGroup.groups(history?.milestones ?? [], excluding: config.repoExclusion)
        let repos = (history?.repositories ?? []).map(\.name).filter { !config.repoExclusion.contains($0) }
        // A repo picked that's gone from view (excluded, or no releases now) is all of them.
        let picked = repos.contains(repo) ? repo : ""
        let included: (String) -> Bool = { !config.repoExclusion.contains($0) && (picked.isEmpty || $0 == picked) }
        let releases = (history?.releases ?? []).filter { !config.repoExclusion.contains($0.repo) }
        let releasesInView = releases.filter { included($0.repo) }
        VStack(spacing: 0) {
            bar(count: part == .milestones ? shownMilestones(groups).count : shownReleases(releasesInView).count, repos: repos, picked: picked)
            Divider()
            if let history {
                switch part {
                case .milestones: milestoneList(groups, releases: releases, config: config)
                case .releases:
                    ReleasesOverview(
                        usage: ReleaseUsage(
                            history: history,
                            downloadHistory: store.downloadHistory(for: org),
                            releases: releasesInView,
                            included: included
                        ),
                        releases: releasesInView,
                        shown: shownReleases(releasesInView),
                        groups: groups,
                        stars: history.stars.filter { included($0.key) },
                        syncedAt: history.syncedAt,
                        repo: $repo
                    )
                }
            } else {
                if let error = store.errors[org] {
                    ContentUnavailableView("Couldn't load milestones", systemImage: "exclamationmark.triangle", description: Text(error))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $part) {
                    ForEach(Part.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .syncOffNotice(.releases)
        .task(id: org) {
            async let releases: Void = store.sync(org, excluding: config.unfetchedRepos)
            async let issues: Void = issueStore.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays())
            _ = await (releases, issues)
        }
    }

    private func bar(count: Int, repos: [String], picked: String) -> some View {
        HStack(spacing: 10) {
            FilterSearchField(text: $search, prompt: part == .milestones ? "Search milestones" : "Search releases")
                .frame(maxWidth: 280)
            switch part {
            case .milestones: Toggle("Closed too", isOn: $showsClosed).checkboxToggle()
            case .releases:
                if repos.count > 1 { repositoryMenu(repos, picked: picked) }
                Toggle("Pre-releases", isOn: $showsPrereleases).checkboxToggle()
            }
            Spacer()
            let noun = part == .milestones ? "milestone" : "release"
            Text("\(count) \(noun)\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Every repo with releases, or one: the tiles, charts and tables follow it.
    private func repositoryMenu(_ repos: [String], picked: String) -> some View {
        Menu {
            Picker("Repository", selection: $repo) {
                Text("All Repositories").tag("")
                Divider()
                ForEach(repos.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) {
                    Text(Self.repoName($0)).tag($0)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(picked.isEmpty ? "All Repositories" : Self.repoName(picked)).lineLimit(1)
        }
        .fixedSize()
        .tint(picked.isEmpty ? nil : .accentColor)
        .help(picked.isEmpty ? "Show one repository's releases, downloads and stars" : "Showing \(picked) only")
    }

    private var words: [Substring] { search.lowercased().split(separator: " ") }

    // MARK: Milestones

    private func shownMilestones(_ groups: [MilestoneGroup]) -> [MilestoneGroup] {
        groups.filter { group in
            guard showsClosed || group.isOpen else { return false }
            let text = ([group.title] + group.repos).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    @ViewBuilder
    private func milestoneList(_ groups: [MilestoneGroup], releases: [RepoRelease], config: OrgConfig) -> some View {
        let shown = shownMilestones(groups)
        if shown.isEmpty {
            ContentUnavailableView(
                groups.isEmpty ? "No milestones" : "No matching milestones",
                systemImage: "flag.checkered",
                description: Text(groups.isEmpty ? "Milestones in the org's repositories show here." : "Try another search, or show closed ones too.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let index = MilestoneGroup.index(issueStore.history(for: org))
            List(shown) { group in
                MilestoneRow(
                    group: group,
                    activity: MilestoneActivity(group: group, index: index, workflow: config.workflow),
                    release: ReleaseLink.release(for: group, in: releases)
                ) {
                    navigate?(.milestone(group.title))
                }
                .contextMenu {
                    ForEach(group.milestones) { milestone in
                        Button(group.milestones.count == 1 ? "Open on GitHub" : "Open in \(Self.repoName(milestone.repo)) on GitHub") {
                            openURL(milestone.url)
                        }
                    }
                }
            }
        }
    }

    // MARK: Releases

    private func shownReleases(_ releases: [RepoRelease]) -> [RepoRelease] {
        releases
            .filter { release in
                guard showsPrereleases || !release.isPrerelease else { return false }
                let text = "\(release.title) \(release.tagName) \(release.repo) \(release.author ?? "")".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { $0.date > $1.date }
    }

    static func repoName(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
}

// MARK: - Rows

private struct MilestoneRow: View {
    let group: MilestoneGroup
    let activity: MilestoneActivity
    let release: RepoRelease?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.title).fontWeight(.medium).lineLimit(1)
                        if !group.isOpen { Text("Closed").font(.caption).foregroundStyle(.purple) }
                        if let release {
                            Label(release.isDraft ? "Draft \(release.tagName)" : "Released as \(release.tagName)", systemImage: "shippingbox")
                                .font(.caption)
                                .foregroundStyle(release.isDraft ? Color.secondary : ChartPalette.good)
                        }
                    }
                    Text(group.repos.map(ReleasesView.repoName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if group.isOpen, let due = group.dueOn {
                    DueLabel(date: due)
                } else if let closed = group.closedAt {
                    Text("Closed \(closed.formatted(.relative(presentation: .named)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if activity.withMergedPullRequest > 0 {
                    Text("\(activity.withMergedPullRequest) merged")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Issues in it with a merged PR, from the issue history")
                }
                if !activity.inProgress.isEmpty {
                    Text("\(activity.inProgress.count) in progress")
                        .font(.callout)
                        .foregroundStyle(ChartPalette.blue)
                }
                MilestoneProgress(closed: group.closed, total: group.total)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

struct ReleaseBadges: View {
    let release: RepoRelease

    var body: some View {
        HStack(spacing: 4) {
            if release.isLatest { badge("Latest", ChartPalette.good) }
            if release.isPrerelease { badge("Pre-release", .orange) }
            if release.isDraft { badge("Draft", .secondary) }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.6)))
    }
}

/// "3 of 8" over a bar, green once everything's closed.
struct MilestoneProgress: View {
    let closed: Int
    let total: Int
    var width: CGFloat = 120

    var body: some View {
        let progress = total == 0 ? 0 : Double(closed) / Double(total)
        VStack(alignment: .trailing, spacing: 3) {
            Text(total == 0 ? "Empty" : "\(closed) of \(total)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(total == 0 ? .secondary : .primary)
            ProgressView(value: progress)
                .frame(width: width)
                .tint(total > 0 && progress >= 1 ? ChartPalette.good : .accentColor)
        }
        .help("Closed of all the issues and pull requests in the milestone, as GitHub counts them")
    }
}

/// A due date, red once it's passed and orange within the week, as
/// Prioritisation shows committed dates.
struct DueLabel: View {
    let date: Date

    var body: some View {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
        let words = days < 0 ? "\(-days)d overdue" : days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : "Due \(date.formatted(.dateTime.day().month(.abbreviated)))"
        Text(words)
            .font(.callout)
            .foregroundStyle(days < 0 ? .red : days < 7 ? .orange : .secondary)
            .help(date.formatted(date: .complete, time: .omitted))
    }
}

// MARK: - Milestone page

/// A milestone across its repos: progress in each, the release it shipped
/// as, its description, and its issues from the issue history.
struct MilestonePage: View {
    @Environment(ReleaseStore.self) private var store
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let org: String
    let title: String

    var body: some View {
        let config = configs.config(for: org)
        let history = store.history(for: org)
        let groups = MilestoneGroup.groups(history?.milestones ?? [], excluding: config.repoExclusion)
        if let group = groups.first(where: { $0.key == MilestoneGroup.key(title) }) {
            content(group, releases: history?.releases ?? [], config: config)
        } else if history == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No milestone called \(title)", systemImage: "flag.checkered", description: Text("It may have been renamed, or closed a while ago."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ group: MilestoneGroup, releases: [RepoRelease], config: OrgConfig) -> some View {
        let issueHistory = issueStore.history(for: org)
        let activity = MilestoneActivity(group: group, index: MilestoneGroup.index(issueHistory), workflow: config.workflow)
        let release = ReleaseLink.release(for: group, in: releases)
        let inProgress = Set(activity.inProgress.map(\.id))
        let open = activity.issues.filter { $0.isOpen && !inProgress.contains($0.id) }.sorted { $0.number > $1.number }
        let closed = activity.issues.filter { !$0.isOpen }.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        return Form {
            Section {
                LabeledContent("State", value: group.isOpen ? "Open" : "Closed")
                if let due = group.dueOn {
                    LabeledContent("Due") {
                        if group.isOpen { DueLabel(date: due) } else { Text(due.formatted(date: .abbreviated, time: .omitted)) }
                    }
                }
                if let closedAt = group.closedAt {
                    LabeledContent("Closed", value: closedAt.formatted(date: .abbreviated, time: .omitted))
                }
                LabeledContent("Progress") { MilestoneProgress(closed: group.closed, total: group.total, width: 200) }
                LabeledContent("In progress", value: "\(activity.inProgress.count)")
                LabeledContent("With a merged PR", value: "\(activity.withMergedPullRequest)")
                if let release {
                    LabeledContent("Release") {
                        Button {
                            navigate?(.release(repo: release.repo, tag: release.tagName))
                        } label: {
                            Label("\(release.title) · \(release.isDraft ? "draft" : release.date.formatted(date: .abbreviated, time: .omitted))", systemImage: "shippingbox")
                        }
                        .linkButton()
                    }
                }
            }
            Section(group.milestones.count == 1 ? "Repository" : "Repositories") {
                ForEach(group.milestones) { milestone in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(milestone.repo)
                            if !milestone.isOpen {
                                Text("Closed").font(.caption).foregroundStyle(.purple)
                            } else if let due = milestone.dueOn, due != group.dueOn {
                                DueLabel(date: due)
                            }
                        }
                        Spacer()
                        MilestoneProgress(closed: milestone.closed, total: milestone.total)
                        Button("GitHub") { openURL(milestone.url) }
                            .linkButton()
                    }
                }
            }
            if let description = group.description {
                Section("Description") {
                    MarkdownText(source: description)
                }
            }
            issueSection("In progress", activity.inProgress.sorted { $0.number > $1.number }, workflow: config.workflow)
            issueSection("Open", open, workflow: config.workflow)
            issueSection("Closed", closed, workflow: config.workflow)
            if issueHistory != nil && activity.issues.count < group.issueTotal {
                Section {
                    Text("GitHub counts \(group.issueTotal) issue\(group.issueTotal == 1 ? "" : "s"); the issue history has \(activity.issues.count), as it keeps only those closed since the window's start.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    /// Each issue with its status on the workflow's board, as In progress
    /// reads it.
    private func issueSection(_ title: String, _ issues: [IssueRecord], workflow: IssueWorkflow) -> some View {
        if !issues.isEmpty {
            Section("\(title) (\(issues.count))") {
                ForEach(issues) { issue in
                    Button {
                        navigate?(.issueReference(IssueReference(org: org, record: issue)))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: issue.isOpen ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(issue.isOpen ? .green : .purple)
                            Text(issue.title).lineLimit(1)
                            Spacer()
                            if !issue.assignees.isEmpty {
                                Text(issue.assignees.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let status = issue.statusChanges.last(where: workflow.counts)?.status {
                                Text(status).foregroundStyle(.secondary)
                            }
                            Text("\(ReleasesView.repoName(issue.repo))#\(String(issue.number))").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Release page

/// A GitHub Release: its facts, the milestone it shipped, and its notes.
struct ReleasePage: View {
    @Environment(ReleaseStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    let org: String
    let repo: String
    let tag: String

    var body: some View {
        let history = store.history(for: org)
        if let release = history?.releases.first(where: { $0.repo == repo && $0.tagName == tag }) {
            let groups = MilestoneGroup.groups(history?.milestones ?? [], excluding: configs.config(for: org).repoExclusion)
            Form {
                Section {
                    LabeledContent("Repository", value: repo)
                    LabeledContent("Tag") { Text(release.tagName).monospaced() }
                    LabeledContent(release.isDraft ? "Drafted" : "Published", value: release.date.formatted(date: .abbreviated, time: .shortened))
                    if let author = release.author { LabeledContent("Author", value: author) }
                    LabeledContent("Downloads", value: release.assets.isEmpty ? "No assets" : release.downloads.formatted())
                    if release.isLatest || release.isPrerelease || release.isDraft {
                        LabeledContent("Marked") { ReleaseBadges(release: release) }
                    }
                    if let milestone = ReleaseLink.milestone(for: release, in: groups) {
                        LabeledContent("Milestone") {
                            Button {
                                navigate?(.milestone(milestone.title))
                            } label: {
                                Label(milestone.title, systemImage: "flag.checkered")
                            }
                            .linkButton()
                        }
                    }
                    LabeledContent("GitHub") {
                        Button("Open on GitHub") { openURL(release.url) }.linkButton()
                    }
                }
                if !release.assets.isEmpty {
                    Section("Assets") {
                        ForEach(release.assets.sorted { $0.downloadCount > $1.downloadCount }, id: \.name) { asset in
                            LabeledContent {
                                Text("\(asset.downloadCount.formatted()) downloads").monospacedDigit()
                            } label: {
                                Text(asset.name)
                                Text(asset.size.formatted(.byteCount(style: .file)))
                            }
                        }
                    }
                }
                Section("Notes") {
                    if let notes = release.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownText(source: notes)
                    } else {
                        Text("No release notes.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        } else if history == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No release \(tag)", systemImage: "shippingbox", description: Text("It may have been deleted, or be in a repository not pushed to in the last year."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
