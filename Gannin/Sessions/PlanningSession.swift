import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A planning session's topic and the documents shared into it.
struct PlanningInfo: Codable, Hashable {
    struct Document: Codable, Hashable, Identifiable {
        var id = UUID()
        let name: String
        /// May go into the harness with the plan; else never committed.
        let commit: Bool
        let sharedAt: Date
    }

    let topic: String
    /// The harness document it starts from, by path.
    let documentPath: String?
    var documents: [Document] = []
    /// Short, for the session's folder and the plan's assets.
    let slug: String
    /// The issue it plans, when it was started from one (Plan This).
    var issue: IssueReference? = nil
    /// What claude keeps in the workspace's state file, as last read, so
    /// the workspace shows it with claude stopped.
    var state: PlanningState? = nil
    /// Scouting findings put aside in the room, by `PlanningState.Finding.id`.
    var dismissed: Set<String>? = nil
    /// Once the room agreed: when, who, and what was written.
    var agreed: PlanningAgreement? = nil
    /// Times round each stage (requirements, design, tasks), counted as
    /// Gannin sees claude move to it; when each was approved (claude moved
    /// past it); and those reopened since, to approve again.
    var stageRounds: [String: Int]? = nil
    var approved: [String: Date]? = nil
    var recheck: Set<String>? = nil
    /// What the room said along the way, sent to claude as it was said.
    var comments: [PlanningComment]? = nil
    /// Context given to read before the first question, besides the
    /// documents: links (Notion, Google Docs, tickets) and where else to
    /// look with claude's connected tools.
    var links: [PlanningLink]? = nil
    var sources: String? = nil

    /// Anything given to read first.
    var hasContext: Bool { !documents.isEmpty || !(links ?? []).isEmpty || !(sources ?? "").isEmpty }
}

/// A link given as context, with what it is.
struct PlanningLink: Codable, Hashable, Identifiable {
    var id = UUID()
    let url: URL
    var note: String?

    /// What's typed in a context box: the web links in it, each with the
    /// rest of the text as its note; with no link, the text alone, as
    /// somewhere else to look.
    static func parse(_ text: String) -> (links: [PlanningLink], note: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], nil) }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = (detector?.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) ?? [])
            .filter { $0.url?.scheme?.hasPrefix("http") == true }
        var rest = trimmed as NSString
        for match in matches.reversed() { rest = rest.replacingCharacters(in: match.range, with: "") as NSString }
        let note = (rest as String).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " :-,;"))
        let kept = note.isEmpty ? nil : note
        guard !matches.isEmpty else { return ([], kept) }
        return (matches.compactMap(\.url).map { PlanningLink(url: $0, note: kept) }, nil)
    }
}

/// Something the room said in the middle of planning, and on which step.
struct PlanningComment: Codable, Hashable, Identifiable {
    var id = UUID()
    let text: String
    let step: String
    let at: Date
}

extension CodeSession {
    var isPlanning: Bool { planning != nil }
}

