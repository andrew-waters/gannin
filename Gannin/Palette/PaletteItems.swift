import SwiftUI

// The command palette's results: everything Gannin has cached for every
// org (pages, settings, people, PRs, issues, harness documents, boards,
// views, repos and Claude Code sessions) and the actions it can run, each a
// `PaletteItem`, ranked against what's typed. Nothing here fetches.

// MARK: - Where a result goes

/// What a result opens in a main window.
enum PaletteTarget: Hashable {
    case sidebar(SidebarItem)
    /// A PR or issue, in a drawer over the page.
    case page(DetailSelection)
    /// A harness document, by its harness and its path there, in a drawer.
    case harnessDocument(repo: String, path: String, kind: HarnessKind)
    case settings(OrgSettingsView.Pane)
    /// The window's project; nil for All.
    case project(String)
    case newIssue
    /// The org alone, as the switcher picks it.
    case org

    /// The page a new window or tab opens on, under any drawer.
    var rootSidebar: SidebarItem {
        switch self {
        case .sidebar(let item):
            item
        case .page(.pullRequest), .page(.pullRequestReference):
            .tab(.pullRequests)
        case .page:
            .issueList(.all)
        case .harnessDocument(_, _, let kind):
            .harnessKind(kind)
        case .settings:
            .tab(.settings)
        case .project, .newIssue, .org:
            .tab(.inbox)
        }
    }
}

/// A result's org and what it opens there.
struct PaletteDestination: Hashable {
    let org: String
    let target: PaletteTarget
}

/// How a result is opened: in this main window (switching its org when it's
/// another one), or in a new tab or window.
enum PalettePlacement {
    case thisWindow
    case newTab
    case newWindow
}

/// What an action does that isn't going somewhere in a main window.
enum PaletteCommand: Hashable {
    case refresh(org: String, full: Bool)
    case newWindow
    case newTab
    case openClaudeCode
    case nextSessionWaiting
    /// Flips a Bool preference (`excludeDrafts`, `showHidden`).
    case toggle(key: String)
    case session(UUID)
}

enum PaletteAction: Hashable {
    case go(PaletteDestination)
    case run(PaletteCommand)
}

// MARK: - Items

/// The palette's groups, in the order they're listed.
enum PaletteGroup: Int, CaseIterable, Comparable {
    case recent
    case actions
    case pages
    case people
    case pullRequests
    case issues
    case harness
    case boards
    case repositories
    case sessions
    /// Issues whose description or comments match, from `IssueTextIndex`.
    case descriptions

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .actions: "Actions"
        case .pages: "Pages"
        case .people: "People"
        case .pullRequests: "Pull Requests"
        case .issues: "Issues"
        case .harness: "Harness"
        case .boards: "Boards and Views"
        case .repositories: "Repositories"
        case .sessions: "Claude Code Sessions"
        case .descriptions: "In Descriptions"
        }
    }

    /// What one result is, shown on its row and read out by VoiceOver.
    var noun: String {
        switch self {
        case .recent: "Recent"
        case .actions: "Action"
        case .pages: "Page"
        case .people: "Person"
        case .pullRequests: "Pull request"
        case .issues, .descriptions: "Issue"
        case .harness: "Document"
        case .boards: "Board"
        case .repositories: "Repository"
        case .sessions: "Session"
        }
    }
}

/// One result: a thing to go to or an action to run.
struct PaletteItem: Identifiable, Hashable {
    /// Stable across launches, for the recent items.
    let id: String
    var group: PaletteGroup
    let title: String
    /// Shown after the title: a PR's `repo#123`, a document's summary.
    var detail: String?
    let systemImage: String
    /// The org it's in; nil for actions that aren't an org's.
    var org: String?
    var number: Int?
    var repo: String?
    /// Open items rank above closed ones.
    var isOpen = true
    let action: PaletteAction
    /// Lower-cased, for matching.
    let searchTitle: String
    let searchText: String
    /// What the row is when its group doesn't say (a recent item).
    var noun: String

