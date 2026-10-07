import SwiftUI

/// What the Pull Requests page narrows its PRs by: open or merged, a search,
/// authors, reviewers, statuses and repositories (several of each, any
/// matching), and whether to hide the viewer's own. Kept per window.
struct PullRequestFilters {
    enum State: String, CaseIterable {
        case open = "Open"
        case merged = "Merged"
        case all = "All"
    }

    enum Key: String, CaseIterable {
        case author = "Author"
        case reviewer = "Reviewer"
        case status = "Status"
        case repository = "Repository"
    }

    /// Reviewer values: a login, or no reviewer requested or reviewing.
    static let noReviewer = ""

    enum Status: String, CaseIterable {
        case draft = "Draft"
        case needsReview = "Needs review"
        case changesRequested = "Changes requested"
        case approved = "Approved"
        case merged = "Merged"

        init(_ pr: PullRequest) {
            if pr.isMerged { self = .merged }
            else if pr.isDraft { self = .draft }
            else {
                switch pr.review {
                case .changesRequested: self = .changesRequested
                case .approved: self = .approved
                default: self = .needsReview
                }
            }
        }
    }

    var state: State = .open
    var search = ""
    var values: [Key: Set<String>] = [:]
    var hideMine = false

    var isNarrowed: Bool { !search.isEmpty || hideMine || values.values.contains { !$0.isEmpty } }

    func inState(_ pr: PullRequest) -> Bool {
        switch state {
        case .open: !pr.isMerged
        case .merged: pr.isMerged
        case .all: true
        }
    }

    /// Everyone asked to review it or who has.
    static func reviewers(_ pr: PullRequest) -> Set<String> {
        Set(pr.requestedReviewers.map(\.login) + pr.reviewers.map(\.login))
    }

    /// Everything but the state, less `key` (so a menu counts what picking
    /// among its values would give).
    func matches(_ pr: PullRequest, except key: Key? = nil, viewerLogin: String? = nil) -> Bool {
        if hideMine, let viewerLogin, pr.author?.login == viewerLogin { return false }
        for (filter, picked) in values where filter != key && !picked.isEmpty {
            let hit: Bool = switch filter {
            case .author: pr.author.map { picked.contains($0.login) } ?? false
            case .reviewer:
                picked.contains { value in
                    value == Self.noReviewer ? Self.reviewers(pr).isEmpty : Self.reviewers(pr).contains(value)
                }
            case .status: picked.contains(Status(pr).rawValue)
            case .repository: picked.contains(pr.repo)
            }
            if !hit { return false }
        }
        let people = ([pr.author].compactMap { $0 } + pr.assignees + pr.requestedReviewers + pr.reviewers).flatMap { [$0.login, $0.displayName] }
        return IssueSearch.matches(search, title: pr.title, repo: pr.repo, number: pr.number, people: people, labels: [])
    }
}

/// Scene storage for `PullRequestFilters`.
struct StoredPullRequestFilters: DynamicProperty {
    @SceneStorage("pullRequests.state") private var state: PullRequestFilters.State = .open
    @SceneStorage("pullRequests.author") private var author = ""
    @SceneStorage("pullRequests.reviewer") private var reviewer = ""
    @SceneStorage("pullRequests.status") private var status = ""
    @SceneStorage("pullRequests.repository") private var repository = ""
    @SceneStorage("pullRequests.hideMine") private var hideMine = false
    @State private var search = ""

    var wrappedValue: PullRequestFilters {
        get {
            PullRequestFilters(state: state, search: search, values: [
                .author: StoredSet.set(author), .reviewer: StoredSet.set(reviewer),
                .status: StoredSet.set(status), .repository: StoredSet.set(repository),
            ], hideMine: hideMine)
        }
        nonmutating set {
            state = newValue.state
            search = newValue.search
            author = StoredSet.string(newValue.values[.author] ?? [])
            reviewer = StoredSet.string(newValue.values[.reviewer] ?? [])
            status = StoredSet.string(newValue.values[.status] ?? [])
            repository = StoredSet.string(newValue.values[.repository] ?? [])
            hideMine = newValue.hideMine
        }
    }

