import AppKit
import SwiftUI

/// An Ask session's files, as sections of its Session pane: those in its
/// folder, newest first, then those it wrote elsewhere, each to open, drag
/// out, open with, reveal, save elsewhere, copy or commit to the harness.
struct AskFilesSections: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let files: SessionFiles
    /// Set by a file's menu, for the pane to show.
    @Binding var committing: SessionFile?
    @Binding var error: String?

    var body: some View {
        Section {
            if session.isRemote {
                Text("Files are listed on this Mac only, and this session runs on a server.")
                    .foregroundStyle(.secondary)
            } else if !files.loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if files.inFolder.isEmpty {
                Text("Nothing yet. What Claude saves in this session's folder shows here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files.inFolder) { row($0) }
            }
        } header: {
            Text(files.inFolder.isEmpty ? "Files" : "Files \(files.inFolder.count)")
        } footer: {
            if files.truncated {
                Text("Only the first \(SessionFiles.limit) files in the folder are listed.")
            }
        }
        if !files.elsewhere.isEmpty {
            Section("Written elsewhere") {
                ForEach(files.elsewhere) { row($0) }
            }
        }
    }

    private func row(_ file: SessionFile) -> some View {
        Button {
            SessionFiles.open(file)
        } label: {
            SessionFileRow(file: file)
        }
        .buttonStyle(.plain)
        .help(file.url.path)
        // An item provider for the file itself, which AppKit offers as a
        // file promise as well as its URL, so Mail attaches it.
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .contextMenu { menu(file) }
    }

    @ViewBuilder
    private func menu(_ file: SessionFile) -> some View {
        Button("Open") { SessionFiles.open(file) }
        Menu("Open With") {
            let applications = SessionFiles.applications(for: file)
            ForEach(Array(applications.enumerated()), id: \.element) { index, application in
                Button {
                    SessionFiles.open(file, with: application)
                } label: {
                    Label {
                        Text(FileManager.default.displayName(atPath: application.path) + (index == 0 ? " (default)" : ""))
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                    }
                }
                if index == 0, applications.count > 1 { Divider() }
            }
            if applications.isEmpty {
                Text("No apps open this kind of file")
            }
        }
        Divider()
        Button("Show in Finder") { SessionFiles.reveal(file) }
        Button("Save a Copy") { error = SessionFiles.saveCopy(of: file) }
        Button("Copy") { SessionFiles.copy(file) }
        // Set apart, and only from here: never a click, drag or Return.
        if !file.isElsewhere, session.harnessRepo != nil {
            Divider()
            Button("Commit to Harness") { committing = file }
        }
    }
}

/// A file in the list: its icon and name, where it is when that isn't
/// `files/`, then its size and when it was written.
private struct SessionFileRow: View {
    let file: SessionFile

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                if let location = file.location {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                Text(Self.when(file.modified))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    /// The time for today's, else the date.
    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// Reads an Ask session's files again a moment after claude edits a file or
/// runs a command, when the transcript names a new file, and every two
/// seconds while they show, since an MCP tool's write fires no hook; with a
/// file's Commit to Harness sheet and Save a Copy's errors.
struct AskFilesRefresh: ViewModifier {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let files: SessionFiles
    @Binding var committing: SessionFile?
    @Binding var error: String?

    private var edited: [String] {
        (sessions.transcripts[session.id]?.filesEdited).map { $0.sorted() } ?? []
    }

    private struct Key: Hashable {
        let changes: Int
        let edited: [String]
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(changes: sessions.changeCount(session.id), edited: edited)) {
                guard session.isAsk, let folder = SessionStore.worktree(for: session) else { return }
                let edited = edited
                do {
                    // A short wait lets a burst of writes settle into one read.
                    if files.loaded { try await Task.sleep(for: .milliseconds(400)) }
                    while true {
                        await files.refresh(folder: folder, edited: edited)
                        try await Task.sleep(for: .seconds(2))
                    }
                } catch {}
            }
            .sheet(item: $committing) { CommitToHarnessSheet(session: session, file: $0) }
            .alert("Couldn't save a copy", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
}

/// An Ask session's Claude artifacts, the claude.ai pages it published with
/// its Artifact tool, newest first, each to open or copy; and a button
/// asking it to publish one, with what it should show.
struct AskArtifactsSection: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    @State private var about = ""

    var body: some View {
        let artifacts = (sessions.transcripts[session.id]?.artifacts ?? []).reversed()
        let running = sessions.isRunning(session.id)
        Section {
            ForEach(Array(artifacts)) { artifact in
                Button {
                    NSWorkspace.shared.open(artifact.url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(artifact.title ?? "Artifact").lineLimit(1)
                            Text(artifact.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if let at = artifact.at {
                            Text(at.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(artifact.url.absoluteString)
                .contextMenu {
                    Button("Open") { NSWorkspace.shared.open(artifact.url) }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(artifact.url.absoluteString, forType: .string)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("What it should show", text: $about, prompt: Text("What it should show (optional)"))
                    .labelsHidden()
                    .onSubmit(ask)
                Button(artifacts.isEmpty ? "Ask for an Artifact" : "Ask for Another", action: ask)
                    .disabled(!running)
            }
            .help(running ? "Ask Claude to publish its answer as a Claude artifact, a page with a link to share" : "Not running: Resume the session first")
        } header: {
            Text(artifacts.isEmpty ? "Artifacts" : "Artifacts \(artifacts.count)")
        } footer: {
            if artifacts.isEmpty {
                Text("Claude artifacts are pages Claude publishes on claude.ai, private to you until you share them.")
            }
        }
    }

    private func ask() {
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = about.isEmpty ? "what we've found so far" : about
        let prompt = "Publish \(what) as a Claude artifact with your Artifact tool: a clear, self-contained page, with tables and charts where they help. If you've already published one for this, update it at the same link. Then tell me its link."
        if sessions.submit(prompt, to: session.id) { self.about = "" }
    }
}
