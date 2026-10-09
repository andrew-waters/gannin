import SwiftUI

/// Planning › Board Hygiene: every issue where the board and the code
/// disagree (the views' Attention flags), by flag, with the fix for those
/// that have one: Done on the board for "PR merged, not done" and "Closed,
/// not done", and closing the issue for "Done, still open". Fixes are
/// ticked, reviewed and written together, confirmed first.
struct BoardHygieneView: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects
    @Environment(AuthStore.self) private var auth
    @Environment(\.navigate) private var navigate
    @SceneStorage(MetricsStore.windowKey) private var windowDays = MetricsStore.defaultWindowDays
    let org: String
    /// Issues left out of a fix, by flag and ID.
    @State private var unticked: Set<String> = []
    @State private var fixing: Fix?

    private struct Fix: Identifiable {
        let flag: IssueSignals.Flag
        let issues: [IssueRecord]
        var id: String { flag.rawValue }
    }

    var body: some View {
        let workflow = configs.config(for: org).workflow
        let history = issueStore.history(for: org)
        Group {
            if workflow.projectNumber == nil {
                ContentUnavailableView("No workflow board", systemImage: "rectangle.split.3x1", description: Text("Pick the board issues move across in the org's Settings, under Issues."))
            } else if let history {
                let context = FieldContext(board: workflow.projectNumber, workflow: workflow, history: history)
                let flagged = IssueSignals.Flag.allCases.map { flag in
                    (flag, history.issues.values.filter { context.signals($0).flags.contains(flag) && !configs.config(for: org).repoExclusion.contains($0.repo) }
                        .sorted { $0.number > $1.number })
                }
                let total = flagged.reduce(0) { $0 + $1.1.count }
                List {
                    if total == 0 {
                        ContentUnavailableView("The board matches the code", systemImage: "checkmark.seal", description: Text("No issue is out of step with its PRs or its state."))
                    }
                    ForEach(flagged.filter { !$0.1.isEmpty }, id: \.0) { flag, issues in
                        Section {
                            ForEach(issues) { issue in
                                row(issue, flag: flag, context: context)
                            }
                        } header: {
                            header(flag, issues: issues)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: org) {
            await issueStore.sync(org, windowDays: MetricsWindow(code: windowDays).syncDays())
            if let board = workflow.projectNumber { await projects.loadDefinition(org: org, number: board) }
        }
        .sheet(item: $fixing) { fix in
            sheet(fix, workflow: workflow)
        }
    }

    private func header(_ flag: IssueSignals.Flag, issues: [IssueRecord]) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(flag.rawValue) (\(issues.count))")
                Text(flag.explanation).font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
            }
            Spacer()
            if let action = action(for: flag) {
                let ticked = issues.filter { !unticked.contains(key(flag, $0)) }
                Button("\(action) (\(ticked.count))") { fixing = Fix(flag: flag, issues: ticked) }
                    .disabled(ticked.isEmpty || doneOption == nil && flag != .doneButOpen)
                    .help(flag == .doneButOpen ? "Close the ticked issues as completed" : "Set the ticked issues to \(doneOption ?? "Done") on the board")
            }
        }
    }

    private func row(_ issue: IssueRecord, flag: IssueSignals.Flag, context: FieldContext) -> some View {
        let signals = context.signals(issue)
        return HStack(spacing: 8) {
            if action(for: flag) != nil {
                Toggle("", isOn: Binding(
                    get: { !unticked.contains(key(flag, issue)) },
                    set: { on in if on { unticked.remove(key(flag, issue)) } else { unticked.insert(key(flag, issue)) } }
                ))
                .labelsHidden()
                .checkboxToggle()
            }
            Button {
                navigate?(.issueReference(IssueReference(org: org, record: issue)))
            } label: {
                HStack(spacing: 8) {
                    Text("\(issue.repo.split(separator: "/").last ?? "")#\(String(issue.number))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(issue.title).lineLimit(1)
                    Spacer()
                    if let status = signals.status {
                        Text(status).foregroundStyle(.secondary)
                    }
                    if let time = signals.timeInStatus {
                        Text(time.compactDuration).foregroundStyle(.secondary).monospacedDigit()
                    }
                    let merged = issue.linkedPullRequests.filter { $0.mergedAt != nil }.count
                    if !issue.linkedPullRequests.isEmpty {
                        Text("\(merged)/\(issue.linkedPullRequests.count) PRs merged").foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func key(_ flag: IssueSignals.Flag, _ issue: IssueRecord) -> String { flag.rawValue + issue.id }

    private func action(for flag: IssueSignals.Flag) -> String? {
        switch flag {
        case .mergedNotDone, .closedNotDone: "Move to \(doneOption ?? "Done")"
        case .doneButOpen: "Close"
        case .quiet, .reviewWithoutPR: nil
        }
    }

    /// The workflow board's Status option for done.
    private var doneOption: String? {
        guard let number = configs.config(for: org).workflow.projectNumber,
              let options = projects.cache(org: org, number: number)?.board.field(named: "Status")?.options else { return nil }
        return options.first { ["done", "complete", "shipped", "released", "closed"].contains(where: $0.name.lowercased().contains) }?.name
    }

    private func sheet(_ fix: Fix, workflow: IssueWorkflow) -> some View {
        let closing = fix.flag == .doneButOpen
        let board = workflow.projectNumber.flatMap { projects.cache(org: org, number: $0)?.board }
        return BulkWriteSheet(
            title: closing ? "Close \(fix.issues.count) issue\(fix.issues.count == 1 ? "" : "s")?" : "Move \(fix.issues.count) issue\(fix.issues.count == 1 ? "" : "s") to \(doneOption ?? "Done")?",
            explanation: closing
                ? "Each is closed as completed on GitHub. They're Done on the board already."
                : "Status is set to \(doneOption ?? "Done") on \(board?.title ?? "the board") for each, on GitHub.",
            action: closing ? "Close Issues" : "Move Issues",
            rows: fix.issues.map { .init(id: $0.id, title: $0.title, detail: "\($0.repo)#\(String($0.number))") }
        ) { row in
            guard let api = auth.api, let issue = fix.issues.first(where: { $0.id == row.id }) else { return }
            if closing {
                try await api.closeIssue(id: issue.id)
                if let number = workflow.projectNumber {
                    projects.recordClosed(org: org, number: number, contentID: issue.id, closed: true)
                }
            } else {
                guard let board, let done = doneOption else { throw InvestmentWriteError.message("The board hasn't loaded") }
                try await FieldWriter.set(
                    "Status", to: done, on: issue, board: board.number, title: board.title,
                    boardID: projects.boardLists[org]?.first { $0.number == board.number }?.id ?? board.id,
                    org: org, api: api, issues: issueStore, projects: projects
                )
            }
        } onClose: {
            fixing = nil
        }
    }
}
