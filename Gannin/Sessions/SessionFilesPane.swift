import AppKit
import SwiftUI

/// An Ask session's Files pane, in place of Changes: what it wrote, newest
/// first, each to open, drag out, open with, reveal, save elsewhere or copy.
/// Read again a moment after claude edits a file or runs a command, when
/// the transcript names a new file, and every two seconds while it shows,
/// since an MCP tool's write fires no hook.
struct SessionFilesPane: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let files: SessionFiles
    @State private var error: String?

    private var edited: [String] {
        (sessions.transcripts[session.id]?.filesEdited).map { $0.sorted() } ?? []
    }

    var body: some View {
        content
            .task(id: RefreshKey(changes: sessions.changeCount(session.id), edited: edited)) {
                guard let folder = SessionStore.worktree(for: session) else { return }
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
            .alert("Couldn't save a copy", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    private struct RefreshKey: Hashable {
        let changes: Int
        let edited: [String]
    }

    @ViewBuilder
    private var content: some View {
        if session.isRemote {
            ContentUnavailableView("Files are listed on this Mac only", systemImage: "externaldrive.badge.xmark",
                                   description: Text("This session runs on a server."))
        } else if !files.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.files.isEmpty {
            ContentUnavailableView("No files yet", systemImage: "doc",
                                   description: Text("What Claude saves in this session's folder shows here."))
        } else {
            List {
                Section {
                    ForEach(files.inFolder) { row($0) }
                } footer: {
                    if files.truncated {
                        Text("Only the first \(SessionFiles.limit) files in the folder are listed.")
                    }
                }
                if !files.elsewhere.isEmpty {
                    Section("Elsewhere") {
                        ForEach(files.elsewhere) { row($0) }
                    }
                }
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
        // Commit to Harness goes here, set apart (andrew-waters/gannin#59).
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
