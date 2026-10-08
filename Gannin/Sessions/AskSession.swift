import AppKit
import SwiftUI

/// An Ask session: an open-ended Claude Code conversation about anything,
/// in its own folder of a project's harness (`.worktrees/ask-<slug>/`), so
/// the harness's CLAUDE.md, skills and MCP servers apply. Not tied to an
/// issue, PR or plan.
struct AskInfo: Codable, Hashable {
    /// From the first message; renamed as you like.
    var title: String
    /// Short, for its folder and anything committed from it
    /// (`research/<date>-<slug>/`).
    let slug: String
    /// What it was started with.
    let message: String
}

extension CodeSession {
    var isAsk: Bool { ask != nil }
}

extension OrgContext {
    /// The files for an Ask session, from the stores: the org's workload
    /// (drafts and hidden items left out as Gannin's defaults have them),
    /// the default metrics window, the issue history, the project's
    /// harness and time off.
    static func files(org: String, harnessRepo: String, orgs: OrgStore, metrics: MetricsStore, issues: IssueStore, configs: OrgConfigStore,
                      harness: HarnessStore, peopleDates: PeopleDatesStore, hidden: HiddenStore) -> [String: Data] {
        let config = configs.baseConfig(for: org)
        let snapshot = orgs.snapshot(for: org)
        let workload = snapshot.map { Workload(snapshot: $0, team: nil, options: .init(hidden: hidden.keys, config: config)) }
        let window = MetricsWindow(code: MetricsStore.defaultWindowDays)
        let metrics = metrics.history(for: org).map {
            OrgMetrics(history: $0, window: window, team: nil, members: snapshot?.members ?? [], hidden: hidden.keys, config: config)
        }
        let index = config.harness(repo: harnessRepo).flatMap { harness.index(for: org, $0) } ?? harness.anyIndex(org: org, repo: harnessRepo)
        return files(org: org, workload: workload, metrics: metrics, issues: issues.history(for: org), config: config,
                     harness: index, people: peopleDates.all(in: org))
    }
}

extension SessionStore {
    /// Starts an Ask session in a project's harness with the first message.
    /// It always runs on this Mac, even with Connect with set, so what it
    /// writes can be grabbed from its Files pane. `choice` is what was
    /// picked from the team's prompts and skills; nil takes the defaults.
    @discardableResult
    func startAsk(org: String, message: String, harness setup: HarnessConfig, choice: PromptChoice? = nil) -> CodeSession {
        let harnessPath = Self.localHarnessPath(org: org, repo: setup.repo)
        let title = Self.askTitle(message)
        let slug = uniqueAskSlug(Self.slug(title), harnessPath: harnessPath)
        let branch = "ask-\(slug)"
        let info = AskInfo(title: title, slug: slug, message: message)
        let instructions = launchInstructions(org: org, setup: setup, use: .ask, repos: [], choice: choice,
                                              values: ["title": title, "repo": setup.repo, "branch": branch])
        let session = CodeSession(
            id: UUID(), issue: IssueReference(org: org, id: "ask-\(UUID().uuidString)", number: 0, title: title, repo: setup.repo,
                                              url: URL(string: "https://github.com/\(setup.repo)")!),
            repo: setup.repo, branch: branch, createdAt: .now,
            connect: nil, harnessRepo: setup.repo, harnessPath: harnessPath,
            prompt: Self.askPrompt(message, branch: branch), instructions: instructions, ask: info
        )
        let directory = Self.directory(for: session.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(Self.askBrief(session).utf8).write(to: directory.appending(path: "brief.md"))
        add(session)
        reveal(session.id)
        return session
    }

    /// The first line of the message, cut at a word near 60 characters.
    static func askTitle(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Ask"
        guard line.count > 60 else { return line }
        let cut = line.prefix(60)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)])
    }

    /// The slug with a number after it when another Ask session, or a
    /// folder left behind, has it.
    private func uniqueAskSlug(_ base: String, harnessPath: String) -> String {
        let taken = Set(sessions.values.compactMap(\.ask?.slug))
        let folder = Self.expanded(harnessPath).appending(path: ".worktrees")
        func free(_ slug: String) -> Bool {
            !taken.contains(slug) && !FileManager.default.fileExists(atPath: folder.appending(path: "ask-\(slug)").path)
        }
        if free(base) { return base }
        return (2...).lazy.map { "\(base)-\($0)" }.first(where: free)!
    }

    /// What claude is told first: your message, then where it is and where
    /// to put what it makes.
    static func askPrompt(_ message: String, branch: String) -> String {
        let folder = ".worktrees/\(branch)"
        return """
            \(message.trimmingCharacters(in: .whitespacesAndNewlines))

            (From Gannin: this is an open-ended conversation in the team's harness, about whatever I've asked. Save any file you make for me, such as an export, a CSV or a chart, in `\(folder)/files/`, where I can grab it. Gannin's view of the org (workload, issues, delivery, the harness's documents, time off) is in `\(folder)/context/`, README.md first, if the question needs it. More in `\(folder)/.gannin/brief.md`.)
            """
    }

    /// The session's brief: where it is, what's on hand, and what not to do.
    static func askBrief(_ session: CodeSession) -> String {
        let folder = ".worktrees/\(session.branch)"
        return """
            # Ask: \(session.title)

            An open-ended conversation started from Gannin. It isn't about an issue, a pull request or a plan: it's about whatever was asked, which may have nothing to do with the code or the harness (how many users logged in today, say, which may need the code to find out where that's kept).

            ## Working here

            - You're in the team's harness, \(session.harnessRepo ?? session.repo), checked out at `\(session.harnessPath ?? "")`. Its CLAUDE.md, skills and MCP servers apply. The code repos are shared clones under `projects/<name>`, to read; don't change them.
            - Save every file you make for the person you're talking to in `\(folder)/files/`, so they can open it, drag it out or save it elsewhere from Gannin. Don't leave files anywhere else unless asked to.
            - `\(folder)/context/` is Gannin's view of the org as JSON, written when the session started or resumed: workload, issues, delivery, the harness's documents and time off. README.md says what's in each. Use it if a question needs it; it isn't the subject.
            - Never commit, push or copy into the harness anything from this folder. Files may hold customer or other sensitive data. If one should be shared, the person commits it themselves from Gannin.
            - `\(folder)/.gannin/` is Gannin's (this brief and the session's hooks). `.worktrees/` is kept out of the harness's git.

            """
    }

    /// Writes the org data for an Ask session where its start script picks
    /// it up, so each start and resume has it as it is now.
    func writeAskContext(_ session: CodeSession) {
        guard let repo = session.harnessRepo else { return }
        let folder = Self.directory(for: session.id).appending(path: "context", directoryHint: .isDirectory)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in orgContext(session.org, repo) {
            try? data.write(to: folder.appending(path: name))
        }
    }

    func renameAsk(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(id) { $0.ask?.title = title }
    }

    /// Ask sessions, most recently active first.
    func askSessions(for org: String) -> [CodeSession] {
        sessions(for: org).filter(\.isAsk).sorted { lastActive($0) > lastActive($1) }
    }

    func lastActive(_ session: CodeSession) -> Date {
        transcripts[session.id]?.lastActivity ?? session.lastActiveAt ?? session.createdAt
    }

    /// Opens a New Ask tab in the Claude Code window.
    func showNewAsk(org: String, harnessRepo: String?, with openWindow: OpenWindowAction) {
        openDraft(PlanningDraft(org: org, harnessRepo: harnessRepo, isAsk: true))
        openWindow(id: Self.windowID)
    }
}

