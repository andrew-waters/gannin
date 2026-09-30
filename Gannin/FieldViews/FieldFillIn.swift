import SwiftUI

/// Fill In: issues one at a time, with one or more board fields to give
/// values. The number keys fill the first field still empty (0 skips it),
/// then the next; once every field has a value or a choice it moves on to
/// the next issue (Next and Previous with the arrows). A field that already
/// has a value shows it, and a click changes it. Choices collect until
/// Review and Write, which confirms every change before anything is written.
struct FieldFillIn: View {
    struct Request: Identifiable {
        let id = UUID()
        let fields: [String]
        let issues: [IssueRecord]

        init(field: String, issues: [IssueRecord]) {
            fields = [field]
            self.issues = issues
        }

        init(fields: [String], issues: [IssueRecord]) {
            self.fields = fields
            self.issues = issues
        }
    }

    @Environment(DetailStore.self) private var details
    @Environment(OrgStore.self) private var orgs

    let org: String
    /// With no fields, the sheet starts by asking for them.
    let requested: Request
    let board: Board?
    let onClose: () -> Void

    init(org: String, request: Request, board: Board?, onClose: @escaping () -> Void) {
        self.org = org
        requested = request
        self.board = board
        self.onClose = onClose
    }

    /// The fields and issues picked at the start, for a multi-field Fill In.
    @State private var picked: Request?
    private var request: Request { picked ?? requested }

    @State private var index = 0
    /// Chosen values by issue ID, then field.
    @State private var chosen: [String: [String: String]] = [:]
    /// Fields passed over on an issue with 0, by issue ID.
    @State private var skipped: [String: Set<String>] = [:]
    @State private var reviewing: [FieldChange]?

    var body: some View {
        if let reviewing {
            FieldWriteSheet(org: org, changes: reviewing, board: board, onClose: onClose)
        } else if request.fields.isEmpty, let board {
            FieldFillInSetup(board: board, issues: requested.issues) { picked = $0 } onCancel: {
                onClose()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if request.issues.indices.contains(index) {
                    card(request.issues[index])
                } else {
                    finished
                }
                Divider()
                footer
            }
            .frame(width: 720, height: request.fields.count > 1 ? 720 : 620)
        }
    }

    private var title: String {
        request.fields.count == 1 ? "Fill In \(request.fields[0])" : "Fill In \(request.fields.joined(separator: ", "))"
    }

    private func options(_ field: String) -> [BoardOption] {
        board?.field(named: field)?.options ?? []
    }

    private func current(_ issue: IssueRecord, _ field: String) -> String? {
        board.flatMap { issue.fields(onProject: $0.number)?.values[field]?.display }
    }

    /// The field the number keys fill: the first with no value, choice or skip.
    private func activeField(_ issue: IssueRecord) -> String? {
        request.fields.first { field in
            current(issue, field) == nil && chosen[issue.id]?[field] == nil && !(skipped[issue.id]?.contains(field) ?? false)
        }
    }

