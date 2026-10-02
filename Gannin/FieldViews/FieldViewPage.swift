import SwiftUI

/// Changes waiting to be confirmed, for the write sheet.
struct PendingFieldChanges: Identifiable {
    let id = UUID()
    let changes: [FieldChange]
}

/// A saved view: its issues in one of five layouts (Outline, Board, Table,
/// Grid, Aging), each group with its count and the view's measure, each
/// issue with how long it's sat and anything that doesn't add up. Issues
/// can be selected and a board field set on all of them, dragged between
/// the board's columns, or filled in one at a time; every write is
/// confirmed first.
struct FieldViewPage: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(ProjectStore.self) private var projects
    @Environment(HarnessStore.self) private var harness
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @Environment(\.navigate) private var navigate
    @Environment(\.openWindow) private var openWindow
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays

    let org: String
    let id: UUID
    @Binding var selection: DetailSelection?

    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var editing: FieldView?
    @State private var writing: PendingFieldChanges?
    @State private var fillIn: FieldFillIn.Request?
    /// The grid's picked cell: its row and column values.
    @State private var cell: [FieldValue]?
    @State private var editingFields: BoardFieldsRequest?
    /// The org's harness, for the Plan and Requirement fields.
    private var harnessIndex: HarnessIndex? {
        harness.combined(org: org, configs.config(for: org).harnesses)
    }

    /// The issue open in the drawer.
    @State private var inspected: IssueReference?
    /// Titles and numbers, for this window only.
    @State private var search = ""

    var body: some View {
        if let view = configs.fieldView(id, in: org) {
            let context = view.context(workflow: configs.config(for: org).workflow, history: issueStore.history(for: org), harness: harnessIndex)
            let issues = Self.searched(view.issues(in: issueStore.history(for: org), context: context), for: search)
            VStack(spacing: 0) {
                controlBar(view, issues: issues)
                filterBar(view, context: context)
                Divider()
                content(view, issues: issues, context: context)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .trailing) { drawer(context: context, order: navigationOrder(view, issues: issues, context: context)) }
                    .animation(.snappy(duration: 0.25), value: inspected?.id)
            }
            .task(id: view.projectNumber) {
                await projects.loadBoards(org: org)
                if let number = view.projectNumber { await projects.loadDefinition(org: org, number: number) }
            }
            .task(id: org) { await issueStore.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays()) }
            .loadsHarness(org: org)
            .sheet(item: $editing) { draft in
                FieldViewEditor(org: org, view: draft) { saved in
                    configs.saveFieldView(saved, in: org)
                    editing = nil
                } onCancel: {
                    editing = nil
                }
            }
            .sheet(item: $writing) { pending in
                FieldWriteSheet(org: org, changes: pending.changes, board: board(view)) {
                    writing = nil
                    selected = []
                }
            }
            .sheet(item: $fillIn) { request in
                FieldFillIn(org: org, request: request, board: board(view)) {
                    fillIn = nil
                }
            }
            .sheet(item: $editingFields) { request in
                BoardFieldsEditor(org: org, number: request.number) { editingFields = nil }
            }
            .onChange(of: view) { cell = nil }
        } else {
            ContentUnavailableView("No such view", systemImage: WorkloadTab.views.systemImage, description: Text("It was deleted."))
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ view: FieldView, issues: [IssueRecord], context: FieldContext) -> some View {
        let definition = board(view)
        let actions = FieldActions(
            open: open,
            setMenu: { AnyView(setMenu($0, view: view, definition: definition)) },
            propose: { writing = PendingFieldChanges(changes: $0) }
        )
        if view.dimensions.isEmpty {
            ContentUnavailableView {
                Label("Nothing to group by", systemImage: WorkloadTab.views.systemImage)
            } actions: {
                Button("Edit View") { editing = view }
            }
        } else {
            switch view.layout {
            case .outline:
                list(issues, view: view, dimensions: view.dimensions, context: context, definition: definition, heading: nil)
            case .board:
                FieldBoard(issues: issues, view: view, context: context, definition: definition, actions: actions)
            case .table:
                FieldTable(issues: issues, view: view, context: context, selected: $selected, actions: actions)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !selected.isEmpty { selectionBar(issues, view: view, definition: definition) }
                    }
            case .grid where view.dimensions.count >= 2:
                VStack(spacing: 0) {
                    FieldGrid(issues: issues, view: view, context: context, cell: $cell)
                        .frame(maxHeight: 360)
                    Divider()
                    if let cell {
                        let members = issues.filter { issue in
                            view.dimensions[0].values(of: issue, in: context).contains(cell[0])
                                && view.dimensions[1].values(of: issue, in: context).contains(cell[1])
                        }
                        list(members, view: view, dimensions: Array(view.dimensions.dropFirst(2)), context: context, definition: definition, heading: "\(cell[0].title), \(cell[1].title)")
                    } else {
                        ContentUnavailableView("Pick a cell", systemImage: "square.grid.3x3.middle.filled", description: Text("Its issues are listed here, to open or change."))
                    }
                }
            case .grid:
                // One grouping gives the rows; the columns need a second.
                ContentUnavailableView {
                    Label("Pick the grid's columns", systemImage: FieldViewLayout.grid.systemImage)
                } description: {
                    Text("Rows are \(view.dimensions[0].title). Choose what the columns are.")
                } actions: {
                    Menu("Columns") {
                        ForEach(sortKeys(view).filter { !view.dimensions.contains($0) }, id: \.self) { key in
                            Button(key.title) {
                                var changed = view
                                changed.dimensions.append(key)
                                configs.saveFieldView(changed, in: org)
                            }
                        }
                    }
                    .fixedSize()
                }
            case .aging:
                FieldAging(issues: issues, view: view, context: context, history: issueStore.history(for: org), workflow: configs.config(for: org).workflow, actions: actions)
            }
        }
    }

    /// A drawer over the right of the view, as GitHub's. A click outside it
    /// closes it; the arrow keys step through the issues.
    @ViewBuilder
    private func drawer(context: FieldContext, order: [IssueRecord]) -> some View {
        if let reference = inspected {
            let index = order.firstIndex { $0.id == reference.id }
            // A click anywhere outside the drawer closes it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { inspected = nil }
            GeometryReader { geometry in
                let width = min(max(700, geometry.size.width * 0.7), max(geometry.size.width - 80, 480))
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    IssueSheet(
                        reference: reference,
                        signals: issueStore.history(for: org)?.issues[reference.id].map(context.signals),
                        isWide: width >= 900,
                        position: index.map { ($0 + 1, order.count) },
                        onPrevious: index.flatMap { current in current > 0 ? { open(order[current - 1]) } : nil },
                        onNext: index.flatMap { current in current + 1 < order.count ? { open(order[current + 1]) } : nil }
                    ) {
                        inspected = nil
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    // Its leading corners rounded.
                    .background(Color.windowBackground, in: Self.drawerShape)
                    .clipShape(Self.drawerShape)
                    .overlay { Self.drawerShape.strokeBorder(Color.separatorLine) }
                    .shadow(color: .black.opacity(0.25), radius: 24, x: -4)
                }
            }
            .transition(.move(edge: .trailing))
        }
    }

    /// The issues as the layout shows them, for stepping through in the
    /// drawer: column by column on the board, group by group in the outline
    /// and grid, the view's order otherwise.
    private func navigationOrder(_ view: FieldView, issues: [IssueRecord], context: FieldContext) -> [IssueRecord] {
        switch view.layout {
        case .table, .aging:
            return issues
        case .outline, .board, .grid:
            let dimensions = view.layout == .board ? Array(view.dimensions.prefix(1)) : view.dimensions
            var seen: Set<String> = []
            func leaves(_ groups: [FieldGroup]) -> [IssueRecord] {
                groups.flatMap { $0.children.isEmpty ? $0.issues : leaves($0.children) }
            }
            let groups = FieldGroup.groups(issues, by: dimensions, context: context, order: view.layout == .outline ? view.groupOrder : .value, measure: view.measure)
            return leaves(groups).filter { seen.insert($0.id).inserted }
        }
    }

    private static let drawerShape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, style: .continuous)

    /// Shows the issue in the drawer; Open as Page and Open in Window are
    /// in there.
    private func open(_ issue: IssueRecord) {
        inspected = IssueReference(org: org, record: issue)
    }

    /// The issues grouped by `dimensions`, or flat when there are none left,
    /// with selection and the bar for acting on it.
    private func list(_ issues: [IssueRecord], view: FieldView, dimensions: [FieldKey], context: FieldContext, definition: Board?, heading: String?) -> some View {
        let groups = FieldGroup.groups(issues, by: dimensions, context: context, order: view.groupOrder, measure: view.measure)
        return List(selection: $selected) {
            Section {
                if issues.isEmpty {
                    Text(issueStore.history(for: org) == nil ? "Loading issues." : "No issues match.")
                        .foregroundStyle(.secondary)
                }
                if dimensions.isEmpty {
                    ForEach(issues) { issue in
                        FieldIssueRow(issue: issue, signals: context.signals(issue), shown: FieldChips.values(issue, keys: view.shownFields, context: context), definition: definition).tag(issue.id)
                    }
                } else {
                    ForEach(groups) { group in
                        groupView(group, dimensions: dimensions, total: issues.count, view: view, context: context, definition: definition)
                    }
                }
            } header: {
                HStack {
                    Text(heading.map { "\($0): " } ?? "")
                        + Text(issues.count == 1 ? "1 issue" : "\(issues.count) issues")
                    Spacer()
                    if !dimensions.isEmpty {
                        Button(expanded.isEmpty ? "Expand All" : "Collapse All") {
                            expanded = expanded.isEmpty ? Set(Self.allIDs(groups)) : []
                        }
                        .linkButton()
                        .font(.caption)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            setMenu(issues.filter { ids.contains($0.id) }, view: view, definition: definition)
        } primaryAction: { ids in
            let picked = issues.filter { ids.contains($0.id) }
            if picked.count == 1, let issue = picked.first {
                open(issue)
            } else {
                for issue in picked { openWindow(value: IssueReference(org: org, record: issue)) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selected.isEmpty { selectionBar(issues, view: view, definition: definition) }
        }
    }

    private static func allIDs(_ groups: [FieldGroup]) -> [String] {
        groups.flatMap { [$0.id] + allIDs($0.children) }
    }

    /// A group's row, opening to the next level's groups or, at the last
    /// level, its issues.
    private func groupView(_ group: FieldGroup, dimensions: [FieldKey], total: Int, view: FieldView, context: FieldContext, definition: Board?) -> AnyView {
        // A group's path holds one value per level of this list's dimensions.
        let key = dimensions[group.path.count - 1]
        let isOpen = Binding(
            get: { expanded.contains(group.id) },
            set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } }
        )
        return AnyView(
            DisclosureGroup(isExpanded: isOpen) {
                if group.children.isEmpty {
                    ForEach(group.issues) { issue in
                        FieldIssueRow(issue: issue, signals: context.signals(issue), shown: FieldChips.values(issue, keys: view.shownFields, context: context), definition: definition).tag(issue.id)
                    }
                } else {
                    ForEach(group.children) { child in
                        groupView(child, dimensions: dimensions, total: group.issues.count, view: view, context: context, definition: definition)
                    }
                }
            } label: {
                FieldGroupLabel(
                    value: group.value,
                    key: key,
                    count: group.issues.count,
                    total: total,
                    measure: view.measure == .count ? nil : view.measure.format(view.measure.value(group.issues, context: context)),
                    color: FieldColors.color(group.value, key: key, definition: definition)
                )
                .contextMenu {
                    Button(group.issues.count == 1 ? "Select Issue" : "Select \(group.issues.count) Issues") {
                        selected.formUnion(group.issues.map(\.id))
                    }
                    if group.value == .none, let field = key.fieldName, definition?.field(named: field) != nil {
                        Button("Fill In \(field)") {
                            fillIn = FieldFillIn.Request(field: field, issues: group.issues)
                        }
                    }
                }
            }
        )
    }

    // MARK: Acting on issues

    private func selectionBar(_ issues: [IssueRecord], view: FieldView, definition: Board?) -> some View {
        let chosen = issues.filter { selected.contains($0.id) }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text("\(chosen.count) selected").monospacedDigit()
                Button("Select All \(issues.count)") { selected = Set(issues.map(\.id)) }
                    .disabled(chosen.count == issues.count)
                Button("Clear") { selected = [] }
                Spacer()
                Menu {
                    setMenu(chosen, view: view, definition: definition)
                } label: {
                    Label(chosen.count == 1 ? "Set Field" : "Set Field on \(chosen.count)", systemImage: "square.and.pencil")
                }
                .fixedSize()
                .disabled(definition == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    /// Each field on the board that takes an option or iteration, opening
    /// to its values and Clear.
    @ViewBuilder
    private func setMenu(_ issues: [IssueRecord], view: FieldView, definition: Board?) -> some View {
        if let definition, !issues.isEmpty {
            ForEach(FieldColors.settableFields(definition)) { field in
                Menu(field.name) {
                    ForEach(field.options) { option in
                        Button(option.name) { propose(issues, field: field.name, value: option.name, view: view) }
                    }
                    Divider()
                    Button("Clear \(field.name)") { propose(issues, field: field.name, value: nil, view: view) }
                }
            }
        } else if !issues.isEmpty {
            Text(view.projectNumber == nil ? "Pick a board in Edit View to set its fields" : "Loading the board's fields")
        }
        if issues.count == 1, let issue = issues.first {
            Divider()
            Link("Open on GitHub", destination: issue.url)
        }
    }

    /// The changes, leaving out issues that already have the value.
    private func propose(_ issues: [IssueRecord], field: String, value: String?, view: FieldView) {
        let changes = FieldChange.plan(issues, field: field, value: value, board: view.projectNumber)
        guard !changes.isEmpty else { return }
        writing = PendingFieldChanges(changes: changes)
    }

    /// The board's fields and the rest, for ordering by.
    private func sortKeys(_ view: FieldView) -> [FieldKey] {
        let fields = board(view)?.fields
            .filter { ["SINGLE_SELECT", "ITERATION", "NUMBER", "DATE", "TEXT"].contains($0.dataType) && $0.name != "Title" }
            .map { FieldKey.field($0.name) } ?? view.dimensions.filter { $0.fieldName != nil }
        return fields + FieldKey.attributes + FieldKey.derived
    }

    // MARK: Board

    private func board(_ view: FieldView) -> Board? {
        view.projectNumber.flatMap { projects.cache(org: org, number: $0)?.board }
    }

    /// The view's own controls, across the top of it rather than in the
    /// window's toolbar: layout, sort, fields and measure, the filters as
    /// chips (each opens Edit View), then Fill In, Board Fields and Edit View.
    private func controlBar(_ view: FieldView, issues: [IssueRecord]) -> some View {
        HStack(spacing: 10) {
            Picker("Layout", selection: Binding(get: { view.layout }, set: { layout in
                var changed = view
                changed.layout = layout
                configs.saveFieldView(changed, in: org)
            })) {
                ForEach(FieldViewLayout.allCases, id: \.self) { layout in
                    Label(layout.rawValue, systemImage: layout.systemImage).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            .help("Outline, Board, Table, Grid (the first two groupings) or Aging")
            FieldSortMenu(view: view, keys: sortKeys(view)) { changed in configs.saveFieldView(changed, in: org) }
                .fixedSize()
            FieldShownMenu(view: view, keys: sortKeys(view)) { changed in configs.saveFieldView(changed, in: org) }
                .fixedSize()
            Picker("Measure", selection: Binding(get: { view.measure }, set: { measure in
                var changed = view
                changed.measure = measure
                configs.saveFieldView(changed, in: org)
            })) {
                ForEach(FieldMeasure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("What each group shows beside its count")
            Spacer(minLength: 8)
            Text(issues.count == 1 ? "1 issue" : "\(issues.count) issues")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let definition = board(view) {
                let missing = FieldColors.settableFields(definition).compactMap { field -> (String, [IssueRecord])? in
                    let without = issues.filter { $0.fields(onProject: definition.number)?.values[field.name] == nil }
                    return without.isEmpty ? nil : (field.name, without)
                }
                Menu {
                    ForEach(missing, id: \.0) { field, without in
                        Button("\(field) (\(without.count))") {
                            fillIn = FieldFillIn.Request(field: field, issues: without)
                        }
                    }
                    Divider()
                    // No fields: the sheet asks which, and for which issues.
                    Button("Several Fields") {
                        fillIn = FieldFillIn.Request(fields: [], issues: issues)
                    }
                } label: {
                    Label("Fill In", systemImage: "rectangle.and.pencil.and.ellipsis")
                }
                .fixedSize()
                .help("Go through the issues here missing a field (or several), one at a time")
            }
            if let number = view.projectNumber {
                Button {
                    editingFields = BoardFieldsRequest(number: number)
                } label: {
                    Label("Board Fields", systemImage: "square.grid.3x1.below.line.grid.1x2")
                }
                .help("Add, rename and reorder the board's fields and their options")
            }
            Button {
                editing = view
            } label: {
                Label("Edit View", systemImage: "slider.horizontal.3")
            }
            .help("Change what this view groups and filters by")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Filters

    /// Filtered from the bar rather than Edit View, saved with the view.
    private static let quickKeys: [FieldKey] = [.assignee, .repository, .issueType, .label]

    /// Search, then Assignee, Repository, Type and Label as menus of the
    /// values the view's issues have, then any other filters as chips.
    private func filterBar(_ view: FieldView, context: FieldContext) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search, prompt: Text("Title or number"))
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.7), in: Capsule())
            ForEach(Self.quickKeys, id: \.self) { key in
                quickFilter(key, view: view, context: context)
            }
            filterChips(view)
            Spacer(minLength: 0)
            if !view.filters.isEmpty {
                Button("Clear All") {
                    var changed = view
                    changed.filters = []
                    configs.saveFieldView(changed, in: org)
                }
                .linkButton()
            }
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// A menu of the key's values across the view's issues (as they'd be
    /// without this filter), each with its count; Me first for Assignee.
    private func quickFilter(_ key: FieldKey, view: FieldView, context: FieldContext) -> some View {
        var base = view
        base.filters.removeAll { $0.key == key }
        let pool = base.issues(in: issueStore.history(for: org), context: context)
        var counts: [FieldValue: Int] = [:]
        for issue in pool {
            for value in Set(key.values(of: issue, in: context)) { counts[value, default: 0] += 1 }
        }
        let values = counts.keys.sorted { key == .assignee ? (counts[$0] ?? 0) > (counts[$1] ?? 0) : $0 < $1 }
        let picked = view.filters.first { $0.key == key }?.values ?? []
        let me = auth.viewer?.login
        return Menu {
            if key == .assignee, let me {
                Toggle("Me", isOn: filterBinding(key, value: me, view: view))
                Divider()
            }
            ForEach(values, id: \.self) { value in
                Toggle("\(title(value, key: key)) (\(counts[value] ?? 0))", isOn: filterBinding(key, value: value.name, view: view))
            }
            if !picked.isEmpty {
                Divider()
                Button("Clear") {
                    var changed = view
                    changed.filters.removeAll { $0.key == key }
                    configs.saveFieldView(changed, in: org)
                }
            }
        } label: {
            Text(picked.isEmpty ? key.title : "\(key.title): \(summary(picked, key: key))")
                .lineLimit(1)
        }
        .fixedSize()
        .tint(picked.isEmpty ? nil : .accentColor)
        .help(picked.isEmpty ? "Only issues with some values of \(key.title)" : "Only issues where \(key.title) is \(summary(picked, key: key, limit: 10))")
    }

    /// Names for the picked values: "Me, Sam Lee", or "Me and 3 more".
    private func summary(_ values: Set<String?>, key: FieldKey, limit: Int = 2) -> String {
        let me = auth.viewer?.login
        let names = values.map { value -> String in
            guard let value else { return "No value" }
            if key == .assignee, value == me { return "Me" }
            return title(FieldValue(name: value), key: key)
        }
        .sorted { a, b in a == "Me" ? true : b == "Me" ? false : a.localizedStandardCompare(b) == .orderedAscending }
        return names.count > limit ? "\(names.prefix(limit).joined(separator: ", ")) and \(names.count - limit) more" : names.joined(separator: ", ")
    }

    /// People by name; everything else as it is.
    private func title(_ value: FieldValue, key: FieldKey) -> String {
        guard key == .assignee, let login = value.name else { return value.title }
        return orgs.snapshot(for: org)?.members.first { $0.login == login }?.displayName ?? login
    }

    private func filterBinding(_ key: FieldKey, value: String?, view: FieldView) -> Binding<Bool> {
        Binding {
            view.filters.first { $0.key == key }?.values.contains(value) ?? false
        } set: { isOn in
            var changed = view
            var values = changed.filters.first { $0.key == key }?.values ?? []
            if isOn { values.insert(value) } else { values.remove(value) }
            changed.filters.removeAll { $0.key == key }
            if !values.isEmpty { changed.filters.append(FieldFilter(key: key, values: values)) }
            configs.saveFieldView(changed, in: org)
        }
    }

    /// Other filters, from Edit View, as chips: click to edit, × to drop.
    private func filterChips(_ view: FieldView) -> some View {
        ForEach(view.filters.filter { !Self.quickKeys.contains($0.key) }) { filter in
            let values = filter.values.map { $0 ?? "No value" }.sorted().joined(separator: ", ")
            HStack(spacing: 4) {
                Button {
                    editing = view
                } label: {
                    HStack(spacing: 4) {
                        Text(filter.key.title).foregroundStyle(.secondary)
                        Text(values).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Only issues where \(filter.key.title) is \(values). Click to change.")
                Button {
                    var changed = view
                    changed.filters.removeAll { $0.id == filter.id }
                    configs.saveFieldView(changed, in: org)
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this filter")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.7), in: Capsule())
        }
    }

    /// The issues whose title holds the search, or whose number is it.
    static func searched(_ issues: [IssueRecord], for search: String) -> [IssueRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !query.isEmpty else { return issues }
        return issues.filter { $0.title.localizedCaseInsensitiveContains(query) || String($0.number) == query }
    }
}

/// What the layouts can do with issues, handed down from the page.
struct FieldActions {
    let open: (IssueRecord) -> Void
    /// The Set Field menu for these issues.
    let setMenu: ([IssueRecord]) -> AnyView
    /// Confirms and writes changes.
    let propose: ([FieldChange]) -> Void
}

extension FieldChange {
    /// Setting `field` to `value` on each issue, leaving out those that
    /// already have it.
    static func plan(_ issues: [IssueRecord], field: String, value: String?, board: Int?) -> [FieldChange] {
        issues.compactMap { issue in
            let current = board.flatMap { issue.fields(onProject: $0)?.values[field]?.display }
            let same = current == nil ? value == nil : current?.caseInsensitiveCompare(value ?? "") == .orderedSame
            return same ? nil : FieldChange(issue: issue, field: field, value: value)
        }
    }
}

/// Colours and settable fields, shared by the layouts.
enum FieldColors {
    /// The option's colour on the board, the palette's for Attention, grey
    /// for no value, else the accent.
    static func color(_ value: FieldValue, key: FieldKey, definition: Board?) -> Color {
        guard let name = value.name else { return .secondary.opacity(0.4) }
        switch key {
        case .attention: return ChartPalette.warning
        case .ageInStatus:
            let order = Int(value.order)
            return order <= 1 ? ChartPalette.good : order <= 3 ? ChartPalette.warning : ChartPalette.critical
        default:
            guard let field = key.fieldName.flatMap({ definition?.field(named: $0) }),
                  let option = field.options.first(where: { $0.name == name }) else { return .accentColor }
            return BoardLayout.color(option.color)
        }
    }

    static func settableFields(_ board: Board) -> [BoardField] {
        board.fields.filter { ($0.dataType == "SINGLE_SELECT" || $0.dataType == "ITERATION") && !$0.options.isEmpty }
    }
}

/// A group's label: its value (in the option's colour), a share bar, the
/// view's measure when it isn't the count, and the count.
struct FieldGroupLabel: View {
    let value: FieldValue
    let key: FieldKey
    let count: Int
    let total: Int
    let measure: String?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(value.title)
                .foregroundStyle(value == .none ? .secondary : .primary)
                .lineLimit(1)
            Text(key.title)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if let measure, !measure.isEmpty {
                Text(measure)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color.opacity(0.8))
                        .frame(width: geometry.size.width * CGFloat(count) / CGFloat(max(total, 1)))
                }
            }
            .frame(width: 90, height: 6)
            Text(verbatim: "\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
        }
    }
}

/// An issue in a list: title, where it's from, how long it's sat, what
/// doesn't add up, and who has it.
struct FieldIssueRow: View {
    let issue: IssueRecord
    let signals: IssueSignals
    /// The view's shown fields with this issue's values.
    var shown: [(key: FieldKey, values: [FieldValue])] = []
    var definition: Board?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: "\(issue.repo)#\(issue.number)")
                    if let status = signals.status, let time = signals.timeInStatus {
                        Text("· \(status) for \(time.compactDuration)")
                    }
                    if let inProgress = signals.inProgress {
                        Text("· \(inProgress.compactDuration) in progress")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if !shown.isEmpty {
                    FieldChips(shown: shown, definition: definition)
                }
            }
            Spacer()
            FlagBadge(flags: signals.flags)
            AvatarStack(people: issue.assignees.map { Person(login: $0, name: nil, avatarUrl: URL(string: "https://github.com/\($0).png?size=64")) })
        }
        .padding(.vertical, 2)
    }
}

/// A warning triangle when the board and the code disagree, saying how.
struct FlagBadge: View {
    let flags: [IssueSignals.Flag]

    var body: some View {
        if !flags.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ChartPalette.warning)
                .help(flags.map { "\($0.rawValue): \($0.explanation)" }.joined(separator: "\n"))
        }
    }
}

/// Views, with none picked: the org's saved views, and New View.
struct FieldViewsLanding: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    let org: String
    let open: (UUID) -> Void
    @State private var creating: FieldView?

    var body: some View {
        let views = configs.config(for: org).fieldViews
        Group {
            if views.isEmpty {
                ContentUnavailableView {
                    Label("No views yet", systemImage: WorkloadTab.views.systemImage)
                } description: {
                    Text("Group issues by any board fields and attributes, as an outline, a board, a table, a grid or by age, and set fields on many at once.")
                } actions: {
                    Button("New View", action: create)
                }
            } else {
                List {
                    ForEach(views) { view in
                        Button {
                            open(view.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: view.layout.systemImage)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(view.name)
                                    Text(view.dimensions.map(\.title).joined(separator: " › "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button(action: create) { Label("New View", systemImage: "plus") }
            }
        }
        .task { await projects.loadBoards(org: org) }
        .sheet(item: $creating) { draft in
            FieldViewEditor(org: org, view: draft) { saved in
                configs.saveFieldView(saved, in: org)
                creating = nil
                open(saved.id)
            } onCancel: {
                creating = nil
            }
        }
    }

    /// Starts on the investments board when there is one, else the first,
    /// as a board by Status.
    private func create() {
        var number: Int?
        if case .projectField(let tracked, _, _) = configs.config(for: org).investmentConfig.trackedBy, tracked != 0 { number = tracked }
        number = number ?? projects.boardLists[org]?.first?.number
        creating = FieldView(name: "New View", projectNumber: number, dimensions: number == nil ? [.repository] : [.field("Status")], layout: number == nil ? .outline : .board)
    }
}

/// Sort: what issues are ordered by and which way, and how groups are
/// ordered, saved with the view.
struct FieldSortMenu: View {
    let view: FieldView
    /// Fields and the rest that issues can be ordered by.
    let keys: [FieldKey]
    let save: (FieldView) -> Void

    var body: some View {
        Menu {
            Picker("Issues by", selection: binding(\.sort.by)) {
                ForEach(FieldSort.By.basics, id: \.self) { Text($0.title).tag($0) }
                Divider()
                ForEach(keys, id: \.self) { key in Text(key.title).tag(FieldSort.By.key(key)) }
            }
            Picker("Direction", selection: binding(\.sort.descending)) {
                Text(ascendingTitle(false)).tag(false)
                Text(ascendingTitle(true)).tag(true)
            }
            Divider()
            Picker("Groups by", selection: binding(\.groupOrder)) {
                ForEach(FieldGroupOrder.allCases, id: \.self) { order in
                    Text(order == .measure ? view.measure.rawValue : order.rawValue).tag(order)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Order issues by \(view.sort.by.title.lowercased()), \(ascendingTitle(view.sort.descending).lowercased())")
    }

    /// Words for the direction that fit what's being ordered.
    private func ascendingTitle(_ descending: Bool) -> String {
        switch view.sort.by {
        case .created: descending ? "Newest first" : "Oldest first"
        case .timeInStatus, .inProgress: descending ? "Longest first" : "Shortest first"
        case .number: descending ? "Highest first" : "Lowest first"
        case .title: descending ? "Z to A" : "A to Z"
        case .key: descending ? "Reverse board order" : "Board order"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<FieldView, Value>) -> Binding<Value> {
        Binding {
            view[keyPath: keyPath]
        } set: { value in
            var changed = view
            changed[keyPath: keyPath] = value
            save(changed)
        }
    }
}

/// The view's shown fields on a card or row: small chips, each value in
/// its option's colour. Fields the issue has no value for are left off.
struct FieldChips: View {
    let shown: [(key: FieldKey, values: [FieldValue])]
    let definition: Board?

    static func values(_ issue: IssueRecord, keys: [FieldKey], context: FieldContext) -> [(key: FieldKey, values: [FieldValue])] {
        keys.compactMap { key in
            let values = key.values(of: issue, in: context).filter { $0 != .none }
            return values.isEmpty ? nil : (key, values)
        }
    }

    var body: some View {
        FlowRow(spacing: 4) {
            ForEach(shown, id: \.key) { key, values in
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 4) {
                        switch key {
                        case .plan, .requirement:
                            // Just whether there is one.
                            Image(systemName: key == .plan ? HarnessKind.plans.systemImage : HarnessKind.requirements.systemImage)
                                .foregroundStyle(.secondary)
                        default:
                            Circle()
                                .fill(FieldColors.color(value, key: key, definition: definition))
                                .frame(width: 6, height: 6)
                            Text(value.title).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .help("\(key.title): \(value.title)")
                }
            }
        }
    }
}

/// Fields: which to show on cards and rows, ticked in the order picked.
struct FieldShownMenu: View {
    let view: FieldView
    let keys: [FieldKey]
    let save: (FieldView) -> Void

    var body: some View {
        Menu {
            let fields = keys.filter { $0.fieldName != nil }
            if !fields.isEmpty {
                Section("Board fields") { toggles(fields) }
            }
            Section("Issue") { toggles(FieldKey.attributes) }
            Section("Worked out") { toggles(FieldKey.derived) }
            if !view.shownFields.isEmpty {
                Divider()
                Button("Show None") {
                    var changed = view
                    changed.shownFields = []
                    save(changed)
                }
            }
        } label: {
            Label("Fields", systemImage: "rectangle.and.text.magnifyingglass")
        }
        .help(view.shownFields.isEmpty ? "Show fields on cards and rows" : "Showing \(view.shownFields.map(\.title).joined(separator: ", "))")
    }

    private func toggles(_ keys: [FieldKey]) -> some View {
        ForEach(keys, id: \.self) { key in
            Toggle(key.title, isOn: Binding(
                get: { view.shownFields.contains(key) },
                set: { isOn in
                    var changed = view
                    changed.shownFields.removeAll { $0 == key }
                    if isOn { changed.shownFields.append(key) }
                    save(changed)
                }
            ))
        }
    }
}
