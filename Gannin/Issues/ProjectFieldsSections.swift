import SwiftUI

/// The issue's project boards, one section each, with every editable field.
/// Edits stay local until Save sends them to GitHub.
struct ProjectFieldsSections: View {
    @Environment(AuthStore.self) private var auth
    @Environment(IssueStore.self) private var issueStore
    @Environment(ProjectStore.self) private var projectStore
    let org: String
    let issueID: String

    @State private var items: [ProjectItem] = []
    /// Values as GitHub has them, per item and field, to spot edits.
    @State private var saved: [String: [String: ProjectField.Value?]] = [:]
    @State private var loaded = false
    @State private var loadError: String?
    @State private var saving: Set<String> = []
    @State private var saveErrors: [String: String] = [:]
    @State private var projects: [OrgProject] = []
    @State private var membershipBusy = false
    @State private var membershipError: String?
    @State private var removing: ProjectItem?

    var body: some View {
        Group {
            if !auth.canUseProjects {
                Section("Project") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gannin needs project access to show and edit this issue's board fields. Sign out and back in to grant it.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Sign Out to Grant Access") { auth.signOut() }
                    }
                    .padding(.vertical, 4)
                }
            } else if !loaded {
                // Something must be on screen for the load task to run.
                Section("Project") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading").foregroundStyle(.secondary)
                    }
                }
            } else if items.isEmpty && loadError == nil {
                Section("Project") {
                    Text("Not on a project board.").foregroundStyle(.secondary)
                }
            }
            if let loadError {
                Section("Project") {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            ForEach($items) { $item in
                Section {
                    ForEach($item.fields) { $field in
                        row(item: item, field: $field)
                    }
                    if let error = saveErrors[item.id] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(item.projectTitle)
                        if saving.contains(item.id) {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer()
                        Button("Remove") { removing = item }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(membershipBusy)
                            .help("Take this issue off \(item.projectTitle)")
                    }
                }
                // Save and Revert in their own group, apart from the fields.
                let changes = changedFields(item)
                if !changes.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            Text(changes.count == 1 ? "1 unsaved change" : "\(changes.count) unsaved changes")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Revert") { revert($item) }
                                .disabled(saving.contains(item.id))
                            Button("Save") { save($item) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut("s")
                                .disabled(saving.contains(item.id))
                        }
                    }
                }
            }
            if auth.canUseProjects && loaded {
                addToProjectSection
            }
        }
        .task(id: issueID) { await load() }
        .confirmationDialog(
            "Remove this issue from \(removing?.projectTitle ?? "the project")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { item in
            Button("Remove from Project", role: .destructive) { remove(item) }
        } message: { _ in
            Text("Its field values on that board are lost. The issue itself isn't changed.")
        }
    }

    @ViewBuilder
    private func row(item: ProjectItem, field: Binding<ProjectField>) -> some View {
        let current = field.wrappedValue
        LabeledContent(current.name) {
            switch current.kind {
            case .singleSelect(let options), .iteration(let options):
                Picker(current.name, selection: Binding<String?>(
                    get: { if case .option(let id) = current.value { id } else { nil } },
                    set: { id in edit(field,  id.map(ProjectField.Value.option)) }
                )) {
                    Text("None").tag(String?.none)
                    ForEach(options) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            case .text:
                CommitField(text: { if case .text(let text) = current.value { text } else { "" } }()) { text in
                    edit(field,  text.isEmpty ? nil : .text(text))
                }
            case .number:
                NumberField(value: { if case .number(let number) = current.value { number } else { nil } }()) { number in
                    edit(field, number.map(ProjectField.Value.number))
                }
            case .date:
                if case .date(let date) = current.value {
                    HStack(spacing: 6) {
                        DatePicker(current.name, selection: Binding(
                            get: { date },
                            set: { edit(field,  .date($0)) }
                        ), displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                        Button { edit(field,  nil) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear")
                    }
                } else {
                    Button("Set Date") {
                        let today = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                        var utc = Calendar(identifier: .gregorian)
                        utc.timeZone = TimeZone(identifier: "UTC")!
                        edit(field,  utc.date(from: today).map(ProjectField.Value.date))
                    }
                }
            }
        }
    }

    /// Boards the issue isn't on yet.
    private var addToProjectSection: some View {
        let available = projects.filter { project in !items.contains { $0.projectID == project.id } }
        return Section {
            HStack(spacing: 8) {
                Menu("Add to Project") {
                    ForEach(available) { project in
                        Button(project.title) { add(project) }
                    }
                }
                .fixedSize()
                .disabled(available.isEmpty || membershipBusy)
                if membershipBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let membershipError {
                Label(membershipError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } footer: {
            if available.isEmpty && !projects.isEmpty {
                Text("Already on every open board.").foregroundStyle(.secondary)
            }
        }
    }

    private func add(_ project: OrgProject) {
        guard let api = auth.api else { return }
        membershipBusy = true
        membershipError = nil
        Task {
            defer { membershipBusy = false }
            do {
                try await api.addToProject(projectID: project.id, contentID: issueID)
                // A new item needs its own fields and built-ins fetched,
                // so this re-fetches the board's "everything" filter rather
                // than guessing at a `BoardItem` to patch in.
                await projectStore.sync(org: org, number: project.number, filter: "", force: true)
                await load()
            } catch {
                membershipError = "Couldn't add to \(project.title): \(Self.message(for: error))"
            }
        }
    }

    private func remove(_ item: ProjectItem) {
        guard let api = auth.api else { return }
        membershipBusy = true
        membershipError = nil
        Task {
            defer { membershipBusy = false }
            do {
                try await api.removeFromProject(projectID: item.projectID, itemID: item.id)
                projectStore.recordRemoved(org: org, number: item.projectNumber, itemID: item.id)
                await load()
            } catch {
                membershipError = "Couldn't remove from \(item.projectTitle): \(Self.message(for: error))"
            }
        }
    }

    /// A local edit; nothing goes to GitHub until Save.
    private func edit(_ field: Binding<ProjectField>, _ value: ProjectField.Value?) {
        field.wrappedValue.value = value
    }

    private func changedFields(_ item: ProjectItem) -> [ProjectField] {
        item.fields.filter { field in
            let original = saved[item.id]?[field.id] ?? nil
            return field.value != original
        }
    }

    /// GitHub keeps history for the Status field only, and the issue metrics
    /// read it; note the move locally so they update now.
    private func recordIfStatus(_ field: ProjectField, item: ProjectItem) {
        guard field.name.caseInsensitiveCompare("Status") == .orderedSame,
              case .singleSelect(let options) = field.kind,
              case .option(let id) = field.value,
              let status = options.first(where: { $0.id == id })?.name else { return }
        issueStore.recordStatusChange(org: org, issueID: issueID, status: status, projectNumber: item.projectNumber, projectTitle: item.projectTitle)
    }

    /// The saved value in the issue history's shape.
    private static func issueValue(_ field: ProjectField) -> IssueFieldValue? {
        switch (field.value, field.kind) {
        case (nil, _): nil
        case (.text(let text), _): .text(text)
        case (.number(let number), _): .number(number)
        case (.date(let date), _): .date(date)
        case (.option(let id), .singleSelect(let options)):
            options.firstIndex { $0.id == id }.map { .option(name: options[$0].name, position: $0) }
        case (.option(let id), .iteration(let options)):
            options.first { $0.id == id }.map { .iteration(title: $0.name, start: $0.start ?? .distantPast) }
        case (.option, _): nil
        }
    }

    private func revert(_ item: Binding<ProjectItem>) {
        let originals = saved[item.wrappedValue.id] ?? [:]
        for index in item.wrappedValue.fields.indices {
            let field = item.wrappedValue.fields[index]
            item.wrappedValue.fields[index].value = originals[field.id] ?? nil
        }
        saveErrors[item.wrappedValue.id] = nil
    }

    /// Sends each changed field in turn. Stops at the first failure and
    /// leaves the rest unsaved, so Save can simply be pressed again.
    private func save(_ item: Binding<ProjectItem>) {
        guard let api = auth.api else { return }
        let snapshot = item.wrappedValue
        let changes = changedFields(snapshot)
        guard !changes.isEmpty else { return }
        saving.insert(snapshot.id)
        saveErrors[snapshot.id] = nil
        Task {
            defer { saving.remove(snapshot.id) }
            for field in changes {
                do {
                    try await api.setProjectField(projectID: snapshot.projectID, itemID: snapshot.id, field: field, value: field.value)
                    saved[snapshot.id, default: [:]][field.id] = field.value
                    recordIfStatus(field, item: snapshot)
                    issueStore.recordFieldValue(org: org, issueID: issueID, projectNumber: snapshot.projectNumber, projectTitle: snapshot.projectTitle, field: field.name, value: Self.issueValue(field))
                    projectStore.recordFieldValue(org: org, number: snapshot.projectNumber, itemID: snapshot.id, field: field.name, value: Self.issueValue(field))
                } catch {
                    saveErrors[snapshot.id] = "Couldn't save \(field.name): \(Self.message(for: error))"
                    return
                }
            }
        }
    }

    private func load() async {
        guard let api = auth.api else { return }
        do {
            async let boards = api.orgProjects(org: org)
            items = try await api.projectItems(issueID: issueID)
            projects = (try? await boards) ?? projects
            saved = Dictionary(uniqueKeysWithValues: items.map { item in
                (item.id, Dictionary(uniqueKeysWithValues: item.fields.map { ($0.id, $0.value) }))
            })
            loadError = nil
            loaded = true
        } catch {
            loadError = Self.message(for: error)
            loaded = true
        }
    }

    /// Missing scopes read as a permissions error; say how to fix it.
    private static func message(for error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("scope") || text.localizedCaseInsensitiveContains("not accessible") {
            return "Gannin needs project access. Sign out and back in to grant it."
        }
        return text
    }
}

/// A text field for a text or number field. Edits pass up as you type (they
/// stay local until Save); a number that doesn't parse is left out.
private struct CommitField: View {
    let text: String
    let onCommit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("Value", text: $draft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 240)
            .onAppear { draft = text }
            .onChange(of: text) { if text != draft { draft = text } }
            .onChange(of: draft) { if draft != text { onCommit(draft) } }
    }
}

/// A number field: digits, a decimal point and a minus sign only, with a
/// stepper. Clearing it clears the value.
private struct NumberField: View {
    let value: Double?
    let onChange: (Double?) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("Number", text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 110)
                .onAppear { draft = Self.format(value) }
                .onChange(of: value) { if Double(draft) != value { draft = Self.format(value) } }
                .onChange(of: draft) {
                    let filtered = String(draft.filter { $0.isNumber || $0 == "." || $0 == "-" })
                    if filtered != draft {
                        draft = filtered
                        return
                    }
                    let trimmed = draft.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        if value != nil { onChange(nil) }
                    } else if let number = Double(trimmed), number != value {
                        onChange(number)
                    }
                }
            Stepper("Adjust", value: Binding(
                get: { value ?? 0 },
                set: { onChange($0) }
            ))
            .labelsHidden()
        }
    }

    /// Whole numbers without a trailing ".0".
    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

