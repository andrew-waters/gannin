import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A quick change: work on a small change in a repo (a snag, a tweak, a
/// one-line fix) started from a note and screenshots rather than a written-up
/// issue. It runs as Work on This does, in the project's harness. Whether it
/// gets an issue is asked each time: with one, Gannin makes it from the note
/// and puts it on the workflow board in progress, and the session is the
/// issue's; without, `CodeSession.issue` is a stand-in named for the repo, as
/// an Ask's is, and the PR says it has no issue.
struct QuickChangeInfo: Codable, Hashable {
    /// What to do, as typed.
    let note: String
    /// The screenshots' file names, in the session's `attachments/`, copied
    /// into `.worktrees/<branch>/.gannin/attachments/` by its start script.
    let attachments: [String]
    /// Whether Gannin filed an issue for it.
    let hasIssue: Bool
    /// Why the issue isn't on the workflow board, when GitHub wouldn't put
    /// it there; the session started anyway.
    var boardError: String? = nil
}

extension CodeSession {
    var isQuickChange: Bool { quickChange != nil }
    /// A quick change with no issue: its `issue` is a stand-in.
    var hasNoIssue: Bool { quickChange?.hasIssue == false }

    /// `#123` as rows and notifications show it, or Quick change with no
    /// issue to number.
    var shortReference: String { hasNoIssue ? "Quick change" : "#\(issue.number)" }
    /// `owner/name#123`, or the repo a quick change with no issue is in
    /// (the stand-in's repo: `repo` is the harness).
    var longReference: String { hasNoIssue ? "a quick change in \(issue.repo)" : issue.reference }

    /// The team's prompts' placeholders for its issue (`HarnessPromptLibrary`).
    /// With no issue, `{{issue}}` says what it is and `{{number}}` and
    /// `{{url}}` are empty, rather than a stand-in's `#0`.
    var issueValues: [String: String] {
        var values = HarnessPromptLibrary.values(reference: issue.reference, title: issue.title, url: issue.url, repo: issue.repo, number: issue.number, branch: branch)
        if hasNoIssue { values.merge(SessionStore.noIssueValues(repo: issue.repo)) { $1 } }
        return values
    }
}

extension SessionStore {
    /// The files a quick change's screenshots go in, in the session's folder.
    static let attachmentsFolder = "attachments"

    /// Starts a quick change in a project's harness. `issue` is the one
    /// Gannin just filed for it, or nil for none; `attachments` are the
    /// screenshots by name.
    @discardableResult
    func startQuickChange(org: String, repo: String, title: String, note: String, attachments: [(name: String, data: Data)], issue: IssueReference?,
                          boardError: String? = nil, harness setup: HarnessConfig, harnessPath: String, instructions: String?, placement: SandboxPlacement,
                          brief: (CodeSession) -> String) -> CodeSession {
        let id = UUID()
        let names = Self.attachmentNames(attachments.map(\.name))
        let reference = issue ?? IssueReference(org: org, id: "quick-\(id.uuidString)", number: 0, title: title, repo: repo,
                                                url: URL(string: "https://github.com/\(repo)")!)
        let branch = issue.map(Self.branchName) ?? Self.quickBranchName(title: title, id: id)
        var session = CodeSession(
            id: id, issue: reference, repo: setup.repo, branch: branch, createdAt: .now,
            connect: Self.connectCommand, harnessRepo: setup.repo, harnessPath: harnessPath, instructions: instructions,
            sandbox: placement.isSandboxed ? SandboxPlacement.containerName(for: id) : nil, hostReason: placement.reason
        )
        session.quickChange = QuickChangeInfo(note: note, attachments: names, hasIssue: issue != nil, boardError: boardError)
        session.prompt = Self.quickChangePrompt(session)
        let directory = Self.directory(for: id)
        let folder = directory.appending(path: Self.attachmentsFolder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, attachment) in zip(names, attachments) {
            try? attachment.data.write(to: folder.appending(path: name))
        }
        try? Data(brief(session).utf8).write(to: directory.appending(path: "brief.md"))
        add(session)
        return session
    }

    /// `quick-short-title-3f9a`: no number to start with, so the start of
    /// the session's ID keeps it apart from another of the same name.
    static func quickBranchName(title: String, id: UUID) -> String {
        let words = String(title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ")
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : "\(slug)-\(word)"
            if next.count > 32 { break }
            slug = next
        }
        let suffix = id.uuidString.prefix(4).lowercased()
        return slug.isEmpty ? "quick-\(suffix)" : "quick-\(slug)-\(suffix)"
    }

    /// `{{issue}}`, `{{number}}` and `{{url}}` for a quick change with no issue.
    static func noIssueValues(repo: String) -> [String: String] {
        ["issue": "a quick change in \(repo)", "pr": "a quick change in \(repo)", "number": "", "url": ""]
    }

    /// File names safe for the shell and unique: letters, digits, dashes
    /// and underscores, the stem and extension cleaned apart so the
    /// extension survives a name in another script (`screenshot-N` for a
    /// stem with nothing left), and a number added to a repeat.
    static func attachmentNames(_ names: [String]) -> [String] {
        func clean(_ text: String) -> String {
            String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) ? $0 : "-" })
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        var taken: Set<String> = []
        return names.enumerated().map { index, name in
            // An empty name as a URL would be the current folder.
            let url = name.isEmpty ? nil : URL(filePath: name)
            let ext = url.map { clean($0.pathExtension) } ?? "png"
            let cleanedStem = clean(url.map { $0.pathExtension.isEmpty ? name : $0.deletingPathExtension().lastPathComponent } ?? "")
            let stem = cleanedStem.isEmpty ? "screenshot-\(index + 1)" : cleanedStem
            func named(_ stem: String) -> String { ext.isEmpty ? stem : "\(stem).\(ext)" }
            var candidate = named(stem)
            var count = 2
            while taken.contains(candidate.lowercased()) {
                candidate = named("\(stem)-\(count)")
                count += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }

    /// Claude's first prompt: what to do and where, without the issue's
    /// "propose a plan first", since it's meant to be small. One filed from
    /// the note is written up once claude has looked, before it changes
    /// anything, since a note is rarely enough to go on later.
    static func quickChangePrompt(_ session: CodeSession) -> String {
        let folder = ".worktrees/\(session.branch)"
        let shots = session.quickChange?.attachments.isEmpty == false
        let about = session.hasNoIssue
            ? "You're making a quick change in \(session.issue.repo), \"\(session.issue.title)\", in the team's harness."
            : "You're making a quick change, \(session.issue.reference), \"\(session.issue.title)\", in the team's harness."
        let writeUp = session.hasNoIssue ? "" : "Then, before changing anything, fill out \(session.issue.reference) from what you found, "
            + "since it was filed from the note alone: with `gh issue edit`, give it a clear title and a description of the problem, "
            + "what you'll change and where, and anything out of scope, keeping any images already in its description. "
        return """
            \(about) Read \(folder)/.gannin/brief.md first: it has the note\(shots ? " and the screenshots to look at" : ""). \
            It's meant to be small, so there's no plan document: look through the code, say in a line or two what you'll change. \
            \(writeUp)Then make the change in a worktree of the repo under \(folder)/, as the brief says, never in projects/ or the harness \
            checkout itself. If it turns out not to be small, stop and say so before going further.
            """
    }

    /// Opens a New Quick Change tab in the Claude Code window.
    func showNewQuickChange(org: String, harnessRepo: String?, with openWindow: OpenWindowAction) {
        openDraft(PlanningDraft(org: org, harnessRepo: harnessRepo, isQuickChange: true))
        openWindow(id: Self.windowID)
    }
}

extension SessionBrief {
    /// A quick change's note and screenshots in place of the issue's
    /// description, and what makes it a quick change.
    static func quickChangeSections(_ session: CodeSession) -> [String] {
        guard let quick = session.quickChange else { return [] }
        let folder = ".worktrees/\(session.branch)"
        var lines = [
            "## A quick change",
            "",
            "Started from a quick note in Gannin rather than a written-up issue\(quick.hasIssue ? " (Gannin filed \(session.issue.reference) from the note)" : ", and there's no issue for it"). It's meant to be small: a snag, a tweak or a one-line fix in \(session.issue.repo). It needs no plan document. If it turns out bigger than that (more than one repo, a design decision to make, or more than a short piece of work), stop and say so before going further, so it can be written up as an issue.",
            "",
            "## The note",
            "",
            quick.note.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
        ]
        if !quick.attachments.isEmpty {
            lines += [
                "## Screenshots",
                "",
                "Attached to the note. Look at each one (the Read tool shows images). They're on this box only: never commit them or copy them into a repo.",
                "",
            ]
            lines += quick.attachments.map { "- `\(folder)/.gannin/\(SessionStore.attachmentsFolder)/\($0)`" }
            lines.append("")
        }
        return lines
    }
}

// MARK: - Starting

/// A screenshot added to a quick change, held until it starts.
struct QuickChangeAttachment: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let image: NSImage?

    /// Screenshots past this are refused: they'd be slow to send to a server.
    static let maxBytes = 20 * 1024 * 1024
}

