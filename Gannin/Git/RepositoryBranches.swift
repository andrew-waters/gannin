import SwiftUI

/// The branch button beside the repo switcher: a popover of the clone's
/// branches and origin's, searchable from the keyboard (arrows, Return to
/// switch), with each one's ahead and behind and the worktree holding it.
struct BranchPopoverButton: View {
    let repository: LocalRepository
    @State private var shown = false

    var body: some View {
        let status = repository.status
        Button {
            shown.toggle()
        } label: {
            Label(status?.branch ?? "Detached at \(status?.head ?? "?")", systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
        }
        .help("Branches: switch, create, publish, rename and delete")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            BranchPopover(repository: repository) { shown = false }
        }
    }
}

private struct BranchPopover: View {
    let repository: LocalRepository
    let close: () -> Void
    @State private var query = ""
    @State private var highlighted: GitBranch.ID?
    @FocusState private var searching: Bool

    var body: some View {
        let local = repository.branches.filter { !$0.isRemote && matches($0) }
        let localNames = Set(repository.branches.filter { !$0.isRemote }.map(\.name))
        let remote = repository.branches.filter { $0.isRemote && !localNames.contains($0.localName) && matches($0) }
        let all = local + remote
        VStack(spacing: 0) {
            PopoverSearchField(text: $query, prompt: "Branches", focused: $searching) {
                if let branch = all.first(where: { $0.id == highlighted }) { pick(branch) }
            } move: { step in
                move(step, in: all)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !local.isEmpty { heading("Branches") }
                        ForEach(local) { row($0) }
                        if !remote.isEmpty { heading("Only on origin") }
                        ForEach(remote) { row($0) }
                        if all.isEmpty {
                            Text("No branch matches").foregroundStyle(.secondary).padding(10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            HStack {
                Button("New Branch") {
                    close()
                    repository.creatingBranch = CreateBranchRequest(base: repository.status?.branch ?? "HEAD")
                }
                Spacer()
                Text("Return switches; right-click for more").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(8)
        }
        .frame(width: 440)
        .frame(minHeight: 200, maxHeight: 460)
        .onAppear {
            highlighted = repository.branches.first { !$0.isRemote && $0.name == repository.status?.branch }?.id ?? all.first?.id
            searching = true
        }
        .onChange(of: query) { highlighted = all.first?.id }
    }

    private func matches(_ branch: GitBranch) -> Bool {
        query.lowercased().split(separator: " ").allSatisfy { branch.name.lowercased().contains($0) }
    }

    private func move(_ step: Int, in all: [GitBranch]) {
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : all.count)
        highlighted = all[max(0, min(all.count - 1, index + step))].id
    }

    /// Switches to it, or works in its worktree when another has it.
    private func pick(_ branch: GitBranch) {
        guard branch.name != repository.status?.branch || branch.isRemote else { return close() }
        close()
        if let elsewhere = repository.worktree(holding: branch) {
            repository.use(worktree: elsewhere)
        } else {
            repository.requestSwitch(to: branch)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ branch: GitBranch) -> some View {
        let isCurrent = !branch.isRemote && branch.name == repository.status?.branch
        let elsewhere = repository.worktree(holding: branch)
        let isHighlighted = branch.id == highlighted
        return Button {
            pick(branch)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isCurrent ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(branch.name).lineLimit(1).truncationMode(.middle)
                        if branch.name == repository.snapshot?.defaultBranch, !branch.isRemote { Pill(text: "Default", color: .gray) }
                        if let elsewhere { Pill(text: "In \((elsewhere as NSString).lastPathComponent)", color: .purple) }
                    }
                    Text(branch.subject)
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if !branch.isRemote { upstream(branch) }
                Text(branch.date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(branch.id)
        .onHover { if $0 { highlighted = branch.id } }
        .help(elsewhere.map { "Checked out in \(SessionStore.tildePath(URL(filePath: $0))): Return works there" } ?? branch.name)
        .contextMenu { menu(branch, isCurrent: isCurrent, elsewhere: elsewhere) }
    }

    private func upstream(_ branch: GitBranch) -> some View {
        Group {
            if branch.upstreamGone {
                Text("Gone from origin").foregroundStyle(.orange)
            } else if branch.upstream == nil {
                Text("Not published")
            } else if branch.ahead > 0 || branch.behind > 0 {
                Text([branch.ahead > 0 ? "↑\(branch.ahead)" : nil, branch.behind > 0 ? "↓\(branch.behind)" : nil].compactMap { $0 }.joined(separator: " "))
            }
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder
    private func menu(_ branch: GitBranch, isCurrent: Bool, elsewhere: String?) -> some View {
        if !isCurrent {
            Button("Switch to \(branch.localName)") { pick(branch) }
                .disabled(elsewhere != nil)
        }
        if let elsewhere {
            Button("Work in Its Worktree") { close(); repository.use(worktree: elsewhere) }
        } else if !isCurrent {
            Button("New Worktree for \(branch.localName)") { close(); repository.creatingWorktree = CreateWorktreeRequest(branch: branch) }
        }
        Button("New Branch from \(branch.name)") { close(); repository.creatingBranch = CreateBranchRequest(base: branch.name) }
        Divider()
        if !branch.isRemote {
            if branch.upstream == nil || branch.upstreamGone {
                Button("Publish") { Task { await repository.publish(branch) } }
            }
            Button("Rename") { close(); repository.renamingBranch = branch }
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch.localName, forType: .string)
        }
        Divider()
        Button(branch.isRemote ? "Delete on origin" : "Delete", role: .destructive) { close(); repository.deletingBranch = branch }
            .disabled(isCurrent || elsewhere != nil)
    }
}

/// The worktree button beside the branch one: a popover of the clone's
/// worktrees, the one worked in ticked; picking another works there.
struct WorktreePopoverButton: View {
    let repository: LocalRepository
    @State private var shown = false

    var body: some View {
        let current = repository.currentWorktree
        Button {
            shown.toggle()
        } label: {
            Label(current.map { $0.isMain ? "Clone" : $0.name } ?? "Worktree", systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .help(repository.worktrees.count > 1 ? "\(repository.worktrees.count) worktrees: which one this page works in" : "Worktrees: work on another branch beside this one")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            WorktreePopover(repository: repository) { shown = false }
        }
    }
}

private struct WorktreePopover: View {
    let repository: LocalRepository
    let close: () -> Void
    @State private var highlighted: GitWorktree.ID?
    @FocusState private var focused: Bool

    var body: some View {
        let worktrees = repository.worktrees
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(worktrees) { row($0) }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack {
                Button("New Worktree") {
                    close()
                    repository.creatingWorktree = CreateWorktreeRequest()
                }
                if worktrees.contains(where: \.isPrunable) {
                    Button("Prune") { Task { await repository.pruneWorktrees() } }
                        .help("Forget worktrees whose folders are gone")
                }
                Spacer()
            }
            .controlSize(.small)
            .padding(8)
        }
        .frame(width: 440)
        .frame(minHeight: 120, maxHeight: 420)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1, in: worktrees) }
        .onKeyPress(.upArrow) { move(-1, in: worktrees) }
        .onKeyPress(.return) {
            if let worktree = worktrees.first(where: { $0.id == highlighted }) { pick(worktree) }
            return .handled
        }
        .onAppear {
            highlighted = repository.currentWorktree?.id ?? worktrees.first?.id
            focused = true
        }
    }

    private func move(_ step: Int, in all: [GitWorktree]) -> KeyPress.Result {
        guard !all.isEmpty else { return .ignored }
        let index = all.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : all.count)
        highlighted = all[max(0, min(all.count - 1, index + step))].id
        return .handled
    }

    private func pick(_ worktree: GitWorktree) {
        guard !worktree.isPrunable else { return }
        close()
        repository.use(worktree: worktree.path)
    }

    private func row(_ worktree: GitWorktree) -> some View {
        let isCurrent = LocalRepository.samePath(worktree.path, repository.path)
        let isHighlighted = worktree.id == highlighted
        return Button {
            pick(worktree)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isCurrent ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(worktree.branch ?? "Detached at \(worktree.head ?? "?")").lineLimit(1)
                        if worktree.isMain { Pill(text: "Clone", color: .gray) }
                        if worktree.isPrunable { Pill(text: "Folder gone", color: .orange) }
                        if worktree.isLocked { Pill(text: "Locked", color: .gray) }
                    }
                    Text(SessionStore.tildePath(URL(filePath: worktree.path)))
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = worktree.id } }
        .contextMenu {
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
                Button("Remove", role: .destructive) { close(); repository.removingWorktree = worktree }
            }
        }
    }
}

