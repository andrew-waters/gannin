import SwiftUI

/// What the issue pages narrow their issues by: open or closed, a search,
/// and assignees, repositories and labels (several of each, any matching).
/// Kept per window, as newline-joined strings in scene storage.
struct IssueFilters {
    enum State: String, CaseIterable {
        case open = "Open"
        case closed = "Closed"
        case all = "All"
    }

    enum Key: String, CaseIterable {
        case assignee = "Assignee"
        case repository = "Repository"
        case label = "Label"
    }

    /// Assignee values: a login, or these.
    static let unassigned = ""
    static let anyoneAssigned = "*"

    var state: State = .open
    var search = ""
    var assignees: Set<String> = []
    var repositories: Set<String> = []
    var labels: Set<String> = []

    var isNarrowed: Bool { !search.isEmpty || !assignees.isEmpty || !repositories.isEmpty || !labels.isEmpty }

    func values(_ key: Key) -> Set<String> {
        switch key {
        case .assignee: assignees
        case .repository: repositories
        case .label: labels
        }
    }

    mutating func set(_ key: Key, _ values: Set<String>) {
        switch key {
        case .assignee: assignees = values
        case .repository: repositories = values
        case .label: labels = values
        }
    }

    func inState(_ issue: IssueRecord) -> Bool {
        switch state {
        case .open: issue.isOpen
        case .closed: !issue.isOpen
        case .all: true
        }
    }

    /// Everything but the state, less `key` (so a menu counts what picking
    /// among its values would give).
    func matches(_ issue: IssueRecord, except key: Key? = nil, names: (String) -> String) -> Bool {
        if key != .assignee, !assignees.isEmpty {
            let hit = assignees.contains { value in
                switch value {
                case Self.unassigned: issue.assignees.isEmpty
                case Self.anyoneAssigned: !issue.assignees.isEmpty
                default: issue.assignees.contains(value)
                }
            }
            if !hit { return false }
        }
        if key != .repository, !repositories.isEmpty, !repositories.contains(issue.repo) { return false }
        if key != .label, !labels.isEmpty, !issue.labels.contains(where: labels.contains) { return false }
        return IssueSearch.matches(search, title: issue.title, repo: issue.repo, number: issue.number,
                                   people: issue.assignees + issue.assignees.map(names) + [issue.author].compactMap { $0 },
                                   labels: issue.labels)
    }
}

/// Scene storage for `IssueFilters`, under a page's own prefix.
struct StoredIssueFilters: DynamicProperty {
    @SceneStorage private var state: IssueFilters.State
    @SceneStorage private var assignees: String
    @SceneStorage private var repositories: String
    @SceneStorage private var labels: String
    @State private var search = ""

    init(_ prefix: String) {
        _state = SceneStorage(wrappedValue: .open, "\(prefix).state")
        _assignees = SceneStorage(wrappedValue: "", "\(prefix).assignees")
        _repositories = SceneStorage(wrappedValue: "", "\(prefix).repositories")
        _labels = SceneStorage(wrappedValue: "", "\(prefix).labels")
    }

    var wrappedValue: IssueFilters {
        get {
            IssueFilters(state: state, search: search, assignees: Self.set(assignees), repositories: Self.set(repositories), labels: Self.set(labels))
        }
        nonmutating set {
            state = newValue.state
            search = newValue.search
            assignees = Self.string(newValue.assignees)
            repositories = Self.string(newValue.repositories)
            labels = Self.string(newValue.labels)
        }
    }

    var projectedValue: Binding<IssueFilters> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }

    // The unassigned value is empty, so an empty string is no values.
    private static func set(_ text: String) -> Set<String> {
        text.isEmpty ? [] : Set(text.components(separatedBy: "\n").map { $0 == "\u{1}" ? IssueFilters.unassigned : $0 })
    }

    private static func string(_ values: Set<String>) -> String {
        values.map { $0.isEmpty ? "\u{1}" : $0 }.sorted().joined(separator: "\n")
    }
}