    init(id: String, group: PaletteGroup, title: String, detail: String? = nil, systemImage: String, org: String?,
         number: Int? = nil, repo: String? = nil, isOpen: Bool = true, keywords: [String] = [], action: PaletteAction) {
        self.id = id
        self.group = group
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.org = org
        self.number = number
        self.repo = repo
        self.isOpen = isOpen
        self.action = action
        noun = group.noun
        searchTitle = title.lowercased()
        let numbers = number.map { ["#\($0)", "\($0)"] } ?? []
        searchText = ([title, detail ?? "", repo ?? "", org ?? ""] + numbers + keywords).joined(separator: " ").lowercased()
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.group == rhs.group }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Matching

/// What's typed, ready to match: every word must be found, and `#123`,
/// `123` or `repo#123` also finds that number.
struct PaletteQuery {
    let text: String
    let words: [String]
    let number: Int?
    let repo: String?

    init(_ raw: String) {
        text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 1, let hash = text.lastIndex(of: "#") ?? (Int(text) != nil ? text.startIndex : nil) {
            let digits = text[hash...].drop { $0 == "#" }
            number = Int(digits)
            let before = text[..<hash]
            repo = before.isEmpty ? nil : String(before)
        } else {
            number = nil
            repo = nil
        }
    }

    var isEmpty: Bool { words.isEmpty }

    /// Lower is better; nil doesn't match. The exact number first, then a
    /// title starting with what's typed, then a word in it starting with the
    /// first word, then a match anywhere.
    func rank(_ item: PaletteItem) -> Int? {
        if let number, item.number == number {
            if let repo {
                if let itemRepo = item.repo?.lowercased(), itemRepo == repo || itemRepo.hasSuffix("/" + repo) { return 0 }
            } else {
                return 0
            }
        }
        guard words.allSatisfy({ item.searchText.contains($0) }) else { return nil }
        if item.searchTitle.hasPrefix(text) { return 1 }
        if let first = words.first, item.searchTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(first) }) {
            return 2
        }
        return 3
    }
}

extension Array where Element == PaletteItem {
    /// The items matching `query`, best first: rank, then the window's own
    /// org, then open before closed, then shorter titles.
    func ranked(_ query: PaletteQuery, homeOrg: String?) -> [PaletteItem] {
        compactMap { item in query.rank(item).map { (item, $0) } }
            .sorted { lhs, rhs in
                let left = (lhs.1, lhs.0.org == homeOrg ? 0 : 1, lhs.0.isOpen ? 0 : 1, lhs.0.title.count)
                let right = (rhs.1, rhs.0.org == homeOrg ? 0 : 1, rhs.0.isOpen ? 0 : 1, rhs.0.title.count)
                return left < right
            }
            .map(\.0)
    }
}

// MARK: - Recent items

/// The results picked lately, by ID, newest first, on this Mac.
enum PaletteRecents {
    private static let key = "commandPaletteRecents"
    private static let limit = 40

    static var ids: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ id: String) {
        var ids = ids.filter { $0 != id }
        ids.insert(id, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(limit)), forKey: key)
    }

    /// Up to `count` of them still found among `items`: the window's org's
    /// first, then other orgs' (and actions), each newest first.
    static func items(from items: [String: PaletteItem], homeOrg: String?, count: Int = 8) -> [PaletteItem] {
        let found = ids.compactMap { items[$0] }
        let home = found.filter { $0.org != nil && $0.org == homeOrg }
        let others = found.filter { $0.org == nil || $0.org != homeOrg }
        return (home + others).prefix(count).map { item in
            var recent = item
            recent.group = .recent
            return recent
        }
    }
}

// MARK: - Building them

/// Every item, from what the stores have cached. Built when the palette
/// opens; the stores are read once.
struct PaletteSources {
    let orgs: OrgStore
    let issues: IssueStore
    let projects: ProjectStore
    let harness: HarnessStore
    /// The app's settings, with no project laid over them: the palette
    /// searches everything.
    let configs: OrgConfigStore
    let sessions: SessionStore