/// What's been entered in a New Quick Change tab, kept on `SessionStore`
/// while another tab is showing.
struct QuickChangeForm {
    var pickedOrg: String?
    var picked: String?
    var repo = ""
    var title = ""
    var note = ""
    var attachments: [QuickChangeAttachment] = []
    var screenshotsInIssue = false
    var issueImages = IssueImageSet()
    var recording = true
    var sandboxed = true
    var choice = PromptChoice()
    var choseDefaults = false
}

/// A New Quick Change tab in the Claude Code window, until it's started:
/// the project and repo, the note, screenshots, whether to file an issue,
/// the team's prompts and skills for work, where it runs, and Start.
struct NewQuickChangeView: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgStore.self) private var orgs
    @Environment(IssueStore.self) private var issues
    @Environment(ProjectStore.self) private var projects
    @Environment(AuthStore.self) private var auth
    let draftID: UUID
    let draft: PlanningDraft

    @State private var pickedOrg: String?
    @State private var picked: String?
    @State private var repo: String
    @State private var title: String
    @State private var note: String
    @State private var attachments: [QuickChangeAttachment]
    @AppStorage("quickChangeCreatesIssue") private var createsIssue = true
    /// Whether the issue shows the screenshots, committed to the harness.
    @State private var screenshotsInIssue: Bool
    /// The screenshots as the issue's images, kept so trying again after
    /// GitHub refuses the issue doesn't commit them twice.
    @State private var issueImages: IssueImageSet
    @State private var recording: Bool
    @State private var sandboxed: Bool
    @State private var choice: PromptChoice
    @State private var choseDefaults: Bool
    @State private var working = false
    @State private var steps: [String] = []
    @State private var error: String?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    /// Starts from what was entered before the tab was left, if anything.
    init(draftID: UUID, draft: PlanningDraft, saved: QuickChangeForm?) {
        self.draftID = draftID
        self.draft = draft
        let form = saved ?? QuickChangeForm()
        _pickedOrg = State(initialValue: form.pickedOrg)
        _picked = State(initialValue: form.picked)
        _repo = State(initialValue: form.repo)
        _title = State(initialValue: form.title)
        _note = State(initialValue: form.note)
        _attachments = State(initialValue: form.attachments)
        _screenshotsInIssue = State(initialValue: form.screenshotsInIssue)
        _issueImages = State(initialValue: form.issueImages)
        _recording = State(initialValue: form.recording)
        _sandboxed = State(initialValue: form.sandboxed)
        _choice = State(initialValue: form.choice)
        _choseDefaults = State(initialValue: form.choseDefaults)
        restored = saved != nil
    }

    /// Whether the form came back from a tab left earlier, so its choices
    /// aren't put back to the defaults.
    private let restored: Bool

    private var org: String { pickedOrg ?? draft.org }

    /// What's been entered, kept on the store while the tab is away.
    private var form: QuickChangeForm {
        QuickChangeForm(pickedOrg: pickedOrg, picked: picked, repo: repo, title: title, note: note,
                        attachments: attachments, screenshotsInIssue: screenshotsInIssue,
                        issueImages: issueImages, recording: recording, sandboxed: sandboxed,
                        choice: choice, choseDefaults: choseDefaults)
    }

    var body: some View {
        let config = configs.config(for: org)
        let harnesses = config.repoProjects.isEmpty ? config.harnesses : config.allHarnesses
        let setup = (picked ?? draft.harnessRepo).flatMap(config.harness(repo:)) ?? harnesses.first
        let library = setup.map { sessions.promptLibrary(org: org, setup: $0) } ?? HarnessPromptLibrary(index: nil)
        let workflow = setup.map { configs.scoped($0.repo).config(for: org).workflow } ?? config.workflow
        let blocked = SessionStore.unavailable(org: org, harness: setup)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Label("New Quick Change", systemImage: "bolt")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                Form {
                    whatSection(setup: setup)
                    screenshotsSection
                    issueSection(workflow: workflow, setup: setup)
                    PromptPickerSections(library: library, use: .work,
                                         values: ["title": effectiveTitle, "repo": repo], choice: $choice)
                    runSection
                    startSection(setup: setup, workflow: workflow, blocked: blocked)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .onPasteCommand(of: [.fileURL, .image]) { _ in _ = pastePicture(fromKeyboard: false) }
        .onAppear {
            focused = true
            if repo.isEmpty { repo = defaultRepo(setup: setup) }
            if !restored { sandboxed = placement.isSandboxed }
        }
        .onDisappear {
            // Switching tabs drops this view: keep what's entered, unless
            // the tab's gone (closed, or started as a session).
            if sessions.planningDrafts[draftID] != nil { sessions.quickChangeForms[draftID] = form }
        }
        .onChange(of: setup?.repo) { repo = defaultRepo(setup: setup) }
        .onChange(of: repo) { sandboxed = placement.isSandboxed }
        .task(id: setup?.repo) {
            if let setup { await harness.load(org: org, setup: setup) }
        }
        .task(id: org) { await harness.loadRepositories(org: org) }
        .task(id: workflow.projectNumber) {
            if let number = workflow.projectNumber { await projects.loadDefinition(org: org, number: number) }
        }
        .onChange(of: library.offered(for: .work).map(\.path), initial: true) {
            if !choseDefaults, !library.isEmpty {
                choice = library.defaults(for: .work, repos: repo.isEmpty ? [] : [repo])
                choseDefaults = true
            }
        }
    }

    // MARK: Sections

    private func whatSection(setup: HarnessConfig?) -> some View {
        Section {
            Picker("Project", selection: Binding(get: { "\(org)\u{1F}\(setup?.repo ?? "")" }, set: { value in
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
            LabeledContent("Repository") {
                SearchablePicker(choices: repoChoices(setup: setup), selection: repo.isEmpty ? nil : repo, prompt: "Search repositories",
                                 isLoading: harness.repositories[org] == nil) { value in
                    if let value { repo = value }
                }
            }
            TextField("What to change", text: $note, prompt: Text("What to change: the Save button on Settings sits too low on small windows, nudge it up"), axis: .vertical)
                .lineLimit(4...14)
                .focused($focused)
            TextField("Title", text: $title, prompt: Text(SessionStore.askTitle(note).isEmpty || note.isEmpty ? "From the note's first line" : SessionStore.askTitle(note)))
        } footer: {
            Text(setup == nil
                 ? "A quick change runs in a project's harness. Add one in the org's Settings, under Projects."
                 : "For a snag, a tweak or a one-line fix: Claude Code starts on it straight away in \(setup!.repo), with a worktree and branch of its own, as Work on This does for an issue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var screenshotsSection: some View {
        Section {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(attachments) { attachment in
                            thumbnail(attachment)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Text(dropTargeted ? "Drop to attach" : "Drop screenshots here")
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background {
                    // AppKit's, as the form's own views take a drag before
                    // SwiftUI's drop destinations see it.
                    ScreenshotDropTarget(targeted: $dropTargeted, files: { urls in
                        for url in urls { addFile(url) }
                    }, image: addImageData, paste: { pastePicture(fromKeyboard: true) })
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("Drop screenshots here")
            HStack {
                Text(attachments.isEmpty ? "Or paste them (⌘V) or add them." : "\(attachments.count) attached")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Paste") { _ = pastePicture(fromKeyboard: false) }
                    .help("Attach the picture or image files on the clipboard")
                Button("Add Screenshots") { pickFiles() }
            }
        } header: {
            Text("Screenshots")
        } footer: {
            Text(addsScreenshots
                 ? "They stay with the session, for Claude to look at, and are committed to the harness for the issue to show."
                 : "They stay with the session, for Claude to look at, and aren't uploaded to GitHub or committed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func thumbnail(_ attachment: QuickChangeAttachment) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image = attachment.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 80)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Button {
                    attachments.removeAll { $0.id == attachment.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .padding(3)
                .help("Remove \(attachment.name)")
                .accessibilityLabel("Remove \(attachment.name)")
            }
            Text(attachment.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120)
        }
    }

    private func issueSection(workflow: IssueWorkflow, setup: HarnessConfig?) -> some View {
        Section {
            Toggle("Create an issue for it", isOn: $createsIssue)
            Text(issueExplanation(workflow: workflow))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if createsIssue, !attachments.isEmpty, let setup {
                Toggle("Add the screenshots to the issue", isOn: $screenshotsInIssue)
                if screenshotsInIssue {
                    Label {
                        Text(IssueImages.audience(harness: setup.repo, repo: repo))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
                if let error = issueImages.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    /// Whether Start commits the screenshots for the issue to show.
    private var addsScreenshots: Bool { createsIssue && screenshotsInIssue && !attachments.isEmpty }

    private func issueExplanation(workflow: IssueWorkflow) -> String {
        guard createsIssue else {
            return "No issue: the branch is named quick-…, the pull request says it's a quick change with no issue, and it counts in pull request metrics but not on the board or in issue metrics."
        }
        let target = repo.isEmpty ? "the repo" : repo
        guard workflow.projectNumber != nil else {
            return "Start files an issue in \(target) from the note on GitHub, assigned to you, and the pull request closes it. The project has no workflow board (Settings › Issues), so it isn't put on one.\(screenshotsNote)"
        }
        let board = boardDefinition(workflow).map { "\"\($0.title)\"" } ?? "the workflow board"
        let status = inProgressStatus(workflow).map { " as \($0)" } ?? ""
        return "Start files an issue in \(target) from the note on GitHub, assigned to you, puts it on \(board)\(status), and the pull request closes it.\(screenshotsNote)"
    }

    private var screenshotsNote: String {
        guard !attachments.isEmpty else { return "" }
        return addsScreenshots ? " The screenshots show in it, committed to the harness first." : " Screenshots aren't added to it."
    }

    @ViewBuilder
    private var runSection: some View {
        let offered = placement
        Section {
            if SandboxCredentials.isEnabled {
                Picker("Run in", selection: $sandboxed) {
                    Text("A sandbox").tag(true)
                    Text("This Mac").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!offered.isSandboxed)
                Text(offered.reason ?? (sandboxed
                    ? "Claude works in a Linux sandbox that sees only this change's folder, the shared clones' git and the harness, read-only."
                    : "Claude works on this Mac as you, able to reach everything you can."))
                    .font(.caption)
                    .foregroundStyle(offered.isSandboxed ? Color.secondary : Color.orange)
            }
            Toggle("Record the session in the harness", isOn: $recording)
            Text("Gannin commits its brief (the note, not the screenshots) and session.json under sessions/ in the harness it runs in, so the team can see it and any box can start it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startSection(setup: HarnessConfig?, workflow: IssueWorkflow, blocked: String?) -> some View {
        Section {
            ForEach(steps, id: \.self) { step in
                Label(step, systemImage: "checkmark").foregroundStyle(.secondary)
            }
            if let message = error ?? blocked {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(working ? "Starting" : addsScreenshots ? "Commit \(attachments.count == 1 ? "1 Image" : "\(attachments.count) Images"), Create Issue and Start"
                       : createsIssue ? "Create Issue and Start" : "Start") {
                    if let setup { start(setup: setup, workflow: workflow) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(working || setup == nil || blocked != nil || repo.isEmpty || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (createsIssue && auth.api == nil))
                .help(addsScreenshots ? "Commits the screenshots to \(setup?.repo ?? "the harness"), files the issue on GitHub showing them, then starts Claude Code on it (⌘↩)"
                      : createsIssue ? "Files the issue on GitHub, then starts Claude Code on it (⌘↩)" : "Starts Claude Code on it (⌘↩)")
            }
        }
    }

    // MARK: Choices

    private var effectiveTitle: String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? SessionStore.askTitle(note) : typed
    }

    /// Where it would run by default, as Work on This decides.
    private var placement: SandboxPlacement {
        SandboxPlacement.decide(
            enabled: SandboxCredentials.isEnabled, repos: repo.isEmpty ? [] : [repo],
            reposNeedingMac: configs.config(for: org).reposNeedingMac, org: org,
            hasGitHubToken: SandboxCredentials.gitHubToken(org: org) != nil,
            connectsBySSH: SessionStore.connectCommand.map { Shell.sshArguments($0) != nil } ?? true
        )
    }

    private func project(for setup: HarnessConfig?) -> RepoProject? {
        guard let setup else { return nil }
        return configs.config(for: org).repoProjects.first { $0.harness.repo == setup.repo }
    }

    private func defaultRepo(setup: HarnessConfig?) -> String {
        project(for: setup)?.repos.first ?? repoChoices(setup: setup).first?.value ?? ""
    }

    /// The project's repos first, then the org's with issues, then the rest.
    private func repoChoices(setup: HarnessConfig?) -> [SearchableChoice] {
        let config = configs.config(for: org)
        let own = project(for: setup)?.repos ?? []
        let history = issues.history(for: org).map { Array($0.issues.values) } ?? []
        let busy = Dictionary(grouping: history, by: \.repo).mapValues(\.count)
            .sorted { $0.value > $1.value }.map(\.key)
            .filter { !own.contains($0) && !config.repoExclusion.contains($0) }
        let rest = Set(harness.repositories[org] ?? []).subtracting(own).subtracting(busy)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return own.map { SearchableChoice(value: $0, title: $0, section: project(for: setup)?.name) }
            + busy.map { SearchableChoice(value: $0, title: $0, section: "With issues") }
            + rest.map { SearchableChoice(value: $0, title: $0, section: "Everything else") }
    }

    private func boardDefinition(_ workflow: IssueWorkflow) -> Board? {
        workflow.projectNumber.flatMap { projects.cache(org: org, number: $0)?.board }
    }

    /// The board's first Status option that counts as in progress.
    private func inProgressStatus(_ workflow: IssueWorkflow) -> String? {
        boardDefinition(workflow)?.field(named: "Status")?.options.first { workflow.isInProgress($0.name) }?.name
    }

    /// Orgs with a project, this one first.
    private var projectOrgs: [String] {
        let logins = orgs.orgs.map(\.login).filter { !projectChoices($0).isEmpty }
        return [draft.org].filter(logins.contains) + logins.filter { $0 != draft.org }
    }

    private func projectChoices(_ login: String) -> [(name: String, repo: String)] {
        let config = configs.config(for: login)
        if !config.repoProjects.isEmpty {
            return config.repoProjects.map { ($0.name, $0.harness.repo) }
        }
        return config.harnesses.map { ($0.repo, $0.repo) }
    }

    // MARK: Screenshots

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Screenshots for Claude to look at"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFile(url) }
    }

    /// What's on the pasteboard: image files copied in Finder, else a
    /// picture (a screenshot taken to the clipboard). From ⌘V, only when
    /// that's all there is, so text still pastes into the note; returns
    /// whether it took it.
    private func pastePicture(fromKeyboard: Bool) -> Bool {
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let images = files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !files.isEmpty, !fromKeyboard || images.count == files.count {
            for url in files { addFile(url) }
            return true
        }
        if files.isEmpty, !fromKeyboard || board.string(forType: .string) == nil,
           let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            addImageData(data)
            return true
        }
        if !fromKeyboard { error = "There's no picture on the clipboard." }
        return false
    }

    private func addFile(_ url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
            error = "\(url.lastPathComponent) isn't an image."
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        append(name: url.lastPathComponent, data: data)
    }

    /// A pasted or dragged picture with no file: kept as a PNG.
    private func addImageData(_ data: Data) {
        let image = NSImage(data: data)
        let png = image.flatMap { $0.tiffRepresentation }.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]) ?? data
        append(name: "screenshot-\(attachments.count + 1).png", data: png)
    }

    private func append(name: String, data: Data) {
        guard data.count <= QuickChangeAttachment.maxBytes else {
            error = "\(name) is over 20 MB. Attach a smaller screenshot."
            return
        }
        error = nil
        attachments.append(QuickChangeAttachment(name: name, data: data, image: NSImage(data: data)))
    }

    // MARK: Starting

    private func start(setup: HarnessConfig, workflow: IssueWorkflow) {
        guard let path = SessionStore.harnessPath(org: org, repo: setup.repo) else { return }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = effectiveTitle
        guard !note.isEmpty, !repo.isEmpty else { return }
        working = true
        error = nil
        steps = []
        let org = org
        let repo = repo
        let decided = placement
        // Picked here: the Mac over a sandbox, never the other way.
        let chosen: SandboxPlacement = decided.isSandboxed && !sandboxed ? .host(SandboxPlacement.pickedHost) : decided
        let index = harness.index(for: org, setup)
        let goals = configs.scoped(setup.repo).config(for: org).measurables
        let recording = recording
        let login = auth.viewer?.login
        let addsScreenshots = addsScreenshots
        Task {
            defer { working = false }
            var issue: IssueReference?
            var boardError: String?
            if createsIssue {
                guard let api = auth.api else { return }
                var writing = "the issue"
                var committedTo: String?
                do {
                    // Assigned to whoever started it, so it's in their workload.
                    var assignees: [String] = []
                    if let login { assignees = Array(try await api.userIDs([login]).values) }
                    var links: [(name: String, url: URL)] = []
                    if addsScreenshots {
                        issueImages.keep(Set(attachments.map(\.id)))
                        for attachment in attachments where !issueImages.images.contains(where: { $0.id == attachment.id }) {
                            guard issueImages.add(name: attachment.name, data: attachment.data, id: attachment.id) != nil else {
                                self.error = issueImages.error
                                return
                            }
                        }
                        writing = "the screenshots"
                        links = try await issueImages.commit(org: org, repo: repo, setup: setup, harness: harness)
                        committedTo = setup.repo
                        writing = "the issue"
                        steps.append("Committed \(links.count == 1 ? "a screenshot" : "\(links.count) screenshots") to \(setup.repo)")
                    }
                    let made = try await api.createIssue(repo: repo, title: title, body: IssueImages.body(note, links: links), assigneeIDs: assignees)
                    issue = IssueReference(org: org, id: made.id, number: made.number, title: title, repo: repo, url: made.url)
                    steps.append("Created \(repo)#\(made.number)")
                } catch {
                    let kept = committedTo.map { "The images are committed to \($0), and trying again links them rather than committing them twice. " } ?? ""
                    self.error = "\(kept)GitHub didn't take \(writing): \(error.localizedDescription)"
                    return
                }
                // The board is a nicety: the session starts whatever happens,
                // saying when the issue isn't on it.
                if let number = workflow.projectNumber, boardDefinition(workflow) == nil {
                    await projects.loadDefinition(org: org, number: number)
                }
                let definition = boardDefinition(workflow)
                let status = inProgressStatus(workflow)
                if workflow.projectNumber != nil, definition == nil, let made = issue {
                    boardError = "\(made.reference) isn't on the workflow board: Gannin couldn't read the board. Add it from the issue."
                }
                if let definition, let made = issue {
                    do {
                        let item = try await api.addToBoard(projectID: definition.id, contentID: made.id)
                        steps.append("Added it to \(definition.title)")
                        if let status, let field = definition.field(named: "Status"), let value = field.value(from: status) {
                            try await api.setProjectField(projectID: definition.id, itemID: item, field: field.projectField, value: value)
                            steps.append("Set Status to \(status)")
                        }
                    } catch {
                        boardError = "GitHub didn't put \(made.reference) on \(definition.title): \(error.localizedDescription)"
                    }
                }
            }
            let values = issue.map(WorkOnThisLauncher.values) ?? SessionStore.noIssueValues(repo: repo).merging(["title": title, "repo": repo]) { $1 }
            let instructions = sessions.launchInstructions(org: org, setup: setup, use: .work, repos: [repo], choice: choice, values: values)
            let session = sessions.startQuickChange(
                org: org, repo: repo, title: title, note: note, attachments: attachments.map { (name: $0.name, data: $0.data) }, issue: issue, boardError: boardError,
                harness: setup, harnessPath: path, instructions: instructions, placement: chosen
            ) { session in
                SessionBrief.make(session: session, record: nil, detail: nil, parent: nil, harness: index, goals: goals)
            }
            // Committed before the terminal starts, so its pull brings the brief.
            if recording { await sessions.record(session.id, startedBy: login) }
            sessions.replaceDraft(draftID, with: session.id)
        }
    }
}

// MARK: - In its panel

/// A quick change's note and screenshots, beside its terminal. The
/// screenshots are the copies in the session's folder on this Mac.
struct QuickChangeSection: View {
    let session: CodeSession

    var body: some View {
        if let quick = session.quickChange {
            Section("Quick change") {
                Text(session.issue.title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if session.hasNoIssue {
                    LabeledContent("Repository", value: session.issue.repo)
                    Text("No issue: its pull request says it's a quick change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = quick.boardError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(quick.note)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !quick.attachments.isEmpty {
                    let folder = SessionStore.directory(for: session.id).appending(path: SessionStore.attachmentsFolder, directoryHint: .isDirectory)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(quick.attachments, id: \.self) { name in
                                let url = folder.appending(path: name)
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Group {
                                        if let image = NSImage(contentsOf: url) {
                                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                        } else {
                                            Image(systemName: "photo").foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 96, height: 64)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(name)")
                                .accessibilityLabel("Screenshot \(name)")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Dropping

/// Where screenshots are dropped: image files from Finder, files promised
/// by the screenshot thumbnail and other apps, or a picture with no file
/// (from a browser or Preview), read off the drag's pasteboard.
struct ScreenshotDropTarget: NSViewRepresentable {
    @Binding var targeted: Bool
    let files: ([URL]) -> Void
    let image: (Data) -> Void
    /// ⌘V in its window, wherever the focus is (a text field's editor
    /// would otherwise take it): true when it took a picture.
    let paste: () -> Bool

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        update(view)
        return view
    }

    func updateNSView(_ view: DropView, context: Context) { update(view) }

    private func update(_ view: DropView) {
        view.onTargeted = { targeted = $0 }
        view.onFiles = files
        view.onImage = image
        view.onPaste = paste
    }

    final class DropView: NSView {
        var onTargeted: ((Bool) -> Void)?
        var onFiles: (([URL]) -> Void)?
        var onImage: ((Data) -> Void)?
        var onPaste: (() -> Bool)?
        private let promiseQueue = OperationQueue()
        private var keyMonitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        }

        required init?(coder: NSCoder) { nil }

        /// Watches for ⌘V while it's in a window, letting it through unless
        /// it took a picture; gone when the tab is.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v",
                      self.onPaste?() == true else { return event }
                return nil
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onTargeted?(true)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }

        override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted?(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargeted?(false)
            let board = sender.draggingPasteboard
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                onFiles?(urls)
                return true
            }
            if let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
                let folder = FileManager.default.temporaryDirectory.appending(path: "gannin-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for promise in promises {
                    // Written on the queue, so handed back to the main actor.
                    promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { @Sendable [weak self] url, error in
                        guard error == nil, let view = self else { return }
                        Task { @MainActor in view.onFiles?([url]) }
                    }
                }
                return true
            }
            if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
                onImage?(data)
                return true
            }
            return false
        }
    }
}
