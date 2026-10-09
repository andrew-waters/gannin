import SwiftUI

/// Review Config on a repository's page: opens `ReviewConfigSheet`.
struct ReviewConfigButton: View {
    let org: String
    let repo: String
    /// The clone, when there is one here, for the repo's own file.
    var repository: LocalRepository?
    @State private var editing = false

    var body: some View {
        Button {
            editing = true
        } label: {
            Label("Review Config", systemImage: "checklist")
        }
        .help("How Claude reviews this repo's PRs: how much to say, instructions, files to skip, checks")
        .sheet(isPresented: $editing) {
            ReviewConfigSheet(org: org, repo: repo, repository: repository)
        }
    }
}

/// Edits how Claude reviews a repo (`ReviewConfig`) in one of three places:
/// the repo's section of the harness's `.gannin/review.json`, the harness's
/// defaults for every repo in the project, or the repo's own
/// `.gannin/review.json`, written into the clone to commit. Each is its own
/// draft until saved.
struct ReviewConfigSheet: View {
    @Environment(HarnessStore.self) private var harness
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.dismiss) private var dismiss
    let org: String
    let repo: String
    let repository: LocalRepository?

    enum Target: Hashable { case repoSection, defaults, repoFile }

    @State private var target: Target = .repoSection
    @State private var drafts: [Target: Draft] = [:]
    @State private var saved: [Target: Draft] = [:]
    @State private var saving = false
    @State private var error: String?
    @State private var note: String?

    private var setup: HarnessConfig? { configs.config(for: org).harness(covering: [repo]) }
    private var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    private var filePath: String? { repository.map { ($0.path as NSString).appendingPathComponent(ReviewConfig.path) } }

    var body: some View {
        let draft = Binding(get: { drafts[target] ?? Draft() }, set: { drafts[target] = $0 })
        Form {
            Section {
                Picker("Edit", selection: $target) {
                    if setup != nil {
                        Text("\(repo) in the harness").tag(Target.repoSection)
                        Text("Every repo in the project").tag(Target.defaults)
                    }
                    Text("\(repoName)'s own file").tag(Target.repoFile)
                }
            } footer: {
                Text(targetHelp).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Profile", selection: draft.profile) {
                    Text(target == .defaults ? "Default (Chill)" : "As set above it").tag(ReviewConfig.Profile?.none)
                    ForEach(ReviewConfig.Profile.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("How much to say")
            } footer: {
                Text(draft.wrappedValue.profile?.help ?? "Inherits from the harness, else Chill: real problems and worthwhile improvements, few nits.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                editor(draft.instructions, placeholder: "Check every new endpoint has auth and input validation. We use the repository pattern; flag queries outside it.")
                TextField("Tone", text: draft.tone, prompt: Text("Friendly and brief; explain the why"))
            } header: {
                Text("Instructions")
            }

            Section {
                editor(draft.ignore, placeholder: "**/*.generated.swift\nvendor/\npackage-lock.json", monospaced: true)
            } header: {
                Text("Skip files")
            } footer: {
                Text("One glob a line: `**` any folders, `*` within a name, a name alone anywhere, a folder ending `/` and everything in it. The reviewer leaves them alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(draft.wrappedValue.paths) { row in
                    let item = pathBinding(row.id)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Path", text: item.path, prompt: Text("src/api/**"))
                                .font(.body.monospaced())
                            removeButton { remove { $0.paths.removeAll { $0.id == row.id } } }
                        }
                        TextField("Instructions", text: item.instructions, prompt: Text("Check auth, validation and error responses"), axis: .vertical)
                            .lineLimit(2...6)
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Path Instructions") {
                    drafts[target, default: Draft()].paths.append(.init(path: "", instructions: ""))
                }
            } header: {
                Text("Path instructions")
            } footer: {
                Text("Guidance for files matching a glob, on top of the instructions above.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(draft.wrappedValue.checks) { row in
                    let check = checkBinding(row.id)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: check.name, prompt: Text("Migrations are reversible"))
                            Picker("Mode", selection: check.mode) {
                                ForEach(ReviewConfig.Check.Mode.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                            removeButton { remove { $0.checks.removeAll { $0.id == row.id } } }
                        }
                        TextField("What passes", text: check.instructions, prompt: Text("Every migration that changes a table has a down step"), axis: .vertical)
                            .lineLimit(2...6)
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Check") {
                    drafts[target, default: Draft()].checks.append(.init(name: "", mode: .warning, instructions: ""))
                }
            } header: {
                Text("Checks")
            } footer: {
                Text("The reviewer judges each PR against them. In the review's Overview a failed Error check blocks the merge and a failed Warning is to fix. A check with the same name further down replaces this one.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Skip titles containing", text: draft.skipKeywords, prompt: Text("WIP, chore(deps)"))
            } header: {
                Text("Automatic reviews")
            } footer: {
                Text("Comma separated. Review requests whose title has one aren't reviewed by themselves; Review with Claude still works.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let note {
                Label(note, systemImage: "checkmark.circle.fill").foregroundStyle(ChartPalette.good)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 720)
        .navigationTitle("Review Config: \(repo)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) { save() }
                    .disabled(saving || !canSave || drafts[target] == saved[target])
            }
        }
        .task { load() }
        .onChange(of: target) { note = nil; error = nil }
    }

    // MARK: Pieces

    private func editor(_ text: Binding<String>, placeholder: String, monospaced: Bool = false) -> some View {
        TextEditor(text: text)
            .font(monospaced ? .body.monospaced() : .body)
            .frame(minHeight: 70)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(monospaced ? .body.monospaced() : .body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }

    /// A row's binding found by its ID each time, never by position: a
    /// position goes stale when a row above it is removed while a field in
    /// it is still committing, and reading it then crashes.
    private func pathBinding(_ id: UUID) -> Binding<ReviewConfig.PathInstruction> {
        let target = target
        return Binding(
            get: { drafts[target]?.paths.first { $0.id == id } ?? .init(id: id, path: "", instructions: "") },
            set: { value in
                guard let index = drafts[target]?.paths.firstIndex(where: { $0.id == id }) else { return }
                drafts[target]?.paths[index] = value
            }
        )
    }

    private func checkBinding(_ id: UUID) -> Binding<ReviewConfig.Check> {
        let target = target
        return Binding(
            get: { drafts[target]?.checks.first { $0.id == id } ?? .init(id: id, name: "", mode: .off, instructions: "") },
            set: { value in
                guard let index = drafts[target]?.checks.firstIndex(where: { $0.id == id }) else { return }
                drafts[target]?.checks[index] = value
            }
        )
    }

    /// Removes after the current update, so fields being torn down commit
    /// to rows that are still there.
    private func remove(_ change: @escaping (inout Draft) -> Void) {
        let target = target
        DispatchQueue.main.async {
            if var draft = drafts[target] {
                change(&draft)
                drafts[target] = draft
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }

    private var targetHelp: String {
        switch target {
        case .repoSection: "Kept in \(setup?.repo ?? "the harness")'s .gannin/review.json for this repo, over the project's defaults."
        case .defaults: "Kept in \(setup?.repo ?? "the harness")'s .gannin/review.json for every repo in the project."
        case .repoFile: repository == nil
            ? "Clone the repo to add its own file. It's read from the default branch and wins over the harness."
            : "The repo's own .gannin/review.json, read from its default branch once it's merged there, and over the harness's. Written into the clone for you to commit."
        }
    }

    private var saveTitle: String {
        if saving { return "Saving" }
        switch target {
        case .repoSection, .defaults: return "Commit to \(setup?.repo.split(separator: "/").last.map(String.init) ?? "Harness")"
        case .repoFile: return "Write to the Clone"
        }
    }

    private var canSave: Bool {
        switch target {
        case .repoSection, .defaults: setup != nil
        case .repoFile: repository != nil
        }
    }

    // MARK: Loading and saving

    private func load() {
        if setup == nil { target = .repoFile }
        let text = setup.flatMap { harness.index(for: org, $0)?.dataFiles?.first { $0.path == ReviewConfig.path }?.text }
        let team = HarnessReviewConfig.read(text)
        let repoFile = filePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.flatMap(ReviewConfig.read)
        let loaded: [Target: Draft] = [
            .repoSection: Draft(team.config(for: repo)),
            .defaults: Draft(team.defaults),
            .repoFile: Draft(repoFile),
        ]
        drafts = loaded
        saved = loaded
    }

    private func save() {
        guard let draft = drafts[target] else { return }
        let config = draft.config
        saving = true
        error = nil
        note = nil
        let target = target
        Task {
            defer { saving = false }
            do {
                switch target {
                case .repoSection, .defaults:
                    guard let setup else { return }
                    let repo = repo
                    try await harness.commit(org: org, setup: setup) { head in
                        let text = try await harness.files(setup: setup, at: head, paths: [ReviewConfig.path])[ReviewConfig.path] ?? nil
                        var team = HarnessReviewConfig.read(text)
                        if target == .defaults {
                            team.defaults = config.isEmpty ? nil : config
                        } else {
                            team = team.setting(config, for: repo)
                        }
                        let json = team.json
                        guard json != text else { return nil }
                        return HarnessChange(message: target == .defaults ? "Gannin: review config for the project" : "Gannin: review config for \(repo)", files: [ReviewConfig.path: json])
                    }
                    note = "Committed. Reviews started from now on follow it."
                case .repoFile:
                    guard let filePath, let repository else { return }
                    try FileManager.default.createDirectory(atPath: (filePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try config.json.write(toFile: filePath, atomically: true, encoding: .utf8)
                    await repository.refresh()
                    note = "Written to \(ReviewConfig.path) in the clone. Commit it from Changes; reviews follow it once it's on the default branch."
                }
                saved[target] = draft
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The config as the form edits it: text where the file has lists.
    struct Draft: Equatable {
        var profile: ReviewConfig.Profile?
        var instructions = ""
        var tone = ""
        var ignore = ""
        var paths: [ReviewConfig.PathInstruction] = []
        var checks: [ReviewConfig.Check] = []
        var skipKeywords = ""

        init(_ config: ReviewConfig? = nil) {
            profile = config?.profile
            instructions = config?.instructions ?? ""
            tone = config?.tone ?? ""
            ignore = (config?.ignore ?? []).joined(separator: "\n")
            paths = config?.pathInstructions ?? []
            checks = config?.checks ?? []
            skipKeywords = (config?.skipTitleKeywords ?? []).joined(separator: ", ")
        }

        var config: ReviewConfig {
            func text(_ value: String) -> String? {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            func list(_ values: [String]) -> [String]? {
                let kept = values.compactMap(text)
                return kept.isEmpty ? nil : kept
            }
            let paths = paths.filter { text($0.path) != nil && text($0.instructions) != nil }
            let checks = checks.filter { text($0.name) != nil && text($0.instructions) != nil }
            return ReviewConfig(
                profile: profile, instructions: text(instructions), tone: text(tone),
                ignore: list(ignore.components(separatedBy: .newlines)),
                pathInstructions: paths.isEmpty ? nil : paths,
                checks: checks.isEmpty ? nil : checks,
                skipTitleKeywords: list(skipKeywords.components(separatedBy: ","))
            )
        }
    }
}
