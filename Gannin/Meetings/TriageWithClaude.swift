#if os(macOS)
import SwiftUI

/// Triage with Claude, from Prioritisation's Triage: for each issue with no
/// Status, Claude suggests the board's single-select fields (Priority,
/// Size and the like, but not Status, which triage is for), an investment
/// category, and whether it's a good one to hand to an agent, from its
/// title, description and labels. Each suggestion is ticked to keep;
/// Apply writes the board fields on GitHub (confirmed first) and sets the
/// category where the org tracks it.
struct TriageWithClaudeSheet: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(DetailStore.self) private var details
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let org: String
    let issues: [IssueRecord]

    /// One issue's suggestions, read forgivingly: a field Claude couldn't
    /// decide (null) or gave as a number is skipped or kept as text, the
    /// number may come as text, and agent as yes or no.
    struct Suggestion: Decodable {
        let number: Int
        let repo: String?
        let fields: [String: String]?
        let category: String?
        let agent: Bool?
        let why: String?

        private enum Keys: String, CodingKey { case number, repo, fields, category, agent, why }

        private struct Value: Decodable {
            let text: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) { text = string }
                else if let number = try? container.decode(Double.self) { text = number.rounded() == number ? String(Int(number)) : String(number) }
                else if let flag = try? container.decode(Bool.self) { text = flag ? "Yes" : "No" }
                else { text = nil }
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let number = try? container.decode(Int.self, forKey: .number) {
                self.number = number
            } else {
                let text = (try? container.decode(String.self, forKey: .number)) ?? ""
                guard let number = Int(text.filter(\.isNumber)) else {
                    throw DecodingError.dataCorruptedError(forKey: .number, in: container, debugDescription: "No issue number")
                }
                self.number = number
            }
            repo = try? container.decode(String.self, forKey: .repo)
            let raw = (try? container.decode([String: Value].self, forKey: .fields)) ?? [:]
            fields = raw.compactMapValues(\.text).filter { !$0.value.isEmpty }
            category = try? container.decode(String.self, forKey: .category)
            if let flag = try? container.decode(Bool.self, forKey: .agent) {
                agent = flag
            } else if let text = try? container.decode(String.self, forKey: .agent) {
                agent = ["yes", "true", "y"].contains(text.lowercased())
            } else {
                agent = nil
            }
            why = try? container.decode(String.self, forKey: .why)
        }
    }

    /// One unreadable suggestion doesn't lose the rest.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    @State private var suggestions: [String: Suggestion] = [:]
    /// Suggestions left out, as "issue ID|field".
    @State private var unticked: Set<String> = []
    @State private var working = true
    @State private var error: String?
    /// Claude's reply, when it couldn't be read, to show as it was.
    @State private var rawReply: String?
    @State private var writing = false

    private var board: Board? {
        configs.config(for: org).workflow.projectNumber.flatMap { projects.cache(org: org, number: $0)?.board }
    }

    /// Single-select fields claude may suggest: not Status, nor the field
    /// investments are tracked in (the category covers that).
    private var fields: [BoardField] {
        let tracked: String? = if case .projectField(_, _, let field) = configs.config(for: org).investmentConfig.trackedBy { field } else { nil }
        return (board?.fields ?? []).filter { $0.dataType == "SINGLE_SELECT" && $0.name != "Status" && $0.name != tracked && !$0.options.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Triage").font(.headline)
                Spacer()
                if working { ProgressView().controlSize(.small); Text("Claude is reading \(issues.count) issues").foregroundStyle(.secondary) }
            }
            .padding(12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { Text(error).foregroundStyle(.red) }
                    if let rawReply {
                        DisclosureGroup("What Claude said") {
                            Text(rawReply)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    table
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text("Board fields are written to GitHub. \(categoryNote)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply \(changes.count + categoryChanges.count)") {
                    if changes.isEmpty {
                        for (issue, id) in categoryChanges { configs.setCategory(id, for: issue.id, in: org) }
                        dismiss()
                    } else {
                        writing = true
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || changes.isEmpty && categoryChanges.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 1100, idealWidth: 1320, maxWidth: .infinity, minHeight: 460, idealHeight: 620)
        .task { await suggest() }
        .sheet(isPresented: $writing) { writeSheet }
    }

    private var categoryNote: String {
        switch configs.config(for: org).investmentConfig.trackedBy {
        case .gannin: "Categories are set in Gannin."
        case .labels: "Categories tracked by label aren't applied here: assign them from Investments."
        case .projectField: "Categories are written to their board field."
        }
    }

    /// The columns: fields Claude suggested something for, in board
    /// order, then the category.
    private var columns: [String] {
        let suggested = Set(suggestions.values.flatMap { ($0.fields ?? [:]).keys })
        var names = fields.map(\.name).filter(suggested.contains)
        if suggestions.values.contains(where: { $0.category != nil }) { names.append(Self.categoryColumn) }
        return names
    }

    private static let categoryColumn = "\u{0}category"

    /// A row per issue, a column per field: values ticked to keep.
    private var table: some View {
        let columns = columns
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                Text("Issue")
                Image(systemName: "sparkle")
                    .foregroundStyle(.orange)
                    .help("Good for an agent")
                ForEach(columns, id: \.self) { column in
                    Button {
                        toggleColumn(column)
                    } label: {
                        Text(column == Self.categoryColumn ? "Category" : column)
                    }
                    .buttonStyle(.plain)
                    .help("Tick or untick \(column == Self.categoryColumn ? "Category" : column) for every issue")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            ForEach(issues) { issue in
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                let suggestion = suggestions[issue.id]
                GridRow(alignment: .center) {
                    HStack(spacing: 6) {
                        Text("#\(String(issue.number))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(issue.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 420, alignment: .leading)
                        if let why = suggestion?.why {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .help(why)
                        }
                    }
                    .help(issue.title)
                    Group {
                        if suggestion?.agent == true {
                            Image(systemName: "sparkle").foregroundStyle(.orange).help("Good for an agent")
                        } else {
                            Color.clear.frame(width: 1, height: 1)
                        }
                    }
                    ForEach(columns, id: \.self) { column in
                        cell(issue, column: column, suggestion: suggestion)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func cell(_ issue: IssueRecord, column: String, suggestion: Suggestion?) -> some View {
        if column == Self.categoryColumn, let category = suggestion?.category {
            chip(category, key: "\(issue.id)|\u{0}category", valid: categoryID(category) != nil && configs.config(for: org).investmentConfig.trackedBy != .labels)
        } else if let value = suggestion?.fields?[column] {
            chip(value, key: "\(issue.id)|\(column)", valid: isValid(field: column, value: value))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// Unticks the column for every issue, or ticks it again when it's off
    /// for all.
    private func toggleColumn(_ column: String) {
        let keys = issues.map { "\($0.id)|\(column)" }
        if keys.allSatisfy(unticked.contains) {
            unticked.subtract(keys)
        } else {
            unticked.formUnion(keys)
        }
    }

    private func chip(_ text: String, key: String, valid: Bool) -> some View {
        let on = valid && !unticked.contains(key)
        return Button {
            if unticked.remove(key) == nil { unticked.insert(key) }
        } label: {
            Text(text)
                .lineLimit(1)
                .fixedSize()
                .strikethrough(!on)
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(on ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!valid)
        .help(valid ? (on ? "Click to leave it out" : "Click to keep it") : "Not an option on the board")
    }

    private func isValid(field: String, value: String) -> Bool {
        fields.first { $0.name == field }?.options.contains { $0.name == value } == true
    }

    private func categoryID(_ name: String) -> UUID? {
        configs.config(for: org).investmentConfig.categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    /// Board field writes ticked: the issue, field and option.
    private var changes: [FieldChange] {
        var changes: [FieldChange] = []
        let investments = configs.config(for: org).investmentConfig
        for issue in issues {
            guard let suggestion = suggestions[issue.id] else { continue }
            for (field, value) in suggestion.fields ?? [:] where isValid(field: field, value: value) && !unticked.contains("\(issue.id)|\(field)") {
                changes.append(FieldChange(issue: issue, field: field, value: value))
            }
            if case .projectField(_, _, let field) = investments.trackedBy, let name = suggestion.category,
               let id = categoryID(name), let value = investments.category(id: id)?.githubValue,
               !unticked.contains("\(issue.id)|\u{0}category") {
                changes.append(FieldChange(issue: issue, field: field, value: value))
            }
        }
        return changes
    }

    /// Categories chosen in Gannin, when that's where they're tracked.
    private var categoryChanges: [(IssueRecord, UUID)] {
        guard configs.config(for: org).investmentConfig.trackedBy == .gannin else { return [] }
        return issues.compactMap { issue in
            guard let name = suggestions[issue.id]?.category, let id = categoryID(name), !unticked.contains("\(issue.id)|\u{0}category") else { return nil }
            return (issue, id)
        }
    }

    private var writeSheet: some View {
        FieldWriteSheet(org: org, changes: changes, board: board) {
            for (issue, id) in categoryChanges { configs.setCategory(id, for: issue.id, in: org) }
            writing = false
            dismiss()
        }
    }

    private func suggest() async {
        if let number = configs.config(for: org).workflow.projectNumber {
            await projects.loadDefinition(org: org, number: number)
        }
        for issue in issues where details.detail(for: issue.id) == nil {
            await details.load(issue.id)
        }
        let investments = configs.config(for: org).investmentConfig
        let fieldText = fields.map { "- \($0.name): \($0.options.map(\.name).joined(separator: " | "))" }.joined(separator: "\n")
        let categoryText = investments.categories.map { "- \($0.name): \($0.details)" }.joined(separator: "\n")
        let issueText = issues.map { issue in
            let body = details.detail(for: issue.id)?.body.prefix(1500) ?? ""
            return "### \(issue.repo)#\(issue.number): \(issue.title)\nLabels: \(issue.labels.joined(separator: ", "))\n\(body)"
        }.joined(separator: "\n\n")
        let prompt = """
            Triage these GitHub issues for an engineering team. For each, suggest a value for each board field below where you can tell (leave a field out when you can't), the investment category it belongs to, whether it's a good task to hand to an AI coding agent (clear, self-contained, low risk), and one short sentence of why.

            Board fields and their options (use them exactly):
            \(fieldText.isEmpty ? "(none)" : fieldText)

            Investment categories:
            \(categoryText)

            Issues:
            \(issueText)

            Reply with only a JSON list: [{"number": 123, "repo": "owner/name", "fields": {"Field": "Option"}, "category": "Name", "agent": true, "why": "..."}]
            """
        do {
            let reply = try await ClaudeRunner.ask(prompt, org: org)
            guard let list = ClaudeRunner.json([Lenient<Suggestion>].self, in: reply)?.compactMap(\.value), !list.isEmpty else {
                error = "Claude's reply wasn't a list of suggestions. Try again, or see what it said below."
                rawReply = String(reply.prefix(4000))
                working = false
                return
            }
            for suggestion in list {
                if let issue = issues.first(where: { $0.number == suggestion.number && (suggestion.repo == nil || $0.repo == suggestion.repo) }) {
                    suggestions[issue.id] = suggestion
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}
#endif
