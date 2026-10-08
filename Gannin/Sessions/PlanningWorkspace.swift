import AppKit
import SwiftUI

/// What claude keeps in a planning session's state file as the room
/// answers: the requirement, what it found in the code, the pieces the work
/// splits into and what was settled. Read leniently, so a field claude
/// leaves out or gets wrong is empty rather than losing the rest. The file
/// is snake case; the session keeps its copy as Swift names it.
struct PlanningState: Codable, Hashable {
    struct Requirement: Codable, Hashable {
        var problem: String?
        var goal: String?
        var users: String?
        var scope: [String] = []
        var nonGoals: [String] = []
        var acceptance: [String] = []
        var openQuestions: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            problem = c.lenient(String.self, .problem)
            goal = c.lenient(String.self, .goal)
            users = c.lenient(String.self, .users)
            scope = c.list(String.self, .scope)
            nonGoals = c.list(String.self, .nonGoals)
            acceptance = c.list(String.self, .acceptance)
            openQuestions = c.list(String.self, .openQuestions)
        }

        var isEmpty: Bool {
            problem == nil && goal == nil && users == nil && scope.isEmpty && nonGoals.isEmpty && acceptance.isEmpty && openQuestions.isEmpty
        }
    }

    /// What claude is reading right now, and why.
    struct Scouting: Codable, Hashable {
        var why: String?
        var paths: [String] = []

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            why = c.lenient(String.self, .why)
            paths = c.list(String.self, .paths)
        }
    }

    /// Something in the code that matters to the plan: an area it touches,
    /// a pattern to follow or a risk.
    struct Finding: Codable, Hashable, Identifiable {
        var kind: String?
        var repo: String?
        /// `path`, or `path#L10-L24`.
        var path: String?
        var note: String

        var id: String { "\(repo ?? ""):\(path ?? ""):\(note)" }

        var label: String { (kind ?? "area").capitalized }

        /// The file on GitHub, at its lines when it names them.
        var url: URL? {
            guard let repo, let path, !path.isEmpty else { return nil }
            return URL(string: "https://github.com/\(repo)/blob/HEAD/\(path)")
        }
    }

    /// One piece of the work, to become a sub-issue.
    struct Piece: Codable, Hashable, Identifiable {
        var title: String
        var body: String?
        var repo: String?
        var labels: [String] = []

        var id: String { title }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            body = c.lenient(String.self, .body)
            repo = c.lenient(String.self, .repo)
            labels = c.list(String.self, .labels)
        }
    }

    struct Decision: Codable, Hashable {
        var question: String?
        var answer: String
    }

    var title: String?
    var summary: String?
    /// Where claude says it is: refining, scouting, requirements,
    /// breakdown or ready.
    var phase: String?
    var requirement = Requirement()
    var scoutingNow: Scouting?
    var scouting: [Finding] = []
    var breakdown: [Piece] = []
    var decisions: [Decision] = []
    /// Claude has asked all it needs to.
    var done = false

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(String.self, .title)
        summary = c.lenient(String.self, .summary)
        phase = c.lenient(String.self, .phase)
        requirement = c.lenient(Requirement.self, .requirement) ?? Requirement()
        scoutingNow = c.lenient(Scouting.self, .scoutingNow)
        scouting = c.list(Finding.self, .scouting)
        breakdown = c.list(Piece.self, .breakdown)
        decisions = c.list(Decision.self, .decisions)
        done = c.lenient(Bool.self, .done) ?? false
    }

    var isScouting: Bool { scoutingNow != nil || phase == "scouting" }

    /// The step claude is on: as it says, else worked out from what's there.
    var step: PlanningStep {
        switch phase?.lowercased() {
        case "context": return .context
        case "refining": return .refine
        case "scouting": return .scout
        case "requirements": return .requirements
        case "breakdown": return .breakdown
        case "ready": return .agree
        default:
            if done { return .agree }
            if scoutingNow != nil { return .scout }
            return breakdown.isEmpty ? .refine : .breakdown
        }
    }

    /// Read from claude's file, whose keys are snake case.
    static func read(_ data: Data) -> PlanningState? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(PlanningState.self, from: data)
    }

    /// What Gannin always tells a planning session, after the team's own
    /// guidance: that the room is live, how to ask, how to scout, and the
    /// state file the workspace draws.
    static func instructions(path: String) -> String {
        """
        This is a live planning session. The team is in the room watching Gannin's planning workspace on a shared screen, and one person, the facilitator, answers for the room.

        Gannin shows the session as steps, and `phase` in the state file says which you're on:

        0. `context`: when the room has given you documents, links or places to look, read them first (you'll be told what they are).
        1. `refining`: interview the room with the AskUserQuestion tool, one question at a time: two to four options, each with a short description, and your recommendation marked "(Recommended)" when you have one. The room can always answer something else. Cover the problem and who has it, the goal, what's in and out of scope, constraints, and how they'll know it's done; skip what you already know.
        2. `scouting`: when a question depends on the code, say so in one line, set `scouting_now`, and look before asking: read only, in the harness's `projects/<name>` clones or with `gh` for repos not cloned here. Never edit, commit or push in a code repo. Add what you found to `scouting`, clear `scouting_now`, and go back to `refining`.
        3. Refining and scouting are a loop: go round it as many times as it takes. When the requirement is clear, set `requirements` and ask the room, with AskUserQuestion, whether it's right. If not, back to `refining`.
        4. `breakdown`: once the room agrees the requirements, propose the pieces and ask the room whether they're right.
        5. `ready`: once the room agrees the breakdown, set `done` to true, say so, and stop asking.

        The room can interject at any point with a message starting "From the room". Take it into account straight away, even mid-step: it may answer something, change direction, or send you back a step. Record anything it settles as a decision.

        Keep `\(path)` up to date after every answer and every scout, rewriting the whole file as JSON in this shape:

        {"title": "short title", "summary": "a sentence or two", "phase": "context" | "refining" | "scouting" | "requirements" | "breakdown" | "ready", "requirement": {"problem": "...", "goal": "...", "users": "who it's for", "scope": ["what it must do"], "non_goals": ["..."], "acceptance": ["how we'll know it's done"], "open_questions": ["..."]}, "scouting_now": {"why": "...", "paths": ["owner/name:path"]} or null, "scouting": [{"kind": "area" | "pattern" | "risk", "repo": "owner/name", "path": "path or path#L10-L24", "note": "what's there and why it matters"}], "breakdown": [{"title": "...", "body": "Markdown: what to do and how it'll be checked", "repo": "owner/name", "labels": ["..."]}], "decisions": [{"question": "...", "answer": "..."}], "done": false}

        The breakdown is pieces an engineer or an agent could each pick up and finish, in the order they'd be done, each in its repo. Record each answer the room settles as a decision.

        Don't write the plan, the requirement or any issues, and don't commit them: when the room agrees, Gannin writes the plan and requirement from the state file, makes the issues and tells you.
        """
    }
}

