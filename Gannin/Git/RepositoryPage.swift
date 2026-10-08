import SwiftUI

/// What a repo's page shows, picked in the toolbar.
enum RepositoryPart: String, CaseIterable {
    case history = "History"
    case changes = "Changes"
}

/// A repo, picked under Repositories: its clone on this Mac (changes,
/// history and tags, branches and worktrees).
struct RepositoryPage: View {
    @Environment(OrgConfigStore.self) private var configs
    @SceneStorage("repositoryPart") private var part: RepositoryPart = .history
    let org: String
    /// `owner/name`.
    let repo: String
    let workload: Workload?
    @Binding var selection: DetailSelection?
    /// Switches the page to another repo; nil for a repo pushed onto the
    /// trail, which has no switcher.
    var switchTo: ((String) -> Void)? = nil
    @State private var local: LocalRepository?
    /// Looked for a clone, and found none if `local` is still nil.
    @State private var looked = false

    var body: some View {
        Group {
            if let local {
                LocalRepositoryView(repository: local, part: $part, switcher: switcher) { locate() }
            } else {
                VStack(spacing: 0) {
                    RepositoryBar {
                        if let switcher { switcher }
                        RepositoryPartPicker(part: $part)
                    }
                    Divider()
                    if looked {
                        NotClonedView(org: org, repo: repo) { locate() }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task(id: repo) { locate() }
    }

    private var switcher: RepositorySwitcher? {
        switchTo.map { RepositorySwitcher(org: org, current: repo, workload: workload, pick: $0) }
    }

    /// Finds the clone, working in the worktree last used.
    private func locate() {
        looked = true
        guard let root = LocalClones.find(repo, org: org, config: configs.config(for: org)) else {
            local = nil
            return
        }
        let worktree = UserDefaults.standard.string(forKey: LocalRepository.worktreeKey(repo)).flatMap { LocalClones.isGitFolder($0) ? $0 : nil }
        if local?.root != root {
            local = LocalRepository(repo: repo, root: root, worktree: worktree)
        }
    }
}

/// A clone's parts, under a bar of its branch, sync and open controls, and
/// everything they ask about.
private struct LocalRepositoryView: View {
    @Bindable var repository: LocalRepository
    @Binding var part: RepositoryPart
    let switcher: RepositorySwitcher?
    /// The clone's folder changed or went: look for it again.
    let relocate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RepositoryBar {
                if let switcher { switcher }
                Group {
                    BranchPopoverButton(repository: repository)
                    WorktreePopoverButton(repository: repository)
                }
                .fixedSize()
                RepositoryPartPicker(part: $part)
                Spacer()
                Group {
                    syncMenu
                    openMenu
                }
                .fixedSize()
            }
            Divider()
            content
        }
        // Status every ten seconds, for edits made anywhere.
        .task(id: repository.path) {
            do {
                while true {
                    // Coming back to the app reads it again, so nothing's
                    // read while Gannin is in the background.
                    if NSApp.isActive { await repository.refresh() }
                    try await Task.sleep(for: .seconds(10))
                }
            } catch {}
        }
        // Fetch in the background while the page is open: git's own, so
        // nothing of GitHub's API budget.
        .task(id: repository.root) {
            do {
                try await Task.sleep(for: .seconds(2))
                while true {
                    await repository.fetch(quietly: true)
                    try await Task.sleep(for: .seconds(300))
                }
            } catch {}
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await repository.refresh() }
        }
        .confirmationDialog(
            "You have changes on \(repository.status?.branch ?? "this branch")",
            isPresented: Binding(get: { repository.switching != nil }, set: { if !$0 { repository.switching = nil } }),
            presenting: repository.switching
        ) { branch in
            Button("Leave Them on \(repository.status?.branch ?? "This Branch")") {
                Task { await repository.switchTo(branch, leavingChanges: true) }
            }
            Button("Bring Them to \(branch.localName)") {
                Task { await repository.switchTo(branch, leavingChanges: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Left behind, they're stashed and offered back when you return to this branch. Brought along, git keeps them if they don't clash with the other branch.")
        }
        .confirmationDialog("Your branch and its upstream have both moved on", isPresented: $repository.reconciling) {
            Button("Merge") { Task { await repository.pull(rebase: false) } }
            Button("Rebase") { Task { await repository.pull(rebase: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Merge makes a merge commit of the two; rebase puts your commits on top of theirs. Set pull.rebase in your git config to choose once.")
        }
        .confirmationDialog("Force push \(repository.status?.branch ?? "the branch")?", isPresented: $repository.confirmingForcePush) {
            Button("Force Push", role: .destructive) { Task { await repository.push(force: true) } }
        } message: {
            Text("Your branch replaces the one on its remote, unless it has commits you haven't had in this branch, even ones a background fetch brought in (--force-with-lease --force-if-includes).")
        }
        .modifier(BranchDialogs(repository: repository))
        .sheet(item: $repository.creatingBranch) { request in
            NewBranchSheet(repository: repository, base: request.base)
        }
        .sheet(item: $repository.creatingWorktree) { request in
            NewWorktreeSheet(repository: repository, branch: request.branch)
        }
        .sheet(item: $repository.creatingTag) { request in
            NewTagSheet(repository: repository, target: request.target)
        }
        .sheet(isPresented: Binding(get: { repository.actionError != nil }, set: { if !$0 { repository.actionError = nil } })) {
            GitOutputSheet(title: "Couldn't do that", output: repository.actionError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = repository.error, repository.snapshot == nil {
            ContentUnavailableView {
                Label("Couldn't read the clone", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(SessionStore.tildePath(URL(filePath: LocalClones.expand(repository.path)))): \(error)")
            } actions: {
                Button("Try Again") { Task { await repository.refresh() } }
                Button("Use Another Folder") { chooseFolder() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !repository.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch part {
            case .history: RepositoryHistoryView(repository: repository)
            case .changes: RepositoryChangesView(repository: repository)
            }
        }
    }

    // MARK: Bar

    private var syncMenu: some View {
        let status = repository.status
        let hasUpstream = status?.upstream != nil
        return Menu {
            Button("Fetch") { Task { await repository.fetch() } }
            Button("Pull") { Task { await repository.pull() } }
                .disabled(!hasUpstream)
            Button(hasUpstream ? "Push" : "Publish Branch") { Task { await repository.push() } }
                .disabled(status?.branch == nil)
            Divider()
            Button("Force Push") { repository.confirmingForcePush = true }
                .disabled(!hasUpstream)
        } label: {
            Label(syncTitle, systemImage: syncImage)
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        } primaryAction: {
            Task { await repository.sync() }
        }
        .disabled(repository.busy != nil)
        .help(syncHelp)
    }

    private var syncTitle: String {
        if let busy = repository.busy { return busy }
        let status = repository.status
        let ahead = status?.ahead ?? 0
        let behind = status?.behind ?? 0
        switch repository.syncAction {
        case .publish: return "Publish Branch"
        case .pull: return ahead > 0 ? "Pull ↓\(behind) ↑\(ahead)" : "Pull ↓\(behind)"
        case .push: return "Push ↑\(ahead)"
        case .fetch: return "Fetch"
        }
    }

    private var syncImage: String {
        switch repository.syncAction {
        case .publish: "icloud.and.arrow.up"
        case .pull: "arrow.down.circle"
        case .push: "arrow.up.circle"
        case .fetch: "arrow.triangle.2.circlepath"
        }
    }

    private var syncHelp: String {
        var lines: [String] = []
        if let upstream = repository.status?.upstream {
            lines.append("Tracking \(upstream)")
        }
        if let fetched = repository.lastFetched {
            lines.append("Fetched \(fetched.formatted(.relative(presentation: .named)))")
        }
        if let failure = repository.fetchError {
            lines.append("The last fetch failed: \(failure)")
        }
        return lines.isEmpty ? "Fetch, pull and push" : lines.joined(separator: "\n")
    }

    private var openMenu: some View {
        Menu {
            Button("Open in \(CodeEditor.chosen.name)") { repository.openInEditor() }
            Button("Open in Terminal") { repository.openInTerminal() }
            Button("Show in Finder") { repository.revealInFinder() }
            if let url = URL(string: "https://github.com/\(repository.repo)") {
                Link("Open on GitHub", destination: url)
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(LocalClones.expand(repository.path), forType: .string)
            }
            Button("Use Another Folder") { chooseFolder() }
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        .help("Open the worktree in your editor, Terminal or Finder")
    }

    private func chooseFolder() {
        guard let url = GitFolders.choose(message: "Choose your clone of \(repository.repo).") else { return }
        if let problem = GitFolders.problem(with: url, for: repository.repo) {
            repository.actionError = problem
            return
        }
        LocalClones.save(SessionStore.tildePath(url), for: repository.repo)
        UserDefaults.standard.removeObject(forKey: LocalRepository.worktreeKey(repository.repo))
        relocate()
    }
}

/// Picking a clone's folder.
enum GitFolders {
    static func choose(message: String, prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Why the folder isn't a clone of the repo, if it isn't.
    static func problem(with url: URL, for repo: String) -> String? {
        let path = url.path
        guard LocalClones.isGitFolder(path) else { return "\(SessionStore.tildePath(url)) isn't a git checkout." }
        // A worktree's `.git` is a file, with no config of its own to read.
        let remotes = LocalClones.remotes(of: path)
        if !remotes.isEmpty, !LocalClones.isCheckout(path, of: repo) {
            return "\(SessionStore.tildePath(url)) is a clone of \(remotes.joined(separator: ", ")), not \(repo)."
        }
        return nil
    }
}

/// A repo with no clone here: clone it, or add one you have.
struct NotClonedView: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    let repo: String
    let found: () -> Void
    @State private var cloning = false
    @State private var error: String?

    var body: some View {
        let destination = LocalClones.destination(repo, org: org, config: configs.config(for: org))
        VStack(spacing: 12) {
            if cloning {
                ProgressView("Cloning \(repo)")
            } else {
                ContentUnavailableView {
                    Label("\(repo.split(separator: "/").last.map(String.init) ?? repo) isn't on this Mac", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Clone it into \(destination) to work on it here, or add a clone you already have.")
                } actions: {
                    Button("Clone") { Task { await clone(to: destination, saving: false) } }
                        .buttonStyle(.borderedProminent)
                    Button("Clone To") {
                        guard let folder = GitFolders.choose(message: "Choose where the clone of \(repo) goes. It's put in a folder of its own there.", prompt: "Clone Here") else { return }
                        let name = repo.split(separator: "/").last.map(String.init) ?? repo
                        Task { await clone(to: SessionStore.tildePath(folder.appending(path: name)), saving: true) }
                    }
                    Button("Add Existing Clone") { addExisting() }
                }
            }
            if let error {
                Text(error)
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clone(to path: String, saving: Bool) async {
        cloning = true
        error = await LocalClones.clone(repo, to: path)
        cloning = false
        guard error == nil else { return }
        if saving { LocalClones.save(path, for: repo) }
        found()
    }

    private func addExisting() {
        guard let url = GitFolders.choose(message: "Choose your clone of \(repo).") else { return }
        if let problem = GitFolders.problem(with: url, for: repo) {
            error = problem
            return
        }
        LocalClones.save(SessionStore.tildePath(url), for: repo)
        found()
    }
}

/// What git said, in full: a hook's complaint can run to many lines.
struct GitOutputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(output)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 320)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}

/// The bar at the top of a repo's page, as other pages have one: the part
/// picker, then what acts on the clone.
private struct RepositoryBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct RepositoryPartPicker: View {
    @Binding var part: RepositoryPart

    var body: some View {
        Picker("Show", selection: $part) {
            ForEach(RepositoryPart.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