/// A search field for a popover list: arrows move through the list and
/// Return picks, as the Mac's own pickers do.
struct PopoverSearchField: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.7), in: Capsule())
        .padding(10)
    }
}

/// What the branch and worktree popovers ask about, shown over the page
/// once the popover has closed: rename, delete (forced when unmerged) and
/// remove a worktree (forced when it has changes).
struct BranchDialogs: ViewModifier {
    @Bindable var repository: LocalRepository
    @State private var forcing: GitBranch?
    @State private var forcingOnOrigin = false
    @State private var forcingRemoval: GitWorktree?

    func body(content: Content) -> some View {
        content
            .sheet(item: $repository.renamingBranch) { branch in
                RenameBranchSheet(repository: repository, branch: branch)
            }
            .confirmationDialog("Delete \(repository.deletingBranch?.name ?? "the branch")?", isPresented: Binding(get: { repository.deletingBranch != nil }, set: { if !$0 { repository.deletingBranch = nil } }), presenting: repository.deletingBranch) { branch in
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
            .confirmationDialog("\(forcing?.name ?? "It") has commits that aren't merged", isPresented: Binding(get: { forcing != nil }, set: { if !$0 { forcing = nil } }), presenting: forcing) { branch in
                Button("Delete Anyway", role: .destructive) {
                    let onOrigin = forcingOnOrigin
                    Task {
                        if let failure = await repository.deleteBranch(branch, here: true, onOrigin: onOrigin, force: true) {
                            repository.actionError = failure
                        }
                    }
                }
            } message: { _ in
                Text("Those commits are on no other branch, so they're lost unless they're pushed somewhere.")
            }
            .confirmationDialog("Remove the worktree at \(repository.removingWorktree.map { SessionStore.tildePath(URL(filePath: $0.path)) } ?? "")?", isPresented: Binding(get: { repository.removingWorktree != nil }, set: { if !$0 { repository.removingWorktree = nil } }), presenting: repository.removingWorktree) { worktree in
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

    private func delete(_ branch: GitBranch, here: Bool, onOrigin: Bool) {
        Task {
            guard let failure = await repository.deleteBranch(branch, here: here, onOrigin: onOrigin) else { return }
            if failure.contains("not fully merged") {
                forcingOnOrigin = onOrigin
                forcing = branch
            } else {
                repository.actionError = failure
            }
        }
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

struct RenameBranchSheet: View {
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