// MARK: - Starting

/// The box an Ask starts from: the project it runs in, the first message
/// (Return starts it; Shift-Return is a new line) and the team's prompts and
/// skills for Ask, in a New Ask tab of the Claude Code window.
struct NewAskForm: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgStore.self) private var orgs
    let org: String
    /// The harness to start in, when one was picked first.
    var harnessRepo: String? = nil
    /// Told the session it started.
    let started: (CodeSession) -> Void
    @State private var pickedOrg: String?
    @State private var picked: String?
    @State private var message = ""
    @State private var choice = PromptChoice()
    @State private var choseDefaults = false
    @FocusState private var focused: Bool

    private var currentOrg: String { pickedOrg ?? org }

    var body: some View {
        let config = configs.config(for: currentOrg)
        let harnesses = config.repoProjects.isEmpty ? config.harnesses : config.allHarnesses
        let setup = (picked ?? harnessRepo).flatMap(config.harness(repo:)) ?? harnesses.first
        let library = setup.map { sessions.promptLibrary(org: currentOrg, setup: $0) } ?? HarnessPromptLibrary(index: nil)
        Form {
            Section {
                Picker("Project", selection: Binding(get: { "\(currentOrg)\u{1F}\(setup?.repo ?? "")" }, set: { value in
                    let parts = value.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return }
                    pickedOrg = parts[0]
                    picked = parts[1]
                    choseDefaults = false
                })) {
                    ForEach(projectOrgs, id: \.self) { login in
                        Section(orgs.org(login: login)?.displayName ?? login) {
                            ForEach(projectChoices(login), id: \.repo) { choice in
                                Text(choice.name).tag("\(login)\u{1F}\(choice.repo)")
                            }
                        }
                    }
                }
                TextField("Ask anything", text: $message, prompt: Text("Ask anything: how many users logged in today, pull last month's signups as a CSV, explain how billing works"), axis: .vertical)
                    .lineLimit(3...12)
                    .focused($focused)
                    // Return starts; Shift-Return (or Option-Return) is a new line.
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            message += "\n"
                        } else if let setup {
                            start(setup)
                        }
                        return .handled
                    }
            } footer: {
                Text(setup == nil
                     ? "Ask runs in a project's harness. Add one in the org's Settings, under Projects."
                     : "Claude Code runs in \(setup!.repo) on this Mac, with its CLAUDE.md, skills and MCP servers, and Gannin's view of the org on hand. What it makes is listed beside the terminal to open or drag out, and stays on this Mac unless you commit a file yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PromptPickerSections(library: library, use: .ask, values: ["title": SessionStore.askTitle(message), "repo": setup?.repo ?? ""], choice: $choice)
            Section {
                HStack {
                    Spacer()
                    Button("Start") { if let setup { start(setup) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(setup == nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Start (Return, or ⌘↩ from anywhere here)")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { focused = true }
        .task(id: setup?.repo) {
            if let setup { await harness.load(org: currentOrg, setup: setup) }
        }
        // The defaults for Ask once the harness's prompts are in.
        .onChange(of: library.offered(for: .ask).map(\.path), initial: true) {
            if !choseDefaults, !library.isEmpty {
                choice = library.defaults(for: .ask, repos: [])
                choseDefaults = true
            }
        }
    }

    private func start(_ setup: HarnessConfig) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let session = sessions.startAsk(org: currentOrg, message: text, harness: setup, choice: choice)
        message = ""
        started(session)
    }

    /// Orgs with a project to ask in, this one first.
    private var projectOrgs: [String] {
        let logins = orgs.orgs.map(\.login).filter { !projectChoices($0).isEmpty }
        return [org].filter(logins.contains) + logins.filter { $0 != org }
    }

    /// An org's projects by name, or its harnesses by repo with none named.
    private func projectChoices(_ login: String) -> [(name: String, repo: String)] {
        let config = configs.config(for: login)
        if !config.repoProjects.isEmpty {
            return config.repoProjects.map { ($0.name, $0.harness.repo) }
        }
        return config.harnesses.map { ($0.repo, $0.repo) }
    }
}

/// A New Ask tab in the Claude Code window, until it's started.
struct NewAskView: View {
    @Environment(SessionStore.self) private var sessions
    let draftID: UUID
    let draft: PlanningDraft

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Label("New Ask", systemImage: "sparkle.magnifyingglass")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                NewAskForm(org: draft.org, harnessRepo: draft.harnessRepo) { session in
                    sessions.replaceDraft(draftID, with: session.id)
                }
                .scrollDisabled(true)
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Listing

/// The org's Ask sessions: title, when last active and how many files,
/// each to open (resuming the conversation), rename or delete.
struct AskSessionsList: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    let org: String
    @State private var renaming: CodeSession?
    @State private var newTitle = ""
    @State private var deleting: CodeSession?
    /// Its folder couldn't be removed: why, to delete it anyway.
    @State private var failed: (session: CodeSession, message: String)?

    var body: some View {
        let all = sessions.askSessions(for: org)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(all) { session in
                AskSessionRow(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture { sessions.show(session.id, with: openWindow) }
                    .contextMenu { menu(session) }
                Divider()
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { session in
            TextField("Title", text: $newTitle)
            Button("Rename") { sessions.renameAsk(session.id, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "this Ask")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { session in
            Button("Delete", role: .destructive) { delete(session) }
        } message: { _ in
            Text("This ends Claude and removes the session's folder and every file in it, on this Mac. It can't be undone. Anything you committed to the harness stays there.")
        }
        .alert(
            "Couldn't remove its folder",
            isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } }),
            presenting: failed
        ) { failed in
            Button("Delete Anyway", role: .destructive) { sessions.remove(failed.session.id) }
            Button("Cancel", role: .cancel) {}
        } message: { failed in
            Text("\(failed.message) Delete Anyway forgets the session and leaves its folder where it is.")
        }
    }

    @ViewBuilder
    private func menu(_ session: CodeSession) -> some View {
        Button("Open") { sessions.show(session.id, with: openWindow) }
        Button("Rename") {
            newTitle = session.title
            renaming = session
        }
        if let folder = SessionStore.worktree(for: session) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                .disabled(!FileManager.default.fileExists(atPath: folder.path))
        }
        Divider()
        Button("Delete", role: .destructive) { deleting = session }
    }

    private func delete(_ session: CodeSession) {
        Task {
            do {
                try await sessions.finish(session.id)
            } catch {
                failed = (session, error.localizedDescription)
            }
        }
    }
}

/// One Ask: its state, title, first message, when it was last active and
/// how many files it has.
private struct AskSessionRow: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var fileCount: Int?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(sessions.state(session.id).color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).fontWeight(.medium).lineLimit(1)
                if let message = session.ask?.message, message != session.title {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let fileCount, fileCount > 0 {
                Label(fileCount == 1 ? "1 file" : "\(fileCount) files", systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(sessions.lastActive(session).formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .task(id: sessions.changeCount(session.id)) {
            guard let folder = SessionStore.worktree(for: session) else { return }
            fileCount = await Task.detached { SessionFiles.scan(folder: folder, edited: []).0.count }.value
        }
    }
}