    var projectedValue: Binding<PullRequestFilters> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// Pull Requests: the open ones and those merged in the lookback, found with
/// the bar's search and narrowed by author, reviewer, status and repository,
/// as the issue pages are.
struct PullRequestsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(HiddenStore.self) private var hidden
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openURL) private var openURL
    let workload: Workload
    @Binding var selection: DetailSelection?
    private var stored = StoredPullRequestFilters()
    @State private var tableSelection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<PullRequestTableRow>] = []
    @AppStorage("pullRequestColumns") private var storedColumns = Data()

    init(workload: Workload, selection: Binding<DetailSelection?>) {
        self.workload = workload
        _selection = selection
    }

    var body: some View {
        let filters = stored.wrappedValue
        let pool = (workload.openPullRequests + workload.mergedPullRequests).filter(filters.inState)
        let shown = pool.filter { filters.matches($0, viewerLogin: auth.viewer?.login) }
        let open = shown.filter { !$0.isMerged }.sorted { $0.updatedAt > $1.updatedAt }.map(PullRequestTableRow.init)
        let merged = shown.filter(\.isMerged).sorted { ($0.mergedAt ?? $0.updatedAt) > ($1.mergedAt ?? $1.updatedAt) }.map(PullRequestTableRow.init)
        var sections: [(title: String, rows: [PullRequestTableRow])] = []
        if filters.state != .merged, !open.isEmpty { sections.append(("Open", open)) }
        if filters.state != .open, !merged.isEmpty { sections.append(("Merged in the last \(workload.snapshot.lookbackDays) days", merged)) }
        return VStack(spacing: 0) {
            bar(filters, pool: pool)
            Divider()
            if shown.isEmpty {
                ContentUnavailableView(pool.isEmpty ? "No pull requests" : "No pull requests match", systemImage: "arrow.triangle.pull")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(sections)
            }
        }
        // A row picked opens in the drawer, as a list row did.
        .onChange(of: tableSelection) {
            if tableSelection.count == 1, let id = tableSelection.first { selection = .pullRequest(id) }
        }
    }

    private func table(_ sections: [(title: String, rows: [PullRequestTableRow])]) -> some View {
        Table(of: PullRequestTableRow.self, selection: $tableSelection, sortOrder: $sortOrder, columnCustomization: TableColumnStore.binding($storedColumns)) {
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.pr.statusColor).frame(width: 8, height: 8)
                    Text(row.title).lineLimit(1)
                }
                .opacity(hidden.isHidden(row.id) ? 0.45 : 1)
                .help(row.title)
            }
            .width(min: 220, ideal: 440)
            .customizationID("title")
            TableColumn("Claude") { row in
                ClaudeReviewBadge(sessions: sessions, pullRequestID: row.id)
            }
            .width(min: 60, ideal: 110)
            .customizationID("claude")
            TableColumn("Repository", value: \.repoName) { row in
                Text(verbatim: row.repoName).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 100)
            .customizationID("repository")
            TableColumn("Number", value: \.number) { row in
                Text(verbatim: "#\(row.number)").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            .customizationID("number")
            TableColumn("Author", value: \.authorSort) { row in
                if let author = row.pr.author {
                    HStack(spacing: 6) {
                        Avatar(url: author.avatarUrl, size: 18)
                        Text(author.displayName).lineLimit(1)
                    }
                    .help(author.displayName)
                }
            }
            .width(min: 80, ideal: 140)
            .customizationID("author")
            TableColumn("Reviewers", value: \.reviewerSort) { row in
                AvatarStack(people: row.reviewers)
                    .help(row.reviewers.map(\.displayName).joined(separator: ", "))
            }
            .width(min: 60, ideal: 90)
            .customizationID("reviewers")
            TableColumn("Status", value: \.status) { row in
                HStack(spacing: 4) {
                    Text(row.status).foregroundStyle(row.pr.statusColor).lineLimit(1)
                    if Workload.isStale(row.pr) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .help("No activity for \(Workload.staleAfterDays) days")
                    }
                }
            }
            .width(min: 90, ideal: 150)
            .customizationID("status")
            TableColumn("Linked", value: \.linkedCount) { row in
                if row.linkedCount > 0 {
                    Label("\(row.linkedCount)", systemImage: "link")
                        .foregroundStyle(.secondary)
                        .help(row.pr.linkedIssues.map { "#\($0.number)" }.joined(separator: ", "))
                }
            }
            .width(min: 50, ideal: 60)
            .customizationID("linked")
            // A builder takes ten columns at most.
            Group {
                TableColumn("Updated", value: \PullRequestTableRow.when) { row in
                    RelativeDate(date: row.when)
                        .foregroundStyle(.secondary)
                        .help(row.pr.isMerged ? "Merged" : "Last updated")
                }
                .width(min: 70, ideal: 100)
                .customizationID("updated")
                TableColumn("Files", value: \PullRequestTableRow.files) { row in
                    if let files = row.pr.changedFiles {
                        Text(verbatim: files.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .width(min: 40, ideal: 50)
                .customizationID("files")
                TableColumn("Size", value: \PullRequestTableRow.size) { row in
                    LinesText(added: row.pr.additions, removed: row.pr.deletions)
                        .help("\((row.pr.additions + row.pr.deletions).formatted()) lines changed")
                }
                .width(min: 70, ideal: 90)
                .customizationID("size")
            }
        } rows: {
            ForEach(sections, id: \.title) { section in
                Section("\(section.title) (\(section.rows.count))") {
                    // Sorted within the section, so open and merged stay apart.
                    ForEach(sortOrder.isEmpty ? section.rows : section.rows.sorted(using: sortOrder)) { TableRow($0) }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = sections.flatMap(\.rows).first(where: { ids.contains($0.id) }) {
                OpenElsewhereItems(.pullRequest(row.id))
                Button(hidden.isHidden(row.id) ? "Unhide" : "Hide") { hidden.toggle(row.id) }
                Button("Open on GitHub") { openURL(row.pr.url) }
            }
        } primaryAction: { ids in
            if let id = ids.first { selection = .pullRequest(id) }
        }
    }

    private func bar(_ filters: PullRequestFilters, pool: [PullRequest]) -> some View {
        HStack(spacing: 8) {
            FilterSearchField(text: stored.projectedValue.search, prompt: "Title, number, person or repo")
            ForEach(PullRequestFilters.Key.allCases, id: \.self) { menu($0, filters: filters, pool: pool) }
            Toggle("Hide mine", isOn: stored.projectedValue.hideMine)
                .checkboxToggle()
            Spacer(minLength: 0)
            if filters.isNarrowed {
                Button("Clear All") {
                    let state = filters.state
                    stored.wrappedValue = PullRequestFilters(state: state)
                }
                .linkButton()
            }
            Picker("State", selection: stored.projectedValue.state) {
                ForEach(PullRequestFilters.State.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func menu(_ key: PullRequestFilters.Key, filters: PullRequestFilters, pool: [PullRequest]) -> some View {
        let candidates = pool.filter { filters.matches($0, except: key, viewerLogin: auth.viewer?.login) }
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for pr in candidates {
            switch key {
            case .author:
                if let author = pr.author {
                    counts[author.login, default: 0] += 1
                    names[author.login] = author.displayName
                }
            case .reviewer:
                let reviewers = pr.requestedReviewers + pr.reviewers
                if reviewers.isEmpty { counts[PullRequestFilters.noReviewer, default: 0] += 1 }
                for person in Dictionary(reviewers.map { ($0.login, $0) }, uniquingKeysWith: { first, _ in first }).values {
                    counts[person.login, default: 0] += 1
                    names[person.login] = person.displayName
                }
            case .status: counts[PullRequestFilters.Status(pr).rawValue, default: 0] += 1
            case .repository: counts[pr.repo, default: 0] += 1
            }
        }
        let me = auth.viewer?.login
        var leading: [FilterOption] = []
        var options: [FilterOption]
        switch key {
        case .author, .reviewer:
            if let me { leading.append(FilterOption(value: me, title: "Me", count: counts[me] ?? 0)) }
            if key == .reviewer {
                leading.append(FilterOption(value: PullRequestFilters.noReviewer, title: "No Reviewer", count: counts[PullRequestFilters.noReviewer] ?? 0))
            }
            options = counts.keys.filter { $0 != me && $0 != PullRequestFilters.noReviewer }
                .map { FilterOption(value: $0, title: names[$0] ?? $0, count: counts[$0] ?? 0) }
                .sorted(byCount: true)
        case .status:
            // In their own order, not by name.
            options = PullRequestFilters.Status.allCases.compactMap { status in
                counts[status.rawValue].map { FilterOption(value: status.rawValue, title: status.rawValue, count: $0) }
            }
        case .repository:
            options = counts.keys
                .map { FilterOption(value: $0, title: $0.split(separator: "/").last.map(String.init) ?? $0, count: counts[$0] ?? 0) }
                .sorted(byCount: false)
        }
        return FilterMenu(
            title: key.rawValue, leading: leading, options: options,
            picked: Binding(get: { filters.values[key] ?? [] }, set: { stored.wrappedValue.values[key] = $0 })
        )
    }
}

/// A PR as the Pull Requests table shows it, with what its columns sort by.
struct PullRequestTableRow: Identifiable {
    let pr: PullRequest

    var id: String { pr.id }
    var title: String { pr.title }
    var repoName: String { pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo }
    var number: Int { pr.number }
    var authorSort: String { pr.author?.displayName.lowercased() ?? "" }
    /// Asked for a review, then those who've given one.
    var reviewers: [Person] {
        var seen: Set<String> = []
        return (pr.requestedReviewers + pr.reviewers).filter { seen.insert($0.login).inserted }
    }
    var reviewerSort: Int { reviewers.count }
    var status: String { pr.statusText }
    var linkedCount: Int { pr.linkedIssues.count }
    var when: Date { pr.mergedAt ?? pr.updatedAt }
    var size: Int { pr.additions + pr.deletions }
    /// Files changed, those not yet known sorting first.
    var files: Int { pr.changedFiles ?? -1 }
}