/// Once the room agreed: who, when and what was written.
struct PlanningAgreement: Codable, Hashable {
    var at: Date
    var by: [String]
    var planPath: String?
    var requirementPath: String?
    /// `owner/name#123`, and where it is.
    var parent: String?
    var parentURL: URL?
    var issues: [URL]
}

private extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// The entries that decode, leaving out any that don't.
    func list<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}

extension SessionStore {
    /// Reads the session's state file again, here or on its server, and
    /// keeps it with the session when it's changed.
    func refreshPlanning(_ id: UUID) async {
        guard let session = sessions[id], session.planning != nil else { return }
        let data: Data?
        if let worktree = Self.worktree(for: session) {
            let url = worktree.appending(path: "planning.json")
            data = await Task.detached { try? Data(contentsOf: url) }.value
        } else {
            let path = SessionScript.shellPath(Self.worktreePath(for: session) + "/planning.json")
            let result = await ClaudeRunner.runScript("cat \(path) 2>/dev/null\n", for: session)
            data = result.status == 0 ? Data(result.output.utf8) : nil
        }
        guard let data, !data.isEmpty, let state = PlanningState.read(data),
              sessions[id]?.planning?.state != state else { return }
        let wasScouting = sessions[id]?.planning?.state?.isScouting ?? false
        update(id) {
            $0.planning?.state = state
            let rounds = $0.planning?.rounds ?? 0
            if state.isScouting && !wasScouting { $0.planning?.rounds = rounds + 1 }
        }
    }

