import SwiftUI

/// Settings section listing the org's investment categories, with a preset
/// picker and an editor sheet per category.
struct InvestmentCategoriesSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var issueStore
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

        Section {
            ForEach(Array(config.categories.enumerated()), id: \.element.id) { index, category in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ChartPalette.slot(category.slot))
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.name)
                        Text("\(category.rules.count == 1 ? "1 rule" : "\(category.rules.count) rules") · \(placed[category.id] ?? 0) stored issues")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Button("Clear \(config.manual.count) Chosen by Hand") {
                        configs.updateInvestments(org) { $0.manual = [:] }
                    }
                }
            }
        } header: {
            Text("Investment categories")
        } footer: {
            Text("An issue goes to the first category, top to bottom, with a rule matching it; failing that, one matching its parent. Choosing a category by hand (right-click an issue, or in its window) beats the rules.")
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
                        Text(rule.conditions.count > 1 ? "Rule: all of these" : "Rule")
                    }
                }

                Section {
                    Button("Add Rule") {
                        category.rules.append(InvestmentRule(conditions: [InvestmentCondition(field: .label, op: .isEqual, value: "")]))
                    }
                } footer: {
                    Text(matchSummary(issues, history: history, config: config))
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
