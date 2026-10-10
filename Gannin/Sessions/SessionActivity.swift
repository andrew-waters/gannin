import SwiftUI

/// What claude has been doing, from its transcript: what it cost and how
/// long it worked against how long it waited on you, the plans it wrote
/// (to approve or send back), the helpers on its issue, a reviewer's
/// findings, and its activity, newest last.
struct SessionActivityPane: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var reading: PlanReading?
    @State private var planChanges = ""
    @State private var addingHelper = false
    @State private var imported: Int?

    var body: some View {
        let transcript = sessions.transcripts[session.id]
        let running = sessions.isRunning(session.id)
        ScrollViewReader { proxy in
            Form {
                if let transcript {
                    stats(transcript)
                    if !transcript.plans.isEmpty { plans(transcript.plans, running: running) }
                    if session.isReviewer { findings(transcript) }
                }
                if let working = pairSession { PairReviewSection(session: working) }
                helpers
                if let transcript, !transcript.events.isEmpty {
                    Section("Activity") {
                        ForEach(transcript.events) { event in
                            ActivityRow(event: event)
                                .id(event.id)
                        }
                    }
                } else {
                    Section("Activity") {
                        Text(running ? "Claude's activity shows here as it works." : "Start the session to see what claude has been doing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: transcript?.events.last?.id) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
        .sheet(item: $reading) { reading in
            PlanSheet(session: session, path: reading.path)
        }
        .sheet(isPresented: $addingHelper) {
            HelperSheet(parent: session.parentID.flatMap { sessions.sessions[$0] } ?? session)
        }
    }

    private func stats(_ transcript: SessionTranscript) -> some View {
        Section("Claude Code") {
            if let model = transcript.model {
                LabeledContent("Model", value: model)
            }
            LabeledContent("Cost", value: transcript.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))))
            LabeledContent("Working", value: Self.duration(transcript.workingSeconds))
            LabeledContent("Waiting on you", value: Self.duration(transcript.waitingSeconds))
            LabeledContent("Files edited", value: "\(transcript.filesEdited.count)")
            if let tokens = transcript.contextTokens {
                LabeledContent("Context", value: "\(tokens.formatted()) of \(transcript.contextLimit.formatted()) tokens")
            }
            if let check = transcript.lastCheck {
                LabeledContent("Last test or build") {
                    Label(check.passed ? "Passed" : "Failed", systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.passed ? ChartPalette.good : ChartPalette.critical)
                        .help(check.command)
                }
            }
        }
    }

    /// Plans claude wrote: read one, then let it go ahead or say what to
    /// change.
    private func plans(_ plans: [String], running: Bool) -> some View {
        Section("Plans") {
            ForEach(plans, id: \.self) { path in
                HStack {
                    Image(systemName: "list.bullet.clipboard")
                        .foregroundStyle(.secondary)
                    Text((path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                    Spacer()
                    Button("Read") { reading = PlanReading(path: path) }
                }
            }
            TextField("What to change in the plan", text: $planChanges, axis: .vertical)
                .lineLimit(1...4)
            HStack {
                Spacer()
                Button("Request Changes") {
                    if sessions.submit("Changes to the plan before you start:\n\n\(planChanges)", to: session.id) { planChanges = "" }
                }
                .disabled(!running || planChanges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Approve Plan") {
                    sessions.submit("The plan looks good. Go ahead with it, ticking its tasks off as they land.", to: session.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!running)
            }
        }
    }

    private func findings(_ transcript: SessionTranscript) -> some View {
        let findings = transcript.findings
        let parent = session.parentID.flatMap { sessions.sessions[$0] }
        return Section("Review") {
            if findings.isEmpty {
                Text("When the review's done, its findings show here, to add to the comments on \(parent.map { "#\($0.issue.number)" } ?? "the session")'s changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.line.map { "\(finding.path):\($0)" } ?? finding.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(finding.comment)
                            .font(.callout)
                    }
                }
                HStack {
                    if let imported { Text("Added \(imported)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Add to Comments") {
                        imported = sessions.importFindings(from: session.id)
                    }
                    .help("Add them to the comments on the session's changes, to read over and send to it from Changes")
                }
            }
        }
    }

    /// The working session whose review loop shows here: this one, or the
    /// one this reviews.
    private var pairSession: CodeSession? {
        session.canPairReview ? session : sessions.pairReviewed(by: session.id)
    }

    /// The other agents on this issue, and starting another.
    private var helpers: some View {
        let parent = session.parentID.flatMap { sessions.sessions[$0] } ?? session
        let others = ([parent] + sessions.helpers(of: parent.id)).filter { $0.id != session.id }
        let learnings = sessions.reviewLearnings(for: parent)
        return Section("Agents on \(session.shortReference)") {
            ForEach(others) { other in
                Button {
                    sessions.reveal(other.id)
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(sessions.state(other.id).color).frame(width: 7, height: 7)
                        Text(other.role ?? "Main session")
                        Spacer()
                        Text(sessions.state(other.id).label).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Review the Changes") {
                    _ = sessions.startHelper(for: parent.id, role: "Review", prompt: SessionStore.reviewPrompt(for: parent, learnings: learnings), reviewer: true)
                }
                .help("Start a second agent that reads the changes, can't edit, and reports findings you can send back")
                Spacer()
                Button("Add Helper") { addingHelper = true }
                    .help("Another agent on this issue, in the same folder and branch, with a job of its own")
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow, zeroValueUnits: .hide, fractionalPart: .hide))
            .ifEmpty("0m")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private struct PlanReading: Identifiable {
    let path: String
    var id: String { path }
}

private struct ActivityRow: View {
    let event: SessionTranscript.Event

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if let at = event.at {
                        Text(at.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(isTool ? .caption.monospaced() : .callout)
                        .foregroundStyle(isTool ? .secondary : .primary)
                        .lineLimit(isTool ? 2 : 8)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var isTool: Bool {
        if case .tool = event.kind { return true }
        return false
    }

    private var title: String {
        switch event.kind {
        case .prompt: "You"
        case .reply: "Claude"
        case .tool(let name): event.failed == true ? "\(name), failed" : name
        }
    }

    private var symbol: String {
        switch event.kind {
        case .prompt: return "person.fill"
        case .reply: return "sparkle"
        case .tool(let name):
            switch name {
            case "Bash": return "terminal"
            case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
            case "Read": return "doc.text"
            case "Grep", "Glob": return "magnifyingglass"
            case "AskUserQuestion": return "questionmark.bubble"
            case "Task", "Agent": return "person.2"
            case "WebFetch", "WebSearch": return "globe"
            default: return "wrench.and.screwdriver"
            }
        }
    }

    private var color: Color {
        switch event.kind {
        case .prompt: .accentColor
        case .reply: .orange
        case .tool: event.failed == true ? ChartPalette.critical : .secondary
        }
    }
}

/// A plan claude wrote, read from its box.
private struct PlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: CodeSession
    let path: String
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((path as NSString).lastPathComponent).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                if let text {
                    MarkdownText(source: text, reflows: true, reading: 14)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error {
                    Text(error).foregroundStyle(.secondary).padding(20)
                } else {
                    ProgressView().padding(40)
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 720)
        .task { await load() }
    }

    private func load() async {
        guard let runner = SessionChanges.runner(for: session) else {
            error = "This session's box can't be reached from here."
            return
        }
        let script = "cat \(SessionScript.quoted(path))"
        let result = await Task.detached { Shell.run(script, runner) }.value
        if result.ok { text = result.output } else { error = result.error.isEmpty ? "Couldn't read the plan." : result.error }
    }
}

/// Another agent on the issue: what it's for, and its first prompt.
private struct HelperSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let parent: CodeSession
    @State private var role = "Tests"
    @State private var prompt = ""

    var body: some View {
        Form {
            Section {
                TextField("For", text: $role, prompt: Text("Tests"))
                TextField("First prompt", text: $prompt, axis: .vertical)
                    .lineLimit(4...10)
            } footer: {
                Text("It works in #\(parent.issue.number)'s folder on \(parent.branch), beside the main session, with the same brief. Tell it which repo and files are its, so they don't both edit the same ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") {
                    _ = sessions.startHelper(for: parent.id, role: role.isEmpty ? "Helper" : role, prompt: prompt, reviewer: false)
                    dismiss()
                }
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            if prompt.isEmpty {
                prompt = "You're helping on \(parent.issue.reference), \"\(parent.issue.title)\". Another agent is implementing it in \(parent.isInHarness ? ".worktrees/\(parent.branch)/" : "this worktree"). Read the brief, then write tests for what it's changing. Don't edit its files except to add tests."
            }
        }
    }
}