    /// Pulls each org's snapshot and board list from disk, where a previous
    /// launch saved them. Nothing is fetched.
    func loadSnapshots() {
        for org in orgs.orgs {
            orgs.loadCached(org.login)
            projects.loadCachedBoards(org.login)
        }
    }

    /// Orgs whose issue history isn't in memory yet, for `IssueStore.loadCached`
    /// one at a time (they're the large ones).
    var orgsWithoutIssueHistory: [String] {
        orgs.orgs.map(\.login).filter { issues.history(for: $0) == nil }
    }

    /// Orgs with neither a snapshot nor an issue history cached.
    var unloadedOrgs: [Organisation] {
        orgs.orgs.filter { orgs.snapshot(for: $0.login) == nil && issues.history(for: $0.login) == nil }
    }

    func items() -> [PaletteItem] {
        var items = globalActions()
        for org in orgs.orgs {
            items += orgItems(org.login, name: org.displayName)
        }
        items += sessionItems()
        return items
    }

    private func globalActions() -> [PaletteItem] {
        let defaults = UserDefaults.standard
        var items = [
            PaletteItem(id: "action:new-window", group: .actions, title: "New Window", systemImage: "macwindow", org: nil, action: .run(.newWindow)),
            PaletteItem(id: "action:new-tab", group: .actions, title: "New Tab", systemImage: "plus.square.on.square", org: nil, action: .run(.newTab)),
            PaletteItem(id: "action:claude-code", group: .actions, title: "Open Claude Code", systemImage: "terminal", org: nil, keywords: ["sessions", "agents"], action: .run(.openClaudeCode)),
            PaletteItem(
                id: "action:exclude-drafts", group: .actions,
                title: defaults.bool(forKey: "excludeDrafts") ? "Include Draft Pull Requests" : "Exclude Draft Pull Requests",
                systemImage: "pencil.slash", org: nil, keywords: ["drafts", "toggle"], action: .run(.toggle(key: "excludeDrafts"))
            ),
            PaletteItem(
                id: "action:show-hidden", group: .actions,
                title: defaults.bool(forKey: "showHidden") ? "Stop Showing Hidden Items" : "Show Hidden Items",
                systemImage: "eye", org: nil, keywords: ["hidden", "toggle"], action: .run(.toggle(key: "showHidden"))
            ),
        ]
        if sessions.nextWaiting != nil {
            items.append(PaletteItem(id: "action:next-waiting", group: .actions, title: "Next Session Waiting on You", systemImage: "questionmark.bubble", org: nil, keywords: ["claude", "agent"], action: .run(.nextSessionWaiting)))
        }
        return items
    }

