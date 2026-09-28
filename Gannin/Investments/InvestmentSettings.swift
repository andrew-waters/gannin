import SwiftUI

/// Settings section listing the org's investment categories, with a preset
/// picker and an editor sheet per category.
struct InvestmentCategoriesSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
    @Environment(InvestmentPrompt.self) private var prompt: InvestmentPrompt?
    let org: String

    @State private var editing: InvestmentCategory?
    @State private var confirmingPreset: InvestmentPreset?

    var body: some View {
        let config = configs.config(for: org).investmentConfig
        let history = issueStore.history(for: org)
        let issues = history.map { Array($0.issues.values) } ?? []
        let placed = Dictionary(grouping: issues.compactMap { issue in
            config.categorise(issue, parent: issue.parentID.flatMap { history?.issues[$0] })?.category.id
        }, by: { $0 }).mapValues(\.count)

        TrackingSection(org: org, issues: issues)
        Section {
            ForEach(Array(config.categories.enumerated()), id: \.element.id) { index, category in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ChartPalette.slot(category.slot))
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.name)
                        Text(rowSummary(category, config: config, placed: placed[category.id] ?? 0))
                            .font(.caption)
                            .foregroundStyle(config.trackedBy.writesToGitHub && (category.githubValue ?? "").isEmpty ? Color.orange : .secondary)
                    }
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                        .help("Move up: higher categories win when several match")
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == config.categories.count - 1)
                        .help("Move down")
                    Button("Edit") { editing = category }
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Button("Add Category") {
                    // Saved on Done, so cancelling leaves nothing behind.
                    editing = InvestmentCategory(name: "New category", details: "", slot: config.freeSlot ?? 0, rules: [])
                }
                .disabled(config.freeSlot == nil)
                .help(config.freeSlot == nil ? "Eight categories at most, one per chart colour" : "")
                Menu("Start From Preset") {
                    ForEach(InvestmentPreset.allCases) { preset in
                        Button(preset.rawValue) { confirmingPreset = preset }
                    }
                }
                .fixedSize()
                Spacer()
                if !config.manual.isEmpty {
                    if config.trackedBy.writesToGitHub, let prompt, let history {
                        // Choices made here before the org tracked in GitHub.
                        Button("Write \(config.manual.count) Chosen in Gannin to GitHub") {
                            let changes = config.manual.compactMap { issueID, categoryID -> InvestmentChange? in
                                guard let issue = history.issues[issueID], let category = config.category(id: categoryID) else { return nil }
                                return InvestmentChange.plan(issue, to: category, config: config)
                            }
                            prompt.propose(changes, org: org, configs: configs)
                        }
                    }
                    Button("Clear \(config.manual.count) Chosen by Hand") {
                        configs.updateInvestments(org) { $0.manual = [:] }
                    }
                }
            }
        } header: {
            Text("Investment categories")
        } footer: {
            Text(config.trackedBy.writesToGitHub
                 ? "An issue's category is the one whose \(config.trackedBy.valueName.lowercased()) it has on GitHub, else its parent's. Rules only suggest a category when assigning. Choosing a category (right-click an issue, in its window, or Assign to Categories) writes it to GitHub after you confirm."
                 : "An issue goes to the first category, top to bottom, with a rule matching it; failing that, one matching its parent. Choosing a category by hand (right-click an issue, or in its window) beats the rules.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { category in
            InvestmentCategoryEditor(org: org, category: category)
        }
        .confirmationDialog(
            "Replace the categories with \(confirmingPreset?.rawValue ?? "")?",
            isPresented: Binding(get: { confirmingPreset != nil }, set: { if !$0 { confirmingPreset = nil } }),
            presenting: confirmingPreset
        ) { preset in
            Button("Replace Categories", role: .destructive) {
                configs.updateInvestments(org) { $0 = InvestmentConfig(categories: preset.categories) }
            }
        } message: { preset in
            Text("\(preset.summary) Your categories and choices made by hand are replaced.")
        }
    }

    private func rowSummary(_ category: InvestmentCategory, config: InvestmentConfig, placed: Int) -> String {
        let rules = category.rules.count == 1 ? "1 rule" : "\(category.rules.count) rules"
        guard config.trackedBy.writesToGitHub else { return "\(rules) · \(placed) stored issues" }
        let value = category.githubValue.flatMap { $0.isEmpty ? nil : $0 }
        return "\(config.trackedBy.valueName): \(value ?? "not set") · \(placed) stored issues · \(rules) to suggest"
    }

    private func move(_ index: Int, by offset: Int) {
        configs.updateInvestments(org) { config in
            let target = index + offset
            guard config.categories.indices.contains(target) else { return }
            config.categories.swapAt(index, target)
        }
    }
}

