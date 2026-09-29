import SwiftUI

/// Makes or changes a field view: its name and board, what it groups by
/// (in order, as many as wanted), and which issues it keeps.
struct FieldViewEditor: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(ProjectStore.self) private var projects
    @Environment(OrgConfigStore.self) private var configs

    let org: String
    let onSave: (FieldView) -> Void
    let onCancel: () -> Void
    @State private var draft: FieldView

    init(org: String, view: FieldView, onSave: @escaping (FieldView) -> Void, onCancel: @escaping () -> Void) {
        self.org = org
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: view)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Board", selection: $draft.projectNumber) {
                        Text("None: every issue").tag(Int?.none)
                        Divider()
                        ForEach(projects.boardLists[org] ?? []) { board in
                            Text(board.title).tag(Optional(board.number))
                        }
                    }
                    Picker("Issues", selection: $draft.state) {
                        ForEach(FieldViewState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Layout", selection: $draft.layout) {
                        ForEach(FieldViewLayout.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.systemImage).tag($0) }
                    }
                    Picker("Measure", selection: $draft.measure) {
                        ForEach(FieldMeasure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } footer: {
                    Text("The board's columns are the first grouping and its swimlanes the second; the grid needs two; Aging places each issue in the first by how long it's been there.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Group by") {
                    ForEach(draft.dimensions.indices, id: \.self) { index in
                        HStack {
                            Text(verbatim: "\(index + 1)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            keyPicker(selection: $draft.dimensions[index])
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                .help("Group by this sooner")
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless)
                                .disabled(index == draft.dimensions.count - 1)
                                .help("Group by this later")
                            Button { draft.dimensions.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop grouping by this")
                        }
                    }
                    Menu("Add Grouping") {
                        keyMenu(excluding: Set(draft.dimensions)) { draft.dimensions.append($0) }
                    }
                    .fixedSize()
                }

                Section("Only issues where") {
                    if draft.filters.isEmpty {
                        Text("Every issue on the board, in the state above.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($draft.filters) { $filter in
                        HStack {
                            keyPicker(selection: $filter.key)
                                .onChange(of: filter.key) { filter.values = [] }
                            Text("is").foregroundStyle(.secondary)
                            valuesMenu($filter)
                            Button { draft.filters.removeAll { $0.id == filter.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove this filter")
                        }
                    }
                    Menu("Add Filter") {
                        keyMenu(excluding: []) { draft.filters.append(FieldFilter(key: $0, values: [])) }
                    }
                    .fixedSize()
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(cleaned) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.name.isEmpty || cleaned.dimensions.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .task(id: draft.projectNumber) {
            await projects.loadBoards(org: org)
            if let number = draft.projectNumber { await projects.loadDefinition(org: org, number: number) }
        }
    }

    /// Trimmed, and without filters that allow everything.
    private var cleaned: FieldView {
        var view = draft
        view.name = view.name.trimmingCharacters(in: .whitespaces)
        view.filters.removeAll { $0.values.isEmpty }
        return view
    }

    private func move(_ index: Int, by step: Int) {
        let target = index + step
        guard draft.dimensions.indices.contains(target) else { return }
        draft.dimensions.swapAt(index, target)
    }

    // MARK: Keys and values

    /// The board's fields (from its definition, or as seen on its issues),
    /// then the issue's own attributes.
    private var fieldKeys: [FieldKey] {
        guard let number = draft.projectNumber else { return [] }
        let defined = (projects.cache(org: org, number: number)?.board.fields ?? [])
            .filter { ["SINGLE_SELECT", "ITERATION", "NUMBER", "DATE", "TEXT"].contains($0.dataType) }
            .map(\.name)
            .filter { $0 != "Title" }
        let seen = FieldView.fieldNames(in: issueStore.history(for: org), board: number)
        var names = defined
        for name in seen where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        return names.map(FieldKey.field)
    }

    private var keys: [FieldKey] { fieldKeys + FieldKey.attributes + FieldKey.derived }

    private func keyPicker(selection: Binding<FieldKey>) -> some View {
        Picker("Field", selection: selection) {
            if !fieldKeys.isEmpty {
                Section("Board fields") {
                    ForEach(fieldKeys, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Issue") {
                ForEach(FieldKey.attributes, id: \.self) { Text($0.title).tag($0) }
            }
            Section("Worked out") {
                ForEach(FieldKey.derived, id: \.self) { Text($0.title).tag($0) }
            }
            // A saved key the board no longer lists stays pickable.
            if !keys.contains(selection.wrappedValue) {
                Text(selection.wrappedValue.title).tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func keyMenu(excluding used: Set<FieldKey>, add: @escaping (FieldKey) -> Void) -> some View {
        let fields = fieldKeys.filter { !used.contains($0) }
        if !fields.isEmpty {
            Section("Board fields") {
                ForEach(fields, id: \.self) { key in Button(key.title) { add(key) } }
            }
        }
        Section("Issue") {
            ForEach(FieldKey.attributes.filter { !used.contains($0) }, id: \.self) { key in Button(key.title) { add(key) } }
        }
        Section("Worked out") {
            ForEach(FieldKey.derived.filter { !used.contains($0) }, id: \.self) { key in Button(key.title) { add(key) } }
        }
    }

    /// The values the key takes across the board's issues, each ticked in
    /// or out of the filter.
    private func valuesMenu(_ filter: Binding<FieldFilter>) -> some View {
        var base = draft
        base.filters = []
        let context = base.context(workflow: configs.config(for: org).workflow, history: issueStore.history(for: org))
        let values = FieldView.values(of: filter.wrappedValue.key, in: base.issues(in: issueStore.history(for: org), context: context), context: context)
        let picked = filter.wrappedValue.values
        let label = picked.isEmpty ? "Anything" : values.filter { picked.contains($0.name) }.map(\.title).joined(separator: ", ")
        return Menu {
            ForEach(values, id: \.self) { value in
                Toggle(value.title, isOn: Binding(
                    get: { filter.wrappedValue.values.contains(value.name) },
                    set: { isOn in
                        if isOn { filter.wrappedValue.values.insert(value.name) } else { filter.wrappedValue.values.remove(value.name) }
                    }
                ))
            }
        } label: {
            Text(label.isEmpty ? "Anything" : label).lineLimit(1)
        }
        #if !os(macOS)
        // Ticking several values without the menu closing each time.
        .menuActionDismissBehavior(.disabled)
        #endif
        .frame(maxWidth: 260, alignment: .leading)
    }
}