    /// Says something from the room: closes a question that's open first
    /// (claude reads the comment in its place), and keeps it with the
    /// session for the plan.
    func interject(_ text: String, step: PlanningStep, to id: UUID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isRunning(id) else { return }
        update(id) {
            let comments = $0.planning?.comments ?? []
            $0.planning?.comments = comments + [PlanningComment(text: text, step: step.rawValue, at: .now)]
        }
        let message = "From the room, on \(step.rawValue.lowercased()): \(text)"
        if transcripts[id]?.question != nil {
            sendKeys("\u{1B}", to: id)
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                _ = submit(message, to: id)
            }
        } else {
            _ = submit(message, to: id)
        }
    }

    /// The planning session for an issue, if it has one that isn't finished.
    func planningSession(forIssue id: String) -> CodeSession? {
        sessions.values.first { $0.planning?.issue?.id == id && $0.archivedAt == nil }
    }
}


/// The steps of planning, as the workspace shows them. Refine and Scout are
/// a loop the room goes round until the requirements are clear; then the
/// room confirms them, breaks the work down and agrees.
enum PlanningStep: String, CaseIterable, Identifiable {
    case context = "Context"
    case refine = "Refine"
    case scout = "Scout"
    case requirements = "Requirements"
    case breakdown = "Break Down"
    case agree = "Agree"

    var id: Self { self }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var systemImage: String {
        switch self {
        case .context: "tray.full"
        case .refine: "text.bubble"
        case .scout: "magnifyingglass"
        case .requirements: "text.badge.checkmark"
        case .breakdown: "list.number"
        case .agree: "checkmark.seal"
        }
    }

    /// What happens on the step, under its title.
    var explanation: String {
        switch self {
        case .context: "What the room gave to read first: documents, links and places to look. The questions build on it."
        case .refine: "Questions for the room, one at a time. Answer on the card, or say something else below."
        case .scout: "Looking at the code a question depends on, then back to refining."
        case .requirements: "Is this what we need? Confirm it to break the work down, or keep refining."
        case .breakdown: "The pieces the work splits into. Each becomes a sub-issue when the room agrees."
        case .agree: "Who was here, the issues to make and the plan to write, confirmed before anything's written."
        }
    }
}