    private var changes: [FieldChange] {
        request.issues.flatMap { issue in
            request.fields.compactMap { field in
                guard let value = chosen[issue.id]?[field], value != current(issue, field) else { return nil }
                return FieldChange(issue: issue, field: field, value: value)
            }
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            Spacer()
            Text("\(min(index + 1, request.issues.count)) of \(request.issues.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            ProgressView(value: Double(min(index, request.issues.count)), total: Double(max(request.issues.count, 1)))
                .frame(width: 120)
        }
        .padding(16)
    }

    private var footer: some View {
        let count = changes.count
        return HStack(spacing: 10) {
            Button { index = max(0, index - 1) } label: { Label("Previous", systemImage: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index == 0)
            Button { index = min(request.issues.count, index + 1) } label: { Label("Next", systemImage: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index >= request.issues.count)
            Spacer()
            if count > 0 {
                Text(count == 1 ? "1 change to write" : "\(count) changes to write").foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Review and Write") { reviewing = changes }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
        }
        .padding(16)
    }

    // MARK: The issue

    private func card(_ issue: IssueRecord) -> some View {
        let active = activeField(issue)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    meta(issue)
                }
                otherFields(issue)
                ForEach(request.fields, id: \.self) { field in
                    fieldBlock(field, issue: issue, isActive: field == active)
                }
                if let body = details.detail(for: issue.id)?.body, !body.isEmpty {
                    Divider()
                    MarkdownText(source: String(body.prefix(4000)))
                        .font(.callout)
                }
            }
            .padding(16)
        }
        .task(id: issue.id) { await details.load(issue.id) }
    }

    /// One field's options; the active one has the number keys, and says so.
    private func fieldBlock(_ field: String, issue: IssueRecord, isActive: Bool) -> some View {
        let options = options(field)
        let existing = current(issue, field)
        return VStack(alignment: .leading, spacing: 8) {
            if request.fields.count > 1 {
                HStack(spacing: 8) {
                    Text(field).font(.headline)
                    if let existing, chosen[issue.id]?[field] == nil {
                        Text("is \(existing)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isActive {
                        Text("1 to \(min(options.count, 9)), or 0 to skip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                    optionButton(option, field: field, number: offset + 1, issue: issue, hasKeys: isActive || request.fields.count == 1)
                }
            }
            if options.isEmpty {
                Text("The board's options for \(field) haven't loaded.").foregroundStyle(.secondary)
            }
            if isActive, request.fields.count > 1 {
                Button("Skip") { skip(field, issue: issue) }
                    .keyboardShortcut("0", modifiers: [])
                    // Invisible but live, for its key.
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
        }
        .padding(request.fields.count > 1 ? 10 : 0)
        .background {
            if request.fields.count > 1 {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.6) : Color.separatorLine)
            }
        }
    }

    private func choose(_ value: String, field: String, issue: IssueRecord) {
        chosen[issue.id, default: [:]][field] = value
        advanceIfDone(issue)
    }

    private func skip(_ field: String, issue: IssueRecord) {
        skipped[issue.id, default: []].insert(field)
        advanceIfDone(issue)
    }

    /// On to the next issue once no field is left to fill.
    private func advanceIfDone(_ issue: IssueRecord) {
        if activeField(issue) == nil { index += 1 }
    }

    /// Open or closed, who opened it and when, where it is (the link to
    /// GitHub) and its type.
    private func meta(_ issue: IssueRecord) -> some View {
        let author = issue.author.map { login in
            orgs.snapshot(for: org)?.members.first { $0.login == login }
                ?? Person(login: login, name: nil, avatarUrl: URL(string: "https://github.com/\(login).png?size=64"))
        }
        return HStack(spacing: 6) {
            Pill(text: issue.isOpen ? "Open" : "Closed", color: issue.isOpen ? .green : .purple)
            if let author {
                Avatar(url: author.avatarUrl, size: 18)
                Text(author.displayName).help(author.login)
            }
            Text(author == nil ? "Opened" : "opened")
            Text(issue.createdAt.formatted(date: .abbreviated, time: .omitted))
            Text("(") + Text(issue.createdAt, format: .relative(presentation: .named)) + Text(")")
            Text("·")
            Link(destination: issue.url) {
                Text(verbatim: "\(issue.repo)#\(issue.number)")
            }
            .help("Open on GitHub")
            if let type = issue.issueType {
                Pill(text: type, color: .secondary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The issue's other values on the board, as chips in their options'
    /// colours: "Horizon · Now".
    private func otherFields(_ issue: IssueRecord) -> some View {
        let values = (board.flatMap { issue.fields(onProject: $0.number)?.values } ?? [:])
            .filter { !request.fields.contains($0.key) }
            .sorted { $0.key < $1.key }
        return FlowRow(spacing: 6) {
            ForEach(values, id: \.key) { name, value in
                HStack(spacing: 5) {
                    Circle()
                        .fill(color(field: name, value: value))
                        .frame(width: 7, height: 7)
                    Text(name).foregroundStyle(.secondary)
                    Text(value.display).lineLimit(1)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }

    private func color(field: String, value: IssueFieldValue) -> Color {
        guard let option = board?.field(named: field)?.options.first(where: { $0.name == value.display }) else { return .secondary.opacity(0.5) }
        return BoardLayout.color(option.color)
    }

    private func optionButton(_ option: BoardOption, field: String, number: Int, issue: IssueRecord, hasKeys: Bool) -> some View {
        let picked = chosen[issue.id]?[field] ?? current(issue, field)
        let isChosen = picked == option.name
        return Button {
            choose(option.name, field: field, issue: issue)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(BoardLayout.color(option.color)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).lineLimit(1)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if number <= 9, hasKeys {
                    Text(verbatim: "\(number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isChosen ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(number <= 9 && hasKeys ? KeyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: []) : nil)
    }

    private var finished: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("That's the lot.").font(.title3)
            Text(changes.isEmpty ? "Nothing chosen. Use Previous to pick up any you passed." : "Review and Write shows the changes before anything is written to GitHub.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Picks the fields for a multi-field Fill In, and which issues: those
/// missing any of them, or every issue in the view.
struct FieldFillInSetup: View {
    let board: Board
    let issues: [IssueRecord]
    let onStart: (FieldFillIn.Request) -> Void
    let onCancel: () -> Void

    @State private var picked: [String] = []
    @State private var everyIssue = false

    var body: some View {
        let fields = FieldColors.settableFields(board)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    ForEach(fields) { field in
                        let missing = issues.filter { $0.fields(onProject: board.number)?.values[field.name] == nil }.count
                        Toggle(isOn: Binding(
                            get: { picked.contains(field.name) },
                            set: { isOn in
                                picked.removeAll { $0 == field.name }
                                if isOn { picked.append(field.name) }
                            }
                        )) {
                            Text(field.name)
                            Text(missing == 0 ? "Every issue has one" : "\(missing) missing")
                        }
                    }
                } header: {
                    Text("Fields, in the order picked")
                }
                Section {
                    Picker("Issues", selection: $everyIssue) {
                        Text("Missing any of these").tag(false)
                        Text("Every issue in the view").tag(true)
                    }
                    .pickerStyle(.inline)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    let queue = everyIssue ? issues : issues.filter { issue in
                        picked.contains { issue.fields(onProject: board.number)?.values[$0] == nil }
                    }
                    onStart(FieldFillIn.Request(fields: picked, issues: queue))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440, height: 520)
    }
}
