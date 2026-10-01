import Observation
import SwiftUI

/// A point raised in the prioritisation meeting that isn't in GitHub yet:
/// something CS heard from the field. Kept until it's dealt with.
struct FieldNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var raisedAt: Date
    var doneAt: Date?
}

/// What's been heard from the field, per org, on this Mac.
@Observable
final class FieldNotesStore {
    private(set) var notes: [String: [FieldNote]] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: [FieldNote]].self, from: data) {
            notes = saved
        }
    }

    func notes(for org: String) -> [FieldNote] { notes[org] ?? [] }

    func add(_ text: String, in org: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes[org, default: []].append(FieldNote(text: text, raisedAt: .now))
        save()
    }

    func setDone(_ id: UUID, _ isDone: Bool, in org: String) {
        guard let index = notes[org]?.firstIndex(where: { $0.id == id }) else { return }
        notes[org]?[index].doneAt = isDone ? .now : nil
        save()
    }

    func remove(_ id: UUID, in org: String) {
        notes[org]?.removeAll { $0.id == id }
        save()
    }

    private static let key = "fieldNotes"

    private func save() {
        if let data = try? JSONEncoder().encode(notes) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Meetings › Prioritisation, for the morning session with CS: triage (open
/// issues with no Status on the workflow board, or not on it), what's been
/// heard from the field, and the issues with a committed date, soonest
/// first. Issues open in the drawer, where their Status and fields are set.
struct PrioritisationView: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HiddenStore.self) private var hidden
    @Environment(FieldNotesStore.self) private var fieldNotes
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String
    let workload: Workload
    @Binding var selection: DetailSelection?

    /// The board's date field that says an issue's committed to.
    @AppStorage private var dateField: String
    @State private var note = ""
    @State private var search = ""
    @FocusState private var isNoting: Bool

    init(org: String, workload: Workload, selection: Binding<DetailSelection?>) {
        self.org = org
        self.workload = workload
        _selection = selection
        _dateField = AppStorage(wrappedValue: "Committed", "prioritisationDateField.\(org)")
    }

    var body: some View {
        let workflow = configs.config(for: org).workflow
        VStack(spacing: 0) {
            bar(board: workflow.projectNumber)
            Divider()
            if let board = workflow.projectNumber {
                List(selection: $selection) {
                    triage(board: board)
                    field
                    committed(board: board)
                }
            } else {
                ContentUnavailableView(
                    "No board",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Pick the board issues move across in the org's Settings, under Issues, for triage and committed dates.")
                )
            }
        }
        .task(id: org) { await issueStore.sync(org, windowDays: windowDays) }
    }

    // MARK: Bar

    private func bar(board: Int?) -> some View {
        HStack(spacing: 8) {
            FilterSearchField(text: $search, prompt: "Title, number or person")
            Spacer(minLength: 0)
            if let board {
                let fields = dateFields(board: board)
                Picker("Committed date", selection: $dateField) {
                    ForEach(fields.contains(dateField) ? fields : [dateField] + fields, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                .help("The board's date field that says when an issue is committed to")
            }
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Date fields issues on the board have, by name.
    private func dateFields(board: Int) -> [String] {
        var names: Set<String> = []
        for issue in openIssues {
            for (name, value) in issue.fields(onProject: board)?.values ?? [:] {
                if case .date = value { names.insert(name) }
            }
        }
        return names.sorted()
    }

    // MARK: Issues

    /// Open issues the workload counts: excluded repos and hidden ones left
    /// out, and the search applied.
    private var openIssues: [IssueRecord] {
        let excluded = configs.config(for: org).excludedRepos
        let members = workload.team.map { Set($0.members) }
        return (issueStore.history(for: org).map { Array($0.issues.values) } ?? [])
            .filter { $0.isOpen && !excluded.contains($0.repo) && !hidden.keys.contains($0.id) }
            .filter { issue in members.map { team in issue.assignees.contains(where: team.contains) || issue.assignees.isEmpty } ?? true }
            .filter { issue in
                IssueSearch.matches(search, title: issue.title, repo: issue.repo, number: issue.number,
                                    people: issue.assignees + issue.assignees.map { workload.person(login: $0).displayName } + [issue.author].compactMap { $0 },
                                    labels: issue.labels)
            }
    }

    /// No Status on the board, or not on it: newest first.
    @ViewBuilder
    private func triage(board: Int) -> some View {
        let issues = openIssues
            .filter { issue in
                guard let fields = issue.fields(onProject: board) else { return true }
                return fields.values["Status"] == nil
            }
            .sorted { $0.createdAt > $1.createdAt }
        Section(header: SectionHeader(title: "Triage", count: issues.count)) {
            if issues.isEmpty {
                Text(issueStore.history(for: org) == nil ? "Loading issues." : "Nothing to triage: every open issue has a Status.")
                    .foregroundStyle(.secondary)
            }
            ForEach(issues) { issue in
                row(issue, detail: issue.fields(onProject: board) == nil ? "Not on the board" : "No status", since: issue.createdAt, sinceLabel: "Opened")
            }
        }
    }

    /// Open issues with the committed date set: overdue first, then the soonest.
    @ViewBuilder
    private func committed(board: Int) -> some View {
        let dated = openIssues.compactMap { issue -> (IssueRecord, Date)? in
            if case .date(let date) = issue.fields(onProject: board)?.values[dateField] { return (issue, date) }
            return nil
        }
        .sorted { $0.1 < $1.1 }
        Section(header: SectionHeader(title: dateField, count: dated.count)) {
            if dated.isEmpty {
                Text("No open issue has \(dateField) set on the board.").foregroundStyle(.secondary)
            }
            ForEach(dated, id: \.0.id) { issue, date in
                let status = issue.fields(onProject: board)?.values["Status"]?.display ?? "No status"
                row(issue, detail: status, due: date)
            }
        }
    }

    private func row(_ issue: IssueRecord, detail: String, since: Date? = nil, sinceLabel: String = "", due: Date? = nil) -> some View {
        let reference = IssueReference(org: org, record: issue)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(issue.repo)#\(String(issue.number))")
                    Text("· \(detail)")
                    if !issue.labels.isEmpty { Text("· \(issue.labels.prefix(3).joined(separator: ", "))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let due {
                dueText(due)
            } else if let since {
                RelativeDate(date: since)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("\(sinceLabel) \(since.formatted(date: .abbreviated, time: .shortened))")
            }
            AvatarStack(people: issue.assignees.map { workload.person(login: $0) })
        }
        .padding(.vertical, 2)
        .tag(DetailSelection.issueReference(reference))
        .hideable(issue.id, url: issue.url, opens: .issueReference(reference))
    }

    /// The date, red once it's passed and orange within the week.
    private func dueText(_ date: Date) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        let color: Color = days < 0 ? ChartPalette.critical : days <= 7 ? ChartPalette.warning : .secondary
        let words = days < 0 ? "\(-days)d overdue" : days == 0 ? "Today" : days == 1 ? "Tomorrow" : date.formatted(.dateTime.day().month(.abbreviated))
        return Text(words)
            .font(.callout.monospacedDigit())
            .foregroundStyle(color)
            .help(date.formatted(date: .complete, time: .omitted))
    }

    // MARK: From the field

    /// Points CS raise, ticked off when dealt with. Those still open carry
    /// over to the next meeting; ticked ones show for the day they're ticked.
    @ViewBuilder
    private var field: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let notes = fieldNotes.notes(for: org).filter { note in note.doneAt.map { $0 >= today } ?? true }
        let open = notes.filter { $0.doneAt == nil }.count
        Section(header: SectionHeader(title: "From the field", count: open)) {
            HStack(spacing: 8) {
                TextField("Something heard from the field", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNoting)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(notes) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle(isOn: Binding(get: { item.doneAt != nil }, set: { fieldNotes.setDone(item.id, $0, in: org) })) {
                        Text(item.text)
                            .strikethrough(item.doneAt != nil)
                            .foregroundStyle(item.doneAt != nil ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .checkboxToggle()
                    Spacer(minLength: 8)
                    Text(Calendar.current.isDateInToday(item.raisedAt) ? "Today" : item.raisedAt.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        fieldNotes.remove(item.id, in: org)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
        }
    }

    private func add() {
        fieldNotes.add(note, in: org)
        note = ""
        isNoting = true
    }
}
