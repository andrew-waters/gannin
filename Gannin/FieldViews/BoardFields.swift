import SwiftUI

// MARK: - Writes

/// An option as sent to GitHub. With its `id`, GitHub keeps the option's
/// identity, so issues keep their value through a rename, recolour or
/// reorder; without one it's new.
struct FieldOptionInput: Hashable {
    var id: String?
    var name: String
    var color: String
    var description: String

    /// A GraphQL input object, strings escaped as JSON (which GraphQL reads).
    var literal: String {
        var parts: [String] = []
        if let id { parts.append("id: \(Self.string(id))") }
        parts.append("name: \(Self.string(name))")
        parts.append("color: \(color)")
        parts.append("description: \(Self.string(description))")
        return "{ \(parts.joined(separator: ", ")) }"
    }

    static func string(_ value: String) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "\"\""
    }
}

extension GitHubAPI {
    /// Renames a field and/or replaces its options (the whole list, each
    /// existing one with its ID). A write.
    func updateProjectField(fieldID: String, name: String?, options: [FieldOptionInput]?, multiSelect: Bool) async throws {
        // updateProjectV2Field is nullable: an empty Response would decode
        // past a refusal (no write access to the board) rather than
        // surfacing it.
        struct Response: Decodable {
            struct Payload: Decodable { let clientMutationId: String? }
            let updateProjectV2Field: Payload
        }
        var input = ["fieldId: $field"]
        var variables = ["field": fieldID]
        if let name {
            input.append("name: $name")
            variables["name"] = name
        }
        if let options {
            input.append("\(multiSelect ? "multiSelectOptions" : "singleSelectOptions"): [\(options.map(\.literal).joined(separator: ", "))]")
        }
        let _: Response = try await query("""
            mutation($field: ID!\(name == nil ? "" : ", $name: String!")) {
              updateProjectV2Field(input: { \(input.joined(separator: ", ")) }) { clientMutationId }
            }
            """, variables: variables)
    }

    /// A new field on the board, with its options for a select. A write.
    func createProjectField(projectID: String, name: String, dataType: String, options: [FieldOptionInput]) async throws {
        // Nullable, as updateProjectV2Field is.
        struct Response: Decodable {
            struct Payload: Decodable { let clientMutationId: String? }
            let createProjectV2Field: Payload
        }
        var input = ["projectId: $project", "name: $name", "dataType: \(dataType)"]
        if dataType == "SINGLE_SELECT" || dataType == "MULTI_SELECT" {
            input.append("\(dataType == "MULTI_SELECT" ? "multiSelectOptions" : "singleSelectOptions"): [\(options.map(\.literal).joined(separator: ", "))]")
        }
        let _: Response = try await query("""
            mutation($project: ID!, $name: String!) {
              createProjectV2Field(input: { \(input.joined(separator: ", ")) }) { clientMutationId }
            }
            """, variables: ["project": projectID, "name": name])
    }

    /// Deletes a field, and every item's value in it. A write.
    func deleteProjectField(fieldID: String) async throws {
        // Nullable, as the other field mutations are.
        struct Response: Decodable {
            struct Payload: Decodable { let clientMutationId: String? }
            let deleteProjectV2Field: Payload
        }
        let _: Response = try await query("""
            mutation($field: ID!) {
              deleteProjectV2Field(input: { fieldId: $field }) { clientMutationId }
            }
            """, variables: ["field": fieldID])
    }
}

// MARK: - Drafts

/// A field being edited, or made.
struct FieldDraft: Hashable {
    struct Option: Identifiable, Hashable {
        let key = UUID()
        /// GitHub's ID; nil for an option added here.
        var id: String?
        var name: String
        var color: String
        var description: String

        var input: FieldOptionInput { FieldOptionInput(id: id, name: name.trimmingCharacters(in: .whitespaces), color: color, description: description) }
    }

    static let types = ["SINGLE_SELECT", "MULTI_SELECT", "TEXT", "NUMBER", "DATE"]
    static let colors = ["GRAY", "BLUE", "GREEN", "YELLOW", "ORANGE", "RED", "PINK", "PURPLE"]

    /// nil for a field being made.
    var fieldID: String?
    var name: String
    var dataType: String
    var options: [Option]

    var hasOptions: Bool { dataType == "SINGLE_SELECT" || dataType == "MULTI_SELECT" }

    init(field: BoardField) {
        fieldID = field.id
        name = field.name
        dataType = field.dataType
        options = field.dataType == "ITERATION" ? [] : field.options.map {
            Option(id: $0.id, name: $0.name, color: $0.color ?? "GRAY", description: $0.description ?? "")
        }
    }

