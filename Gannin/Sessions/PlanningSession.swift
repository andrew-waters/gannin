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
    func startPlanning(org: String, topic: String, documentPath: String?, harness setup: HarnessConfig, harnessPath: String, guidance: String, choice: PromptChoice? = nil) -> CodeSession {
        let slug = Self.slug(topic)
        let branch = "plan-\(slug)"
        let info = PlanningInfo(topic: topic, documentPath: documentPath, slug: slug)
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
        HarnessAuthoring.fill(guidance, [
            "topic": info.topic,
            "plan": "plans/\(HarnessAuthoring.today)-\(info.slug).md",
            "docs": ".worktrees/\(branch)/docs/",
            "assets": "plans/assets/\(info.slug)/",
            "starting_point": info.documentPath.map { "Then read \($0), which we're starting from." } ?? "",
        ])
    }

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
        let folder = SessionScript.shellPath(Self.worktreePath(for: session) + "/docs")
        var script = ["set -e", "mkdir -p \(folder)", "cd \(folder)"]
        var shared: [PlanningInfo.Document] = []
        var converted = false
        for file in files {
            guard let data = try? Data(contentsOf: file.url) else { continue }
            let name = file.url.lastPathComponent
            script.append("printf %s \(data.base64EncodedString()) | base64 -d > \(SessionScript.quoted(name))")
            if let text = Self.plainText(file.url) {
                converted = true
                script.append("printf %s \(Data(text.utf8).base64EncodedString()) | base64 -d > \(SessionScript.quoted(name + ".txt"))")
            }
            shared.append(.init(name: name, commit: file.commit, sharedAt: .now))
        }
        guard !shared.isEmpty else { return }
        let result = await ClaudeRunner.runScript(script.joined(separator: "\n") + "\n", for: session)
        guard result.status == 0 else { throw SessionError.message(result.error.isEmpty ? "Couldn't copy the documents." : result.error) }
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

/// Starts a planning session: a topic, and optionally the harness document
/// it starts from.
struct NewPlanningSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let org: String
    var documentPath: String? = nil
    var topic = ""
    @State private var text = ""
    @State private var choice = PromptChoice()
    /// The harness picked, by repo; nil for the document's, else the primary.
    @State private var picked: String?

    /// A document from a combined index names its harness.
    private var source: (repo: String?, path: String)? { documentPath.map(HarnessIndex.split) }

    var body: some View {
        let config = configs.config(for: org)
        let harnesses = config.harnesses
        let setup = (picked ?? source?.repo).flatMap(config.harness(repo:)) ?? harnesses.first
        let library = setup.map { sessions.promptLibrary(org: org, setup: $0) } ?? HarnessPromptLibrary(index: nil)
        Form {
            Section {
                TextField("What are we planning?", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                if let source {
                    LabeledContent("Starting from", value: source.path)
                }
                if harnesses.count > 1 {
                    Picker("Harness", selection: Binding(get: { setup?.repo ?? "" }, set: { repo in
                        picked = repo
                        choice = config.harness(repo: repo).map { sessions.promptLibrary(org: org, setup: $0).defaults(for: .planning, repos: []) } ?? PromptChoice()
                    })) {
                        ForEach(harnesses, id: \.repo) { Text($0.repo).tag($0.repo) }
                    }
                }
            } footer: {
                Text(setup == nil
                     ? "Planning sessions run in the org's harness. Pick or create it in the org's Settings, under Harness."
                     : "Claude asks what it needs, then writes the plan in \(setup!.repo)'s plans folder. You can share documents into the session; each is confirmed, and only those you mark are committed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if library.hasChoices(for: .planning) {
                PromptPickerSections(
                    library: library, use: .planning,
                    values: SessionStore.planningValues(topic: text, harness: setup?.repo ?? "", branch: "plan-\(SessionStore.slug(text))"),
                    choice: $choice
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: library.hasChoices(for: .planning) ? 560 : 480)
        .frame(maxHeight: 680)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start Planning") {
                    guard let setup, let path = SessionStore.harnessPath(org: org, repo: setup.repo) else { return }
                    // The document's own path, when it's in the harness picked.
                    let start = source.flatMap { ($0.repo ?? harnesses.first?.repo) == setup.repo ? $0.path : nil }
                    let session = sessions.startPlanning(org: org, topic: text.trimmingCharacters(in: .whitespacesAndNewlines), documentPath: start, harness: setup, harnessPath: path,
                                                          guidance: HarnessAuthoring.guidance(for: .plans, config: configs.config(for: org), org: org), choice: choice)
                    sessions.show(session.id, with: openWindow)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || SessionStore.unavailable(org: org, harness: setup) != nil)
                .help(SessionStore.unavailable(org: org, harness: setup) ?? "")
            }
        }
        .onAppear {
            text = topic
            choice = library.defaults(for: .planning, repos: [])
        }
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
