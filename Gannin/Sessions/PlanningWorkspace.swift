import AppKit
import SwiftUI

/// What claude keeps in a planning session's state file, as a spec built in
/// stages: the requirement (with acceptance criteria to trace), the design
/// and what was found in the code, the tasks, and what was settled. Read
/// leniently, so a field claude leaves out or gets wrong is empty rather
/// than losing the rest. The file is snake case; the session keeps its copy
/// as Swift names it.
struct PlanningState: Codable, Hashable {
    /// One acceptance criterion, `R1`, testable: "When X, the system shall Y".
    struct Criterion: Codable, Hashable, Identifiable {
        var id: String
        var text: String

        init(id: String, text: String) {
            self.id = id
            self.text = text
        }

        /// An object, or a bare string (numbered by its place).
        init(from decoder: Decoder) throws {
            if let bare = try? decoder.singleValueContainer().decode(String.self) {
                id = ""
                text = bare
            } else {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = c.lenient(String.self, .id) ?? ""
                text = try c.decode(String.self, forKey: .text)
            }
        }
    }

    struct Requirement: Codable, Hashable {
        var problem: String?
        var goal: String?
        var users: String?
        var scope: [String] = []
        var nonGoals: [String] = []
        var acceptance: [Criterion] = []
        var openQuestions: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            problem = c.lenient(String.self, .problem)
            goal = c.lenient(String.self, .goal)
            users = c.lenient(String.self, .users)
            scope = c.list(String.self, .scope)
            nonGoals = c.list(String.self, .nonGoals)
            acceptance = c.list(Criterion.self, .acceptance).enumerated().map { index, criterion in
                Criterion(id: criterion.id.isEmpty ? "R\(index + 1)" : criterion.id, text: criterion.text)
            }
            openQuestions = c.list(String.self, .openQuestions)
        }

