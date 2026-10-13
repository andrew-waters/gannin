import SwiftUI
import UniformTypeIdentifiers

/// A meeting's transcript (Google Meet's, say), pasted or dropped after the
/// session: saved as `transcript.txt` in the session's folder on this Mac,
/// never committed or uploaded, for Claude to propose findings from.
enum RefineTranscript {
    static let file = "transcript.txt"

    /// The kinds of file a transcript is read from. An extension macOS
    /// doesn't know is left out rather than widened to any file.
    nonisolated static let types: [UTType] = [UTType.plainText, UTType.text, UTType.rtf]
        + ["vtt", "srt", "docx"].compactMap { UTType(filenameExtension: $0) }

    /// The biggest file read: an hour's meeting is far less, and a bigger
    /// file is more likely something else.
    nonisolated static let limit = 10 * 1024 * 1024

    /// Whether a file looks like a transcript, by its type alone: a
    /// screenshot or PDF dropped on the findings isn't one.
    nonisolated static func accepts(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return types.contains(where: type.conforms(to:))
    }

    /// A file's text, read off the main actor: plain text as it is, a Word
    /// or RTF document through textutil. Nil for anything else, or a file
    /// over `limit`.
    static func text(from url: URL) async -> String? {
        await Task.detached { RefineTranscript.read(url) }.value
    }

    nonisolated private static func read(_ url: URL) -> String? {
        guard accepts(url), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { return nil }
        if let converted = SessionStore.plainText(url) { return converted }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Why a file gave no text.
    static func unreadable(_ url: URL) -> String {
        "Couldn't read text from \(url.lastPathComponent). It has to be text, .vtt, .srt, Word or RTF, and under 10 MB."
    }

    static func url(in session: CodeSession) -> URL? {
        SessionStore.worktree(for: session)?.appending(path: file)
    }
}

extension SessionStore {
    /// Saves the transcript in the session's folder and asks Claude for
    /// the findings it raises.
    func saveTranscript(_ text: String, in id: UUID) throws {
        guard let session = sessions[id], let url = RefineTranscript.url(in: session) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        update(id) { $0.refine?.transcript = RefineTranscript.file }
        tellReviewer(id, """
            The room shared the meeting's transcript at `.worktrees/\(session.branch)/\(RefineTranscript.file)`. Read it, and add \
            what it raises that isn't already in findings.json to refine.json's suggestions, with "source": "transcript". \
            Don't copy it anywhere else.
            """)
    }
}

/// Paste the meeting's transcript, or pick or drop its file.
struct RefineTranscriptSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let session: CodeSession
    /// Read from a file dropped on the findings, to share.
    var dropped: String? = nil
    /// Why a file dropped on the findings couldn't be read.
    var failed: String? = nil
    @State private var text = ""
    @State private var picking = false
    @State private var reading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Transcript")
                .font(.title2.weight(.semibold))
            Text("Paste the meeting's transcript, such as Google Meet's, or choose or drop its file (text, .vtt, .srt, Word or RTF). Claude reads it and suggests findings from it for the room to keep or dismiss.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: \.isFileURL), RefineTranscript.accepts(url) else { return false }
                    load(url)
                    return true
                }
            Label("It stays on this Mac, in the session's folder for Claude to read. It's never committed to the harness or put in an issue.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Choose File") { picking = true }
                    .disabled(reading)
                if reading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Share with Claude", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(reading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 600)
        .fileImporter(isPresented: $picking, allowedContentTypes: RefineTranscript.types) { result in
            guard case .success(let url) = result else { return }
            load(url)
        }
        .onAppear {
            error = failed
            if let dropped {
                text = dropped
            } else if let url = RefineTranscript.url(in: session), session.refine?.transcript != nil {
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }

    /// Reads a file into the box, off the main actor.
    private func load(_ url: URL) {
        reading = true
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let read = await RefineTranscript.text(from: url) {
                text = read
                error = nil
            } else {
                error = RefineTranscript.unreadable(url)
            }
            reading = false
        }
    }

    private func save() {
        do {
            try sessions.saveTranscript(text, in: session.id)
            dismiss()
        } catch {
            self.error = "Couldn't save the transcript: \(error.localizedDescription)"
        }
    }
}
