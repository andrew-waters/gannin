import SwiftUI

/// What isn't committed in the worktree: conflicts, staged and unstaged
/// files with their diffs, staged and discarded by file or hunk, and the
/// commit.
struct RepositoryChangesView: View {
    @Bindable var repository: LocalRepository
    @State private var discarding: GitFileChange?

    var body: some View {
        FixedSplit(key: "repositoryChangesListWidth", width: 360, range: 260...620) {
            VStack(spacing: 0) {
                banners
                fileList
                Divider()
                CommitComposer(repository: repository)
            }
        } trailing: {
            GitDiffView(repository: repository)
        }
        .confirmationDialog(
            "Discard the changes to \(discarding?.name ?? "the file")?",
            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
            presenting: discarding
        ) { file in
            Button(file.area == .untracked ? "Delete File" : "Discard Changes", role: .destructive) {
                Task { await repository.discard(file) }
            }
        } message: { file in
            Text(Self.discardMessage(file))
        }
    }

    private static func discardMessage(_ file: GitFileChange) -> String {
        switch file.area {
        case .untracked: "It's new and not in git, so it's deleted."
        case .unstaged: "It goes back to what's staged, or to the last commit if nothing is."
        case .staged, .conflicted: "It goes back to the last commit, staged changes and all."
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if let status = repository.status {
            if let operation = status.operation {
                let conflicts = status.files(in: .conflicted).count
                banner(
                    conflicts > 0 ? "\(operation.title): \(conflicts == 1 ? "1 file" : "\(conflicts) files") in conflict" : "\(operation.title): conflicts resolved",
                    systemImage: "exclamationmark.triangle.fill", tint: .orange
                ) {
                    Button("Abort") { Task { await repository.abortOperation() } }
                    Button("Continue") { Task { await repository.continueOperation() } }
                        .disabled(conflicts > 0)
                        .help(conflicts > 0 ? "Resolve and stage every conflicted file first" : "Carry on with the \(operation.rawValue)")
                }
            }
            if status.leftHere != nil {
                banner("You left changes here when you switched branch", systemImage: "tray.and.arrow.down", tint: .accentColor) {
                    Button("Drop") { Task { await repository.dropLeftChanges() } }
                    Button("Restore") { Task { await repository.restoreLeftChanges() } }
                }
            }
            if status.branch == nil, status.head != nil {
                banner("Not on a branch: at \(status.head ?? "")", systemImage: "arrow.triangle.branch", tint: .secondary) {
                    Button("New Branch Here") { repository.creatingBranch = CreateBranchRequest(base: "HEAD") }
                }
            }
        }
        // Still showing what was read last.
        if let error = repository.error, repository.snapshot != nil {
            banner(error, systemImage: "exclamationmark.circle", tint: .secondary) { EmptyView() }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(text)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions()
            }
            .font(.callout)
            .controlSize(.small)
            .padding(8)
            .background(.bar)
            Divider()
        }
    }

    // MARK: Files

    private var fileList: some View {
        let status = repository.status ?? GitStatus()
        let conflicted = status.files(in: .conflicted)
        let staged = status.files(in: .staged)
        let unstaged = status.files.filter { $0.area == .unstaged || $0.area == .untracked }
        return List(selection: $repository.selected) {
            if !conflicted.isEmpty {
                conflictedSection(conflicted)
            }
            stagedSection(staged)
            unstagedSection(unstaged, nothingElse: staged.isEmpty && conflicted.isEmpty)
        }
        .frame(maxHeight: .infinity)
    }

    private func conflictedSection(_ files: [GitFileChange]) -> some View {
        Section {
            ForEach(files) { row($0) }
        } header: {
            SectionHeader(title: "Conflicted", count: files.count)
        }
    }

    private func stagedSection(_ files: [GitFileChange]) -> some View {
        Section {
            if files.isEmpty {
                Text("Nothing staged").foregroundStyle(.secondary)
            }
            ForEach(files) { row($0) }
        } header: {
            sectionHeader("Staged", count: files.count, action: "Unstage All") {
                Task { await repository.unstageAll() }
            }
        }
    }

