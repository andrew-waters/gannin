import SwiftUI

/// Settings section: which project board and statuses mark an issue as in
/// progress, for issue cycle time.
struct IssueWorkflowSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(IssueStore.self) private var store
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String

    @State private var newStatus = ""

    var body: some View {
        let workflow = configs.config(for: org).workflow
        let metrics = store.history(for: org).map { IssueMetrics(history: $0, windowDays: windowDays, team: nil, config: configs.config(for: org)) }
        let seen = metrics?.statusesSeen ?? []
        let statuses = seen.map(\.status) + workflow.inProgressStatuses.filter { status in !seen.contains { $0.status.caseInsensitiveCompare(status) == .orderedSame } }.sorted()

        Section {
            Picker("Project", selection: binding(\.projectNumber)) {
                Text("Any project").tag(Int?.none)
                ForEach(metrics?.projectsSeen ?? [], id: \.number) { project in
                    Text(project.title).tag(Optional(project.number))
                }
            }
            LabeledContent("In progress when the status is") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(statuses, id: \.self) { status in
                        Toggle(isOn: statusBinding(status)) {
                            HStack(spacing: 6) {
                                Text(status)
                                if let count = seen.first(where: { $0.status == status })?.count {
                                    Text("\(count) moves").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .checkboxToggle()
                    }
                    HStack {
                        TextField("Add a status", text: $newStatus)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit(addStatus)
                        Button("Add", action: addStatus).disabled(newStatus.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            Toggle("Otherwise, start at the first linked PR", isOn: binding(\.fallBackToPullRequests))
        } header: {
            Text("Issue workflow")
        } footer: {
            Text(seen.isEmpty
                 ? "Statuses appear here once issues have synced (open the Issues page). Reading project boards needs the project permission, so sign out and back in once if none show up."
                 : "Cycle time is the time an issue spends in these statuses on the project board; time in other statuses doesn't count. Issues that never reach one fall back to their first linked PR, if that's on.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