// MARK: - Editor

/// Name, colour and rules for one category, saved on Done.
private struct InvestmentCategoryEditor: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    @Environment(IssueStore.self) private var issueStore
    @Environment(\.dismiss) private var dismiss

    let org: String
    @State private var category: InvestmentCategory

    init(org: String, category: InvestmentCategory) {
        self.org = org
        _category = State(initialValue: category)
    }

    var body: some View {
        let config = configs.config(for: org).investmentConfig
        let history = issueStore.history(for: org)
        let issues = history.map { Array($0.issues.values) } ?? []
        let suggestions = Suggestions(issues)
        let usedSlots = Set(config.categories.filter { $0.id != category.id }.map(\.slot))

        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $category.name)
                    TextField("Description", text: $category.details, axis: .vertical)
                    LabeledContent("Colour") {
                        HStack(spacing: 6) {
                            ForEach(0..<InvestmentCategory.slotCount, id: \.self) { slot in
                                Button {
                                    category.slot = slot
                                } label: {
                                    Circle()
                                        .fill(ChartPalette.slot(slot))
                                        .frame(width: 18, height: 18)
                                        .overlay {
                                            if category.slot == slot {
                                                Circle().strokeBorder(.primary, lineWidth: 2).padding(-3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .disabled(usedSlots.contains(slot))
                                .opacity(usedSlots.contains(slot) ? 0.25 : 1)
                                .help(usedSlots.contains(slot) ? "Used by another category" : "")
                            }
                        }
                    }
                }

                if config.trackedBy.writesToGitHub {
                    Section {
                        HStack {
                            TextField(config.trackedBy.valueName, text: Binding(get: { category.githubValue ?? "" }, set: { category.githubValue = $0 }))
                            Menu {
                                ForEach(githubSuggestions(config.trackedBy, suggestions: suggestions).prefix(40), id: \.self) { value in
                                    Button(value) { category.githubValue = value }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Values seen on stored issues")
                        }
                    } header: {
                        Text("On GitHub")
                    } footer: {
                        Text(config.trackedBy == .labels
                             ? "Issues with this label are in this category, and choosing it adds the label (and removes the other categories')."
                             : "Issues with this option are in this category, and choosing it sets the option.")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach($category.rules) { $rule in
                    Section {
                        ForEach($rule.conditions) { $condition in
                            ConditionRow(condition: $condition, suggestions: suggestions) {
                                rule.conditions.removeAll { $0.id == condition.id }
                            }
                        }
                        HStack {
                            Button("Add Condition") {
                                rule.conditions.append(InvestmentCondition(field: .label, op: .isEqual, value: ""))
                            }
                            Spacer()
                            Button("Remove Rule", role: .destructive) {
                                category.rules.removeAll { $0.id == rule.id }
                            }
                        }
                        .buttonStyle(.borderless)
                    } header: {
                        let kind = config.trackedBy.writesToGitHub ? "Suggestion rule" : "Rule"
                        Text(rule.conditions.count > 1 ? "\(kind): all of these" : kind)
                    } footer: {
                        if Self.repeatsTracked(rule, category: category, tracking: config.trackedBy) {
                            HStack {
                                Text("This rule only repeats the \(config.trackedBy.valueName.lowercased()), so it never suggests anything.")
                                    .foregroundStyle(.orange)
                                Button("Remove It") { category.rules.removeAll { $0.id == rule.id } }
                                    .linkButton()
                            }
                        }
                    }
                }

                Section {
                    Button("Add Rule") {
                        category.rules.append(InvestmentRule(conditions: [InvestmentCondition(field: .label, op: .isEqual, value: "")]))
                    }
                } footer: {
                    Text(config.trackedBy.writesToGitHub
                         ? "Optional. Issues get their category from GitHub; rules only suggest one when assigning issues that don't have it yet, so they're worth adding for things other than the \(config.trackedBy.valueName.lowercased()) (a label, a type, a repository)."
                         : matchSummary(issues, history: history, config: config))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Delete Category", role: .destructive) {
                    configs.updateInvestments(org) { config in
                        config.categories.removeAll { $0.id == category.id }
                        config.manual = config.manual.filter { $0.value != category.id }
                    }
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    configs.updateInvestments(org) { config in
                        if let index = config.categories.firstIndex(where: { $0.id == category.id }) {
                            config.categories[index] = category
                        } else {
                            config.categories.append(category)
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 620)
    }

    /// A rule that only checks the category's own label or option: it can
    /// only match issues already in the category.
    static func repeatsTracked(_ rule: InvestmentRule, category: InvestmentCategory, tracking: InvestmentTracking) -> Bool {
        guard let value = category.githubValue, !value.isEmpty, !rule.conditions.isEmpty else { return false }
        return rule.conditions.allSatisfy { condition in
            let sameValue = condition.value.caseInsensitiveCompare(value) == .orderedSame && (condition.op == .isEqual || condition.op == .contains || condition.op == .startsWith)
            switch tracking {
            case .gannin: return false
            case .labels: return condition.field == .label && sameValue
            case .projectField(_, _, let field):
                return condition.field == .projectField && (condition.projectField ?? "").caseInsensitiveCompare(field) == .orderedSame && sameValue
            }
        }
    }

    private func githubSuggestions(_ tracking: InvestmentTracking, suggestions: Suggestions) -> [String] {
        switch tracking {
        case .gannin: []
        case .labels: suggestions.values(for: .label)
        case .projectField(let number, _, let field):
            // The field's options in board order, else values seen on issues.
            projects.cache(org: org, number: number)?.board.field(named: field)?.options.map(\.name)
                ?? suggestions.projectFieldValues(field)
        }
    }

    /// How many stored issues the rules match, and how many land here once
    /// higher categories have taken theirs.
    private func matchSummary(_ issues: [IssueRecord], history: IssueHistory?, config: InvestmentConfig) -> String {
        var edited = config
        if let index = edited.categories.firstIndex(where: { $0.id == category.id }) {
            edited.categories[index] = category
        } else {
            edited.categories.append(category)
        }
        let matching = issues.filter { category.matches(InvestmentItem($0)) }.count
        let landing = issues.filter { issue in
            edited.categorise(issue, parent: issue.parentID.flatMap { history?.issues[$0] })?.category.id == category.id
        }.count
        return "An issue lands here when any rule matches it (or its parent). These rules match \(matching) of the \(issues.count) stored issues; \(landing) land here after categories above take theirs."
    }
}

private struct ConditionRow: View {
    @Binding var condition: InvestmentCondition
    let suggestions: Suggestions
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: $condition.field) {
                // An older rule's PR-only field still shows, so it can be changed.
                ForEach(InvestmentCondition.Field.issueFields + (InvestmentCondition.Field.issueFields.contains(condition.field) ? [] : [condition.field])) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if condition.field == .projectField {
                TextField("Field", text: Binding(get: { condition.projectField ?? "" }, set: { condition.projectField = $0.isEmpty ? nil : $0 }))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .help("The board field to compare, such as Bucket")
                if !suggestions.projectFieldNames.isEmpty {
                    Menu {
                        ForEach(suggestions.projectFieldNames, id: \.self) { name in
                            Button(name) { condition.projectField = name }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Board fields seen in the stored history")
                }
            }
            Picker("Operator", selection: $condition.op) {
                ForEach(InvestmentCondition.Operator.allCases) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Value", text: $condition.value)
                .textFieldStyle(.roundedBorder)
            let options = condition.field == .projectField
                ? suggestions.projectFieldValues(condition.projectField)
                : suggestions.values(for: condition.field)
            if !options.isEmpty {
                Menu {
                    ForEach(options.prefix(40), id: \.self) { option in
                        Button(option) {
                            condition.value = option
                            if condition.op == .matches { condition.op = .isEqual }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Values seen in the stored history")
            }
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove condition")
        }
    }
}

/// Values seen in the stored history, most common first, for the value menu.
private struct Suggestions {
    private let values: [InvestmentCondition.Field: [String]]
    private let projectFields: [String: [String]]
    let projectFieldNames: [String]

    init(_ issues: [IssueRecord]) {
        func ranked(_ items: [String]) -> [String] {
            Dictionary(grouping: items, by: { $0 }).sorted { $0.value.count > $1.value.count }.map(\.key)
        }
        values = [
            .label: ranked(issues.flatMap(\.labels)),
            .repository: ranked(issues.map(\.repo)),
            .issueType: ranked(issues.compactMap(\.issueType)),
            .milestone: ranked(issues.compactMap(\.milestone)),
        ]
        var byField: [String: [String]] = [:]
        for issue in issues {
            for board in issue.projectFields {
                for (name, value) in board.values { byField[name, default: []].append(value.display) }
            }
        }
        projectFields = byField.mapValues(ranked)
        projectFieldNames = byField.keys.sorted()
    }

    func projectFieldValues(_ field: String?) -> [String] {
        guard let field else { return [] }
        return projectFields.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value ?? []
    }

    func values(for field: InvestmentCondition.Field) -> [String] {
        values[field] ?? []
    }
}

// MARK: - Tracking

/// How the org keeps investment categories: in Gannin, as labels, or as a
/// single-select field on a board. Everything else follows it. Boards and
/// their fields come from GitHub.
private struct TrackingSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    let org: String
    let issues: [IssueRecord]

    private enum Kind: String, CaseIterable {
        case gannin = "In Gannin"
        case labels = "GitHub labels"
        case projectField = "A board field"
    }

    private var boards: [OrgProject] { projects.boardLists[org] ?? [] }

    /// The board's single-select fields, once its definition has loaded.
    private func fields(_ number: Int) -> [BoardField]? {
        projects.cache(org: org, number: number)?.board.fields.filter { $0.dataType == "SINGLE_SELECT" }
    }

    var body: some View {
        let tracking = configs.config(for: org).investmentConfig.trackedBy
        Section {
            Picker("Tracked by", selection: kindBinding(tracking)) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if case .projectField(let number, _, let field) = tracking {
                Picker("Board", selection: Binding {
                    number
                } set: { newNumber in
                    let title = boards.first { $0.number == newNumber }?.title ?? ""
                    set(.projectField(projectNumber: newNumber, projectTitle: title, field: ""))
                }) {
                    if number == 0 || !boards.contains(where: { $0.number == number }) {
                        Text(number == 0 ? (boards.isEmpty ? "Loading boards" : "Choose a board") : "Project \(number)").tag(number)
                    }
                    ForEach(boards) { Text($0.title).tag($0.number) }
                }
                .task { await projects.loadBoards(org: org) }
                if number != 0 {
                    let fields = fields(number)
                    Picker("Field", selection: Binding {
                        field
                    } set: { newField in
                        let title = boards.first { $0.number == number }?.title ?? ""
                        set(.projectField(projectNumber: number, projectTitle: title, field: newField))
                    }) {
                        if field.isEmpty || !(fields ?? []).contains(where: { $0.name == field }) {
                            Text(field.isEmpty ? (fields == nil ? "Loading fields" : "Choose a field") : field).tag(field)
                        }
                        ForEach(fields ?? []) { Text($0.name).tag($0.name) }
                    }
                    .task(id: number) { await projects.loadDefinition(org: org, number: number) }
                    if let fields, fields.isEmpty {
                        Text("This board has no single-select fields.").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("How we track investments")
        } footer: {
            Text(footer(tracking))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ tracking: InvestmentTracking) -> String {
        switch tracking {
        case .gannin:
            "Categories come from the rules below and choices made in Gannin, and nothing is written to GitHub."
        case .labels:
            "Each category is a label. The balance reads issues' labels, and choosing a category adds its label and removes the other categories', after you confirm. Set each category's label below."
        case .projectField(_, let project, let field):
            "Each category is an option of \(field.isEmpty ? "a single-select field" : field) on \(project.isEmpty ? "the board" : project). The balance reads it, and choosing a category sets it (adding the issue to the board if needed), after you confirm. Set each category's option below."
        }
    }

    private func kindBinding(_ tracking: InvestmentTracking) -> Binding<Kind> {
        Binding {
            switch tracking {
            case .gannin: .gannin
            case .labels: .labels
            case .projectField: .projectField
            }
        } set: { kind in
            switch kind {
            case .gannin: set(.gannin)
            case .labels: set(.labels)
            case .projectField:
                if case .projectField = tracking { return }
                set(.projectField(projectNumber: 0, projectTitle: "", field: ""))
            }
        }
    }

    private func set(_ tracking: InvestmentTracking) {
        configs.updateInvestments(org) { $0.tracking = tracking == .gannin ? nil : tracking }
    }
}
