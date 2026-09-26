import SwiftUI

/// Settings section listing the org's investment categories, with a preset
/// picker and an editor sheet per category.
struct InvestmentCategoriesSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(MetricsStore.self) private var metricsStore
    let org: String

    @State private var editing: InvestmentCategory?
    @State private var confirmingPreset: InvestmentPreset?

    var body: some View {
        let config = configs.config(for: org).investmentConfig
        let prs = metricsStore.history(for: org).map { Array($0.pullRequests.values) } ?? []
        let placed = Dictionary(grouping: prs.compactMap { config.categorise($0)?.category.id }, by: { $0 }).mapValues(\.count)

        Section {
            ForEach(Array(config.categories.enumerated()), id: \.element.id) { index, category in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ChartPalette.slot(category.slot))
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.name)
                        Text("\(category.rules.count == 1 ? "1 rule" : "\(category.rules.count) rules") · \(placed[category.id] ?? 0) PRs in the stored history")
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
            Text("A PR goes to the first category, top to bottom, with a rule matching the PR itself; failing that, one matching an issue it closes, then that issue's parent. Choosing a category by hand (right-click a merged PR) beats the rules.")
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
    @Environment(MetricsStore.self) private var metricsStore
    @Environment(\.dismiss) private var dismiss

    let org: String
    @State private var category: InvestmentCategory

    init(org: String, category: InvestmentCategory) {
        self.org = org
        _category = State(initialValue: category)
    }

    var body: some View {
        let config = configs.config(for: org).investmentConfig
        let prs = metricsStore.history(for: org).map { Array($0.pullRequests.values) } ?? []
        let suggestions = Suggestions(prs)
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
                    Text(matchSummary(prs, config: config))
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

    /// How many stored PRs the rules match, and how many land here once
    /// higher categories have taken theirs.
    private func matchSummary(_ prs: [MetricPullRequest], config: InvestmentConfig) -> String {
        var edited = config
        if let index = edited.categories.firstIndex(where: { $0.id == category.id }) {
            edited.categories[index] = category
        } else {
            edited.categories.append(category)
        }
        let matching = prs.filter { pr in
            ([InvestmentItem(pr)] + pr.linkedIssues.map { InvestmentItem($0.issue) } + pr.linkedIssues.compactMap(\.parent).map(InvestmentItem.init))
                .contains(where: category.matches)
        }.count
        let landing = prs.filter { edited.categorise($0)?.category.id == category.id }.count
        return "A PR lands here when any rule matches. These rules match \(matching) of the \(prs.count) merged PRs in the stored history; \(landing) land here after categories above take theirs."
    }
}

private struct ConditionRow: View {
    @Binding var condition: InvestmentCondition
    let suggestions: Suggestions
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: $condition.field) {
                ForEach(InvestmentCondition.Field.allCases) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Operator", selection: $condition.op) {
                ForEach(InvestmentCondition.Operator.allCases) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Value", text: $condition.value)
                .textFieldStyle(.roundedBorder)
            let options = suggestions.values(for: condition.field)
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

    init(_ prs: [MetricPullRequest]) {
        let issues = prs.flatMap { pr in pr.linkedIssues.flatMap { [$0.issue] + ($0.parent.map { [$0] } ?? []) } }
        func ranked(_ items: [String]) -> [String] {
            Dictionary(grouping: items, by: { $0 }).sorted { $0.value.count > $1.value.count }.map(\.key)
        }
        values = [
            .label: ranked(prs.flatMap(\.labels) + issues.flatMap(\.labels)),
            .repository: ranked(prs.map(\.repo)),
            .author: ranked(prs.compactMap(\.author?.login)),
            .issueType: ranked(issues.compactMap(\.issueType)),
            .milestone: ranked(issues.compactMap(\.milestone)),
        ]
    }

    func values(for field: InvestmentCondition.Field) -> [String] {
        values[field] ?? []
    }
}
