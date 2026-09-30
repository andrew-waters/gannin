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
            IssueFilters(state: state, search: search, assignees: StoredSet.set(assignees), repositories: StoredSet.set(repositories), labels: StoredSet.set(labels))
        }
        nonmutating set {
            state = newValue.state
            search = newValue.search
            assignees = StoredSet.string(newValue.assignees)
            repositories = StoredSet.string(newValue.repositories)
            labels = StoredSet.string(newValue.labels)
        }
    }

    var projectedValue: Binding<IssueFilters> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
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
            FilterSearchField(text: $filters.search, prompt: "Title, number, person or label")
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
        let me = auth.viewer?.login
        let special: Set<String> = [IssueFilters.unassigned, IssueFilters.anyoneAssigned, me ?? "\u{0}"]
        var leading: [FilterOption] = []
        if key == .assignee {
            if let me { leading.append(FilterOption(value: me, title: "Me", count: counts[me] ?? 0)) }
            leading.append(FilterOption(value: IssueFilters.anyoneAssigned, title: "Anyone Assigned", count: counts[IssueFilters.anyoneAssigned] ?? 0))
            leading.append(FilterOption(value: IssueFilters.unassigned, title: "Unassigned", count: counts[IssueFilters.unassigned] ?? 0))
        }
        let options = counts.keys.filter { key != .assignee || !special.contains($0) }
            .map { FilterOption(value: $0, title: title($0, key: key), count: counts[$0] ?? 0) }
            .sorted(byCount: key == .assignee)
        return FilterMenu(
            title: key.rawValue, leading: leading, options: options,
            picked: Binding(get: { filters.values(key) }, set: { filters.set(key, $0) })
        )
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
}

extension IssueFilterBar where Leading == EmptyView {
    init(filters: Binding<IssueFilters>, pool: [IssueRecord], names: @escaping (String) -> String, showsState: Bool = true) {
        self.init(filters: filters, pool: pool, names: names, showsState: showsState) { EmptyView() }
    }
}

// MARK: - Shared pieces

/// A value a filter menu offers, with how many items it would give.
struct FilterOption: Hashable {
    let value: String
    let title: String
    let count: Int
}

extension [FilterOption] {
    /// People by how many they have, anything else by name.
    func sorted(byCount: Bool) -> [FilterOption] {
        sorted { a, b in
            if byCount, a.count != b.count { return a.count > b.count }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

/// A filter bar's menu, as on Views: the values to tick (any of them
/// matches), those in `leading` first, and Clear. Its label says what's
/// picked, tinted while anything is.
struct FilterMenu: View {
    let title: String
    var leading: [FilterOption] = []
    let options: [FilterOption]
    @Binding var picked: Set<String>

    var body: some View {
        Menu {
            ForEach(leading, id: \.value) { toggle($0) }
            if !leading.isEmpty, !options.isEmpty { Divider() }
            ForEach(options, id: \.value) { toggle($0) }
            if !picked.isEmpty {
                Divider()
                Button("Clear") { picked = [] }
            }
        } label: {
            Text(picked.isEmpty ? title : "\(title): \(summary())")
                .lineLimit(1)
        }
        .fixedSize()
        .tint(picked.isEmpty ? nil : .accentColor)
        .help(picked.isEmpty ? "Only some values of \(title)" : "Only where \(title) is \(summary(limit: 10))")
    }

    private func toggle(_ option: FilterOption) -> some View {
        Toggle("\(option.title) (\(option.count))", isOn: Binding {
            picked.contains(option.value)
        } set: { isOn in
            if isOn { picked.insert(option.value) } else { picked.remove(option.value) }
        })
    }

    /// "Me, Ian Wood", or "Me and 3 more".
    private func summary(limit: Int = 2) -> String {
        let known = Dictionary((leading + options).map { ($0.value, $0.title) }, uniquingKeysWith: { first, _ in first })
        let titles = picked.map { known[$0] ?? $0 }
            .sorted { a, b in a == "Me" ? true : b == "Me" ? false : a.localizedStandardCompare(b) == .orderedAscending }
        return titles.count > limit ? "\(titles.prefix(limit).joined(separator: ", ")) and \(titles.count - limit) more" : titles.joined(separator: ", ")
    }
}

/// The filter bar's search, in a capsule as on Views.
struct FilterSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .frame(width: 200)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.7), in: Capsule())
    }
}

/// Newline-joined values in scene storage, as a set; the empty value is
/// kept as a placeholder, so an empty string is no values.
enum StoredSet {
    static func set(_ text: String) -> Set<String> {
        text.isEmpty ? [] : Set(text.components(separatedBy: "\n").map { $0 == "\u{1}" ? "" : $0 })
    }

    static func string(_ values: Set<String>) -> String {
        values.map { $0.isEmpty ? "\u{1}" : $0 }.sorted().joined(separator: "\n")
    }
}