/// A row at the top of an issue page, as the Views page has: search, then
/// Assignee (Me first), Repository and Label as menus of the values the
/// page's issues have, with counts, and Clear All. `leading` goes first
/// (a page's own pickers); the state control sits at the end.
struct IssueFilterBar<Leading: View>: View {
    @Environment(AuthStore.self) private var auth
    @Binding var filters: IssueFilters
    /// The page's issues in the state picked, before these filters.
    let pool: [IssueRecord]
    let names: (String) -> String
    var showsState = true
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 8) {
            leading
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $filters.search, prompt: Text("Title, number, person or label"))
                    .textFieldStyle(.plain)
                    .frame(width: 200)
                if !filters.search.isEmpty {
                    Button { filters.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.7), in: Capsule())
            ForEach(IssueFilters.Key.allCases, id: \.self) { menu($0) }
            Spacer(minLength: 0)
            if filters.isNarrowed {
                Button("Clear All") {
                    let state = filters.state
                    filters = IssueFilters(state: state)
                }
                .linkButton()
            }
            if showsState {
                Picker("State", selection: $filters.state) {
                    ForEach(IssueFilters.State.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func menu(_ key: IssueFilters.Key) -> some View {
        let candidates = pool.filter { filters.matches($0, except: key, names: names) }
        var counts: [String: Int] = [:]
        for issue in candidates {
            switch key {
            case .assignee:
                if issue.assignees.isEmpty { counts[IssueFilters.unassigned, default: 0] += 1 } else { counts[IssueFilters.anyoneAssigned, default: 0] += 1 }
                for login in Set(issue.assignees) { counts[login, default: 0] += 1 }
            case .repository: counts[issue.repo, default: 0] += 1
            case .label: for label in Set(issue.labels) { counts[label, default: 0] += 1 }
            }
        }
        let special: Set<String> = [IssueFilters.unassigned, IssueFilters.anyoneAssigned]
        let values = counts.keys.filter { key != .assignee || !special.contains($0) }.sorted { a, b in
            key == .assignee ? (counts[a] ?? 0, title(b, key: key)) > (counts[b] ?? 0, title(a, key: key)) : title(a, key: key).localizedStandardCompare(title(b, key: key)) == .orderedAscending
        }
        let picked = filters.values(key)
        let me = auth.viewer?.login
        return Menu {
            if key == .assignee {
                if let me { Toggle("Me (\(counts[me] ?? 0))", isOn: binding(key, me)) }
                Toggle("Anyone Assigned (\(counts[IssueFilters.anyoneAssigned] ?? 0))", isOn: binding(key, IssueFilters.anyoneAssigned))
                Toggle("Unassigned (\(counts[IssueFilters.unassigned] ?? 0))", isOn: binding(key, IssueFilters.unassigned))
                Divider()
            }
            ForEach(values.filter { key != .assignee || $0 != me }, id: \.self) { value in
                Toggle("\(title(value, key: key)) (\(counts[value] ?? 0))", isOn: binding(key, value))
            }
            if !picked.isEmpty {
                Divider()
                Button("Clear") { filters.set(key, []) }
            }
        } label: {
            Text(picked.isEmpty ? key.rawValue : "\(key.rawValue): \(summary(picked, key: key))")
                .lineLimit(1)
        }
        .fixedSize()
        .tint(picked.isEmpty ? nil : .accentColor)
        .help(picked.isEmpty ? "Only issues with some values of \(key.rawValue)" : "Only issues where \(key.rawValue) is \(summary(picked, key: key, limit: 10))")
    }

    private func title(_ value: String, key: IssueFilters.Key) -> String {
        switch key {
        case .assignee:
            switch value {
            case IssueFilters.unassigned: "Unassigned"
            case IssueFilters.anyoneAssigned: "Anyone assigned"
            case auth.viewer?.login: "Me"
            default: names(value)
            }
        case .repository: value.split(separator: "/").last.map(String.init) ?? value
        case .label: value
        }
    }

    /// "Me, Ian Wood", or "Me and 3 more".
    private func summary(_ values: Set<String>, key: IssueFilters.Key, limit: Int = 2) -> String {
        let titles = values.map { title($0, key: key) }
            .sorted { a, b in a == "Me" ? true : b == "Me" ? false : a.localizedStandardCompare(b) == .orderedAscending }
        return titles.count > limit ? "\(titles.prefix(limit).joined(separator: ", ")) and \(titles.count - limit) more" : titles.joined(separator: ", ")
    }

    private func binding(_ key: IssueFilters.Key, _ value: String) -> Binding<Bool> {
        Binding {
            filters.values(key).contains(value)
        } set: { isOn in
            var values = filters.values(key)
            if isOn { values.insert(value) } else { values.remove(value) }
            filters.set(key, values)
        }
    }
}

extension IssueFilterBar where Leading == EmptyView {
    init(filters: Binding<IssueFilters>, pool: [IssueRecord], names: @escaping (String) -> String, showsState: Bool = true) {
        self.init(filters: filters, pool: pool, names: names, showsState: showsState) { EmptyView() }
    }
}
