import SwiftUI

/// The clone's worktrees, its branches with where they stand against their
/// upstream, and origin's branches not here yet.
struct RepositoryBranchesView: View {
    let repository: LocalRepository
    @State private var search = ""
    @State private var renaming: GitBranch?
    @State private var deleting: GitBranch?
    /// Refused by `-d` for holding commits merged nowhere.
    @State private var forcing: (branch: GitBranch, onOrigin: Bool)?
    @State private var removing: GitWorktree?
    /// Refused for holding changes.
    @State private var forcingRemoval: GitWorktree?

    var body: some View {
        let local = repository.branches.filter { !$0.isRemote && matches($0.name) }
        let localNames = Set(repository.branches.filter { !$0.isRemote }.map(\.name))
        let remote = repository.branches.filter { $0.isRemote && !localNames.contains($0.localName) && matches($0.name) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FilterSearchField(text: $search, prompt: "Branches")
                Spacer()
                Button("New Worktree") { repository.creatingWorktree = CreateWorktreeRequest() }
                Button("New Branch") { repository.creatingBranch = CreateBranchRequest(base: repository.status?.branch ?? "HEAD") }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List {
                Section {
                    ForEach(repository.worktrees) { worktreeRow($0) }
                } header: {
                    HStack {
                        SectionHeader(title: "Worktrees", count: repository.worktrees.count)
                        Spacer()
                        if repository.worktrees.contains(where: \.isPrunable) {
                            Button("Prune") { Task { await repository.pruneWorktrees() } }
                                .buttonStyle(.link)
                                .font(.caption)
                                .help("Forget worktrees whose folders are gone")
                        }
                    }
                }
                Section {
                    ForEach(local) { branchRow($0) }
                } header: {
                    SectionHeader(title: "Branches", count: local.count)
                }
                if !remote.isEmpty {
                    Section {
                        ForEach(remote) { branchRow($0) }
                    } header: {
                        SectionHeader(title: "Only on origin", count: remote.count)
                    }
                }
            }
        }
        .sheet(item: $renaming) { branch in
            RenameBranchSheet(repository: repository, branch: branch)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "the branch")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { branch in
            if branch.isRemote {
                Button("Delete on origin", role: .destructive) { delete(branch, here: false, onOrigin: true) }
            } else {
                Button("Delete Here", role: .destructive) { delete(branch, here: true, onOrigin: false) }
                if branch.upstream != nil, !branch.upstreamGone {
                    Button("Delete Here and on origin", role: .destructive) { delete(branch, here: true, onOrigin: true) }
                }
            }
        } message: { branch in
            Text(branch.isRemote ? "It's deleted on GitHub for everyone." : "Deleting it on origin deletes it on GitHub for everyone, and closes any open pull request from it.")
        }
        .confirmationDialog("\(forcing?.branch.name ?? "It") has commits that aren't merged", isPresented: Binding(get: { forcing != nil }, set: { if !$0 { forcing = nil } }), presenting: forcing) { forcing in
            Button("Delete Anyway", role: .destructive) {
                Task {
                    if let failure = await repository.deleteBranch(forcing.branch, here: true, onOrigin: forcing.onOrigin, force: true) {
                        repository.actionError = failure
                    }
                }
            }
        } message: { _ in
            Text("Those commits are on no other branch, so they're lost unless they're pushed somewhere.")
        }
        .confirmationDialog("Remove the worktree at \(removing.map { SessionStore.tildePath(URL(filePath: $0.path)) } ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { worktree in
            Button("Remove", role: .destructive) {
                Task {
                    guard let failure = await repository.removeWorktree(worktree, force: false) else { return }
                    if failure.contains("modified or untracked") || failure.contains("--force") {
                        forcingRemoval = worktree
                    } else {
                        repository.actionError = failure
                    }
                }
            }
        } message: { worktree in
            Text("Its folder is deleted. The branch \(worktree.branch ?? "it's on") stays.")
        }
        .confirmationDialog("The worktree has changes", isPresented: Binding(get: { forcingRemoval != nil }, set: { if !$0 { forcingRemoval = nil } }), presenting: forcingRemoval) { worktree in
            Button("Remove Anyway", role: .destructive) {
                Task {
                    if let failure = await repository.removeWorktree(worktree, force: true) { repository.actionError = failure }
                }
            }
        } message: { _ in
            Text("What isn't committed in it is lost.")
        }
    }

    private func matches(_ name: String) -> Bool {
        let words = search.lowercased().split(separator: " ")
        return words.allSatisfy { name.lowercased().contains($0) }
    }

    private func delete(_ branch: GitBranch, here: Bool, onOrigin: Bool) {
        Task {
            guard let failure = await repository.deleteBranch(branch, here: here, onOrigin: onOrigin) else { return }
            if failure.contains("not fully merged") {
                forcing = (branch, onOrigin)
            } else {
                repository.actionError = failure
            }
        }
    }

    // MARK: Rows

    private func worktreeRow(_ worktree: GitWorktree) -> some View {
        let isCurrent = LocalRepository.samePath(worktree.path, repository.path)
        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "folder.fill" : "folder")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(worktree.branch ?? "Detached at \(worktree.head ?? "?")")
                    if worktree.isMain { Pill(text: "Clone", color: .gray) }
                    if worktree.isPrunable { Pill(text: "Folder gone", color: .orange) }
                    if worktree.isLocked { Pill(text: "Locked", color: .gray) }
                }
                Text(SessionStore.tildePath(URL(filePath: worktree.path)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isCurrent {
                Text("Working here").font(.caption).foregroundStyle(.secondary)
            } else if !worktree.isPrunable {
                Button("Work Here") { repository.use(worktree: worktree.path) }
                    .controlSize(.small)
            }
        }
        .contextMenu {
            if !isCurrent, !worktree.isPrunable {
                Button("Work Here") { repository.use(worktree: worktree.path) }
            }
            Button("Open in \(CodeEditor.chosen.name)") { CodeEditor.chosen.open(worktree.path, line: nil, host: nil) }
                .disabled(worktree.isPrunable)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: worktree.path)]) }
                .disabled(worktree.isPrunable)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path, forType: .string)
            }
            if !worktree.isMain {
                Divider()
                Button("Remove", role: .destructive) { removing = worktree }
            }
        }
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        let isCurrent = !branch.isRemote && branch.name == repository.status?.branch
        let elsewhere = repository.worktree(holding: branch)
        return HStack(spacing: 8) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : branch.isRemote ? "cloud" : "arrow.triangle.branch")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(branch.name).fontWeight(isCurrent ? .semibold : .regular)
                    if branch.name == repository.snapshot?.defaultBranch, !branch.isRemote { Pill(text: "Default", color: .gray) }
                    if let elsewhere { Pill(text: "In \((elsewhere as NSString).lastPathComponent)", color: .purple) }
                }
                Text(branch.subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !branch.isRemote { upstream(branch) }
            Text(branch.date.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .trailing)
            if !isCurrent {
                Button("Switch") { repository.requestSwitch(to: branch) }
                    .controlSize(.small)
                    .disabled(elsewhere != nil)
                    .help(elsewhere.map { "Checked out in \(SessionStore.tildePath(URL(filePath: $0)))" } ?? "Switch to \(branch.localName)")
            }
        }
        .contextMenu { branchMenu(branch, isCurrent: isCurrent, elsewhere: elsewhere) }
    }

    @ViewBuilder
    private func upstream(_ branch: GitBranch) -> some View {
        Group {
            if branch.upstreamGone {
                Text("Gone from origin").foregroundStyle(.orange)
            } else if branch.upstream == nil {
                Text("Not published").foregroundStyle(.secondary)
            } else if branch.ahead > 0 || branch.behind > 0 {
                HStack(spacing: 4) {
                    if branch.ahead > 0 { Text("↑\(branch.ahead)") }
                    if branch.behind > 0 { Text("↓\(branch.behind)") }
                }
                .help("\(branch.ahead) to push, \(branch.behind) to pull, against \(branch.upstream ?? "its upstream")")
            }
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    private func branchMenu(_ branch: GitBranch, isCurrent: Bool, elsewhere: String?) -> some View {
        if !isCurrent {
            Button("Switch to \(branch.localName)") { repository.requestSwitch(to: branch) }
                .disabled(elsewhere != nil)
        }
        if let elsewhere {
            Button("Work in Its Worktree") { repository.use(worktree: elsewhere) }
        } else if !isCurrent {
            Button("New Worktree for \(branch.localName)") { repository.creatingWorktree = CreateWorktreeRequest(branch: branch) }
        }
        Button("New Branch from \(branch.name)") { repository.creatingBranch = CreateBranchRequest(base: branch.name) }
        Divider()
        if !branch.isRemote {
            if branch.upstream == nil || branch.upstreamGone {
                Button("Publish") { Task { await repository.publish(branch) } }
            }
            Button("Rename") { renaming = branch }
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch.localName, forType: .string)
        }
        Divider()
        Button(branch.isRemote ? "Delete on origin" : "Delete", role: .destructive) { deleting = branch }
            .disabled(isCurrent || elsewhere != nil)
    }
}