    private func orgItems(_ org: String, name: String) -> [PaletteItem] {
        let config = configs.config(for: org)
        let snapshot = orgs.snapshot(for: org)
        let history = issues.history(for: org)
        var items: [PaletteItem] = []

        func go(_ target: PaletteTarget) -> PaletteAction { .go(PaletteDestination(org: org, target: target)) }

        // Actions.
        items.append(PaletteItem(id: "action:\(org):new-issue", group: .actions, title: "New Issue", systemImage: "square.and.pencil", org: org, keywords: ["create", "write"], action: go(.newIssue)))
        items.append(PaletteItem(id: "action:\(org):refresh", group: .actions, title: "Refresh", systemImage: "arrow.clockwise", org: org, keywords: ["sync"], action: .run(.refresh(org: org, full: false))))
        items.append(PaletteItem(id: "action:\(org):full-refresh", group: .actions, title: "Full Refresh", systemImage: "arrow.clockwise.circle", org: org, keywords: ["sync"], action: .run(.refresh(org: org, full: true))))
        items.append(PaletteItem(id: "action:\(org):switch", group: .actions, title: "Switch to \(name)", systemImage: "building.2", org: org, keywords: ["organisation", "organization", "org"], action: go(.org)))
        if config.repoProjects.count > 1 {
            for project in config.repoProjects {
                items.append(PaletteItem(id: "action:\(org):project:\(project.id)", group: .actions, title: "Switch to Project \(project.name)", systemImage: "square.stack", org: org, keywords: ["project"], action: go(.project(project.id))))
            }
        }

        // Pages, as the sidebar lists them.
        for tab in WorkloadTab.allCases where tab != .harness {
            items.append(PaletteItem(id: "page:\(org):\(tab.rawValue)", group: .pages, title: tab.title, systemImage: tab.systemImage, org: org, keywords: [tab.rawValue], action: go(.sidebar(.tab(tab)))))
        }
        for list in IssueList.allCases {
            items.append(PaletteItem(id: "page:\(org):issues:\(list.rawValue)", group: .pages, title: list.title, systemImage: list.systemImage, org: org, action: go(.sidebar(.issueList(list)))))
        }
        for view in PeopleView.allCases {
            items.append(PaletteItem(id: "page:\(org):people:\(view.rawValue)", group: .pages, title: view.rawValue, systemImage: view.systemImage, org: org, keywords: ["people"], action: go(.sidebar(.peopleView(view)))))
        }
        if !config.allHarnesses.isEmpty {
            for kind in HarnessKind.allCases {
                items.append(PaletteItem(id: "page:\(org):harness:\(kind.rawValue)", group: .pages, title: kind.rawValue, systemImage: kind.systemImage, org: org, keywords: ["harness"], action: go(.sidebar(.harnessKind(kind)))))
            }
        }
        for pane in OrgSettingsView.Pane.allCases {
            items.append(PaletteItem(id: "settings:\(org):\(pane.rawValue)", group: .pages, title: "Settings › \(pane.rawValue)", systemImage: "gearshape", org: org, keywords: ["settings", "preferences"], action: go(.settings(pane))))
        }

        // Boards and views.
        for board in projects.boardLists[org] ?? [] {
            items.append(PaletteItem(id: "board:\(org):\(board.number)", group: .boards, title: board.title, detail: "Board", systemImage: "rectangle.split.3x1", org: org, number: board.number, action: go(.sidebar(.project(board.number)))))
        }
        for view in config.fieldViews {
            items.append(PaletteItem(id: "view:\(org):\(view.id)", group: .boards, title: view.name, detail: "View", systemImage: "square.grid.3x3", org: org, action: go(.sidebar(.fieldView(view.id)))))
        }

        // People.
        for person in snapshot?.members ?? [] {
            items.append(PaletteItem(
                id: "person:\(org):\(person.login)", group: .people, title: person.displayName,
                detail: person.name?.isEmpty == false ? "@\(person.login)" : nil,
                systemImage: "person", org: org, keywords: [person.login], action: go(.sidebar(.person(person.login)))
            ))
        }

        // Pull requests, open and merged in the lookback.
        var repos: Set<String> = []
        for pr in (snapshot?.openPullRequests ?? []) + (snapshot?.mergedPullRequests ?? []) {
            repos.insert(pr.repo)
            let reference = PullRequestReference(org: org, id: pr.id, number: pr.number, title: pr.title, repo: pr.repo, url: pr.url)
            let isOpen = pr.state == "OPEN"
            items.append(PaletteItem(
                id: "pr:\(pr.id)", group: .pullRequests, title: pr.title, detail: "\(pr.repo)#\(pr.number)",
                systemImage: isOpen ? "arrow.triangle.pull" : "arrow.triangle.merge", org: org, number: pr.number, repo: pr.repo,
                isOpen: isOpen, keywords: [pr.author?.login, pr.author?.name].compactMap { $0 },
                action: go(.page(.pullRequestReference(reference)))
            ))
        }

        // Issues: the issue history, and open ones in the snapshot it hasn't got.
        var seen: Set<String> = []
        for record in history?.issues.values.map({ $0 }) ?? [] {
            seen.insert(record.id)
            repos.insert(record.repo)
            items.append(PaletteItem(
                id: "issue:\(record.id)", group: .issues, title: record.title, detail: "\(record.repo)#\(record.number)",
                systemImage: record.closedAt == nil ? "smallcircle.filled.circle" : "checkmark.circle", org: org,
                number: record.number, repo: record.repo, isOpen: record.closedAt == nil,
                keywords: record.assignees + record.labels + [record.author].compactMap { $0 },
                action: go(.page(.issueReference(IssueReference(org: org, record: record))))
            ))
        }
        for issue in snapshot?.issues ?? [] where !seen.contains(issue.id) {
            repos.insert(issue.repo)
            let reference = IssueReference(org: org, id: issue.id, number: issue.number, title: issue.title, repo: issue.repo, url: issue.url)
            items.append(PaletteItem(
                id: "issue:\(issue.id)", group: .issues, title: issue.title, detail: "\(issue.repo)#\(issue.number)",
                systemImage: issue.state == "OPEN" ? "smallcircle.filled.circle" : "checkmark.circle", org: org,
                number: issue.number, repo: issue.repo, isOpen: issue.state == "OPEN",
                keywords: [issue.author?.login].compactMap { $0 }, action: go(.page(.issueReference(reference)))
            ))
        }

        // Repositories with anything synced.
        for repo in repos.sorted() {
            items.append(PaletteItem(id: "repo:\(repo)", group: .repositories, title: repo.split(separator: "/").last.map(String.init) ?? repo, detail: repo, systemImage: "folder", org: org, action: go(.sidebar(.repository(repo)))))
        }

        // Harness documents that follow the standard, from every harness.
        for setup in config.allHarnesses {
            for document in harness.index(for: org, setup)?.documents ?? [] where document.followsStandard {
                items.append(PaletteItem(
                    id: "doc:\(org):\(setup.repo):\(document.path)", group: .harness, title: document.title, detail: document.summary,
                    systemImage: document.kind.systemImage, org: org, isOpen: document.statusLabel != "Done",
                    keywords: [document.path, document.kind.rawValue] + (document.domains ?? []),
                    action: go(.harnessDocument(repo: setup.repo, path: document.path, kind: document.kind))
                ))
            }
        }
        return items
    }