extension SessionStore {
    /// A Claude Code session to write a plan with you, in the org's harness,
    /// about a topic or starting from one of its documents.
    /// `choice` is what was picked from the team's prompts and skills; nil
    /// takes the defaults for planning.
    /// `guidance` is the org's planning prompt (`HarnessAuthoring`), its
    /// placeholders still to fill.
    func startPlanning(org: String, topic: String, documentPath: String?, issue: IssueReference? = nil, harness setup: HarnessConfig, harnessPath: String, guidance: String, choice: PromptChoice? = nil,
                       documents: [PlanningInfo.Document] = [], links: [PlanningLink] = [], sources: String? = nil) -> CodeSession {
        let slug = Self.slug(topic)
        let branch = "plan-\(slug)"
        var info = PlanningInfo(topic: topic, documentPath: documentPath, slug: slug, issue: issue)
        info.documents = documents
        info.links = links.isEmpty ? nil : links
        info.sources = sources.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let url = URL(string: "https://github.com/\(setup.repo)")!
        let instructions = launchInstructions(org: org, setup: setup, use: .planning, repos: [], choice: choice, values: Self.planningValues(topic: topic, harness: setup.repo, branch: branch))
        let session = CodeSession(
            id: UUID(), issue: IssueReference(org: org, id: "plan-\(UUID().uuidString)", number: 0, title: topic, repo: setup.repo, url: url),
            repo: setup.repo, branch: branch, createdAt: .now,
            connect: Self.connectCommand, harnessRepo: setup.repo, harnessPath: harnessPath,
            role: "Plan", prompt: Self.planningPrompt(info, branch: branch, guidance: guidance), instructions: instructions, planning: info
        )
        let directory = Self.directory(for: session.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let brief = "# Planning: \(topic)\n\n" + (documentPath.map { "Starting from `\($0)` in the harness.\n" } ?? "")
            + (issue.map { "Planning \($0.reference): \($0.title)\n" } ?? "")
        try? Data(brief.utf8).write(to: directory.appending(path: "brief.md"))
        add(session)
        reveal(session.id)
        return session
    }

    /// The placeholders for a planning prompt: the topic is its title.
    static func planningValues(topic: String, harness: String, branch: String) -> [String: String] {
        ["title": topic, "topic": topic, "repo": harness, "branch": branch]
    }

    static func planningPrompt(_ info: PlanningInfo, branch: String, guidance: String) -> String {
        var start: [String] = []
        if let path = info.documentPath { start.append("Then read \(path), which we're starting from.") }
        if let issue = info.issue {
            start.append("We're planning \(issue.reference): read it first with `gh issue view \(issue.number) --repo \(issue.repo) --comments`.")
        }
        let filled = HarnessAuthoring.fill(guidance, [
            "topic": info.topic,
            "plan": "plans/\(HarnessAuthoring.today)-\(info.slug).md",
            "docs": ".worktrees/\(branch)/docs/",
            "assets": "plans/assets/\(info.slug)/",
            "starting_point": start.joined(separator: " "),
        ])
        return [filled, PlanningState.instructions(path: statePath(branch: branch)), contextBrief(info, branch: branch)]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    /// What the room gave to read before the first question, and what to
    /// do with it; nil when it gave nothing.
    static func contextBrief(_ info: PlanningInfo, branch: String) -> String? {
        guard info.hasContext else { return nil }
        var parts = ["Before your first question, set `phase` to `context` and read what the room has given you:"]
        if !info.documents.isEmpty {
            var line = "- Documents in `.worktrees/\(branch)/docs/`: \(info.documents.map(\.name).joined(separator: ", ")). Word and RTF ones have a .txt copy beside them to read."
            let committed = info.documents.filter(\.commit).map(\.name)
            let kept = info.documents.filter { !$0.commit }.map(\.name)
            if !committed.isEmpty { line += " These may be committed with the plan, in `plans/assets/\(info.slug)/`: \(committed.joined(separator: ", "))." }
            if !kept.isEmpty { line += " These must not be committed or quoted at length: \(kept.joined(separator: ", "))." }
            parts.append(line)
        }
        if let links = info.links, !links.isEmpty {
            parts.append("- Links, to read with your connected tools (Notion, Google Drive, issue trackers and the like) or by fetching them:\n"
                + links.map { "  - \($0.url.absoluteString)\($0.note.map { ": \($0)" } ?? "")" }.joined(separator: "\n"))
        }
        if let sources = info.sources {
            parts.append("- Where else to look, searching with your connected tools: \(sources)")
        }
        parts.append("If you can't reach something, say so straight away rather than guessing. Then tell the room in a few lines what you learned and what it leaves open, and base your questions on it: don't ask what it already answers.")
        return parts.joined(separator: "\n")
    }

    /// Where claude keeps the workspace's state, from the harness root.
    static func statePath(branch: String) -> String { ".worktrees/\(branch)/planning.json" }

    static func slug(_ text: String) -> String {
        let words = String(text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ")
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : "\(slug)-\(word)"
            if next.count > 40 { break }
            slug = next
        }
        return slug.isEmpty ? "plan" : slug
    }

    /// Copies the documents into the session's `docs/` on its box (Word and
    /// RTF ones with a plain-text copy beside them), records them, and tells
    /// claude which may be committed.
    func share(_ files: [(url: URL, commit: Bool)], with id: UUID) async throws {
        guard let session = sessions[id], var planning = session.planning else { return }
        let (shared, converted) = try await Self.copyDocuments(files, to: Self.worktreePath(for: session) + "/docs", connect: session.connect)
        guard !shared.isEmpty else { return }
        planning.documents += shared
        update(id) { $0.planning = planning }

        let committed = shared.filter(\.commit).map(\.name)
        let kept = shared.filter { !$0.commit }.map(\.name)
        var message = "I've shared \(shared.count == 1 ? "a document" : "\(shared.count) documents") in .worktrees/\(session.branch)/docs/: \(shared.map(\.name).joined(separator: ", "))."
        if converted {
            message += " Word and RTF ones have a .txt copy beside them to read."
        }
        if !committed.isEmpty { message += " These may be committed with the plan, in plans/assets/\(planning.slug)/: \(committed.joined(separator: ", "))." }
        if !kept.isEmpty { message += " These must not be committed or quoted at length: \(kept.joined(separator: ", "))." }
        message += " Read them and tell me what they change."
        submit(message, to: id)
    }

    /// Copies documents into a folder on the box a session runs on (this
    /// Mac, or over `connect`'s ssh), with a plain-text copy beside Word and
    /// RTF ones. Before a session starts too: its folder is known.
    static func copyDocuments(_ files: [(url: URL, commit: Bool)], to path: String, connect: String?) async throws -> (documents: [PlanningInfo.Document], converted: Bool) {
        let folder = SessionScript.shellPath(path)
        var script = ["set -e", "mkdir -p \(folder)", "cd \(folder)"]
        var shared: [PlanningInfo.Document] = []
        var converted = false
        for file in files {
            guard let data = try? Data(contentsOf: file.url) else { continue }
            let name = file.url.lastPathComponent
            script.append("printf %s \(data.base64EncodedString()) | base64 -d > \(SessionScript.quoted(name))")
            if let text = plainText(file.url) {
                converted = true
                script.append("printf %s \(Data(text.utf8).base64EncodedString()) | base64 -d > \(SessionScript.quoted(name + ".txt"))")
            }
            shared.append(.init(name: name, commit: file.commit, sharedAt: .now))
        }
        guard !shared.isEmpty else { return ([], false) }
        let place: ClaudeRunner.Place
        if let connect {
            guard let arguments = Shell.sshArguments(connect) else { throw SessionError.message("The server isn't reached with ssh, so documents can't be copied to it.") }
            place = .remote(arguments)
        } else {
            place = .local
        }
        let body = script.joined(separator: "\n") + "\n"
        let result = await Task.detached { ClaudeRunner.run(body, place: place) }.value
        guard result.status == 0 else { throw SessionError.message(result.error.isEmpty ? "Couldn't copy the documents." : result.error) }
        return (shared, converted)
    }

    /// A Word, RTF or ODT document as text, through macOS's textutil.
    private static func plainText(_ url: URL) -> String? {
        guard ["docx", "doc", "rtf", "rtfd", "odt", "wordml"].contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// A new plan being set up in its own tab: what it starts from.
struct PlanningDraft: Hashable {
    let org: String
    var documentPath: String? = nil
    var topic = ""
    var issue: IssueReference? = nil
    /// The harness to plan in, when it was picked first (a Harness page).
    var harnessRepo: String? = nil
    /// A New Ask rather than a plan (`NewAskView`).
    var isAsk = false
}

extension SessionStore {
    /// Opens a new plan as a tab in the Claude Code window.
    func showNewPlan(_ draft: PlanningDraft, with openWindow: OpenWindowAction) {
        openDraft(draft)
        openWindow(id: Self.windowID)
    }
}

/// Starts a planning session: a topic, optionally the harness document or
/// issue it starts from, and how it's run: a prompt to edit, started from
/// one of the team's (a shortcut that fills the text), the suggested one,
/// or blank, and saved to the harness as new or as an update when asked.
struct NewPlanningView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    /// The draft's tab, which the session takes over.
    let draftID: UUID
    let draft: PlanningDraft
    @Environment(OrgStore.self) private var orgs
    /// The org picked in the Project menu; nil for the draft's.
    @State private var pickedOrg: String?
    private var org: String { pickedOrg ?? draft.org }
    private var documentPath: String? { draft.documentPath }
    private var topic: String { draft.topic }
    private var issue: IssueReference? { draft.issue }
    @State private var text = ""
    /// The harness picked, by repo; nil for the document's, else the primary.
    @State private var picked: String?
    /// What the prompt started from: a team prompt's path, or one of these.
    @State private var startFrom = Self.suggested
    @State private var prompt = ""
    @State private var promptTitle = ""
    @State private var savesPrompt = true
    @State private var skills: Set<String> = []
    @State private var skillSearch = ""
    @State private var saving = false
    @State private var error: String?
    /// Context to read before the first question.
    @State private var contextFiles: [ContextFile] = []
    @State private var links: [PlanningLink] = []
    @State private var contextText = ""
    /// Places to look that aren't links.
    @State private var notes: [String] = []

    struct ContextFile: Identifiable {
        let url: URL
        /// May go into the harness with the plan; else never committed.
        var commit = false
        var id: URL { url }
    }

    private static let suggested = "suggested"
    private static let blank = "blank"

    /// Offered when the harness has no planning prompt, to edit and keep.
    static let suggestedPrompt = """
        Run this like a good refinement session for {{title}}.

        - Start from the problem, not the solution: who has it, how often, and what it costs them today.
        - Push on scope: suggest the smallest version worth shipping, and name what's deliberately left out.
        - Before proposing an approach, look at how similar things are already done in the code, and follow those patterns.
        - Call out risks, dependencies, and anything that needs someone who isn't in the room.
        - Keep each task small enough to review in one sitting, and say how it'll be checked.
        """

    /// A document from a combined index names its harness.
    private var source: (repo: String?, path: String)? { documentPath.map(HarnessIndex.split) }

    var body: some View {
        let config = configs.config(for: org)
        // Every project: this window belongs to none.
        let projects = config.repoProjects
        let harnesses = projects.isEmpty ? config.harnesses : config.allHarnesses
        let setup = (picked ?? draft.harnessRepo ?? source?.repo).flatMap(config.harness(repo:)) ?? harnesses.first
        let library = setup.map { sessions.promptLibrary(org: org, setup: $0) } ?? HarnessPromptLibrary(index: nil)
        VStack(spacing: 0) {
        ScrollView {
        Form {
            Section {
                // Always asked, every org's projects: opened from the window's
                // +, it has neither.
                Picker("Project", selection: Binding(get: { "\(org)\u{1F}\(setup?.repo ?? "")" }, set: { choice in
                    let parts = choice.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return }
                    pickedOrg = parts[0]
                    picked = parts[1]
                    let config = configs.config(for: parts[0])
                    let library = config.harness(repo: parts[1]).map { sessions.promptLibrary(org: parts[0], setup: $0) } ?? HarnessPromptLibrary(index: nil)
                    startWith(library)
                })) {
                    ForEach(projectOrgs, id: \.self) { login in
                        Section(orgName(login)) {
                            ForEach(projectChoices(login), id: \.repo) { choice in
                                Text(choice.name).tag("\(login)\u{1F}\(choice.repo)")
                            }
                        }
                    }
                }
                TextField("What are we planning?", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                if let source {
                    LabeledContent("Starting from", value: source.path)
                }
                if let issue {
                    LabeledContent("Planning", value: issue.reference)
                }
            } header: {
                // In the form, so it lines up with what's beneath.
                Label("New Plan", systemImage: "list.bullet")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
            } footer: {
                Text(setup == nil
                     ? "Planning runs in a project's harness. Add one in the org's Settings, under Projects."
                     : "The room builds a spec in stages: requirements, then the design (with the code looked at), then tasks, each approved before the next and any reopened when a gap turns up. When the room agrees, Gannin writes the plan in \(setup!.repo) and makes the issues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            contextSection
            promptSection(library: library, setup: setup)
            skillsSection(library)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        }
        Divider()
        // Always in view, at the foot of the tab.
        HStack(spacing: 12) {
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { sessions.closeTab(draftID) }
                .keyboardShortcut(.cancelAction)
            Button(saving ? "Starting" : "Start Planning") {
                guard let setup else { return }
                Task { await start(setup: setup, harnesses: harnesses, library: library) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || SessionStore.unavailable(org: org, harness: setup) != nil
                      || (save(library) == .new && promptTitle.trimmingCharacters(in: .whitespaces).isEmpty))
            .help(SessionStore.unavailable(org: org, harness: setup) ?? "Start (⌘↩)")
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return urls.contains(where: \.isFileURL)
        }
        .onAppear {
            text = topic.isEmpty ? issue?.title ?? "" : topic
            startWith(library)
        }
        // The harness's prompts, if they weren't loaded yet; once they are,
        // its default is picked unless the prompt's been changed.
        .task(id: setup?.repo) {
            if let setup { await harness.load(org: org, setup: setup) }
        }
        .onChange(of: library.offered(for: .planning).map(\.path)) {
            if startFrom == Self.suggested && trimmedPrompt == Self.suggestedPrompt.trimmingCharacters(in: .whitespacesAndNewlines) { startWith(library) }
        }
    }

    // MARK: Projects

    /// Orgs with a project to plan in, the draft's first.
    private var projectOrgs: [String] {
        let logins = orgs.orgs.map(\.login).filter { !projectChoices($0).isEmpty }
        return [draft.org].filter(logins.contains) + logins.filter { $0 != draft.org }
    }

    /// An org's projects by name, or its harnesses by repo with none named.
    private func projectChoices(_ login: String) -> [(name: String, repo: String)] {
        let config = configs.config(for: login)
        if !config.repoProjects.isEmpty {
            return config.repoProjects.map { ($0.name, $0.harness.repo) }
        }
        return config.harnesses.map { ($0.repo, $0.repo) }
    }

    private func orgName(_ login: String) -> String {
        orgs.orgs.first { $0.login == login }.flatMap { $0.name?.isEmpty == false ? $0.name : nil } ?? login
    }

    // MARK: Context

    private var contextSection: some View {
        Section {
            ForEach($contextFiles) { $file in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(file.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Toggle("Commit with the plan", isOn: $file.commit)
                        .checkboxToggle()
                        .help("May go into the harness with the plan, in its assets; else it's never committed or quoted at length")
                    removeButton("Remove \(file.url.lastPathComponent)") { contextFiles.removeAll { $0.id == file.id } }
                }
            }
            ForEach(links) { link in
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.url.absoluteString).lineLimit(1).truncationMode(.middle)
                        if let note = link.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    removeButton("Remove the link") { links.removeAll { $0.id == link.id } }
                }
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                HStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    removeButton("Remove it") { notes.remove(at: index) }
                }
            }
            TextField("Context", text: $contextText, prompt: Text("Paste a link and say what it is, or say where else to look"), axis: .vertical)
                .labelsHidden()
                .lineLimit(3...8)
            HStack(spacing: 10) {
                Button("Add Context", action: addContext)
                    .disabled(contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Add Documents") { chooseFiles() }
                    .help("Pick one or more")
                Text("or drop them anywhere here")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Context")
        } footer: {
            Text("Read before the first question, so the questions build on it rather than ask what it answers. Documents (add them or drop them anywhere here) are copied into the session's folder and can hold sensitive details, so share only what may be read; only those ticked are committed. Links and other places are read with the tools Claude Code has connected, such as Notion, or fetched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func addFiles(_ urls: [URL]) {
        let known = Set(contextFiles.map(\.url))
        contextFiles += urls.filter { $0.isFileURL && !known.contains($0) }.map { ContextFile(url: $0) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Documents to read before the first question."
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    private func addContext() {
        let parsed = PlanningLink.parse(contextText)
        links += parsed.links
        if let note = parsed.note { notes.append(note) }
        contextText = ""
    }

    // MARK: Prompt

    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The team's prompt the text came from, if it did.
    private func basis(_ library: HarnessPromptLibrary) -> HarnessPrompt? {
        library.offered(for: .planning).first { $0.path == startFrom }
    }

    private enum Save: Equatable { case none, new, update(HarnessPrompt) }

    private func unchanged(_ basis: HarnessPrompt) -> Bool {
        basis.body.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedPrompt
    }

    /// What saving would do: nothing (unticked, empty, or a team prompt
    /// left as it was), an update to the team prompt it started from, or a
    /// new one.
    private func save(_ library: HarnessPromptLibrary) -> Save {
        guard savesPrompt, !trimmedPrompt.isEmpty else { return .none }
        if let basis = basis(library) {
            return unchanged(basis) ? .none : .update(basis)
        }
        return .new
    }

    /// The default team prompt to start from, else the suggested one.
    private func startWith(_ library: HarnessPromptLibrary) {
        let offered = library.offered(for: .planning)
        if let first = offered.first(where: \.isDefault) ?? offered.first {
            use(first.path, library: library)
        } else {
            use(Self.suggested, library: library)
        }
    }

    /// Fills the text from what's picked, with the skills a team prompt brings.
    private func use(_ choice: String, library: HarnessPromptLibrary) {
        startFrom = choice
        if let basis = library.offered(for: .planning).first(where: { $0.path == choice }) {
            prompt = basis.body
            promptTitle = basis.title
            skills = Set(basis.skills.compactMap { library.skill(named: $0)?.path })
        } else if choice == Self.suggested {
            prompt = Self.suggestedPrompt
            promptTitle = "Planning facilitator"
        } else {
            prompt = ""
            promptTitle = ""
        }
    }

    @ViewBuilder
    private func promptSection(library: HarnessPromptLibrary, setup: HarnessConfig?) -> some View {
        let offered = library.offered(for: .planning)
        let saving = save(library)
        Section {
            Picker("Start from", selection: Binding(get: { startFrom }, set: { use($0, library: library) })) {
                ForEach(offered) { prompt in
                    Text(prompt.title).tag(prompt.path)
                }
                if !offered.isEmpty { Divider() }
                Text("Suggested").tag(Self.suggested)
                Text("Blank").tag(Self.blank)
            }
            TextEditor(text: $prompt)
                .font(.body.monospaced())
                .frame(minHeight: 150)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("How should this session be run?")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            if let basis = basis(library), unchanged(basis) {
                Text("The team's \(basis.title), as saved. Edit it for this session; you can save the change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !trimmedPrompt.isEmpty {
                Toggle(basis(library).map { "Update \($0.title) in the harness" } ?? "Save it to the harness", isOn: $savesPrompt)
                    .checkboxToggle()
                if savesPrompt, basis(library) == nil {
                    TextField("Name", text: $promptTitle, prompt: Text("Planning facilitator"))
                }
            }
        } header: {
            Text("Prompt")
        } footer: {
            Text(footer(saving, first: offered.isEmpty, setup: setup))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(_ saving: Save, first: Bool, setup: HarnessConfig?) -> String {
        let intro = first ? "The harness has no planning prompt yet, so here's one to start from. " : "The team's prompts fill this in; what's here is what the session is told. "
        let repo = setup?.repo ?? "the harness"
        switch saving {
        case .none: return intro + "{{title}} is the topic."
        case .update(let basis): return intro + "Your change is committed to \(basis.path) in \(repo) when the session starts."
        case .new: return intro + "Committed to \(repo) as \(newPath) when the session starts, offered for planning\(first ? " and ticked by default" : "")."
        }
    }

    /// A summary for a prompt saved from here, which the harness needs to
    /// list it: the first sentence of its first line, less any list marker.
    static func summary(of prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "How we run planning sessions"
        let plain = String(line.drop { "-*#> ".contains($0) })
        guard let end = plain.range(of: ". ") else { return plain }
        return String(plain[..<end.lowerBound]) + "."
    }

    private var newPath: String {
        "\(HarnessPrompt.folder)/\(HarnessPrompt.fileName(for: promptTitle.isEmpty ? "planning" : promptTitle)).md"
    }

    // MARK: Skills

    @ViewBuilder
    private func skillsSection(_ library: HarnessPromptLibrary) -> some View {
        if !library.skills.isEmpty {
            Section("Skills") {
                if library.skills.count > 8 {
                    TextField("Search skills", text: $skillSearch)
                }
                let query = skillSearch.trimmingCharacters(in: .whitespaces)
                ForEach(library.skills.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.summary ?? "").localizedCaseInsensitiveContains(query) || skills.contains($0.path) }) { skill in
                    Toggle(isOn: Binding(
                        get: { skills.contains(skill.path) },
                        set: { on in if on { skills.insert(skill.path) } else { skills.remove(skill.path) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                            if let summary = skill.summary {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .checkboxToggle()
                    .help(skill.path)
                }
            }
        }
    }

    // MARK: Starting

    /// Saves the prompt first when asked (a session isn't started on a
    /// failed save), then starts the session told what's in the editor.
    private func start(setup: HarnessConfig, harnesses: [HarnessConfig], library: HarnessPromptLibrary) async {
        guard let path = SessionStore.harnessPath(org: org, repo: setup.repo) else { return }
        error = nil
        let topic = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = SessionStore.planningValues(topic: topic, harness: setup.repo, branch: "plan-\(SessionStore.slug(topic))")
        let skillNames = library.skills.filter { skills.contains($0.path) }.map(\.name)
        var change: HarnessChange?
        switch save(library) {
        case .none:
            break
        case .update(let basis):
            let updated = HarnessPrompt(path: basis.path, title: basis.title, summary: basis.summary ?? Self.summary(of: trimmedPrompt), uses: basis.uses, isDefault: basis.isDefault,
                                        repos: basis.repos, skills: basis.skills, body: trimmedPrompt, otherFields: basis.otherFields)
            change = HarnessChange(message: "Gannin: update the \(basis.title) prompt", files: [basis.path: updated.fileText])
        case .new:
            let file = newPath
            if harness.index(for: org, setup)?.document(at: file) != nil {
                error = "There's already a \(file) in the harness. Give the prompt another name."
                return
            }
            let made = HarnessPrompt(path: file, title: promptTitle.trimmingCharacters(in: .whitespaces), summary: Self.summary(of: trimmedPrompt), uses: [.planning],
                                     isDefault: library.offered(for: .planning).isEmpty, repos: [], skills: skillNames, body: trimmedPrompt)
            change = HarnessChange(message: "Gannin: add the \(made.title) prompt", files: [file: made.fileText])
        }
        if let change {
            saving = true
            defer { saving = false }
            do {
                try await harness.commit(org: org, setup: setup) { _ in change }
            } catch {
                self.error = "Couldn't save the prompt: \(error.localizedDescription) Untick saving to start without it."
                return
            }
        }
        let choice = PromptChoice(prompts: [], skills: skills, note: trimmedPrompt.isEmpty ? "" : HarnessAuthoring.fill(trimmedPrompt, values))
        // A link typed but not added yet is meant too.
        addContext()
        var documents: [PlanningInfo.Document] = []
        if !contextFiles.isEmpty {
            saving = true
            defer { saving = false }
            do {
                documents = try await SessionStore.copyDocuments(
                    contextFiles.map { ($0.url, $0.commit) },
                    to: "\(path)/.worktrees/plan-\(SessionStore.slug(topic))/docs", connect: SessionStore.connectCommand
                ).documents
            } catch {
                self.error = "Couldn't copy the documents: \(error.localizedDescription)"
                return
            }
        }
        // The document's own path, when it's in the harness picked.
        let start = source.flatMap { ($0.repo ?? harnesses.first?.repo) == setup.repo ? $0.path : nil }
        let session = sessions.startPlanning(org: org, topic: topic, documentPath: start, issue: issue, harness: setup, harnessPath: path,
                                              guidance: HarnessAuthoring.guidance(for: .plans, config: configs.config(for: org), org: org), choice: choice,
                                              documents: documents, links: links, sources: notes.joined(separator: "\n"))
        sessions.replaceDraft(draftID, with: session.id)
    }
}

/// Each document confirmed before claude sees it: what it is, a warning
/// that it may hold sensitive details, and whether it may be committed with
/// the plan. Nothing's shared until Share.
struct ShareDocumentsSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let session: CodeSession
    let files: [URL]
    @State private var shared: Set<URL> = []
    @State private var committed: Set<URL> = []
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share with Claude?").font(.title3.weight(.semibold))
            Label {
                Text("Documents can hold customer details, contracts or other sensitive information. Tick each one Claude may read. Claude runs as you\(session.isRemote ? " on your server" : " on this Mac"), and the files are copied into the session's folder, which isn't committed. Only those marked Commit go into the harness, with the plan.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            ForEach(files, id: \.self) { file in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(size(file)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Share", isOn: Binding(get: { shared.contains(file) }, set: { on in
                        if on { shared.insert(file) } else { shared.remove(file); committed.remove(file) }
                    }))
                    .checkboxToggle()
                    Toggle("Commit with the plan", isOn: Binding(get: { committed.contains(file) }, set: { on in
                        if on { committed.insert(file) } else { committed.remove(file) }
                    }))
                    .checkboxToggle()
                    .disabled(!shared.contains(file))
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Sharing" : "Share \(shared.count)") {
                    working = true
                    let chosen = files.filter(shared.contains).map { ($0, committed.contains($0)) }
                    Task {
                        do {
                            try await sessions.share(chosen, with: session.id)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(shared.isEmpty || working || !sessions.isRunning(session.id))
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// In a planning session's panel: what's planned, the documents shared
/// (and whether each may be committed), and Share Documents.
struct PlanningSection: View {
    let session: CodeSession
    @State private var picking: [URL]?

    var body: some View {
        if let planning = session.planning {
            Section("Planning") {
                Text(planning.topic).fontWeight(.semibold)
                if let path = planning.documentPath {
                    LabeledContent("Starting from", value: path)
                }
                ForEach(planning.documents) { document in
                    HStack {
                        Image(systemName: "doc")
                        Text(document.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(document.commit ? "Committed with the plan" : "Not committed")
                            .font(.caption)
                            .foregroundStyle(document.commit ? .orange : .secondary)
                    }
                }
                Button("Share Documents") { choose() }
                    .help("Pick documents for Claude to read; each is confirmed first. You can also drop them on the terminal.")
            }
            .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
                ShareDocumentsSheet(session: session, files: picking ?? [])
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Documents for Claude to read while planning. You'll confirm each before it's shared."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        picking = panel.urls
    }
}

/// Plan This on an issue: a planning session about it, or its session when
/// it has one.
struct PlanThisButton: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.openWindow) private var openWindow
    let reference: IssueReference

    var body: some View {
        if let existing = sessions.planningSession(forIssue: reference.id) {
            Button {
                sessions.show(existing.id, with: openWindow)
            } label: {
                Label("Open Planning", systemImage: "list.bullet.clipboard")
            }
            .help("Show this issue's planning session")
        } else {
            Button {
                sessions.showNewPlan(PlanningDraft(org: reference.org, topic: reference.title, issue: reference,
                                                   harnessRepo: configs.config(for: reference.org).harness(covering: [reference.repo])?.repo), with: openWindow)
            } label: {
                Label("Plan This", systemImage: "list.bullet")
            }
            .help("Plan this issue with the team: requirements, design and tasks, then its sub-issues")
        }
    }
}
