import SwiftUI

/// Settings sections: which project board and statuses mark an issue as in
/// progress, for issue cycle time. With a board picked, its Status options
/// are the choices, in board order; otherwise the statuses issues have
/// passed through, plus any added by hand.
struct IssueWorkflowSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String

    @State private var newStatus = ""

    var body: some View {
        let workflow = configs.config(for: org).workflow
        let metrics = store.history(for: org).map { IssueMetrics(history: $0, windowDays: windowDays, team: nil, config: configs.config(for: org)) }
        let seen = metrics?.statusesSeen ?? []
        let options = workflow.projectNumber.flatMap { projects.cache(org: org, number: $0)?.board.field(named: "Status")?.options } ?? []
        let statuses = statuses(options: options, seen: seen, workflow: workflow)

        Section {
            Picker("Board", selection: binding(\.projectNumber)) {
                Text("Any board").tag(Int?.none)
                ForEach(boards(metrics: metrics, workflow: workflow), id: \.number) { board in
                    Text(board.title).tag(Optional(board.number))
                }
            }
            Toggle("Otherwise, start at the first linked PR", isOn: binding(\.fallBackToPullRequests))
        } header: {
            Text("Issue workflow")
        } footer: {
            Text("Cycle time is the time an issue spends in the statuses below on the board. The clock stops when it moves to any other status (Done, or back to Backlog) or is closed, and starts again if it comes back. Issues that never reach one fall back to their first linked PR, if that's on.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            if statuses.isEmpty {
                Text("Statuses appear here once issues have synced (open the Issues page), or pick a board. Reading boards needs the project permission, so sign out and back in once if none show up.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(statuses, id: \.name) { status in
                Toggle(isOn: statusBinding(status.name)) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(status.color ?? .secondary.opacity(0.4))
                            .frame(width: 9, height: 9)
                        Text(status.name)
                    }
                    if let moves = seen.first(where: { $0.status.caseInsensitiveCompare(status.name) == .orderedSame })?.count {
                        Text("\(moves) moves")
                    }
                }
            }
            // A board's own options are the whole list; without one, any
            // status can be added by name.
            if workflow.projectNumber == nil {
                HStack {
                    TextField("Status", text: $newStatus, prompt: Text("Add a status by name"))
                        .labelsHidden()
                        .onSubmit(addStatus)
                    Button("Add", action: addStatus)
                        .disabled(newStatus.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("In progress when the status is")
        }
        .task(id: workflow.projectNumber) {
            await projects.loadBoards(org: org)
            if let number = workflow.projectNumber { await projects.loadDefinition(org: org, number: number) }
        }
    }

    /// The org's boards, plus any the issue history has seen and the saved
    /// one, so the picked board always has a name to show.
    private func boards(metrics: IssueMetrics?, workflow: IssueWorkflow) -> [(number: Int, title: String)] {
        var titles: [Int: String] = [:]
        for project in metrics?.projectsSeen ?? [] { titles[project.number] = project.title }
        for board in projects.boardLists[org] ?? [] { titles[board.number] = board.title }
        if let number = workflow.projectNumber, titles[number] == nil { titles[number] = "Project \(number)" }
        return titles.map { ($0.key, $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The board's options with their colours, else the statuses seen; then
    /// anything saved that neither has.
    private func statuses(options: [BoardOption], seen: [(status: String, count: Int)], workflow: IssueWorkflow) -> [(name: String, color: Color?)] {
        var result: [(name: String, color: Color?)] = options.isEmpty
            ? seen.map { ($0.status, nil) }
            : options.map { ($0.name, BoardLayout.color($0.color)) }
        for saved in workflow.inProgressStatuses.sorted() where !result.contains(where: { $0.name.caseInsensitiveCompare(saved) == .orderedSame }) {
            result.append((saved, nil))
        }
        return result
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<IssueWorkflow, Value>) -> Binding<Value> {
        Binding {
            configs.config(for: org).workflow[keyPath: keyPath]
        } set: { value in
            configs.update(org) { config in
                var workflow = config.workflow
                workflow[keyPath: keyPath] = value
                config.issueWorkflow = workflow
            }
        }
    }

    private func statusBinding(_ status: String) -> Binding<Bool> {
        Binding {
            configs.config(for: org).workflow.isInProgress(status)
        } set: { isOn in
            configs.update(org) { config in
                var workflow = config.workflow
                workflow.inProgressStatuses = workflow.inProgressStatuses.filter { $0.caseInsensitiveCompare(status) != .orderedSame }
                if isOn { workflow.inProgressStatuses.insert(status) }
                config.issueWorkflow = workflow
            }
        }
    }

    private func addStatus() {
        let status = newStatus.trimmingCharacters(in: .whitespaces)
        guard !status.isEmpty else { return }
        statusBinding(status).wrappedValue = true
        newStatus = ""
    }
}
