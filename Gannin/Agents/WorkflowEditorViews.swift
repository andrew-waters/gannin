import SwiftUI

/// Harness › Workflows: each activity's workflows in a project, built in a
/// node view (stages left to right, steps side by side in a stage), with
/// your default and, for reviews and coding, routing rules. A team
/// workflow's edits are staged as the team's pending changes, committed
/// from the sidebar's Review once confirmed; your own workflows, default
/// and rules are saved on this Mac (`PersonalAgentsStore`).
struct AgentWorkflowsPage: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(HarnessTeamStore.self) private var team
    @Environment(PersonalAgentsStore.self) private var personal
    @Environment(OrgConfigStore.self) private var configs
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgStore.self) private var orgs
    @Environment(IssueStore.self) private var issues
    let org: String
    @SceneStorage("agentWorkflowsActivity") private var activity: WorkflowActivity = .review
    /// The harness edited, by repo; nil for the first.
    @State private var project: String?
    /// The workflow shown, by id; nil for the activity's default.
    @State private var selected: String?
    @State private var selectedStep: String?
    @State private var naming: Naming?
    @State private var confirmingDelete = false
    /// Which rules Routing shows.
    @State private var routing: WorkflowScope = .personal
    @State private var editingSpecialist: EditedSpecialist?
    /// A change to a team workflow that would have named a personal
    /// specialist, and so wasn't made.
    @State private var refused = false

    /// New, Duplicate or Rename, asking for a name.
    private struct Naming: Identifiable {
        enum Kind { case new, duplicate, rename }
        let kind: Kind
        var name: String
        /// Whose it is to start with.
        var scope: WorkflowScope = .personal
        var id: String { "\(kind)" }
    }

    private struct EditedSpecialist: Identifiable {
        let setup: HarnessConfig
        let specialist: HarnessSpecialist
        var id: String { specialist.name }
    }

    var body: some View {
        let harnesses = configs.config(for: org).harnesses
        Group {
            if let setup = harnesses.first(where: { $0.repo == project }) ?? harnesses.first {
                content(setup)
                    .toolbar { toolbar(setup, harnesses: harnesses) }
            } else {
                ContentUnavailableView {
                    Label("No harness", systemImage: "text.book.closed")
                } description: {
                    Text("Workflows are kept in a project's harness. Create one, or link one the org has.")
                } actions: {
                    SetUpHarnessButton()
                }
            }
        }
        .loadsHarness(org: org)
        .task(id: org) {
            orgs.loadCached(org)
            issues.loadCached(org)
            await harness.loadRepositories(org: org)
        }
        .onChange(of: activity) {
            selected = nil
            selectedStep = nil
        }
    }

    /// What Gannin already has for a rule's lists to offer: the project's
    /// repos then the org's, its members and recent PR authors, and the
    /// labels and issue types on its issues.
    private func routingChoices(_ setup: HarnessConfig) -> RoutingChoices {
        let snapshot = orgs.snapshot(for: org)
        let records = issues.history(for: org).map { Array($0.issues.values) } ?? []
        let pullRequests = (snapshot?.openPullRequests ?? []) + (snapshot?.mergedPullRequests ?? [])
        let labels = records.flatMap(\.labels) + (snapshot?.issues ?? []).flatMap { $0.labels.map(\.name) }
        return RoutingChoices(
            repos: RoutingChoices.unique((setup.repos ?? []) + (harness.repositories[org] ?? []).sorted { $0.lowercased() < $1.lowercased() }),
            authors: RoutingChoices.sorted((snapshot?.members.map(\.login) ?? []) + pullRequests.compactMap(\.author?.login)),
            labels: RoutingChoices.sorted(labels),
            issueTypes: RoutingChoices.sorted(records.compactMap(\.issueType))
        )
    }

    private func file(_ setup: HarnessConfig) -> AgentWorkflows {
        team.data(for: org, in: setup).agentWorkflows ?? AgentWorkflows()
    }

    private func library(_ setup: HarnessConfig) -> WorkflowLibrary {
        WorkflowLibrary(team: file(setup), personal: personal.workflows(org: org, project: setup.repo))
    }

    /// Applies a change to the team's file and stages it, or to yours and
    /// saves it. A team file that would name someone's own specialist is
    /// never staged.
    private func change(_ setup: HarnessConfig, _ scope: WorkflowScope, _ edit: (inout AgentWorkflows) -> Void) {
        switch scope {
        case .personal:
            personal.changeWorkflows(org: org, project: setup.repo, edit)
        case .team:
            var workflows = file(setup)
            edit(&workflows)
            guard !workflows.usesPersonalSpecialist else {
                refused = true
                return
            }
            team.stage(org: org, project: setup, [TeamFile.agentWorkflows: workflows.fileText])
        }
    }

    /// Saves a workflow where it's kept.
    private func save(_ workflow: AgentWorkflow, _ setup: HarnessConfig) {
        change(setup, library(setup).isPersonal(workflow.id, for: activity) ? .personal : .team) { $0.save(workflow, for: activity) }
    }

    @ToolbarContentBuilder
    private func toolbar(_ setup: HarnessConfig, harnesses: [HarnessConfig]) -> some ToolbarContent {
        ToolbarItem {
            Picker("Activity", selection: $activity) {
                ForEach(WorkflowActivity.allCases) { Text($0.title).tag($0) }
            }
            .help("Which activity's workflows to show")
        }
        if harnesses.count > 1 {
            ToolbarItem {
                Picker("Project", selection: Binding(get: { setup.repo }, set: { project = $0; selected = nil; selectedStep = nil })) {
                    ForEach(harnesses, id: \.repo) { Text($0.repo).tag($0.repo) }
                }
                .help("The project's harness the workflows are kept in")
            }
        }
    }

    @ViewBuilder
    private func content(_ setup: HarnessConfig) -> some View {
        let workflows = library(setup)
        let options = workflows.workflows(for: activity)
        let current = options.first { $0.id == selected } ?? workflows.defaultWorkflow(for: activity)
        let isDefault = workflows.defaultWorkflow(for: activity).id == current.id
        let specialists = sessions.specialists(org: org, setup: setup)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(setup, workflows: workflows, options: options, current: current, isDefault: isDefault)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    WorkflowCanvas(
                        workflow: current, activity: activity, specialists: specialists, editable: !current.isBuiltIn,
                        selectedStep: $selectedStep
                    ) { edit in
                        var workflow = current
                        edit(&workflow)
                        save(workflow, setup)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                }
                .frame(minHeight: 260)
                Divider()
                passes(current, specialists: specialists)
                if activity.isRouted {
                    Divider()
                    RoutingRulesSection(
                        activity: activity, scope: $routing,
                        rules: (routing == .personal ? workflows.personal : workflows.team)[activity].rules ?? [],
                        options: routing == .personal ? workflows.workflows(for: activity) : workflows.team.workflows(for: activity),
                        choices: routingChoices(setup)
                    ) { edit in change(setup, routing) { edit(&$0[activity].rules) } }
                        .frame(maxHeight: 280)
                }
            }
            Divider()
            inspector(setup, current: current, specialists: specialists, allowsPersonal: workflows.isPersonal(current.id, for: activity))
                .frame(width: 300)
        }
        .sheet(item: $naming) { naming in
            nameSheet(naming, setup: setup, current: current)
        }
        .sheet(item: $editingSpecialist) { edit in
            HarnessSpecialistEditor(org: org, setup: edit.setup, specialist: edit.specialist)
        }
        .alert("Your own specialists stay out of team workflows", isPresented: $refused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A team workflow is committed to the harness, for everyone. Duplicate it as one of yours to use your own specialists.")
        }
        .confirmationDialog("Delete \(current.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                let id = current.id
                if workflows.isPersonal(id, for: activity) {
                    change(setup, .personal) { $0.remove(id, for: activity) }
                } else {
                    change(setup, .team) { $0.remove(id, for: activity) }
                    // Your own rules and default that named it go too.
                    change(setup, .personal) { $0.remove(id, for: activity) }
                }
                selected = nil
                selectedStep = nil
            }
        } message: {
            Text(workflows.isPersonal(current.id, for: activity)
                 ? "Your routing rules that send work to it go with it, and \(activity.title) runs your default instead."
                 : "Its routing rules go with it, and \(activity.title) runs each person's default instead. Nothing changes for the team until you commit it.")
        }
    }

    private func header(_ setup: HarnessConfig, workflows: WorkflowLibrary, options: [AgentWorkflow], current: AgentWorkflow, isDefault: Bool) -> some View {
        HStack(spacing: 10) {
            Picker("Workflow", selection: Binding(get: { current.id }, set: { selected = $0; selectedStep = nil })) {
                ForEach(options) { workflow in
                    Text(workflow.name + (workflows.isPersonal(workflow.id, for: activity) ? " (just me)" : "")
                         + (workflows.defaultWorkflow(for: activity).id == workflow.id ? " (your default)" : "")).tag(workflow.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            if current.isBuiltIn {
                Pill(text: "Gannin's", color: .secondary)
            } else if workflows.isPersonal(current.id, for: activity) {
                Pill(text: "Just me", color: .purple)
                    .help("Saved on this Mac, never committed to the harness")
            } else {
                Pill(text: "Team", color: .accentColor)
                    .help("In \(setup.repo), for everyone in the project")
            }
            if isDefault {
                Text("Your default").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Button("Make My Default") { change(setup, .personal) { $0.setDefault(current.id, for: activity) } }
                    .help("You run it for \(activity.title) unless a routing rule says otherwise. Everyone picks their own; someone new runs Gannin's.")
            }
            Spacer()
            Button("New") { naming = Naming(kind: .new, name: "") }
                .help("A new workflow for \(activity.title)")
            Button("Duplicate") { naming = Naming(kind: .duplicate, name: "\(current.name) copy") }
            if !current.isBuiltIn {
                Button("Rename") { naming = Naming(kind: .rename, name: current.name) }
                Button("Delete", role: .destructive) { confirmingDelete = true }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func nameSheet(_ naming: Naming, setup: HarnessConfig, current: AgentWorkflow) -> some View {
        WorkflowNameSheet(
            title: naming.kind == .rename ? "Rename Workflow" : naming.kind == .new ? "New Workflow" : "Duplicate Workflow",
            name: naming.name,
            scope: naming.kind == .rename ? nil : naming.scope,
            teamAllowed: naming.kind != .duplicate || !current.usesPersonalSpecialist,
            repo: setup.repo
        ) { name, scope in
            switch naming.kind {
            case .new:
                let made = AgentWorkflow.new(activity, name: name)
                change(setup, scope) { $0.save(made, for: activity) }
                selected = made.id
            case .duplicate:
                var made = current.duplicated(name: name)
                made.normalise(for: activity)
                change(setup, scope) { $0.save(made, for: activity) }
                selected = made.id
            case .rename:
                var renamed = current
                renamed.name = name
                save(renamed, setup)
            }
            selectedStep = nil
        }
    }

    private func passes(_ workflow: AgentWorkflow, specialists: [String: HarnessSpecialist]) -> some View {
        let counts = PassCount.of(workflow, specialists: specialists, defaultModel: SessionStore.model, activity: activity)
        let total = counts.reduce(0) { $0 + $1.passes }
        let leadAdded = counts.reduce(0) { $0 + $1.passes } > workflow.steps.reduce(0) { $0 + ($1.isInteractive ? 1 : $1.roundCount) }
        return HStack {
            Text("At most \(total) pass\(total == 1 ? "" : "es"): " + counts.map { "\($0.label) \u{00D7}\($0.passes)" }.joined(separator: ", ")
                 + (leadAdded ? ". The first stage has no Claude Code step, so Gannin's own reviewer runs there too, to hold the review." : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func inspector(_ setup: HarnessConfig, current: AgentWorkflow, specialists: [String: HarnessSpecialist], allowsPersonal: Bool) -> some View {
        if current.isBuiltIn {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gannin's default").font(.headline)
                Text("One step: \(activity.isInteractive ? "the session, with Gannin's own prompt" : "Gannin's own reviewer"), on the provider and model in Settings › General. It can't be changed; Duplicate it to make one of your own.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(14)
        } else if let id = selectedStep, let step = current.step(id) {
            AgentStepInspector(
                step: step, activity: activity, specialists: specialists, allowsPersonal: allowsPersonal,
                canRemove: !(activity.isInteractive && step.isInteractive),
                editSpecialist: { editingSpecialist = EditedSpecialist(setup: setup, specialist: $0) }
            ) { edit in
                var workflow = current
                edit(&workflow)
                save(workflow, setup)
                if workflow.step(id) == nil { selectedStep = nil }
            }
            .id(id)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(current.name).font(.headline)
                Text("Pick a step to set its specialist, provider, model, focus\(activity == .review ? " and rounds" : ""). Steps in one column run side by side and join before the next; a step sees what earlier columns found.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if activity.isInteractive {
                    Text("One step is the session you type in. Steps before it prepare its brief; steps after it review each pull request it opens.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
        }
    }
}

/// Whose a workflow, or a routing rule, is: the team's, in the harness,
/// or yours, on this Mac.
enum WorkflowScope: Hashable {
    case team, personal
}

/// A workflow's name, asked for before it's made or renamed, and for a new
/// one whose it is.
private struct WorkflowNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var name: String
    /// Nil when it's not asked (a rename).
    @State var scope: WorkflowScope?
    /// False for a copy of one with your own specialists in it.
    let teamAllowed: Bool
    let repo: String
    let done: (String, WorkflowScope) -> Void

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("Security first"))
            if scope != nil {
                Picker("Kept for", selection: Binding(get: { scope ?? .personal }, set: { scope = $0 })) {
                    Text("Just me").tag(WorkflowScope.personal)
                    Text("The team").tag(WorkflowScope.team).selectionDisabled(!teamAllowed)
                }
                .pickerStyle(.segmented)
                Text(scope == .team
                     ? "Committed to \(repo) once you review the team's changes, for everyone in the project. It can only use the team's specialists."
                     : teamAllowed ? "Saved on this Mac and never committed. It can use your own specialists as well as the team's."
                     : "It uses your own specialists, so it can only be yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    done(name.trimmingCharacters(in: .whitespaces), teamAllowed ? scope ?? .personal : .personal)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - The node view

/// Where each node is, for drawing the connectors between columns.
private struct NodeBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The workflow as nodes: a start, each stage's steps stacked in a column,
/// and an end, joined left to right by drawn connectors.
struct WorkflowCanvas: View {
    let workflow: AgentWorkflow
    let activity: WorkflowActivity
    let specialists: [String: HarnessSpecialist]
    let editable: Bool
    @Binding var selectedStep: String?
    let edit: ((inout AgentWorkflow) -> Void) -> Void

    private static let start = "\u{0}start"
    private static let end = "\u{0}end"

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            endpoint(activity == .review ? "Pull request" : "Start", symbol: activity == .review ? "arrow.triangle.pull" : "play.circle")
                .anchorPreference(key: NodeBounds.self, value: .bounds) { [Self.start: $0] }
            ForEach(Array(workflow.stages.enumerated()), id: \.element.id) { index, stage in
                VStack(spacing: 12) {
                    ForEach(stage.steps) { step in
                        AgentStepNode(step: step, activity: activity, specialists: specialists, isSelected: selectedStep == step.id)
                            .anchorPreference(key: NodeBounds.self, value: .bounds) { [step.id: $0] }
                            .onTapGesture { selectedStep = step.id }
                            .contextMenu { if editable { menu(step) } }
                    }
                    if editable, !(activity.isInteractive && stage.steps.contains(where: \.isInteractive)) {
                        Button {
                            var added: String?
                            edit { added = $0.addStep(toStage: index, activity: activity) }
                            selectedStep = added
                        } label: {
                            Label("Beside", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add a step that runs at the same time as this column's")
                    }
                }
            }
            if editable {
                Button {
                    var added: String?
                    edit { added = $0.addStage(at: $0.stages.count) }
                    selectedStep = added
                } label: {
                    Label("Stage", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add a stage after the last")
            }
            endpoint(activity == .review ? "One review" : "Done", symbol: activity == .review ? "text.bubble" : "checkmark.circle")
                .anchorPreference(key: NodeBounds.self, value: .bounds) { [Self.end: $0] }
        }
        .padding(36)
        .backgroundPreferenceValue(NodeBounds.self) { anchors in
            GeometryReader { proxy in
                let columns = [[Self.start]] + workflow.stages.map { $0.steps.map(\.id) } + [[Self.end]]
                let rects = anchors.mapValues { proxy[$0] }
                Canvas { context, _ in
                    for (left, right) in zip(columns, columns.dropFirst()) {
                        for from in left.compactMap({ rects[$0] }) {
                            for to in right.compactMap({ rects[$0] }) {
                                var path = Path()
                                let a = CGPoint(x: from.maxX, y: from.midY)
                                let b = CGPoint(x: to.minX, y: to.midY)
                                let bend = (b.x - a.x) / 2
                                path.move(to: a)
                                path.addCurve(to: b, control1: CGPoint(x: a.x + bend, y: a.y), control2: CGPoint(x: b.x - bend, y: b.y))
                                context.stroke(path, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
                            }
                        }
                    }
                }
            }
        }
    }

    private func endpoint(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private func menu(_ step: AgentStep) -> some View {
        Button("Move Earlier") { edit { $0.moveStep(step.id, by: -1, activity: activity) } }
        Button("Move Later") { edit { $0.moveStep(step.id, by: 1, activity: activity) } }
        if activity.isInteractive, !step.isInteractive {
            Button("Make This the Session") { edit { $0.makeInteractive(step.id) } }
        }
        if !(activity.isInteractive && step.isInteractive) {
            Divider()
            Button("Remove Step", role: .destructive) {
                edit { $0.removeStep(step.id, activity: activity) }
                if selectedStep == step.id { selectedStep = nil }
            }
        }
    }
}

/// One step as a card: who runs it, where, its focus and rounds.
private struct AgentStepNode: View {
    let step: AgentStep
    let activity: WorkflowActivity
    let specialists: [String: HarnessSpecialist]
    let isSelected: Bool

    var body: some View {
        let specialist = step.specialist.flatMap { specialists[$0.lowercased()] }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: step.isInteractive ? "terminal" : activity == .review ? "eye" : "bolt")
                    .foregroundStyle(.secondary)
                Text(specialist?.title ?? step.specialist ?? "Gannin's prompt").font(.callout.weight(.semibold)).lineLimit(1)
                if step.specialist != nil, specialist == nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("\(step.specialist ?? "") isn't in this harness's specialists")
                }
            }
            Text(runsOn(specialist)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let focus = HarnessSpecialist.focus(step: step.focus, specialist: specialist?.focus) {
                Text(focus).font(.caption).lineLimit(2)
            }
            HStack(spacing: 6) {
                if step.isInteractive { Pill(text: "Session", color: .accentColor) }
                if activity == .review, step.roundCount > 1 { Pill(text: "\(step.roundCount) rounds", color: .secondary) }
            }
        }
        .padding(10)
        .frame(width: 210, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : Color.separatorLine, lineWidth: isSelected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func runsOn(_ specialist: HarnessSpecialist?) -> String {
        let named = step.provider ?? specialist?.provider
        let id = ProviderID(name: named)
        let provider = id?.title ?? named ?? ProviderID.claudeCode.title
        let model = step.model ?? specialist?.model
        return model.map { "\(provider), \(ModelCatalog.shared.name(of: $0, provider: id ?? .claudeCode))" } ?? provider
    }
}

// MARK: - The step inspector

/// A step's specialist, provider, model, focus and rounds, each saved as
/// it's changed.
private struct AgentStepInspector: View {
    let step: AgentStep
    let activity: WorkflowActivity
    let specialists: [String: HarnessSpecialist]
    /// Your own specialists can be picked: false in a team workflow.
    let allowsPersonal: Bool
    let canRemove: Bool
    let editSpecialist: (HarnessSpecialist) -> Void
    let edit: ((inout AgentWorkflow) -> Void) -> Void
    @State private var focus = ""

    var body: some View {
        let specialist = step.specialist.flatMap { specialists[$0.lowercased()] }
        let provider = ProviderID(name: step.provider ?? specialist?.provider) ?? .claudeCode
        Form {
            Section {
                let sorted = specialists.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                Picker("Specialist", selection: binding(\.specialist)) {
                    Text("None (Gannin's prompt)").tag(String?.none)
                    Section("The team's") {
                        ForEach(sorted.filter { !$0.isPersonal }) { Text($0.title).tag(Optional($0.name)) }
                    }
                    if allowsPersonal {
                        Section("Just me") {
                            ForEach(sorted.filter(\.isPersonal)) { Text($0.title).tag(Optional($0.name)) }
                        }
                    }
                    if let name = step.specialist, specialists[name.lowercased()] == nil {
                        Text(step.namesPersonalSpecialist ? "A personal specialist (missing)" : "\(name) (missing)").tag(Optional(name))
                    }
                }
                if let specialist {
                    Button(specialist.isPersonal ? "Edit Your Specialist" : "Edit Specialist") { editSpecialist(specialist) }
                        .help("Change its defaults (provider, model, focus) or soul")
                }
                Picker("Provider", selection: binding(\.provider)) {
                    Text(specialist?.provider.map { "Specialist's (\(ProviderID(name: $0)?.title ?? $0))" } ?? "Specialist's (Claude Code)").tag(String?.none)
                    ForEach(ProviderID.allCases.filter { $0.isInteractive || !step.isInteractive }) { Text($0.title).tag(Optional($0.rawValue)) }
                }
                ModelPicker(provider: provider, model: Binding(get: { step.model ?? "" }, set: { save(model: $0) }), inherited: inheritedModel(specialist))
                TextField("Focus", text: $focus, prompt: Text(specialist?.focus ?? "What this step looks at"), axis: .vertical)
                    .lineLimit(2...5)
                    .leadingTextBox("Focus")
                    .onChange(of: focus) { save(focus: focus) }
                if activity == .review {
                    Stepper("Rounds: \(step.roundCount)", value: Binding(get: { step.roundCount }, set: { rounds in edit { $0.update(step.id) { $0.rounds = rounds == 1 ? nil : rounds } } }), in: 1...AgentStep.maxRounds)
                }
            } header: {
                Text(step.isInteractive ? "The session" : "Step")
            } footer: {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Move Earlier") { edit { $0.moveStep(step.id, by: -1, activity: activity) } }
                Button("Move Later") { edit { $0.moveStep(step.id, by: 1, activity: activity) } }
                if activity.isInteractive, !step.isInteractive {
                    Button("Make This the Session") { edit { $0.makeInteractive(step.id) } }
                }
                if canRemove {
                    Button("Remove Step", role: .destructive) { edit { $0.removeStep(step.id, activity: activity) } }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            focus = step.focus ?? ""
        }
    }

    /// What the step runs with when it doesn't set a model.
    private func inheritedModel(_ specialist: HarnessSpecialist?) -> String {
        let provider = ProviderID(name: step.provider ?? specialist?.provider) ?? .claudeCode
        if let model = specialist?.model { return "Specialist's (\(ModelCatalog.shared.name(of: model, provider: provider)))" }
        return "Each person's, from Settings › General"
    }

    private var footer: String {
        let mine = allowsPersonal ? "" : " Your own specialists can only go in your own workflows, as this one is committed for the team."
        if activity == .review {
            return "A round is another read-only pass over the same diff, asked for what earlier rounds missed; the step stops early when one finds nothing new. A one-shot CLI such as Junie runs in a throwaway copy on this Mac, and is skipped where it can't run." + mine
        }
        return (step.isInteractive
            ? "The session you type in, on Claude Code. Its specialist's soul and focus come before the team's prompts."
            : "Runs once, on Claude Code: before the session it adds to the brief; after it, it reviews each pull request the session opens.") + mine
    }

    private func binding(_ key: WritableKeyPath<AgentStep, String?>) -> Binding<String?> {
        Binding(get: { step[keyPath: key] }, set: { value in edit { $0.update(step.id) { $0[keyPath: key] = value } } })
    }

    private func save(model: String) {
        let value = model.trimmingCharacters(in: .whitespaces)
        guard (step.model ?? "") != value else { return }
        edit { $0.update(step.id) { $0.model = value.isEmpty ? nil : value } }
    }

    private func save(focus: String) {
        let value = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (step.focus ?? "") != value else { return }
        edit { $0.update(step.id) { $0.focus = value.isEmpty ? nil : value } }
    }
}

// MARK: - Routing rules

/// Reviews' and coding's routing rules, yours or the team's, in order:
/// yours are checked first, then the team's, and with none matching your
/// default runs.
private struct RoutingRulesSection: View {
    let activity: WorkflowActivity
    @Binding var scope: WorkflowScope
    let rules: [RoutingRule]
    /// What a rule can send to: any workflow for yours, the team's for theirs.
    let options: [AgentWorkflow]
    let choices: RoutingChoices
    let change: ((inout [RoutingRule]?) -> Void) -> Void

    var body: some View {
        let targets = options.filter { !$0.isBuiltIn }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Routing").font(.headline)
                Picker("Rules", selection: $scope) {
                    Text("Mine").tag(WorkflowScope.personal)
                    Text("The team's").tag(WorkflowScope.team)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(scope == .personal
                     ? "Checked first, on this Mac only: \(activity == .review ? "send a PR by its repo, author, labels or changed paths" : "send an issue by its repo, labels or type"), to any workflow."
                     : "Checked after yours, for everyone, and only to the team's workflows.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Add Rule") {
                    guard let first = targets.first else { return }
                    change { $0 = rules + [RoutingRule(workflow: first.id)] }
                }
                .disabled(targets.isEmpty)
                .help(targets.isEmpty ? "Make a workflow first" : "Add a rule at the end")
            }
            if rules.isEmpty {
                Text(scope == .personal ? "No rules of yours." : "No team rules.").foregroundStyle(.secondary).font(.callout)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        RoutingRuleRow(rule: rule, index: index, count: rules.count, activity: activity, options: options, choices: choices) { updated in
                            change { stored in
                                var list = stored ?? []
                                guard list.indices.contains(index) else { return }
                                if let updated { list[index] = updated } else { list.remove(at: index) }
                                stored = list.isEmpty ? nil : list
                            }
                        } move: { offset in
                            change { stored in
                                var list = stored ?? []
                                guard list.indices.contains(index), list.indices.contains(index + offset) else { return }
                                list.swapAt(index, index + offset)
                                stored = list
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

/// One rule: which workflow, and what it matches, each a comma-separated
/// list where any entry matches.
private struct RoutingRuleRow: View {
    let rule: RoutingRule
    let index: Int
    let count: Int
    let activity: WorkflowActivity
    let options: [AgentWorkflow]
    let choices: RoutingChoices
    /// The rule changed, or nil to remove it.
    let save: (RoutingRule?) -> Void
    let move: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                Picker("Workflow", selection: Binding(get: { rule.workflow }, set: { workflow in
                    var updated = rule
                    updated.workflow = workflow
                    save(updated)
                })) {
                    ForEach(options) { Text($0.name).tag($0.id) }
                    if !options.contains(where: { $0.id == rule.workflow }) { Text("(deleted)").tag(rule.workflow) }
                }
                .frame(maxWidth: 240)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Check it earlier")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1)
                    .help("Check it later")
                Button(role: .destructive) { save(nil) } label: { Image(systemName: "trash") }
                    .help("Remove the rule")
            }
            .buttonStyle(.borderless)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                field("Repos", \.repos, prompt: "api, acme/web", choices: choices.repos)
                if activity == .review {
                    field("Authors", \.authors, prompt: "alex, sam", choices: choices.authors)
                }
                field("Labels", \.labels, prompt: "security", choices: choices.labels)
                if activity == .review {
                    field("Paths", \.paths, prompt: "docs/, **/*.sql", choices: [])
                } else {
                    field("Issue types", \.issueTypes, prompt: "Bug, Feature", choices: choices.issueTypes)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func field(_ label: String, _ key: WritableKeyPath<RoutingRule, [String]?>, prompt: String, choices: [String]) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            ListField(label: label, prompt: prompt, initial: rule[keyPath: key], choices: choices) { items in
                var updated = rule
                updated[keyPath: key] = items
                save(updated)
            }
        }
    }
}

/// What a routing rule's lists offer to pick from. Typing anything else
/// still works: a glob, a name alone, or one Gannin hasn't seen.
struct RoutingChoices {
    var repos: [String] = []
    var authors: [String] = []
    var labels: [String] = []
    var issueTypes: [String] = []

    /// In order, each once whatever its case.
    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func sorted(_ values: [String]) -> [String] {
        unique(values).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// A comma-separated list typed as text, or added to from `choices`. It
/// keeps what's typed (a comma or space at the end included) and saves the
/// list it makes, rather than showing the list back, which would drop them
/// mid-word.
private struct ListField: View {
    let label: String
    let prompt: String
    let initial: [String]?
    let choices: [String]
    let save: ([String]?) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
            if !choices.isEmpty {
                Menu {
                    let picked = Set(items.map { $0.lowercased() })
                    ForEach(choices.filter { !picked.contains($0.lowercased()) }, id: \.self) { choice in
                        Button(choice) { text = (items + [choice]).joined(separator: ", ") }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add one of the \(label.lowercased()) Gannin knows")
            }
        }
        .onAppear { text = (initial ?? []).joined(separator: ", ") }
        .onChange(of: text) {
            let list = items.isEmpty ? nil : items
            if list != initial { save(list) }
        }
    }

    private var items: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Picking a workflow for one run

/// Before a run starts by hand: which workflow it runs, the one the
/// project's routing rules give it unless another is picked for this run
/// (`PromptChoice.workflow`), and the most passes it can make. Shown only
/// when the project has workflows for the activity.
struct WorkflowPickerSection: View {
    @Environment(SessionStore.self) private var sessions
    let org: String
    let setup: HarnessConfig?
    let activity: WorkflowActivity
    /// The PR or issue, for the workflow its routing rules give it.
    var subject: WorkflowSubject? = nil
    @Binding var choice: PromptChoice

    var body: some View {
        if let setup {
            let file = sessions.agentWorkflows(org, setup)
            let options = file.workflows(for: activity)
            if options.count > 1 {
                let rules = activity.isRouted ? file.rules(for: activity) : []
                let routed = file.resolve(activity, for: subject)
                let shown = options.first { $0.id == choice.workflow } ?? routed
                let counts = PassCount.of(shown, specialists: sessions.specialists(org: org, setup: setup), defaultModel: SessionStore.model, activity: activity)
                let total = counts.reduce(0) { $0 + $1.passes }
                // A review's author, labels and paths are looked up as it starts.
                let laterRules = activity == .review && rules.contains { !($0.authors ?? []).isEmpty || !($0.labels ?? []).isEmpty || !($0.paths ?? []).isEmpty }
                Section {
                    Picker("Workflow", selection: Binding(get: { choice.workflow }, set: { choice.workflow = $0 })) {
                        Text(rules.isEmpty ? "Default (\(routed.name))" : laterRules ? "As routed (\(routed.name) by repo; author, label and path rules are checked as it starts)" : "As routed (\(routed.name))").tag(String?.none)
                        Divider()
                        ForEach(options) { Text($0.name + (file.isPersonal($0.id, for: activity) ? " (just me)" : "")).tag(Optional($0.id)) }
                    }
                    Text("At most \(total) pass\(total == 1 ? "" : "es"): " + counts.map { "\($0.label) \u{00D7}\($0.passes)" }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Workflow")
                } footer: {
                    Text("From Harness › Workflows: the team's and your own. Picking one here is for this \(activity == .review ? "review" : "session") only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension SessionStore {
    /// The workflow picked for one run, by id; nil when none was, or it's
    /// gone, so the routed one runs.
    func pickedWorkflow(_ id: String?, org: String, setup: HarnessConfig, activity: WorkflowActivity) -> AgentWorkflow? {
        id.flatMap { agentWorkflows(org, setup).workflow($0, for: activity) }
    }
}