/// A short name for a branch: spaces become hyphens, as git won't have them.
private func branchName(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
}

/// A new branch from a base, switched to or not.
struct NewBranchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: LocalRepository
    @State var base: String
    @State private var name = ""
    @State private var switching = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("123-short-title"))
                BaseField(repository: repository, base: $base)
                Toggle("Switch to it", isOn: $switching)
            } header: {
                Text("New branch in \(repository.repo)")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text("It doesn't track its base, so its first push publishes it under its own name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create Branch") {
                    Task {
                        working = true
                        error = await repository.createBranch(branchName(name), from: base, switching: switching)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(branchName(name).isEmpty || base.isEmpty || working)
            }
        }
    }
}

/// Where a branch or worktree starts: typed, or picked from the current
/// branch, the default and the other branches.
private struct BaseField: View {
    let repository: LocalRepository
    @Binding var base: String

    var body: some View {
        HStack {
            TextField("From", text: $base)
            Menu {
                if let current = repository.status?.branch { Button(current) { base = current } }
                if let main = repository.snapshot?.defaultBranch { Button("origin/\(main)") { base = "origin/\(main)" } }
                Divider()
                ForEach(repository.branches.prefix(30)) { branch in
                    Button(branch.name) { base = branch.name }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private struct RenameBranchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: LocalRepository
    let branch: GitBranch
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } header: {
                Text("Rename \(branch.name)")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else if branch.upstream != nil {
                    Text("Only here: the branch on origin keeps its name until you publish this one and delete that.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { name = branch.name }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename") {
                    Task {
                        error = await repository.renameBranch(branch, to: branchName(name))
                        if error == nil { dismiss() }
                    }
                }
                .disabled(branchName(name).isEmpty || branchName(name) == branch.name)
            }
        }
    }
}

/// A worktree for a new branch or one there already, in a folder beside
/// the session worktrees.
struct NewWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: LocalRepository
    let branch: GitBranch?
    @State private var isNew = true
    @State private var name = ""
    @State private var base = ""
    @State private var existing = ""
    @State private var path = ""
    /// Typed or chosen, so it no longer follows the branch's name.
    @State private var pathEdited = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        // Branches free to check out: local ones in no worktree, and
        // origin's with no local branch yet.
        let localNames = Set(repository.branches.filter { !$0.isRemote }.map(\.name))
        let choices = repository.branches.filter { $0.isRemote ? !localNames.contains($0.localName) : $0.worktree == nil }
        Form {
            Section {
                Picker("Branch", selection: $isNew) {
                    Text("New branch").tag(true)
                    Text("Existing branch").tag(false)
                }
                .pickerStyle(.segmented)
                if isNew {
                    TextField("Name", text: $name, prompt: Text("123-short-title"))
                    BaseField(repository: repository, base: $base)
                } else {
                    Picker("Branch", selection: $existing) {
                        ForEach(choices) { branch in
                            Text(branch.name).tag(branch.localName)
                        }
                    }
                }
                HStack {
                    TextField("Folder", text: Binding(get: { path }, set: { path = $0; pathEdited = true }))
                    Button("Choose") {
                        if let url = GitFolders.choose(message: "Choose the folder for the worktree. It's created if it's new, and must be empty.") {
                            path = SessionStore.tildePath(url)
                            pathEdited = true
                        }
                    }
                }
            } header: {
                Text("New worktree of \(repository.repo)")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text("A worktree is another checkout of the same clone, on its own branch, so work on two branches can sit side by side.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            base = repository.snapshot?.defaultBranch.map { "origin/\($0)" } ?? repository.status?.branch ?? "HEAD"
            if let branch {
                isNew = false
                existing = branch.localName
            } else {
                existing = choices.first?.localName ?? ""
            }
            suggestPath()
        }
        .onChange(of: name) { suggestPath() }
        .onChange(of: existing) { suggestPath() }
        .onChange(of: isNew) { suggestPath() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create Worktree") {
                    Task {
                        working = true
                        error = await repository.addWorktree(at: path, branch: chosenBranch, newFrom: isNew ? base : nil)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(chosenBranch.isEmpty || path.isEmpty || (isNew && base.isEmpty) || working)
            }
        }
    }

    private var chosenBranch: String { isNew ? branchName(name) : existing }

    private func suggestPath() {
        guard !pathEdited, !chosenBranch.isEmpty else { return }
        path = repository.suggestedWorktreePath(branch: chosenBranch)
    }
}