    init(newOfType dataType: String) {
        fieldID = nil
        name = ""
        self.dataType = dataType
        options = dataType == "SINGLE_SELECT" || dataType == "MULTI_SELECT" ? [Option(id: nil, name: "", color: "GRAY", description: "")] : []
    }

    static func typeName(_ dataType: String) -> String {
        switch dataType {
        case "SINGLE_SELECT": "Single select"
        case "MULTI_SELECT": "Multi select"
        case "TEXT": "Text"
        case "NUMBER": "Number"
        case "DATE": "Date"
        case "ITERATION": "Iteration"
        default: dataType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Why it can't be written yet, if it can't.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the field a name." }
        guard hasOptions else { return nil }
        let names = options.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if names.isEmpty { return "A select needs at least one option." }
        if names.contains("") { return "Every option needs a name." }
        if Set(names).count != names.count { return "Two options have the same name." }
        return nil
    }

    /// What writing this would change, in words, against the field as it is.
    /// Removing an option that issues have is a warning.
    func changes(from original: BoardField?, usage: [String: Int]) -> [(text: String, isWarning: Bool)] {
        guard let original else {
            var lines = [("Add the \(Self.typeName(dataType).lowercased()) field \(name)", false)]
            if hasOptions { lines.append(("With options \(options.map(\.name).joined(separator: ", "))", false)) }
            return lines
        }
        var lines: [(String, Bool)] = []
        if name != original.name { lines.append(("Rename \(original.name) to \(name)", false)) }
        guard hasOptions else { return lines }
        let before = Dictionary(uniqueKeysWithValues: original.options.map { ($0.id, $0) })
        let kept = Set(options.compactMap(\.id))
        for option in original.options where !kept.contains(option.id) {
            let count = usage[option.name] ?? 0
            lines.append(("Remove \(option.name)" + (count == 0 ? "" : ", clearing it from \(count == 1 ? "1 issue" : "\(count) issues")"), count > 0))
        }
        for option in options {
            guard let id = option.id, let old = before[id] else {
                lines.append(("Add \(option.name)", false))
                continue
            }
            if old.name != option.name { lines.append(("Rename \(old.name) to \(option.name)", false)) }
            if (old.color ?? "GRAY") != option.color { lines.append(("Recolour \(option.name) \(option.color.lowercased())", false)) }
            if (old.description ?? "") != option.description { lines.append((option.description.isEmpty ? "Clear \(option.name)'s description" : "Describe \(option.name): \(option.description)", false)) }
        }
        let oldOrder = original.options.map(\.id).filter(kept.contains)
        let newOrder = options.compactMap(\.id)
        if oldOrder != newOrder { lines.append(("Reorder the options", false)) }
        return lines
    }
}

// MARK: - Editor

/// Board Fields: every field on a board, and for its own fields (not
/// GitHub's built-ins) their name and options: added, renamed, recoloured,
/// described, reordered and removed, with how many issues each has. New
/// fields can be made and fields deleted. Every change is reviewed before
/// it's written, and the issue history follows at once.
struct BoardFieldsEditor: View {
    private enum Stage: Equatable {
        case editing
        case reviewing(deleting: Bool)
        case writing
        case failed(String)
    }

    @Environment(ProjectStore.self) private var projects
    @Environment(IssueStore.self) private var issueStore
    @Environment(AuthStore.self) private var auth
    @Environment(\.openURL) private var openURL

    let org: String
    let number: Int
    let onClose: () -> Void

    @State private var selected: String?
    @State private var draft: FieldDraft?
    @State private var stage: Stage = .editing

