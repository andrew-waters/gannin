import SwiftUI

/// Settings sections: how the window's project runs standup. The style it
/// opens on, the label that marks an issue for discussion, which stage each
/// of the workflow board's statuses falls in (guessed from its name until
/// picked), and how Up next sorts the backlog and says who needs work.
struct StandupSettingsSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    let org: String

    var body: some View {
        let config = configs.config(for: org)
        let definition = config.workflow.projectNumber.flatMap { projects.cache(org: org, number: $0)?.board }
        let options = definition?.field(named: "Status")?.options ?? []
        let sortable = (definition?.fields ?? []).filter { field in
            Self.sortableTypes.contains(field.dataType) && field.name.caseInsensitiveCompare("Status") != .orderedSame
        }
        let standup = config.standupConfig
        Section {
            Picker("Style", selection: binding(\.openingStyleSetting)) {
                ForEach(StandupConfig.Style.allCases) { Text($0.name).tag($0) }
            }
            TextField("Discussion label", text: binding(\.label), prompt: Text(StandupConfig.defaultDiscussionLabel))
                .leadingTextBox("Discussion label")
        } header: {
            Text("Standup")
        } footer: {
            Text("The style Rituals › Standup opens on; anyone can pick another for the day. Open issues with the discussion label are listed first, under Done and needs discussion.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section {
            if config.workflow.projectNumber == nil {
                Text("Pick the Board under Issue workflow to set where its statuses show at standup.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if options.isEmpty {
                Text("The board's statuses appear here once it has loaded.")
                    .foregroundStyle(.secondary)
            }
            ForEach(options, id: \.name) { option in
                Picker(selection: stageBinding(option.name, workflow: config.workflow)) {
                    ForEach(StandupConfig.Stage.allCases) { Text($0.name).tag($0) }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(BoardLayout.color(option.color))
                            .frame(width: 9, height: 9)
                        Text(option.name)
                    }
                }
            }
        } header: {
            Text("Standup columns")
        } footer: {
            Text("Every column shows the open issues on the board as it is now. Issues with no Status are Triage, the same as Prioritisation's, and Backlog statuses are Up next's backlog. Until you pick one, each status's column is guessed from its name.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section {
            Picker("Backlog sorted by", selection: binding(\.backlogField)) {
                Text("Oldest first").tag(String?.none)
                // A field picked before the board loaded, or since removed.
                if let field = standup.backlogField, !sortable.contains(where: { $0.name == field }) {
                    Text(field).tag(String?.some(field))
                }
                ForEach(sortable) { Text($0.name).tag(String?.some($0.name)) }
            }
            Toggle("Highest first", isOn: binding(\.highestFirst))
                .disabled(standup.backlogField == nil)
            Picker("Needs work when", selection: binding(\.needsWorkSetting)) {
                ForEach(StandupConfig.NeedsWork.allCases) { Text($0.name).tag($0) }
            }
        } header: {
            Text("Up next")
        } footer: {
            Text("After Triage, Standup lists who needs work, with the backlog already assigned to them, and then the whole backlog to find them more. The backlog is sorted by the field picked, lowest value first unless Highest first is on, and issues without a value go last. Assign to, in a backlog issue's menu, assigns it on GitHub after you confirm.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: config.workflow.projectNumber) {
            if let number = config.workflow.projectNumber { await projects.loadDefinition(org: org, number: number) }
        }
    }

    /// Fields a backlog can be sorted by: one value an issue can have.
    private static let sortableTypes: Set<String> = ["NUMBER", "SINGLE_SELECT", "DATE", "TEXT", "ITERATION"]

    private func binding<Value>(_ keyPath: WritableKeyPath<StandupConfig, Value>) -> Binding<Value> {
        Binding {
            configs.config(for: org).standupConfig[keyPath: keyPath]
        } set: { value in
            configs.update(org) { config in
                var standup = config.standupConfig
                standup[keyPath: keyPath] = value
                config.standup = standup
            }
        }
    }

    private func stageBinding(_ status: String, workflow: IssueWorkflow) -> Binding<StandupConfig.Stage> {
        Binding {
            configs.config(for: org).standupConfig.stage(for: status, workflow: workflow)
        } set: { stage in
            configs.update(org) { config in
                var standup = config.standupConfig
                standup.stages = standup.stages.filter { $0.key.caseInsensitiveCompare(status) != .orderedSame }
                standup.stages[status] = stage
                config.standup = standup
            }
        }
    }
}

private extension StandupConfig {
    /// The style, as Settings picks it.
    var openingStyleSetting: Style {
        get { openingStyle }
        set { style = newValue }
    }

    var highestFirst: Bool {
        get { backlogHighestFirst ?? false }
        set { backlogHighestFirst = newValue ? true : nil }
    }

    var needsWorkSetting: NeedsWork {
        get { needsWork ?? .nothingInProgress }
        set { needsWork = newValue == .nothingInProgress ? nil : newValue }
    }

    /// The discussion label as typed.
    var label: String {
        get { discussionLabel ?? "" }
        set { discussionLabel = newValue.isEmpty ? nil : newValue }
    }
}
