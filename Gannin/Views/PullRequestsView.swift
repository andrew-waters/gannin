import SwiftUI

/// What the Pull Requests page narrows its PRs by: open or merged, a search,
/// and authors, reviewers, statuses and repositories (several of each, any
/// matching). Kept per window.
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
                switch pr.reviewDecision {
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

    var isNarrowed: Bool { !search.isEmpty || values.values.contains { !$0.isEmpty } }

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
    func matches(_ pr: PullRequest, except key: Key? = nil) -> Bool {
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
    @State private var search = ""

    var wrappedValue: PullRequestFilters {
        get {
            PullRequestFilters(state: state, search: search, values: [
                .author: StoredSet.set(author), .reviewer: StoredSet.set(reviewer),
                .status: StoredSet.set(status), .repository: StoredSet.set(repository),
            ])
        }
        nonmutating set {
            state = newValue.state
            search = newValue.search
            author = StoredSet.string(newValue.values[.author] ?? [])
            reviewer = StoredSet.string(newValue.values[.reviewer] ?? [])
            status = StoredSet.string(newValue.values[.status] ?? [])
            repository = StoredSet.string(newValue.values[.repository] ?? [])
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
    let workload: Workload
    @Binding var selection: DetailSelection?
    private var stored = StoredPullRequestFilters()

    init(workload: Workload, selection: Binding<DetailSelection?>) {
        self.workload = workload
        _selection = selection
    }

    var body: some View {
        let filters = stored.wrappedValue
        let pool = (workload.openPullRequests + workload.mergedPullRequests).filter(filters.inState)
        let shown = pool.filter { filters.matches($0) }
        let open = shown.filter { !$0.isMerged }.sorted { $0.updatedAt > $1.updatedAt }
        let merged = shown.filter(\.isMerged).sorted { ($0.mergedAt ?? $0.updatedAt) > ($1.mergedAt ?? $1.updatedAt) }
        VStack(spacing: 0) {
            bar(filters, pool: pool)
            Divider()
            List(selection: $selection) {
                if shown.isEmpty {
                    Text(pool.isEmpty ? "No pull requests." : "No pull requests match.")
                        .foregroundStyle(.secondary)
                }
                if filters.state != .merged, !open.isEmpty {
                    Section(header: SectionHeader(title: "Open", count: open.count)) {
                        ForEach(open) { PullRequestRow(pr: $0).tag(DetailSelection.pullRequest($0.id)) }
                    }
                }
                if filters.state != .open, !merged.isEmpty {
                    Section(header: SectionHeader(title: "Merged in the last \(workload.snapshot.lookbackDays) days", count: merged.count)) {
                        ForEach(merged) { PullRequestRow(pr: $0).tag(DetailSelection.pullRequest($0.id)) }
                    }
                }
            }
        }
    }

    private func bar(_ filters: PullRequestFilters, pool: [PullRequest]) -> some View {
        HStack(spacing: 8) {
            FilterSearchField(text: stored.projectedValue.search, prompt: "Title, number, person or repo")
            ForEach(PullRequestFilters.Key.allCases, id: \.self) { menu($0, filters: filters, pool: pool) }
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
        let candidates = pool.filter { filters.matches($0, except: key) }
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