    private func unstagedSection(_ files: [GitFileChange], nothingElse: Bool) -> some View {
        Section {
            if files.isEmpty {
                Text(nothingElse ? "No changes" : "Nothing else changed").foregroundStyle(.secondary)
            }
            ForEach(files) { row($0) }
        } header: {
            sectionHeader("Changes", count: files.count, action: "Stage All") {
                Task { await repository.stageAll() }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            SectionHeader(title: title, count: count)
            Spacer()
            if count > 0 {
                Button(action, action: perform)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func row(_ file: GitFileChange) -> some View {
        GitFileRow(file: file) {
            Task {
                switch file.area {
                case .staged: await repository.unstage(file)
                case .conflicted: await repository.markResolved(file)
                case .unstaged, .untracked: await repository.stage(file)
                }
            }
        }
        .tag(file.id)
        .contextMenu { menu(file) }
    }

    @ViewBuilder
    private func menu(_ file: GitFileChange) -> some View {
        switch file.area {
        case .conflicted:
            Button("Take Ours") { Task { await repository.takeOurs(file) } }
            Button("Take Theirs") { Task { await repository.takeTheirs(file) } }
            Button("Mark Resolved") { Task { await repository.markResolved(file) } }
        case .staged:
            Button("Unstage") { Task { await repository.unstage(file) } }
        case .unstaged, .untracked:
            Button("Stage") { Task { await repository.stage(file) } }
        }
        Button(file.area == .untracked ? "Delete File" : "Discard Changes", role: .destructive) { discarding = file }
        Divider()
        Button("Open in \(CodeEditor.chosen.name)") { repository.openInEditor(file) }
            .disabled(file.status == "D")
        Button("Show in Finder") { repository.revealInFinder(file) }
            .disabled(file.status == "D")
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
    }
}

/// A changed file: what happened to it, its name and folder, lines added
/// and removed, and a button to stage it, unstage it or mark it resolved.
private struct GitFileRow: View {
    let file: GitFileChange
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(file.status == "?" ? "A" : file.status)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 12)
            Text(file.name)
                .lineLimit(1)
            if !file.folder.isEmpty {
                Text(file.folder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if file.isBinary {
                Text("binary").foregroundStyle(.secondary)
            } else if file.area != .conflicted {
                if file.added > 0 { Text("+\(file.added)").foregroundStyle(ChartPalette.good) }
                if file.removed > 0 { Text("-\(file.removed)").foregroundStyle(ChartPalette.critical) }
            }
            Button(action: toggle) {
                Image(systemName: toggleImage)
            }
            .buttonStyle(.borderless)
            .help(toggleHelp)
        }
        .font(.callout)
        .monospacedDigit()
        .help(file.path)
    }

    private var toggleImage: String {
        switch file.area {
        case .staged: "minus.circle"
        case .conflicted: "checkmark.circle"
        case .unstaged, .untracked: "plus.circle"
        }
    }

    private var toggleHelp: String {
        switch file.area {
        case .staged: "Unstage"
        case .conflicted: "Mark resolved: stage it as it is now"
        case .unstaged, .untracked: "Stage"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case "A", "?": ChartPalette.good
        case "D": ChartPalette.critical
        case "U": .red
        default: .orange
        }
    }
}

/// The selected file's diff, numbered on both sides, with each hunk's
/// Stage, Unstage or Discard.
private struct GitDiffView: View {
    @Bindable var repository: LocalRepository
    @State private var discardingHunk: DiffLine.ID?

    var body: some View {
        if let file = repository.selectedFile {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(file.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(areaLabel(file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Hide whitespace", isOn: $repository.ignoresWhitespace)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Leave out changes to whitespace. Hunks can't be staged while it's on, as they wouldn't apply.")
                    Button {
                        repository.openInEditor(file)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .disabled(file.status == "D")
                    .help("Open in \(CodeEditor.chosen.name)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                Divider()
                if let binary = repository.binary {
                    BinaryChangeView(change: binary)
                } else if repository.diff.isEmpty {
                    ContentUnavailableView(repository.ignoresWhitespace ? "Only whitespace changed" : "No lines to show", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(repository.diff) { line in
                                GitDiffRow(repository: repository, file: file, line: line) { discardingHunk = $0 }
                            }
                        }
                        .frame(minWidth: 400, alignment: .leading)
                    }
                }
            }
            .confirmationDialog("Discard this part of the change?", isPresented: Binding(get: { discardingHunk != nil }, set: { if !$0 { discardingHunk = nil } })) {
                Button("Discard", role: .destructive) {
                    if let hunk = discardingHunk { Task { await repository.discardHunk(hunk) } }
                }
            } message: {
                Text("Those lines go back to what's staged, or to the last commit.")
            }
        } else {
            ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass", description: Text("Pick a file to see its diff."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func areaLabel(_ file: GitFileChange) -> String {
        switch file.area {
        case .staged: "staged"
        case .unstaged: "not staged"
        case .untracked: "new"
        case .conflicted: "in conflict"
        }
    }
}

private struct GitDiffRow: View {
    let repository: LocalRepository
    let file: GitFileChange
    let line: DiffLine
    let discard: (DiffLine.ID) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newLine.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 8)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(DiffStyle.foreground(line.kind))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            if line.kind == .hunk, repository.hunksApply {
                HStack(spacing: 10) {
                    if file.area == .staged {
                        Button("Unstage") { Task { await repository.unstageHunk(line.id) } }
                    } else {
                        Button("Discard") { discard(line.id) }
                        Button("Stage") { Task { await repository.stageHunk(line.id) } }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.trailing, 6)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        // As wide as the widest line, so the colours run across.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffStyle.background(line.kind))
        .contextMenu {
            if let new = line.newLine, file.status != "D" {
                Button("Open in \(CodeEditor.chosen.name) at Line \(new)") { repository.openInEditor(file, line: new) }
            }
            Button("Copy Line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.kind == .hunk || line.kind == .note ? line.text : String(line.text.dropFirst()), forType: .string)
            }
        }
    }
}

/// A binary file: its size before and after, and the pictures when it's an
/// image.
private struct BinaryChangeView: View {
    let change: BinaryChange

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                side("Before", size: change.oldSize, image: change.oldImage)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                side("After", size: change.newSize, image: change.newImage)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func side(_ title: String, size: Int?, image: Data?) -> some View {
        VStack(spacing: 8) {
            if let image, let picture = NSImage(data: image) {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
                    .background(Color.secondary.opacity(0.08))
            }
            Text(title).font(.headline)
            Text(size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "None")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The commit: a summary with a length hint, a description, and Amend;
/// Undo takes an unpushed commit back into the fields. What a hook says
/// when it refuses shows in full.
private struct CommitComposer: View {
    let repository: LocalRepository
    @State private var summary = ""
    @State private var description = ""
    @State private var amend = false
    /// The message Amend filled in, so turning it off clears only that.
    @State private var amended: String?
    @State private var committing = false
    @State private var failure: String?
    @State private var confirmingUndo = false

    var body: some View {
        let status = repository.status
        let staged = status?.files(in: .staged).count ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Summary", text: $summary)
                    .textFieldStyle(.roundedBorder)
                Text("\(summary.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(summary.count > 72 ? Color.red : summary.count > 50 ? Color.orange : Color.secondary)
                    .help("Keep the summary to 50 characters where you can, 72 at most, so it isn't cut short in logs.")
            }
            TextField("Description", text: $description, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
            HStack(spacing: 8) {
                Toggle("Amend", isOn: $amend)
                    .toggleStyle(.checkbox)
                    .disabled(status?.head == nil)
                    .help("Add what's staged to the last commit, with this message, instead of making a new one")
                if repository.canUndoLastCommit {
                    Button("Undo") { confirmingUndo = true }
                        .buttonStyle(.link)
                        .help("Take the last commit back, keeping its changes staged and its message here")
                }
                Spacer()
                Button(amend ? "Amend Last Commit" : "Commit \(staged == 1 ? "1 File" : "\(staged) Files") to \(status?.branch ?? "HEAD")") {
                    Task { await commit() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty || (staged == 0 && !amend) || committing)
            }
            .controlSize(.small)
            if let failure {
                HStack(alignment: .top) {
                    ScrollView {
                        Text(failure)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    Button {
                        self.failure = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }
        }
        .padding(10)
        .onChange(of: amend) { _, on in
            Task {
                if on {
                    guard summary.isEmpty, description.isEmpty else { return }
                    let message = await repository.lastCommitMessage()
                    summary = message.summary
                    description = message.description
                    amended = summary + "\n" + description
                } else if amended == summary + "\n" + description {
                    summary = ""
                    description = ""
                    amended = nil
                }
            }
        }
        .confirmationDialog("Undo the last commit?", isPresented: $confirmingUndo) {
            Button("Undo Commit") {
                Task {
                    guard let message = await repository.undoLastCommit() else { return }
                    summary = message.summary
                    description = message.description
                    amend = false
                }
            }
        } message: {
            Text("It isn't pushed, so it's taken back: its changes stay staged and its message comes back here.")
        }
    }

    private func commit() async {
        committing = true
        failure = await repository.commit(summary: summary, description: description, amend: amend)
        committing = false
        if failure == nil {
            summary = ""
            description = ""
            amended = nil
            amend = false
        }
    }
}