    private var board: Board? { projects.cache(org: org, number: number)?.board }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                fieldList
                    .frame(width: 230)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 620)
        .task { await projects.loadDefinition(org: org, number: number, force: true) }
        .onChange(of: selected) {
            stage = .editing
            draft = selected.flatMap { id in board?.fields.first { $0.id == id } }.map(FieldDraft.init(field:))
        }
    }

    // MARK: Fields

    private static let editableTypes: Set<String> = ["SINGLE_SELECT", "MULTI_SELECT", "TEXT", "NUMBER", "DATE", "ITERATION"]

    private var fieldList: some View {
        let fields = board?.fields ?? []
        return List(selection: $selected) {
            Section(board?.title ?? "Fields") {
                ForEach(fields.filter { Self.editableTypes.contains($0.dataType) }) { field in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.name)
                        Text(FieldDraft.typeName(field.dataType) + (field.dataType == "ITERATION" || field.options.isEmpty ? "" : ", \(field.options.count) options"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(field.id)
                }
            }
            Section("Built in") {
                ForEach(fields.filter { !Self.editableTypes.contains($0.dataType) }) { field in
                    Text(field.name).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch stage {
        case .reviewing(let deleting):
            review(deleting: deleting)
        case .writing:
            ProgressView("Writing to GitHub").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't write it", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Back to Editing") { stage = .editing }
            }
        case .editing:
            if let draft = Binding($draft) {
                editor(draft)
            } else {
                ContentUnavailableView("Pick a field", systemImage: "square.grid.3x1.below.line.grid.1x2", description: Text("Or make a new one."))
            }
        }
    }

    private func editor(_ draft: Binding<FieldDraft>) -> some View {
        let original = original(draft.wrappedValue)
        let usage = usage(of: original?.name ?? draft.wrappedValue.name)
        return Form {
            Section {
                TextField("Name", text: draft.name)
                if draft.wrappedValue.fieldID == nil {
                    Picker("Type", selection: draft.dataType) {
                        ForEach(FieldDraft.types, id: \.self) { Text(FieldDraft.typeName($0)).tag($0) }
                    }
                    .onChange(of: draft.wrappedValue.dataType) {
                        if draft.wrappedValue.hasOptions, draft.wrappedValue.options.isEmpty {
                            draft.wrappedValue.options = [FieldDraft.Option(id: nil, name: "", color: "GRAY", description: "")]
                        }
                    }
                } else {
                    LabeledContent("Type", value: FieldDraft.typeName(draft.wrappedValue.dataType))
                }
            }
            if draft.wrappedValue.hasOptions {
                Section("Options") {
                    ForEach(draft.options) { $option in
                        optionRow($option, count: option.id.flatMap { id in original?.options.first { $0.id == id }?.name }.flatMap { usage[$0] } ?? 0, draft: draft)
                    }
                    .onMove { draft.wrappedValue.options.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        draft.wrappedValue.options.append(FieldDraft.Option(id: nil, name: "", color: "GRAY", description: ""))
                    } label: {
                        Label("Add Option", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if draft.wrappedValue.dataType == "ITERATION", let original {
                Section {
                    if let duration = original.iterationDuration {
                        LabeledContent("Length", value: duration == 7 ? "1 week" : duration % 7 == 0 ? "\(duration / 7) weeks" : "\(duration) days")
                    }
                    ForEach(original.options) { iteration in
                        LabeledContent(iteration.name, value: iteration.start.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                    }
                } header: {
                    Text("Iterations")
                } footer: {
                    Text("Change iterations on GitHub for now: GitHub doesn't keep an iteration's identity when they're changed from outside, so issues could lose their sprint.")
                        .foregroundStyle(.secondary)
                }
            }
            if draft.wrappedValue.fieldID != nil, draft.wrappedValue.dataType != "ITERATION" {
                Section {
                    Button("Delete Field", role: .destructive) { stage = .reviewing(deleting: true) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func optionRow(_ option: Binding<FieldDraft.Option>, count: Int, draft: Binding<FieldDraft>) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(FieldDraft.colors, id: \.self) { color in
                    Button {
                        option.wrappedValue.color = color
                    } label: {
                        Label(color.capitalized, systemImage: option.wrappedValue.color == color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Circle().fill(BoardLayout.color(option.wrappedValue.color)).frame(width: 12, height: 12)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Colour")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Option", text: option.name, prompt: Text("Name"))
                    .labelsHidden()
                TextField("Description", text: option.description, prompt: Text("What it means (optional)"))
                    .labelsHidden()
                    .font(.caption)
            }
            Text(count == 0 ? "" : count == 1 ? "1 issue" : "\(count) issues")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Button {
                draft.wrappedValue.options.removeAll { $0.key == option.wrappedValue.key }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(count == 0 ? "Remove this option" : "Remove this option, clearing it from \(count == 1 ? "1 issue" : "\(count) issues")")
        }
    }

    // MARK: Review and write

    private func review(deleting: Bool) -> some View {
        let draft = draft
        let original = draft.flatMap(original)
        let usage = usage(of: original?.name ?? draft?.name ?? "")
        let used = usage.values.reduce(0, +)
        let lines: [(text: String, isWarning: Bool)] = deleting
            ? [("Delete \(original?.name ?? "the field")" + (used == 0 ? "" : ", clearing it from \(used == 1 ? "1 issue" : "\(used) issues")"), true)]
            : draft?.changes(from: original, usage: usage) ?? []
        return VStack(alignment: .leading, spacing: 12) {
            Text(deleting ? "Delete this field on \(board?.title ?? "the board")?" : "Write these changes to \(board?.title ?? "the board")?")
                .font(.title3.weight(.semibold))
            Text(deleting ? "Its values go too, on every item. This can't be undone from Gannin." : "Options keep their issues through a rename, recolour or reorder.")
                .foregroundStyle(.secondary)
            List(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line.text, systemImage: line.isWarning ? "exclamationmark.triangle.fill" : "circle.fill")
                    .foregroundStyle(line.isWarning ? ChartPalette.critical : .primary)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(FieldDraft.types, id: \.self) { type in
                    Button(FieldDraft.typeName(type)) {
                        selected = nil
                        stage = .editing
                        draft = FieldDraft(newOfType: type)
                    }
                }
            } label: {
                Label("New Field", systemImage: "plus")
            }
            .fixedSize()
            if let board {
                Button("Open on GitHub") { openURL(board.url) }.linkButton()
            }
            Spacer()
            if let problem = draft?.problem, stage == .editing, isChanged {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
            switch stage {
            case .reviewing(let deleting):
                Button("Back") { stage = .editing }
                    .keyboardShortcut(.cancelAction)
                Button(deleting ? "Delete Field" : "Write Changes", role: deleting ? .destructive : nil) {
                    Task { await write(deleting: deleting) }
                }
                .keyboardShortcut(.defaultAction)
            case .writing:
                EmptyView()
            case .editing, .failed:
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Revert") { revert() }
                    .disabled(!isChanged)
                Button("Review Changes") { stage = .reviewing(deleting: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isChanged || draft?.problem != nil)
            }
        }
        .padding(16)
    }

    private var isChanged: Bool {
        guard let draft else { return false }
        guard let original = original(draft) else { return true }
        return !draft.changes(from: original, usage: [:]).isEmpty
    }

    private func revert() {
        guard let draft else { return }
        self.draft = original(draft).map(FieldDraft.init(field:))
    }

    private func original(_ draft: FieldDraft) -> BoardField? {
        draft.fieldID.flatMap { id in board?.fields.first { $0.id == id } }
    }

    /// Issues on the board with each value of the field, by name.
    private func usage(of field: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for issue in issueStore.history(for: org).map({ Array($0.issues.values) }) ?? [] {
            switch issue.fields(onProject: number)?.values[field] {
            case .option(let name, _)?: counts[name, default: 0] += 1
            case .options(let names)?: for name in names { counts[name, default: 0] += 1 }
            default: break
            }
        }
        return counts
    }

    private func write(deleting: Bool) async {
        guard let api = auth.api, let board, let draft else { return }
        let original = original(draft)
        stage = .writing
        do {
            if deleting, let original {
                try await api.deleteProjectField(fieldID: original.id)
                issueStore.rewriteFieldValues(org: org, projectNumber: number) { $0[original.name] = nil }
                self.draft = nil
                selected = nil
            } else if let original {
                let nameChanged = draft.name != original.name
                let optionsChanged = draft.hasOptions && draft.options.map(\.input) != original.options.map {
                    FieldOptionInput(id: $0.id, name: $0.name, color: $0.color ?? "GRAY", description: $0.description ?? "")
                }
                try await api.updateProjectField(
                    fieldID: original.id,
                    name: nameChanged ? draft.name : nil,
                    options: optionsChanged ? draft.options.map(\.input) : nil,
                    multiSelect: draft.dataType == "MULTI_SELECT"
                )
                followInHistory(draft, original: original)
            } else {
                try await api.createProjectField(projectID: board.id, name: draft.name, dataType: draft.dataType, options: draft.options.map(\.input))
            }
            await projects.loadDefinition(org: org, number: number, force: true)
            stage = .editing
            if !deleting {
                // Pick up what GitHub made, IDs and all.
                let saved = projects.cache(org: org, number: number)?.board.fields.first { $0.name == draft.name }
                selected = saved?.id
                self.draft = saved.map(FieldDraft.init(field:))
            }
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Renames and reorders in the stored issues straight away, and drops
    /// removed options, so views match before the next fetch.
    private func followInHistory(_ draft: FieldDraft, original: BoardField) {
        var renamed: [String: (name: String, position: Int)] = [:]
        for (position, option) in draft.options.enumerated() {
            guard let id = option.id, let old = original.options.first(where: { $0.id == id }) else { continue }
            renamed[old.name] = (option.name, position)
        }
        let oldName = original.name
        let newName = draft.name
        issueStore.rewriteFieldValues(org: org, projectNumber: number) { values in
            guard let value = values[oldName] else { return }
            values[oldName] = nil
            switch value {
            case .option(let name, _):
                if let new = renamed[name] { values[newName] = .option(name: new.name, position: new.position) }
            case .options(let names):
                let kept = names.compactMap { renamed[$0]?.name }
                if !kept.isEmpty { values[newName] = .options(kept) }
            default:
                values[newName] = value
            }
        }
    }
}

/// Opens Board Fields from a view.
struct BoardFieldsRequest: Identifiable {
    let number: Int
    var id: Int { number }
}