        var isEmpty: Bool {
            problem == nil && goal == nil && users == nil && scope.isEmpty && nonGoals.isEmpty && acceptance.isEmpty && openQuestions.isEmpty
        }
    }

    /// How it'll be built, besides what the code showed (`scouting`).
    struct Design: Codable, Hashable {
        var approach: String?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            approach = c.lenient(String.self, .approach)
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

    /// Something in the code that matters to the design: an area it
    /// touches, a pattern to follow or a risk.
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

    /// One task, to become a sub-issue, and the criteria it satisfies.
    struct PlanTask: Codable, Hashable, Identifiable {
        var title: String
        var body: String?
        var repo: String?
        var labels: [String] = []
        /// Acceptance criteria by id (`R1`).
        var satisfies: [String] = []

        var id: String { title }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            body = c.lenient(String.self, .body)
            repo = c.lenient(String.self, .repo)
            labels = c.list(String.self, .labels)
            satisfies = c.list(String.self, .satisfies)
        }
    }

    struct Decision: Codable, Hashable {
        var question: String?
        var answer: String
        /// The stage it was settled in: requirements, design or tasks.
        var stage: String?
    }

    var title: String?
    var summary: String?
    /// The stage claude says it's on: context, requirements, design, tasks
    /// or ready.
    var phase: String?
    var requirement = Requirement()
    var design = Design()
    var scoutingNow: Scouting?
    var scouting: [Finding] = []
    var tasks: [PlanTask] = []
    var decisions: [Decision] = []
    /// Claude has asked all it needs to.
    var done = false

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenient(String.self, .title)
        summary = c.lenient(String.self, .summary)
        phase = c.lenient(String.self, .phase)
        requirement = c.lenient(Requirement.self, .requirement) ?? Requirement()
        design = c.lenient(Design.self, .design) ?? Design()
        scoutingNow = c.lenient(Scouting.self, .scoutingNow)
        scouting = c.list(Finding.self, .scouting)
        tasks = c.list(PlanTask.self, .tasks)
        decisions = c.list(Decision.self, .decisions)
        done = c.lenient(Bool.self, .done) ?? false
    }

    /// The stage claude is on: as it says, else worked out from what's there.
    var step: PlanningStep {
        switch phase?.lowercased() {
        case "context": return .context
        case "requirements": return .requirements
        case "design": return .design
        case "tasks": return .tasks
        case "ready": return .agree
        default:
            if done { return .agree }
            if !tasks.isEmpty { return .tasks }
            if design.approach != nil { return .design }
            return .requirements
        }
    }

    /// Acceptance criteria no task says it satisfies.
    var uncovered: [Criterion] {
        let covered = Set(tasks.flatMap(\.satisfies).map { $0.uppercased() })
        return requirement.acceptance.filter { !covered.contains($0.id.uppercased()) }
    }

    func decisions(in step: PlanningStep) -> [Decision] {
        decisions.filter { ($0.stage ?? "requirements").lowercased() == step.phase }
    }

    /// Read from claude's file, whose keys are snake case.
    static func read(_ data: Data) -> PlanningState? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(PlanningState.self, from: data)
    }

    /// What Gannin always tells a planning session, after the team's own
    /// guidance: that the room is live, the stages of the spec and how to
    /// move between them, and the state file the workspace draws.
    static func instructions(path: String) -> String {
        """
        This is a live planning session. The team is in the room watching Gannin's planning workspace on a shared screen, and one person, the facilitator, answers for the room. Together you're writing a spec in stages, and `phase` in the state file says which stage you're on:

        - `context`: when the room has given you documents, links or places to look, read them first (you'll be told what they are).
        - `requirements`: what's needed and why, not how. Interview the room with the AskUserQuestion tool, one question at a time: two to four options, each with a short description, and your recommendation marked "(Recommended)" when you have one. The room can always answer something else. Cover the problem and who has it, the goal, what's in and out of scope, and how they'll know it's done. Write acceptance criteria as testable statements ("When X, the system shall Y"), each with an id: R1, R2 and so on. Look at the code only when a question genuinely depends on it. When the requirements are clear, ask the room whether they're right; once they are, move to `design`.
        - `design`: how it'll be built. Look at the code (read only, in the harness's `projects/<name>` clones or with `gh` for repos not cloned here; never edit, commit or push in a code repo), setting `scouting_now` while you do: the areas it touches, patterns to follow and risks go in `scouting`. Propose the approach in `design.approach`, put the design's open questions to the room, and ask whether the design is right; once it is, move to `tasks`.
        - `tasks`: the pieces an engineer or an agent could each pick up and finish, in the order they'd be done, each in its repo, each naming the acceptance criteria it satisfies (`satisfies`). Every criterion should be covered by a task. Ask the room whether the tasks are right; once they are, set `phase` to `ready` and `done` to true, say so, and stop asking.

        Each stage is a loop: ask, look, revise, until the room approves it. Any stage can go back: if you find a gap in an earlier one (a missing requirement while designing, a design flaw while breaking it down), say so, set `phase` back to that stage, fix it with the room and ask them to approve it again, then recheck what came after against it. The room may send you back too.

        The room can interject at any point with a message starting "From the room". Take it into account straight away: it may answer something, change direction, or send you back a stage. Record anything settled as a decision, with the stage it was settled in.

        Keep `\(path)` up to date after every answer and every look at the code, rewriting the whole file as JSON in this shape:

        {"title": "short title", "summary": "a sentence or two", "phase": "context" | "requirements" | "design" | "tasks" | "ready", "requirement": {"problem": "...", "goal": "...", "users": "who it's for", "scope": ["what it must do"], "non_goals": ["..."], "acceptance": [{"id": "R1", "text": "When ..., the system shall ..."}], "open_questions": ["..."]}, "design": {"approach": "Markdown: how it'll be built and why"}, "scouting_now": {"why": "...", "paths": ["owner/name:path"]} or null, "scouting": [{"kind": "area" | "pattern" | "risk", "repo": "owner/name", "path": "path or path#L10-L24", "note": "what's there and why it matters"}], "tasks": [{"title": "...", "body": "Markdown: what to do and how it'll be checked", "repo": "owner/name", "labels": ["..."], "satisfies": ["R1"]}], "decisions": [{"question": "...", "answer": "...", "stage": "requirements" | "design" | "tasks"}], "done": false}

        Don't write the plan, the requirement or any issues, and don't commit them: when the room agrees, Gannin writes them from the state file and tells you.
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
        update(id) { session in
            guard var planning = session.planning else { return }
            let from = planning.state?.step
            planning.state = state
            if from != state.step { planning.moved(from: from ?? .context, to: state.step) }
            session.planning = planning
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


extension PlanningInfo {
    /// Claude moved stage: a round of the stage it's now on, and approvals.
    /// Forward, the stages passed are approved (and no longer to recheck);
    /// back, the stage and those after lose their approval, and those after
    /// that had been worked on are to recheck.
    mutating func moved(from: PlanningStep, to: PlanningStep) {
        var rounds = stageRounds ?? [:]
        if to.isLoop { rounds[to.rawValue, default: 0] += 1 }
        stageRounds = rounds
        var approved = approved ?? [:]
        var recheck = recheck ?? []
        if to.index > from.index {
            for step in PlanningStep.allCases where step.isLoop && step.index >= from.index && step.index < to.index {
                approved[step.rawValue] = .now
                recheck.remove(step.rawValue)
            }
        } else {
            for step in PlanningStep.allCases where step.isLoop && step.index >= to.index {
                approved[step.rawValue] = nil
                if step != to, (rounds[step.rawValue] ?? 0) > 0 { recheck.insert(step.rawValue) }
            }
            recheck.remove(to.rawValue)
        }
        self.approved = approved
        self.recheck = recheck
    }

    func rounds(_ step: PlanningStep) -> Int { stageRounds?[step.rawValue] ?? 0 }
    func isApproved(_ step: PlanningStep) -> Bool { approved?[step.rawValue] != nil && !(recheck ?? []).contains(step.rawValue) }
    func needsRecheck(_ step: PlanningStep) -> Bool { (recheck ?? []).contains(step.rawValue) }
}

/// The stages of planning, as a spec: Context, then Requirements, Design
/// and Tasks, each a loop until the room approves it (and any can send it
/// back to an earlier one), then Agree.
enum PlanningStep: String, CaseIterable, Identifiable {
    case context = "Context"
    case requirements = "Requirements"
    case design = "Design"
    case tasks = "Tasks"
    case agree = "Agree"

    var id: Self { self }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// A stage gone round until the room approves it.
    var isLoop: Bool { [.requirements, .design, .tasks].contains(self) }

    /// As claude's `phase` names it.
    var phase: String { self == .agree ? "ready" : rawValue.lowercased() }

    var systemImage: String {
        switch self {
        case .context: "tray.full"
        case .requirements: "text.badge.checkmark"
        case .design: "square.on.square.squareshape.controlhandles"
        case .tasks: "list.number"
        case .agree: "checkmark.seal"
        }
    }

    /// What happens in the stage, under its title.
    var explanation: String {
        switch self {
        case .context: "What the room gave to read first: documents, links and places to look. The questions build on it."
        case .requirements: "What's needed and why, not how: questions for the room until the problem, scope and acceptance criteria are clear."
        case .design: "How it'll be built: the code it touches, patterns to follow, risks, and the approach the room settles on."
        case .tasks: "The pieces, each a sub-issue when the room agrees, each naming the criteria it satisfies."
        case .agree: "Who was here, the issues to make and the plan to write, confirmed before anything's written."
        }
    }

    /// What approving it says.
    var approval: String {
        switch self {
        case .requirements: "Requirements Are Right"
        case .design: "Design Is Right"
        case .tasks: "Tasks Are Right"
        default: "Approve"
        }
    }

    var next: PlanningStep? { Self.allCases.first { $0.index == index + 1 } }
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
    /// A stage the room is going back to, and why.
    @State private var backTo: PlanningStep?
    @State private var backReason = ""

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
        planning?.agreed != nil ? .agree : state?.step ?? (planning?.hasContext == true ? .context : .requirements)
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
        .alert("Back to \(backTo?.rawValue ?? "")", isPresented: Binding(get: { backTo != nil }, set: { if !$0 { backTo = nil } })) {
            TextField("Why", text: $backReason, prompt: Text("What's missing or wrong"))
            Button("Go Back", action: goBack)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's reopened to fix with the room and approve again, and what came after is marked to recheck.")
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
        HStack(alignment: .top, spacing: 10) {
            ForEach(PlanningStep.allCases) { step in
                if step != .context {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                stepChip(step)
            }
        }
    }

    private func isDone(_ step: PlanningStep) -> Bool {
        guard let planning else { return false }
        if planning.agreed != nil { return true }
        switch step {
        case .context: return current.index > 0
        case .agree: return false
        default: return planning.isApproved(step)
        }
    }

    private func stepChip(_ step: PlanningStep) -> some View {
        let isCurrent = step == current
        let done = isDone(step)
        let recheck = planning?.needsRecheck(step) ?? false
        let rounds = planning?.rounds(step) ?? 0
        return Button {
            viewing = step == current ? nil : step
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            // Finished looks finished, even on the stage shown.
                            .fill(done ? ChartPalette.good.opacity(0.2) : isCurrent ? Color.accentColor : recheck ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15))
                        if done {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(ChartPalette.good)
                        } else {
                            Image(systemName: recheck && !isCurrent ? "exclamationmark" : step.systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isCurrent ? .white : recheck ? .orange : .secondary)
                                .symbolEffect(.pulse, options: .repeating, isActive: isCurrent && busy)
                        }
                    }
                    .frame(width: 24, height: 24)
                    Text(label(step))
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(isCurrent || done ? .primary : .secondary)
                }
                // How many times round, and whether it needs looking at again.
                Group {
                    if recheck {
                        Text("Recheck").foregroundStyle(.orange)
                    } else if step.isLoop, rounds > 0 {
                        Text("Round \(rounds)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption2)
                // Under the name: past the 24pt circle and its 6pt gap.
                .padding(.leading, 30)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(recheck ? "Changed since: an earlier stage was reopened, so this needs approving again" : isCurrent ? "Under way: \(step.explanation)" : "Look at \(step.rawValue)")
        .accessibilityLabel("\(label(step))\(isCurrent && !done ? ", under way" : done ? ", done" : recheck ? ", to recheck" : "")\(rounds > 1 ? ", round \(rounds)" : "")")
    }

    /// The step's name; the last says Agreed once it is.
    private func label(_ step: PlanningStep) -> String {
        step == .agree && planning?.agreed != nil ? "Agreed" : step.rawValue
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
                    Text("Look over the requirements, design and tasks, then Agree when the room's ready.")
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
            case .requirements: requirementsStep
            case .design: designStep
            case .tasks: tasksStep
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
    private var requirementsStep: some View {
        Label("The requirements are on the right, with their acceptance criteria.", systemImage: "arrow.right")
            .foregroundStyle(.secondary)
        stageActions(.requirements) {
            Button("Look at the Code") { say("Look at the code for what we've covered so far, then carry on asking.") }
                .help("Only when a question depends on it; the design stage is where the code is looked at properly")
        }
        stageDecisions(.requirements)
    }

    @ViewBuilder
    private var designStep: some View {
        if let approach = state?.design.approach {
            sectionTitle("Approach")
            MarkdownText(source: approach, reflows: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.separatorLine) }
        } else {
            empty("The approach is proposed once the code's been looked at.")
        }
        stageActions(.design) {
            Button("Look at the Code") { say("Look at the code again for the design: what else does it touch, and what should it follow?") }
        }
        let findings = state?.scouting ?? []
        if !findings.isEmpty {
            sectionTitle("In the code")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(findings) { finding in
                    findingRow(finding)
                }
            }
        }
        stageDecisions(.design)
    }

    @ViewBuilder
    private var tasksStep: some View {
        let tasks = state?.tasks ?? []
        if tasks.isEmpty {
            empty("The tasks are proposed once the design is approved.")
        } else {
            coverage
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    taskRow(index + 1, task)
                }
            }
        }
        stageActions(.tasks) {
            Button("Agree") { agreeing = true }
                .disabled(state == nil || planning?.agreed != nil)
        }
        stageDecisions(.tasks)
    }

    /// Whether every acceptance criterion has a task satisfying it.
    @ViewBuilder
    private var coverage: some View {
        if let state, !state.requirement.acceptance.isEmpty {
            let uncovered = state.uncovered
            if uncovered.isEmpty {
                Label("Every acceptance criterion is covered by a task.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ChartPalette.good)
            } else {
                Label("Not covered by any task: \(uncovered.map(\.id).joined(separator: ", ")).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(uncovered.map { "\($0.id): \($0.text)" }.joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private var agreeStep: some View {
        if let state, let planning {
            let findings = state.scouting.filter { !(planning.dismissed ?? []).contains($0.id) }.count
            Text("\(count(state.requirement.acceptance.count, "acceptance criterion", plural: "acceptance criteria")), \(count(findings, "finding")), \(count(state.tasks.count, "task")) and \(count(state.decisions.count, "decision")).")
                .foregroundStyle(.secondary)
            let unapproved = PlanningStep.allCases.filter { $0.isLoop && !planning.isApproved($0) }
            if planning.agreed == nil, !unapproved.isEmpty {
                Label("Not approved yet: \(unapproved.map(\.rawValue).joined(separator: ", ")).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            coverage
        }
        if planning?.agreed == nil {
            actions {
                Button("Agree") { agreeing = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(state == nil)
            }
        }
        ForEach([PlanningStep.requirements, .design, .tasks]) { step in
            stageDecisions(step, title: "\(step.rawValue) decisions", limit: nil)
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

    /// A stage's own buttons, then Back to each stage before it (with a
    /// reason) and its approval.
    private func stageActions(_ step: PlanningStep, @ViewBuilder extra: () -> some View) -> some View {
        actions {
            extra()
            ForEach(PlanningStep.allCases.filter { $0.isLoop && $0.index < step.index }) { earlier in
                Button("Back to \(earlier.rawValue)") {
                    backReason = ""
                    backTo = earlier
                }
                .help("Reopen \(earlier.rawValue.lowercased()), saying why; what came after is marked to recheck")
            }
            if step.isLoop {
                Button(step.approval) {
                    let next = step.next.map { $0 == .agree ? "We're ready to agree." : "Move on to \($0.rawValue.lowercased())." } ?? ""
                    say("The \(step.rawValue.lowercased()) are right. \(next)")
                }
                .buttonStyle(.borderedProminent)
                .disabled(step != current)
                .help(step == current ? "The room approves it" : "Approve it when it's the stage under way")
            }
        }
    }

    @ViewBuilder
    private func stageDecisions(_ step: PlanningStep, title: String = "Decisions", limit: Int? = 6) -> some View {
        let decisions = state?.decisions(in: step) ?? []
        if !decisions.isEmpty {
            sectionTitle(title)
            decisionList(limit.map { Array(decisions.suffix($0)) } ?? decisions)
        }
    }

    private func goBack() {
        guard let step = backTo else { return }
        let reason = backReason.trimmingCharacters(in: .whitespacesAndNewlines)
        say("Back to \(step.rawValue.lowercased())\(reason.isEmpty ? "" : ": \(reason)"). Set `phase` to `\(step.phase)`, fix it with us and ask us to approve it again, then recheck what came after against it.")
        backTo = nil
        viewing = nil
    }

    private func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(plural ?? noun + "s")"
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
                criteria(requirement.acceptance)
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

    /// Acceptance criteria with their ids, for the tasks to name.
    private func criteria(_ criteria: [PlanningState.Criterion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Acceptance criteria")
            if criteria.isEmpty {
                Text("Not settled yet").foregroundStyle(.tertiary)
            }
            ForEach(criteria) { criterion in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(criterion.id)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, alignment: .leading)
                    Text(criterion.text)
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
            // One width for every kind, so the paths and notes line up.
            Text(finding.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .frame(minWidth: 64)
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

    private func taskRow(_ number: Int, _ task: PlanningState.PlanTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.title).fontWeight(.semibold)
                    Spacer()
                    if let repo = task.repo {
                        Text(repo).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let body = task.body, !body.isEmpty {
                    MarkdownText(source: body)
                        .foregroundStyle(.secondary)
                }
                if !task.satisfies.isEmpty {
                    HStack(spacing: 6) {
                        Text("Satisfies").font(.caption).foregroundStyle(.secondary)
                        ForEach(task.satisfies, id: \.self) { id in
                            Text(id)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .help(state?.requirement.acceptance.first { $0.id.uppercased() == id.uppercased() }?.text ?? id)
                        }
                    }
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
