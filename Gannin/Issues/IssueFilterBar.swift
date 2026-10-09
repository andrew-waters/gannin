import SwiftUI

/// What the issue pages narrow their issues by: open or closed, a search,
/// and assignees, repositories, labels, board field values and milestones
/// (several of each, any matching; across board fields, every field
/// matching).
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
        case milestone = "Milestone"
    }

    /// Assignee values: a login, or these.
    static let unassigned = ""
    static let anyoneAssigned = "*"
    /// The milestone value for issues in none.
    static let noMilestone = ""
    /// Board field values are kept as the field's name and the value, split
    /// by a tab; an empty value is an issue with none on any board.
    static func fieldValue(_ field: String, _ value: String) -> String { "\(field)\t\(value)" }
    static func field(of picked: String) -> (field: String, value: String) {
        let parts = picked.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }

    /// The values an issue has for a board field, by name, across its
    /// boards; only fields picked from options (single select, multi select,
    /// iteration) are offered as filters.
    static func choices(_ issue: IssueRecord, field: String) -> [String] {
        issue.projectFields.flatMap { board in board.values[field].flatMap(choices) ?? [] }
    }

    static func choices(_ value: IssueFieldValue) -> [String]? {
        switch value {
        case .option(let name, _): [name]
        case .options(let names): names
        case .iteration(let title, _): [title]
        case .text, .number, .date: nil
        }
    }

    var state: State = .open
    var search = ""
    var assignees: Set<String> = []
    var repositories: Set<String> = []
    var labels: Set<String> = []
    var milestones: Set<String> = []
    /// `fieldValue(_:_:)`s.
    var fields: Set<String> = []

    var isNarrowed: Bool { !search.isEmpty || !assignees.isEmpty || !repositories.isEmpty || !labels.isEmpty || !milestones.isEmpty || !fields.isEmpty }

    func values(_ key: Key) -> Set<String> {
        switch key {
        case .assignee: assignees
        case .repository: repositories
        case .label: labels
        case .milestone: milestones
        }
    }

    mutating func set(_ key: Key, _ values: Set<String>) {
        switch key {
        case .assignee: assignees = values
        case .repository: repositories = values
        case .label: labels = values
        case .milestone: milestones = values
        }
    }

    func inState(_ issue: IssueRecord) -> Bool {
        switch state {
        case .open: issue.isOpen
        case .closed: !issue.isOpen
        case .all: true
        }
    }

    /// Everything but the state, less `key` or the board field `exceptField`
    /// (so a menu counts what picking among its values would give).
    func matches(_ issue: IssueRecord, except key: Key? = nil, exceptField: String? = nil, names: (String) -> String) -> Bool {
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
        if key != .milestone, !milestones.isEmpty, !milestones.contains(issue.milestone ?? Self.noMilestone) { return false }
        for (field, picks) in Dictionary(grouping: fields.map { Self.field(of: $0) }, by: { $0.field }) where field != exceptField {
            let have = Self.choices(issue, field: field)
            if !picks.contains(where: { $0.value.isEmpty ? have.isEmpty : have.contains($0.value) }) { return false }
        }
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
    @SceneStorage private var milestones: String
    @SceneStorage private var fields: String
    @State private var search = ""

    init(_ prefix: String) {
        _state = SceneStorage(wrappedValue: .open, "\(prefix).state")
        _assignees = SceneStorage(wrappedValue: "", "\(prefix).assignees")
        _repositories = SceneStorage(wrappedValue: "", "\(prefix).repositories")
        _labels = SceneStorage(wrappedValue: "", "\(prefix).labels")
        _milestones = SceneStorage(wrappedValue: "", "\(prefix).milestones")
        _fields = SceneStorage(wrappedValue: "", "\(prefix).fields")
    }

    var wrappedValue: IssueFilters {
        get {
            IssueFilters(state: state, search: search, assignees: StoredSet.set(assignees), repositories: StoredSet.set(repositories), labels: StoredSet.set(labels), milestones: StoredSet.set(milestones), fields: StoredSet.set(fields))
        }
        nonmutating set {
            state = newValue.state
            search = newValue.search
            assignees = StoredSet.string(newValue.assignees)
            repositories = StoredSet.string(newValue.repositories)
            labels = StoredSet.string(newValue.labels)
            milestones = StoredSet.string(newValue.milestones)
            fields = StoredSet.string(newValue.fields)
        }
    }

    var projectedValue: Binding<IssueFilters> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// A row at the top of an issue page, as the Views page has: search, then
/// Assignee (Me first), Repository, Label, Field (the issues' board fields,
/// once any has one) and Milestone (once any issue has one) as menus of the values the page's issues have, with counts, and
/// Clear All. `leading` goes first
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
            ForEach(keys, id: \.self) { key in
                menu(key)
                if key == .label { fieldMenu }
            }
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

    private var keys: [IssueFilters.Key] {
        let hasMilestones = !filters.milestones.isEmpty || pool.contains { $0.milestone != nil }
        return IssueFilters.Key.allCases.filter { $0 != .milestone || hasMilestones }
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
            case .milestone: counts[issue.milestone ?? IssueFilters.noMilestone, default: 0] += 1
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
        if key == .milestone {
            leading.append(FilterOption(value: IssueFilters.noMilestone, title: "No Milestone", count: counts[IssueFilters.noMilestone] ?? 0))
        }
        let options = counts.keys.filter { key == .assignee ? !special.contains($0) : key != .milestone || $0 != IssueFilters.noMilestone }
            .map { FilterOption(value: $0, title: title($0, key: key), count: counts[$0] ?? 0) }
            .sorted(byCount: key == .assignee)
        return FilterMenu(
            title: key.rawValue, leading: leading, options: options,
            picked: Binding(get: { filters.values(key) }, set: { filters.set(key, $0) })
        )
    }

    /// Board fields picked from options that the page's issues have, or
    /// that are picked, by name (a field on several boards is one).
    private var fieldNames: [String] {
        var names = Set(filters.fields.map { IssueFilters.field(of: $0).field })
        for issue in pool {
            for board in issue.projectFields {
                for (name, value) in board.values where IssueFilters.choices(value) != nil { names.insert(name) }
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Field, a submenu per board field with its values (in the board's
    /// order) and No value, each with counts.
    @ViewBuilder private var fieldMenu: some View {
        let names = fieldNames
        if !names.isEmpty {
            let picked = filters.fields
            Menu {
                ForEach(names, id: \.self) { name in
                    let count = picked.filter { IssueFilters.field(of: $0).field == name }.count
                    Menu(count == 0 ? name : "\(name) (\(count) picked)") { fieldValues(name) }
                }
                if !picked.isEmpty {
                    Divider()
                    Button("Clear") { filters.fields = [] }
                }
            } label: {
                Text(picked.isEmpty ? "Field" : fieldSummary())
                    .lineLimit(1)
            }
            .fixedSize()
            .tint(picked.isEmpty ? nil : .accentColor)
            .help(picked.isEmpty ? "Only issues with some values of a board field" : "Only issues where \(fieldSummary(limit: 10))")
        }
    }

    @ViewBuilder private func fieldValues(_ name: String) -> some View {
        let tally = fieldTally(name)
        fieldToggle(name, value: "", title: "No \(name) (\(tally.none))")
        if !tally.values.isEmpty { Divider() }
        ForEach(tally.values, id: \.self) { value in
            fieldToggle(name, value: value, title: "\(value) (\(tally.counts[value] ?? 0))")
        }
    }

    /// A board field's values among the issues the other filters leave, in
    /// the board's order (options by position, iterations by start), with
    /// how many have each and how many have none.
    private func fieldTally(_ name: String) -> (values: [String], counts: [String: Int], none: Int) {
        var counts: [String: Int] = [:]
        var order: [String: IssueFieldValue] = [:]
        var none = 0
        for issue in pool where filters.matches(issue, exceptField: name, names: names) {
            var have = Set<String>()
            for board in issue.projectFields {
                guard let value = board.values[name], let choices = IssueFilters.choices(value) else { continue }
                for choice in choices {
                    have.insert(choice)
                    if order[choice] == nil { order[choice] = value }
                }
            }
            for choice in have { counts[choice, default: 0] += 1 }
            if have.isEmpty { none += 1 }
        }
        let picked = filters.fields.map { IssueFilters.field(of: $0) }.filter { $0.field == name && !$0.value.isEmpty }.map { $0.value }
        let values = Set(counts.keys).union(picked).sorted { a, b in
            switch (order[a], order[b]) {
            case (.option(_, let x)?, .option(_, let y)?): x < y
            case (.iteration(_, let x)?, .iteration(_, let y)?): x < y
            default: a.localizedStandardCompare(b) == .orderedAscending
            }
        }
        return (values, counts, none)
    }

    private func fieldToggle(_ name: String, value: String, title: String) -> some View {
        let key = IssueFilters.fieldValue(name, value)
        return Toggle(title, isOn: Binding {
            filters.fields.contains(key)
        } set: { isOn in
            if isOn { filters.fields.insert(key) } else { filters.fields.remove(key) }
        })
    }

    /// "Status: In Progress, Done", or with several fields "Status: Done;
    /// Priority: P1", cut short past `limit` values.
    private func fieldSummary(limit: Int = 2) -> String {
        let byField = Dictionary(grouping: filters.fields.map { IssueFilters.field(of: $0) }, by: { $0.field })
        var shown = 0
        var parts: [String] = []
        for field in byField.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let values = byField[field, default: []].map { $0.value.isEmpty ? "none" : $0.value }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let room = max(limit - shown, 0)
            guard room > 0 else { break }
            parts.append("\(field): \(values.prefix(room).joined(separator: ", "))")
            shown += min(values.count, room)
        }
        let more = filters.fields.count - shown
        return more > 0 ? "\(parts.joined(separator: "; ")) and \(more) more" : parts.joined(separator: "; ")
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
        case .milestone: value == IssueFilters.noMilestone ? "No Milestone" : value
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

    /// "Me, Sam Lee", or "Me and 3 more".
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
    /// Whether it stretches across the space it's given, rather than the
    /// bars' usual 200 points.
    var fills = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .frame(minWidth: fills ? 80 : 200, maxWidth: fills ? .infinity : 200)
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