    private func sessionItems() -> [PaletteItem] {
        sessions.sessions.values.map { session in
            PaletteItem(
                id: "session:\(session.id)", group: .sessions, title: session.title, detail: session.issue.reference,
                systemImage: session.isPullRequestReview ? "checkmark.bubble" : "terminal", org: session.org,
                number: session.issue.number, repo: session.issue.repo, isOpen: session.archivedAt == nil,
                keywords: [session.branch], action: .run(.session(session.id))
            )
        }
    }

    /// Issues whose description or comments match, from the full-text index,
    /// as rows for "In Descriptions", leaving out those already listed.
    static func descriptionItems(_ query: String, orgs: [String], issues: IssueStore, excluding: Set<String>) async -> [PaletteItem] {
        var items: [PaletteItem] = []
        for org in orgs {
            for hit in await IssueTextIndex.shared.search(org: org, text: query, limit: 6) where !excluding.contains("issue:\(hit.id)") {
                let record = issues.history(for: org)?.issues[hit.id]
                guard let url = record?.url ?? URL(string: "https://github.com/\(hit.repo)/issues/\(hit.number)") else { continue }
                let reference = IssueReference(org: org, id: hit.id, number: hit.number, title: hit.title, repo: hit.repo, url: url)
                items.append(PaletteItem(
                    id: "issue:\(hit.id)", group: .descriptions, title: hit.title,
                    detail: hit.snippet.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").replacingOccurrences(of: "\n", with: " "),
                    systemImage: "text.magnifyingglass", org: org, number: hit.number, repo: hit.repo,
                    isOpen: record.map { $0.closedAt == nil } ?? true, action: .go(PaletteDestination(org: org, target: .page(.issueReference(reference))))
                ))
            }
        }
        return items
    }
}