/// A planning session's tab, as a wizard: the steps across the top (Refine
/// and Scout a loop with its round), what's happening now (the question to
/// the room, what's being read, or whose turn it is), the step picked
/// beneath, and a comment bar to say something at any point. The terminal
/// is a drawer. It is laid out large, for the screen in the room.
struct PlanningWorkspaceView: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    /// A step picked to look back at; nil follows the one under way.
    @State private var viewing: PlanningStep?
    @State private var agreeing = false
    /// Documents picked or dropped, being confirmed.
    @State private var sharing: [URL]?
    @State private var comment = ""
    @FocusState private var commenting: Bool
    @AppStorage("planningShowsTerminal") private var showsTerminal = false
    /// The question the dim was lifted for, by clicking past it; a new
    /// question dims again, and clicking the card puts it back.
    @State private var undimmed: String?
    @State private var newContext = ""

    private var openQuestion: String? {
        sessions.isRunning(session.id) ? sessions.transcripts[session.id]?.question?.id : nil
    }

    private var dimmed: Bool { openQuestion != nil && undimmed != openQuestion && !isLookingBack }

    /// A step other than the one under way is open.
    private var isLookingBack: Bool { viewing.map { $0 != current } ?? false }

    private var planning: PlanningInfo? { session.planning }
    private var state: PlanningState? { planning?.state }
    private var running: Bool { sessions.isRunning(session.id) }
    private var busy: Bool { [.starting, .working].contains(sessions.state(session.id)) }

    /// The step under way.
    private var current: PlanningStep {
        planning?.agreed != nil ? .agree : state?.step ?? (planning?.hasContext == true ? .context : .refine)
    }

    private var shown: PlanningStep { viewing ?? current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                stepper
                Spacer(minLength: 12)
                actionsBar
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            VSplitView {
                VStack(spacing: 0) {
                    // Questions and the step on the left; the requirement
                    // as it stands on the right, always in view.
                    FixedSplit(key: "planningQuestionsWidth", width: 900, range: 560...1400) {
                        VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 36) {
                                now
                                    .simultaneousGesture(TapGesture().onEnded { undimmed = nil })
                                VStack(alignment: .leading, spacing: 28) {
                                    if let viewing, viewing != current {
                                        lookingBack(viewing)
                                    }
                                    stepContent(shown)
                                }
                                .dimmedWhileAsking(dimmed) { undimmed = openQuestion }
                            }
                            .padding(.horizontal, 36)
                            .padding(.vertical, 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        commentBox
                            .padding(.horizontal, 36)
                            .padding(.top, 12)
                            .padding(.bottom, 24)
                        }
                    } trailing: {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Label("Requirements", systemImage: PlanningStep.requirements.systemImage)
                                    .font(.title2.weight(.semibold))
                                requirementView
                            }
                            .padding(.horizontal, 36)
                            .padding(.vertical, 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dimmedWhileAsking(dimmed) { undimmed = openQuestion }
                        }
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    }
                }
                .font(.title3)
                .frame(minHeight: 320, maxHeight: .infinity)
                if showsTerminal {
                    VStack(spacing: 0) {
                        TerminalHost(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        SessionComposer(session: session)
                    }
                    .frame(minHeight: 160, idealHeight: 240, maxHeight: .infinity)
                }
            }
        }
        // Starts claude with the terminal put away, as opening the tab did.
        .onAppear { _ = sessions.open(session) }
        .onChange(of: current) { viewing = nil }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            sharing = files
            return true
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            ShareDocumentsSheet(session: session, files: sharing ?? [])
        }
        .sheet(isPresented: $agreeing) {
            PlanningAgreeSheet(session: session)
        }
        // Each change signal reads the file again (a short wait lets a
        // burst of writes settle), then every few seconds in case one
        // was missed.
        .task(id: sessions.changeCount(session.id)) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                while true {
                    await sessions.refreshPlanning(session.id)
                    try await Task.sleep(for: .seconds(session.isRemote ? 15 : 4))
                }
            } catch {}
        }
    }

    // MARK: Actions

    /// Beside the steps: the window's title already names the plan.
    private var actionsBar: some View {
        HStack(spacing: 10) {
            Button {
                choose()
            } label: {
                Label("Share Documents", systemImage: "doc.badge.plus")
            }
            .help("Pick documents to read while planning; each is confirmed first. You can also drop them on the workspace.")
            .disabled(!running)
            Toggle(isOn: $showsTerminal.animation()) {
                Label("Terminal", systemImage: "terminal")
            }
            .toggleStyle(.button)
            .help(showsTerminal ? "Put the terminal away" : "Show the terminal and its composer")
            Button(planning?.agreed == nil ? "Agree" : "Agreed") { agreeing = true }
                .buttonStyle(.borderedProminent)
                .disabled(state == nil || planning?.agreed != nil)
                .help(planning?.agreed == nil ? "Write the plan and requirement to the harness and make the issues, confirmed first" : "The room agreed this plan")
        }
        .padding(.bottom, 16)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Documents to read while planning. You'll confirm each before it's shared."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        sharing = panel.urls
    }

    // MARK: Stepper

    private var stepper: some View {
        HStack(spacing: 10) {
            stepChip(.context)
                .padding(.bottom, 16)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    stepChip(.refine)
                    loopMark
                    stepChip(.scout)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                Text("Until the requirements are clear")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach([PlanningStep.requirements, .breakdown, .agree]) { step in
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 16)
                stepChip(step)
                    .padding(.bottom, 16)
            }
        }
    }

    /// Round and round: refining and scouting, with how many times.
    private var loopMark: some View {
        let inLoop = current == .refine || current == .scout
        return VStack(spacing: 1) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(inLoop ? Color.accentColor : .secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: inLoop && busy)
            Text("Round \(max(1, planning?.rounds ?? 0))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help("Refining and scouting go round until the requirements are clear")
    }

    private func isDone(_ step: PlanningStep) -> Bool {
        if planning?.agreed != nil { return true }
        if current == .scout && step == .refine { return false }
        return step.index < current.index
    }

    private func stepChip(_ step: PlanningStep) -> some View {
        let isCurrent = step == current
        let done = isDone(step)
        let picked = step == shown
        return Button {
            viewing = step == current ? nil : step
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isCurrent ? Color.accentColor : done ? ChartPalette.good.opacity(0.2) : Color.secondary.opacity(0.15))
                    if done {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ChartPalette.good)
                    } else {
                        Image(systemName: step.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isCurrent ? .white : .secondary)
                            .symbolEffect(.pulse, options: .repeating, isActive: isCurrent && busy)
                    }
                }
                .frame(width: 24, height: 24)
                Text(step.rawValue)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent || done ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(picked ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "Under way: \(step.explanation)" : "Look at \(step.rawValue)")
        .accessibilityLabel("\(step.rawValue)\(isCurrent ? ", under way" : done ? ", done" : "")")
    }

    private func lookingBack(_ step: PlanningStep) -> some View {
        HStack {
            Image(systemName: "eye")
            Text("Looking at \(step.rawValue). \(current.rawValue) is under way.")
            Button("Back to \(current.rawValue)") { viewing = nil }
                .buttonStyle(.link)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Now

    /// What's happening now, whichever step is shown: the agreement, the
    /// question to the room, what's being read, or whose turn it is.
    @ViewBuilder
    private var now: some View {
        if let agreed = planning?.agreed {
            agreedStatus(agreed)
        } else if isLookingBack, openQuestion != nil {
            // Out of the way while another step's looked at.
            HStack(spacing: 12) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("A question is waiting for the room")
                    .font(.headline)
                Spacer()
                Button("Back to the Question") { viewing = nil }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.45)) }
        } else if let question = sessions.transcripts[session.id]?.question, sessions.isRunning(session.id) {
            PlanningQuestionView(session: session, question: question, history: state?.decisions ?? [],
                                 revisitLast: state?.decisions.last.map { last in { revisit(last) } })
        } else if permissionPending {
            SessionQuestionCard(session: session)
        } else if let scouting = state?.scoutingNow {
            statusLine("Looking at the code", symbol: "magnifyingglass", color: ChartPalette.blue, busy: true) {
                if let why = scouting.why { Text(why) }
                ForEach(scouting.paths, id: \.self) { path in
                    Text(path).font(.callout.monospaced())
                }
            }
        } else {
            turnStatus
        }
    }

    /// A real permission prompt: a tool waiting that isn't the question
    /// just answered. Answering closes the question before claude's hooks
    /// catch up, so "needs you" alone would flash a permission card.
    private var permissionPending: Bool {
        guard sessions.state(session.id) == .needsYou,
              let tool = sessions.transcripts[session.id]?.pendingTool,
              case .tool(let name) = tool.kind, name != "AskUserQuestion" else { return false }
        return SessionQuestionCard.isAsking(session, in: sessions)
    }

    @ViewBuilder
    private var turnStatus: some View {
        switch sessions.state(session.id) {
        case .needsYou where !permissionPending && state?.done != true:
            // Just answered: claude has it, and is about to say so.
            statusLine("Thinking", symbol: "ellipsis.bubble", color: ChartPalette.blue, busy: true) { EmptyView() }
        case .starting:
            statusLine("Starting", symbol: "ellipsis.bubble", color: ChartPalette.blue, busy: true) { EmptyView() }
        case .working:
            statusLine("Thinking", symbol: "ellipsis.bubble", color: ChartPalette.blue, busy: true) { EmptyView() }
        case .needsYou, .idle:
            if state?.done == true {
                statusLine("Ready to agree", symbol: "checkmark.circle", color: ChartPalette.good) {
                    Text("Look over the requirements and breakdown, then Agree when the room's ready.")
                }
            } else {
                statusLine("Waiting for the room", symbol: "text.bubble", color: .orange) {
                    Text("Say something in the box below the questions to carry on, or pick a step to look back at.")
                }
            }
        case .exited, .stopped:
            statusLine("Not running", symbol: "pause.circle", color: .secondary) {
                Text("Open the terminal below to start it again; it picks up the conversation.")
            }
        }
    }

    private func agreedStatus(_ agreed: PlanningAgreement) -> some View {
        statusLine("Agreed \(agreed.at.formatted(date: .abbreviated, time: .shortened))", symbol: "checkmark.seal.fill", color: ChartPalette.good) {
            if !agreed.by.isEmpty {
                Text("By \(agreed.by.joined(separator: ", ")).")
            }
            HStack(spacing: 14) {
                if let path = agreed.planPath, let url = harnessURL(path) {
                    Link("Plan", destination: url)
                }
                if let path = agreed.requirementPath, let url = harnessURL(path) {
                    Link("Requirement", destination: url)
                }
                if let parent = agreed.parent, let url = agreed.parentURL {
                    Link(parent, destination: url)
                }
                if !agreed.issues.isEmpty {
                    Text("\(agreed.issues.count) sub-issues")
                }
            }
        }
    }

    private func harnessURL(_ path: String) -> URL? {
        session.harnessRepo.flatMap { URL(string: "https://github.com/\($0)/blob/HEAD/\(path)") }
    }

    /// `busy` animates the symbol and puts a spinner by the title, so
    /// it's clear work is under way.
    private func statusLine(_ title: String, symbol: String, color: Color, busy: Bool = false, @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: busy)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
                detail()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Steps

    @ViewBuilder
    private func stepContent(_ step: PlanningStep) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label(step.rawValue, systemImage: step.systemImage)
                    .font(.title2.weight(.semibold))
                Text(step.explanation)
                    .foregroundStyle(.secondary)
            }
            switch step {
            case .context: contextStep
            case .refine: refineStep
            case .scout: scoutStep
            case .requirements: requirementsStep
            case .breakdown: breakdownStep
            case .agree: agreeStep
            }
        }
    }

    @ViewBuilder
    private var contextStep: some View {
        let documents = planning?.documents ?? []
        let links = planning?.links ?? []
        if documents.isEmpty && links.isEmpty && (planning?.sources ?? "").isEmpty {
            empty("Nothing was given to read first. Add links or documents below, and they're read before the next question.")
        }
        if !documents.isEmpty {
            sectionTitle("Documents")
            ForEach(documents) { document in
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                    Text(document.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(document.commit ? "Committed with the plan" : "Not committed")
                        .font(.callout)
                        .foregroundStyle(document.commit ? .orange : .secondary)
                }
            }
        }
        if !links.isEmpty {
            sectionTitle("Links")
            ForEach(links) { link in
                HStack(spacing: 10) {
                    Image(systemName: "link")
                    Link(link.url.absoluteString, destination: link.url).lineLimit(1).truncationMode(.middle)
                    if let note = link.note { Text(note).foregroundStyle(.secondary) }
                    Spacer()
                }
            }
        }
        if let sources = planning?.sources {
            sectionTitle("Where else to look")
            ForEach(Array(sources.split(whereSeparator: \.isNewline).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "text.magnifyingglass")
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        sectionTitle("Add more")
        VStack(alignment: .leading, spacing: 10) {
            TextField("Context", text: $newContext, prompt: Text("Paste a link and say what it is, or say where else to look"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Add Context", action: addContext)
                    .buttonStyle(.borderedProminent)
                    .disabled(newContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !running)
                Button {
                    choose()
                } label: {
                    Label("Add Documents", systemImage: "doc.badge.plus")
                }
                .disabled(!running)
                .help("Pick one or more; each is confirmed before it's shared")
                Text("or drop them anywhere here")
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.large)
    }

    /// Context given later: links kept with the others, anything else as
    /// somewhere to look, and all of it sent to be read now.
    private func addContext() {
        let text = newContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, running else { return }
        let parsed = PlanningLink.parse(text)
        sessions.update(session.id) {
            let links = $0.planning?.links ?? []
            $0.planning?.links = links + parsed.links
            if let note = parsed.note {
                let sources = $0.planning?.sources
                $0.planning?.sources = [sources, note].compactMap { $0 }.joined(separator: "\n")
            }
        }
        say("Here's more context: \(text)\n\nRead any links with your connected tools or by fetching them, look where it says, and tell us what it changes.")
        newContext = ""
    }

    @ViewBuilder
    private var refineStep: some View {
        actions {
            Button("Look at the Code Now") { say("Look at the code for what we've covered so far, then carry on asking.") }
                .help("Send it to scout before the next question")
            Button("We've Covered It") { say("We think the requirements are clear now. Show us them to confirm.") }
                .help("Move on to confirming the requirements")
        }
        if let decisions = state?.decisions, !decisions.isEmpty {
            sectionTitle("Decisions")
            decisionList(Array(decisions.suffix(5)))
        }
    }

    @ViewBuilder
    private var scoutStep: some View {
        let findings = state?.scouting ?? []
        if findings.isEmpty {
            empty("Nothing found yet. The code is looked at when a question depends on it.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(findings) { finding in
                    findingRow(finding)
                }
            }
        }
    }

    @ViewBuilder
    private var requirementsStep: some View {
        Label("The requirement is on the right.", systemImage: "arrow.right")
            .foregroundStyle(.secondary)
        actions {
            Button("Keep Refining") { say("The requirements aren't settled yet. Keep asking about what's missing.") }
            Button("Requirements Are Right") { say("The requirements are right. Move on to breaking the work down.") }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var breakdownStep: some View {
        let pieces = state?.breakdown ?? []
        if pieces.isEmpty {
            empty("The pieces are proposed once the requirements are agreed.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                    pieceRow(index + 1, piece)
                }
            }
        }
        actions {
            Button("Rework It") { commenting = true }
                .help("Say what to change in the comment bar")
            Button("Breakdown Is Right") { say("The breakdown is right. We're ready to agree.") }
            Button("Agree") { agreeing = true }
                .buttonStyle(.borderedProminent)
                .disabled(state == nil || planning?.agreed != nil)
        }
    }

    @ViewBuilder
    private var agreeStep: some View {
        if let state {
            let findings = state.scouting.filter { !(planning?.dismissed ?? []).contains($0.id) }.count
            Text("\(count(state.breakdown.count, "piece")), \(count(findings, "finding")) and \(count(state.decisions.count, "decision")) from \(count(max(1, planning?.rounds ?? 0), "round")) of refining.")
                .foregroundStyle(.secondary)
        }
        if planning?.agreed == nil {
            actions {
                Button("Agree") { agreeing = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(state == nil)
            }
        }
        if let decisions = state?.decisions, !decisions.isEmpty {
            sectionTitle("Decisions")
            decisionList(decisions)
        }
        if let comments = planning?.comments, !comments.isEmpty {
            sectionTitle("From the room")
            ForEach(comments) { comment in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(comment.at.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(comment.text)
                    Text(comment.step).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    private func say(_ text: String) {
        sessions.interject(text, step: current, to: session.id)
    }

    private func actions(@ViewBuilder _ buttons: () -> some View) -> some View {
        HStack(spacing: 10) {
            buttons()
        }
        .controlSize(.large)
        .disabled(!running)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: Parts

    @ViewBuilder
    private var requirementView: some View {
        let requirement = state?.requirement ?? PlanningState.Requirement()
        if requirement.isEmpty {
            empty("Fills in as the room answers.")
        } else {
            VStack(alignment: .leading, spacing: 24) {
                field("Problem", requirement.problem)
                field("Goal", requirement.goal)
                field("Who it's for", requirement.users)
                list("Scope", requirement.scope, numbered: true)
                list("Out of scope", requirement.nonGoals)
                list("Done when", requirement.acceptance)
                list("Open questions", requirement.openQuestions)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.separatorLine) }
        }
    }

    private func field(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(label)
            Text(value ?? "Not settled yet")
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func list(_ label: String, _ items: [String], numbered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(label)
            if items.isEmpty {
                Text("Not settled yet").foregroundStyle(.tertiary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(numbered ? "\(index + 1)." : "•")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(item)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func findingRow(_ finding: PlanningState.Finding) -> some View {
        let dismissed = (planning?.dismissed ?? []).contains(finding.id)
        let risk = finding.kind?.lowercased() == "risk"
        return HStack(alignment: .top, spacing: 12) {
            Text(finding.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background((risk ? Color.orange : ChartPalette.blue).opacity(0.18), in: Capsule())
            VStack(alignment: .leading, spacing: 4) {
                if let path = finding.path {
                    let shown = finding.repo.map { "\($0.split(separator: "/").last.map(String.init) ?? $0): \(path)" } ?? path
                    if let url = finding.url {
                        Link(shown, destination: url).font(.callout.monospaced())
                    } else {
                        Text(shown).font(.callout.monospaced())
                    }
                }
                Text(finding.note)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(dismissed ? "Restore" : "Dismiss") {
                sessions.update(session.id) { session in
                    var set = session.planning?.dismissed ?? []
                    if dismissed { set.remove(finding.id) } else { set.insert(finding.id) }
                    session.planning?.dismissed = set
                }
            }
            .help(dismissed ? "Put it back in the plan" : "Leave it out of the plan")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.separatorLine) }
        .opacity(dismissed ? 0.45 : 1)
    }

    private func pieceRow(_ number: Int, _ piece: PlanningState.Piece) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(piece.title).fontWeight(.semibold)
                    Spacer()
                    if let repo = piece.repo {
                        Text(repo).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let body = piece.body, !body.isEmpty {
                    MarkdownText(source: body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.separatorLine) }
    }

    private func decisionList(_ decisions: [PlanningState.Decision]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let question = decision.question {
                            Text(question).foregroundStyle(.secondary)
                        }
                        Text(decision.answer)
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if planning?.agreed == nil {
                        Button("Revisit") { revisit(decision) }
                            .disabled(!running)
                            .help("Ask it again: the room wants to reconsider this")
                    }
                }
            }
        }
    }

    /// Has claude put a settled question to the room again, with what was
    /// said before, so it can be answered differently.
    private func revisit(_ decision: PlanningState.Decision) {
        let topic = decision.question.map { "\"\($0)\"" } ?? "what we settled as \"\(decision.answer)\""
        say("We want to revisit \(topic). We said \"\(decision.answer)\". Ask it again as a question, with that answer marked as what we said before, and update everything that depended on it once we've answered.")
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Comments

    /// Always there: anything typed goes to the session
    /// as from the room, closing an open question so it's read first.
    private var commentBox: some View {
        // Icon, text and send on one centre line; growing, the text keeps
        // them centred on it.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "text.bubble.fill")
                .font(.title2)
                .foregroundStyle(commenting ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
            TextField("Say something to the session at any point: a comment, a correction, where to go next", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(1...10)
                .focused($commenting)
                // Return sends; Shift-Return (or Option-Return) is a new line.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        comment += "\n"
                    } else {
                        send()
                    }
                    return .handled
                }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canSend ? Color.accentColor : .secondary)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .help(running ? "Send (Return); Shift-Return for a new line. An open question is closed so this is read first." : "Not running: open the terminal to start it again")
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(commenting ? Color.accentColor : Color.separatorLine, lineWidth: commenting ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { commenting = true }
        .animation(.easeInOut(duration: 0.15), value: commenting)
    }

    private var canSend: Bool {
        running && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, running else { return }
        sessions.interject(text, step: shown, to: session.id)
        comment = ""
    }
}

private extension View {
    /// Faded while a question has the room's attention; a click lifts it.
    func dimmedWhileAsking(_ dimmed: Bool, lift: @escaping () -> Void) -> some View {
        opacity(dimmed ? 0.25 : 1)
            .overlay {
                if dimmed {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: lift)
                        .help("Click to look at this while the question's open")
                }
            }
            .animation(.easeInOut(duration: 0.25), value: dimmed)
    }
}
