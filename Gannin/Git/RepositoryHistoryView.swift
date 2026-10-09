import SwiftUI

/// The checked-out branch's commits, newest first, with their tags and the branches at
/// them; picking one shows its message, files and each file's diff. Tags
/// are made, pushed and deleted from here.
struct RepositoryHistoryView: View {
    let repository: LocalRepository
    @State private var history = GitHistory()
    @State private var search = ""
    @State private var deletingTag: String?
    /// The commit list keeps the keyboard: picking a commit loads its files
    /// and selects the first, which would otherwise take the arrows.
    @FocusState private var listFocused: Bool

    var body: some View {
        let words = search.lowercased().split(separator: " ")
        let commits = history.commits.filter { commit in
            words.allSatisfy { word in
                commit.subject.lowercased().contains(word) || commit.author.lowercased().contains(word)
                    || commit.sha.hasPrefix(word) || commit.tags.contains { $0.lowercased().contains(word) }
            }
        }
        let onlyHere = repository.remoteTags.map { remote in repository.tags.filter { !remote.contains($0.name) }.count } ?? 0
        FixedSplit(key: "repositoryHistoryListWidth", width: 440, range: 280...760) {
            VStack(spacing: 0) {
                // Above the commits, so it costs the page no row of its own.
                HStack(spacing: 8) {
                    FilterSearchField(text: $search, prompt: "Search commits, authors, SHAs and tags", fills: true)
                    if onlyHere > 0 {
                        Button("Push \(onlyHere == 1 ? "1 Tag" : "\(onlyHere) Tags")") { Task { await repository.pushAllTags() } }
                            .help("Push every tag that's only here to origin")
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
                commitList(commits)
            }
        } trailing: {
            CommitDetailView(repository: repository, history: history)
        }
        .task(id: reloadKey) {
            await history.load(path: repository.path, ref: shownRef, upstream: upstream)
            // The newest commit is shown to start with, and again when the
            // one picked is no longer listed (another branch, say).
            if !history.commits.contains(where: { $0.id == history.selected }) {
                history.selected = history.commits.first?.id
            }
        }
        .task(id: repository.root) { await repository.loadRemoteTags() }
        .onChange(of: repository.status?.branch) { history.reset() }
        .confirmationDialog("Delete the tag \(deletingTag ?? "")?", isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } }), presenting: deletingTag) { tag in
            Button("Delete Here", role: .destructive) { Task { await repository.deleteTag(tag, here: true, onOrigin: false) } }
            if repository.remoteTags?.contains(tag) == true {
                Button("Delete Here and on origin", role: .destructive) { Task { await repository.deleteTag(tag, here: true, onOrigin: true) } }
            }
        } message: { _ in
            Text("Deleting it on origin takes it away for everyone. A GitHub release on it becomes a draft.")
        }
    }

    /// The branch checked out, as the bar's branch button shows it.
    private var shownRef: String { "HEAD" }

    /// Where unpushed commits are counted from: the branch's upstream.
    private var upstream: String? { repository.status?.upstream }

    /// Read again when the branch moves or tags change.
    private var reloadKey: String {
        [repository.path, repository.status?.branch ?? "", repository.status?.head ?? "", repository.tags.map(\.name).joined(separator: ",")].joined(separator: "|")
    }

    @ViewBuilder
    private func commitList(_ commits: [GitCommit]) -> some View {
        if let error = history.error, history.commits.isEmpty {
            ContentUnavailableView("Couldn't read the history", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if history.commits.isEmpty {
            if history.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No commits yet", systemImage: "clock")
            }
        } else {
            List(selection: Binding(get: { history.selected }, set: { history.selected = $0 })) {
                ForEach(commits) { commit in
                    CommitRow(
                        commit: commit,
                        isUnpushed: history.unpushed.contains(commit.sha),
                        remoteTags: repository.remoteTags,
                        current: repository.status?.branch
                    ) { tag in tagMenu(tag) }
                    .tag(commit.sha)
                    .contextMenu { commitMenu(commit) }
                }
                if history.hasMore, search.isEmpty {
                    Button("Show \(GitHistory.pageSize) More") {
                        Task { await history.loadMore(path: repository.path, ref: shownRef, upstream: upstream) }
                    }
                    .buttonStyle(.link)
                }
            }
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onChange(of: history.files) { listFocused = true }
        }
    }

    @ViewBuilder
    private func commitMenu(_ commit: GitCommit) -> some View {
        Button("Tag This Commit") { repository.creatingTag = CreateTagRequest(target: commit.sha) }
        Button("New Branch from Here") { repository.creatingBranch = CreateBranchRequest(base: commit.sha) }
        Divider()
        Button("Copy SHA") { copy(commit.sha) }
        Button("Copy Subject") { copy(commit.subject) }
        if let url = URL(string: "https://github.com/\(repository.repo)/commit/\(commit.sha)") {
            Link("Open on GitHub", destination: url)
        }
    }

    @ViewBuilder
    private func tagMenu(_ tag: String) -> some View {
        if repository.remoteTags?.contains(tag) == false {
            Button("Push \(tag) to origin") {
                if let found = repository.tags.first(where: { $0.name == tag }) { Task { await repository.pushTag(found) } }
            }
        }
        Button("New Branch from \(tag)") { repository.creatingBranch = CreateBranchRequest(base: tag) }
        Button("Copy Name") { copy(tag) }
        Divider()
        Button("Delete \(tag)", role: .destructive) { deletingTag = tag }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A commit in the list: its subject, then SHA, author and when, with its
/// tags (orange while only here) and other branches at it.
private struct CommitRow<TagMenu: View>: View {
    let commit: GitCommit
    let isUnpushed: Bool
    let remoteTags: Set<String>?
    let current: String?
    @ViewBuilder let tagMenu: (String) -> TagMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(commit.subject)
                    .lineLimit(1)
                if commit.parents > 1 {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(.secondary)
                        .help("A merge")
                }
            }
            HStack(spacing: 6) {
                Text(commit.shortSHA).font(.caption.monospaced())
                Text(commit.author).font(.caption)
                Text(commit.date.formatted(.relative(presentation: .named))).font(.caption)
                if isUnpushed {
                    Label("Not pushed", systemImage: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(commit.tags, id: \.self) { tag in
                    let onlyHere = remoteTags.map { !$0.contains(tag) } ?? false
                    Label(tag, systemImage: "tag.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(onlyHere ? Color.orange : Color.accentColor)
                        .background((onlyHere ? Color.orange : Color.accentColor).opacity(0.15), in: Capsule())
                        .help(onlyHere ? "\(tag): only here, not on origin" : "\(tag), on origin")
                        .contextMenu { tagMenu(tag) }
                }
                ForEach(commit.branches.filter { $0 != current }, id: \.self) { branch in
                    Pill(text: branch, color: .gray)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// The picked commit: its whole message, who and when, Tag This Commit,
/// then its files and the picked file's diff.
private struct CommitDetailView: View {
    let repository: LocalRepository
    let history: GitHistory
    /// The file list keeps the keyboard once a file's picked, so the arrows
    /// step through files as their diffs load; picking another commit hands
    /// it back to the commit list.
    @FocusState private var filesFocused: Bool
    @State private var filesActive = false

    var body: some View {
        if let commit = history.selectedCommit {
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    header(commit)
                    Divider()
                    List(selection: Binding(get: { history.selectedFile }, set: { file in
                        history.selectedFile = file
                        filesActive = true
                        filesFocused = true
                    })) {
                        ForEach(history.files) { file in
                            fileRow(file).tag(file.id)
                        }
                    }
                    .focused($filesFocused)
                    .onChange(of: history.diff) { if filesActive { filesFocused = true } }
                }
                .frame(minHeight: 160, idealHeight: 260)
                diffView
                    .frame(minHeight: 120, maxHeight: .infinity)
            }
            .task(id: commit.sha) {
                filesActive = false
                await history.loadSelected(path: repository.path)
            }
            .task(id: "\(commit.sha)|\(history.selectedFile ?? "")") { await history.loadDiff(path: repository.path) }
        } else {
            ContentUnavailableView("No commit selected", systemImage: "clock", description: Text("Pick a commit to see what it changed, or right-click one to tag it."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ commit: GitCommit) -> some View {
        let message = history.message ?? commit.subject
        let (subject, body) = LocalRepository.splitMessage(message)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(subject)
                    .font(.headline)
                    .textSelection(.enabled)
                Spacer()
                Button("Tag This Commit") { repository.creatingTag = CreateTagRequest(target: commit.sha) }
                    .controlSize(.small)
            }
            if !body.isEmpty {
                ScrollView {
                    Text(body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(commit.shortSHA).font(.caption.monospaced()).textSelection(.enabled)
                Text(commit.author)
                Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                if commit.parents > 1 { Text("Merge: changes against its first parent") }
                Spacer()
                Text(history.files.count == 1 ? "1 file" : "\(history.files.count) files")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func fileRow(_ file: GitCommitFile) -> some View {
        HStack(spacing: 6) {
            Text(file.status)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(file.status == "A" ? ChartPalette.good : file.status == "D" ? ChartPalette.critical : .orange)
                .frame(width: 12)
            Text(file.name).lineLimit(1)
            if !file.folder.isEmpty {
                Text(file.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            if file.isBinary {
                Text("binary").foregroundStyle(.secondary)
            } else {
                if file.added > 0 { Text("+\(file.added)").foregroundStyle(ChartPalette.good) }
                if file.removed > 0 { Text("-\(file.removed)").foregroundStyle(ChartPalette.critical) }
            }
        }
        .font(.callout)
        .monospacedDigit()
        .help(file.path)
    }

    @ViewBuilder
    private var diffView: some View {
        if history.selectedFile == nil {
            ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffScroll(lines: history.diff) { line in
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
                }
                .font(Font(EditorFontStore.shared.font))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DiffStyle.background(line.kind))
            }
        }
    }
}

/// A tag on a commit: lightweight, or annotated when it has a message, and
/// pushed straight away if wanted.
struct NewTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: LocalRepository
    @State var target: String
    @State private var name = ""
    @State private var message = ""
    @State private var push = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let exists = repository.tags.contains { $0.name == trimmedName }
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Name", text: $name, prompt: Text(suggestion ?? "v1.0.0"))
                    if let last = repository.tags.first {
                        Text("Last: \(last.name)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help([last.sha, last.subject, last.date.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    }
                }
                TextField("On", text: $target, prompt: Text("HEAD"))
                    .help("A branch, tag or commit; HEAD is the commit checked out")
                TextField("Message", text: $message, prompt: Text("Optional: makes it an annotated tag"), axis: .vertical)
                    .lineLimit(2...8)
                Toggle("Push to origin", isOn: $push)
            } header: {
                Text("New tag in \(repository.repo)")
            }
            Section {
                if target.count >= 7, let commit = repository.tags.first(where: { $0.sha.hasPrefix(String(target.prefix(7))) || target.hasPrefix($0.sha) }) {
                    Text("This commit is already tagged \(commit.name).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else if exists {
                    Text("There's a tag called \(trimmedName) already.").foregroundStyle(.red)
                } else {
                    Text("With a message it's annotated, as releases usually are: the first line is the title, the rest the notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(push ? "Create and Push" : "Create Tag") {
                    Task {
                        working = true
                        error = await repository.createTag(trimmedName, target: target, message: message, push: push)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(trimmedName.isEmpty || exists || working)
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// The next patch version after the newest `v1.2.3` tag.
    private var suggestion: String? {
        guard let latest = repository.tags.first(where: { $0.name.hasPrefix("v") && $0.name.dropFirst().split(separator: ".").count == 3 }) else { return nil }
        let parts = latest.name.dropFirst().split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return "v\(parts[0]).\(parts[1]).\(parts[2] + 1)"
    }
}
