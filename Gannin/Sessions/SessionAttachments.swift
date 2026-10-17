import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A file dropped or pasted on a session's panel for claude: copied into
/// `.gannin/attachments/` in its folder on the box claude runs on (this Mac,
/// a server, or a sandbox mounting either), with a copy in the session's
/// folder here for its thumbnail and to send again.
struct SessionAttachment: Codable, Hashable, Identifiable {
    /// Shell-safe and unique in the session (`SessionStore.attachmentNames`).
    let name: String
    let addedAt: Date
    let size: Int
    /// Whether it's on the box, where claude can read it.
    var uploaded = false
    /// When a prompt naming it was sent; nil until then.
    var sentAt: Date? = nil

    var id: String { name }
}

extension SessionStore {
    /// The most one attachment may be: they travel through a shell.
    static let attachmentLimit = 25_000_000

    /// The local copies of a session's attachments, in the folder a quick
    /// change keeps its screenshots in, so names never clash on the box.
    static func attachmentsFolder(for id: UUID) -> URL {
        directory(for: id).appending(path: attachmentsFolder, directoryHint: .isDirectory)
    }

    static func localAttachment(_ name: String, in id: UUID) -> URL {
        attachmentsFolder(for: id).appending(path: name)
    }

    /// Where claude finds it, from the folder claude runs in: the harness
    /// root for a session in a harness, else its worktree.
    static func attachmentPath(_ name: String, in session: CodeSession) -> String {
        let folder = ".gannin/\(attachmentsFolder)/\(name)"
        return session.harnessPath == nil ? folder : ".worktrees/\(session.branch)/\(folder)"
    }

    /// The prompt as sent with attachments: what was typed, then the paths
    /// to read. With nothing typed, the paths are the prompt.
    static func attachmentPrompt(_ text: String, paths: [String]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty else { return text }
        let list = paths.map { "`\($0)`" }.joined(separator: ", ")
        return text.isEmpty ? "Have a look at \(paths.count == 1 ? "this file" : "these files"): \(list)." : "\(text)\n\nAttached: \(list)"
    }

    /// The script that writes one attachment, from standard input, into
    /// `.gannin/attachments/` in the session's folder on its box: to a part
    /// file first, so one cut short isn't taken as there. Never makes the
    /// session's folder itself: the start script takes one that's there for
    /// a checkout, and a harness clone needs an empty one. Whatever it gives
    /// up on, it reads standard input to the end, so the write to it can't
    /// break.
    static func attachmentUploadScript(_ name: String, in session: CodeSession) -> String {
        let part = "\"$d\"/" + SessionScript.quoted(".\(name).part")
        return """
            w=\(SessionScript.shellPath(worktreePath(for: session)))
            if [ ! -d "$w" ]; then cat >/dev/null; echo "\(attachmentWaiting)" >&2; exit 1; fi
            d="$w/.gannin/\(attachmentsFolder)"
            { mkdir -p "$d" && cat > \(part) && mv \(part) "$d"/\(SessionScript.quoted(name)); } || { cat >/dev/null; exit 1; }
            """
    }

    /// Why a file wasn't copied before the session's folder was made.
    static let attachmentWaiting = "The session's folder isn't there yet. It's copied once the session has started."

    /// The names taken in the session's folder on its box: its own, its
    /// issue session's and every helper's on the same folder, and a quick
    /// change's screenshots.
    private func takenAttachmentNames(_ id: UUID) -> [String] {
        let root = sessions[id]?.parentID ?? id
        return ([root] + helpers(of: root).map(\.id)).flatMap { member in
            ((try? FileManager.default.contentsOfDirectory(atPath: Self.attachmentsFolder(for: member).path)) ?? [])
                + attachments(of: member).map(\.name) + (sessions[member]?.quickChange?.attachments ?? [])
        }
    }

    private static func attachmentRunner(_ session: CodeSession) -> Shell.Runner? {
        guard let connect = session.connect else { return .local }
        return Shell.sshArguments(connect).map { .ssh($0) }
    }

    func attachments(of id: UUID) -> [SessionAttachment] {
        sessions[id]?.attachments ?? []
    }

    func staged(in id: UUID) -> [SessionAttachment] {
        let all = attachments(of: id)
        return (stagedAttachments[id] ?? []).compactMap { name in all.first { $0.name == name } }
    }

    /// Picks an attachment to go with the next prompt, or puts it back.
    func toggleStaged(_ name: String, in id: UUID) {
        if stagedAttachments[id]?.contains(name) == true {
            stagedAttachments[id]?.removeAll { $0 == name }
        } else if attachments(of: id).contains(where: { $0.name == name && $0.uploaded }) {
            stagedAttachments[id, default: []].append(name)
        }
    }

    func isUploading(_ name: String, in id: UUID) -> Bool {
        uploadingAttachments.contains("\(id.uuidString)/\(name)")
    }

    /// Files dropped or picked, folders and those over the limit refused.
    /// Returns why any were left out.
    func addAttachments(_ urls: [URL], to id: UUID) async -> String? {
        let limit = Self.attachmentLimit
        let checked = await Task.detached { () -> (files: [Attaching], refused: [String]) in
            var files: [Attaching] = []
            var refused: [String] = []
            for url in urls where url.isFileURL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard let values, values.isDirectory != true, let size = values.fileSize, size <= limit else {
                    refused.append(url.lastPathComponent)
                    continue
                }
                files.append(Attaching(name: url.lastPathComponent, size: size, source: .file(url)))
            }
            return (files, refused)
        }.value
        await addAttachments(checked.files, to: id)
        guard !checked.refused.isEmpty else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
        return "Left out \(checked.refused.joined(separator: ", ")): only files up to \(size) can be attached, not folders."
    }

    /// What was dropped from another app: files, or an image with no file
    /// (from a browser or Preview) as a PNG. Returns whether any could be
    /// taken.
    func addDroppedAttachments(_ providers: [NSItemProvider], to id: UUID) -> Bool {
        var taken = false
        // Each file loads on its own, so each only adds to what the drop
        // has to say, cleared once here.
        attachmentNotices[id] = nil
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                taken = true
                _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        guard let note = await self.addAttachments([url], to: id) else { return }
                        self.attachmentNotices[id] = [self.attachmentNotices[id], note].compactMap { $0 }.joined(separator: " ")
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                taken = true
                _ = provider.loadObject(ofClass: NSImage.self) { @Sendable image, _ in
                    guard let png = (image as? NSImage).flatMap(Self.png) else { return }
                    Task { @MainActor in await self.addAttachmentData([("dropped-image.png", png)], to: id) }
                }
            }
        }
        if !taken { attachmentNotices[id] = "Only files and images can be attached." }
        return taken
    }

    nonisolated static func png(_ image: NSImage) -> Data? {
        image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }

    /// The clipboard's files, or its image as a PNG. Returns why nothing was
    /// added, if nothing was.
    func pasteAttachments(to id: UUID) async -> String? {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return await addAttachments(urls, to: id)
        }
        guard let image = NSImage(pasteboard: pasteboard), let png = Self.png(image) else {
            return "There's no image or file on the clipboard."
        }
        await addAttachmentData([("pasted-image.png", png)], to: id)
        return nil
    }

    func addAttachmentData(_ files: [(name: String, data: Data)], to id: UUID) async {
        await addAttachments(files.map { Attaching(name: $0.name, size: $0.data.count, source: .data($0.data)) }, to: id)
    }

    /// A file on its way in, from a file or from data.
    nonisolated struct Attaching: Sendable {
        nonisolated enum Source: Sendable { case file(URL), data(Data) }
        let name: String
        let size: Int
        let source: Source
    }

    /// Names and lists each file at once, so another drop meanwhile can't
    /// take a name; keeps its copy here, written off the main actor; then
    /// copies it to the box and adds it to the next prompt.
    private func addAttachments(_ files: [Attaching], to id: UUID) async {
        guard !files.isEmpty, sessions[id] != nil else { return }
        let names = Self.attachmentNames(files.map(\.name), existing: takenAttachmentNames(id))
        let added = zip(names, files).map { SessionAttachment(name: $0, addedAt: .now, size: $1.size) }
        let keys = names.map { "\(id.uuidString)/\($0)" }
        uploadingAttachments.formUnion(keys)
        update(id) { $0.attachments = ($0.attachments ?? []) + added }
        let folder = Self.attachmentsFolder(for: id)
        let jobs = zip(names, files.map(\.source)).map { (name: $0, source: $1) }
        let written = await Task.detached { () -> [String] in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return jobs.compactMap { job in
                let target = folder.appending(path: job.name)
                switch job.source {
                case .file(let url): return (try? FileManager.default.copyItem(at: url, to: target)) != nil ? job.name : nil
                case .data(let data): return (try? data.write(to: target, options: .atomic)) != nil ? job.name : nil
                }
            }
        }.value
        uploadingAttachments.subtract(keys)
        let failed = Set(names).subtracting(written)
        if !failed.isEmpty {
            update(id) { $0.attachments?.removeAll { failed.contains($0.name) } }
            attachmentNotices[id] = "Couldn't keep \(failed.sorted().joined(separator: ", ")) on this Mac to attach."
        }
        // Each goes with the next prompt once claude can read it.
        for name in written {
            await upload(name, in: id)
            if attachments(of: id).contains(where: { $0.name == name && $0.uploaded }), stagedAttachments[id]?.contains(name) != true {
                stagedAttachments[id, default: []].append(name)
            }
        }
    }

    /// Copies what isn't on the box yet: on start, once its folder is there.
    func retryAttachments(_ id: UUID) {
        let pending = attachments(of: id).filter { !$0.uploaded && !isUploading($0.name, in: id) }
        guard !pending.isEmpty else { return }
        Task {
            for attachment in pending { await upload(attachment.name, in: id) }
        }
    }

    /// Copies an attachment's local copy to the box: again, after a failure.
    func upload(_ name: String, in id: UUID) async {
        guard let session = sessions[id] else { return }
        let key = "\(id.uuidString)/\(name)"
        guard !uploadingAttachments.contains(key) else { return }
        uploadingAttachments.insert(key)
        defer { uploadingAttachments.remove(key) }
        attachmentErrors[id]?[name] = nil
        guard let runner = Self.attachmentRunner(session) else {
            attachmentErrors[id, default: [:]][name] = "The server isn't reached with ssh, so files can't be copied to it."
            return
        }
        let file = Self.localAttachment(name, in: id)
        let script = Self.attachmentUploadScript(name, in: session)
        let result = await Task.detached { () -> Shell.Result? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return Shell.run(script, runner, input: data)
        }.value
        guard let result, result.ok else {
            let reason = result.map { $0.error.isEmpty ? "Couldn't copy it to where claude runs." : $0.error } ?? "Its copy on this Mac is gone."
            attachmentErrors[id, default: [:]][name] = reason
            return
        }
        setAttachment(name, in: id) { $0.uploaded = true }
    }

    /// Sends a prompt with the attachments picked for it, and marks them
    /// sent once it's in the terminal.
    @discardableResult
    func submit(_ text: String, withAttachmentsTo id: UUID) -> Bool {
        guard let session = sessions[id] else { return false }
        let staged = staged(in: id)
        let prompt = Self.attachmentPrompt(text, paths: staged.map { Self.attachmentPath($0.name, in: session) })
        guard !prompt.isEmpty, submit(prompt, to: id) else { return false }
        stagedAttachments[id] = nil
        let names = Set(staged.map(\.name))
        guard !names.isEmpty else { return true }
        update(id) { session in
            for index in session.attachments?.indices ?? 0..<0 where names.contains(session.attachments![index].name) {
                session.attachments![index].sentAt = .now
            }
        }
        return true
    }

    func setAttachmentSent(_ name: String, _ sent: Bool, in id: UUID) {
        setAttachment(name, in: id) { $0.sentAt = sent ? .now : nil }
    }

    /// Takes it off the list, deleting the copy here and, best effort, on
    /// the box.
    func removeAttachment(_ name: String, from id: UUID) {
        guard let session = sessions[id] else { return }
        stagedAttachments[id]?.removeAll { $0 == name }
        attachmentErrors[id]?[name] = nil
        update(id) { $0.attachments?.removeAll { $0.name == name } }
        // A quick change's screenshot of the same name never gets here:
        // names are unique across both.
        try? FileManager.default.removeItem(at: Self.localAttachment(name, in: id))
        deleteAttachmentsOnBox([name], of: session)
    }

    /// Deletes attachments from the session's folder on its box, best
    /// effort: on Remove, and when the session is forgotten, so a later
    /// session on the branch can't find them.
    func deleteAttachmentsOnBox(_ names: [String], of session: CodeSession) {
        guard !names.isEmpty, let runner = Self.attachmentRunner(session) else { return }
        let folder = SessionScript.shellPath(Self.worktreePath(for: session) + "/.gannin/" + Self.attachmentsFolder)
        let script = "cd \(folder) 2>/dev/null || exit 0\nrm -f " + names.map(SessionScript.quoted).joined(separator: " ")
        Task.detached { _ = Shell.run(script, runner) }
    }

    private func setAttachment(_ name: String, in id: UUID, _ change: (inout SessionAttachment) -> Void) {
        update(id) { session in
            guard let index = session.attachments?.firstIndex(where: { $0.name == name }) else { return }
            change(&session.attachments![index])
        }
    }
}

/// In a session's panel: what's been dropped or pasted for claude, each
/// clicked to go with the next prompt, and whether it's been sent.
struct SessionAttachmentsSection: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession

    var body: some View {
        let attachments = sessions.attachments(of: session.id)
        let error = sessions.attachmentNotices[session.id]
        let staged = Set(sessions.stagedAttachments[session.id] ?? [])
        Section {
            ForEach(attachments) { attachment in
                row(attachment, staged: staged.contains(attachment.name))
            }
            if attachments.isEmpty {
                Text("Drop files anywhere on this panel, or paste a screenshot, to copy them to where claude runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Paste") {
                    Task { sessions.attachmentNotices[session.id] = await sessions.pasteAttachments(to: session.id) }
                }
                .help("Attach the image or files on the clipboard")
                Button("Add Files") { choose() }
                    .help("Pick files to attach")
                Spacer()
            }
        } header: {
            Text("Attachments")
        } footer: {
            if !attachments.isEmpty {
                Text("New ones go with the next prompt you send from the bar under the terminal; click one to add it or leave it out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ attachment: SessionAttachment, staged: Bool) -> some View {
        let uploading = sessions.isUploading(attachment.name, in: session.id)
        let failure = sessions.attachmentErrors[session.id]?[attachment.name]
        return Button {
            sessions.toggleStaged(attachment.name, in: session.id)
        } label: {
            HStack(spacing: 10) {
                AttachmentThumbnail(url: SessionStore.localAttachment(attachment.name, in: session.id), side: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name).lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if staged {
                    Image(systemName: "paperclip").foregroundStyle(Color.accentColor)
                        .help("Goes with the next prompt")
                }
                status(attachment, uploading: uploading, failure: failure)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(failure ?? (attachment.uploaded
            ? (staged ? "Click to leave it out of the next prompt" : "Click to add it to the next prompt")
            : uploading ? "Copying it to where claude runs" : "Not copied to where claude runs yet; Try Again is in its menu"))
        .contextMenu {
            Button(staged ? "Remove from Prompt" : "Add to Prompt") { sessions.toggleStaged(attachment.name, in: session.id) }
                .disabled(!attachment.uploaded)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SessionStore.attachmentPath(attachment.name, in: session), forType: .string)
            }
            Button(attachment.sentAt == nil ? "Mark as Sent" : "Mark as Not Sent") {
                sessions.setAttachmentSent(attachment.name, attachment.sentAt == nil, in: session.id)
            }
            if !attachment.uploaded && !uploading {
                Button("Try Again") { Task { await sessions.upload(attachment.name, in: session.id) } }
            }
            Divider()
            Button("Remove", role: .destructive) { sessions.removeAttachment(attachment.name, from: session.id) }
        }
    }

    @ViewBuilder
    private func status(_ attachment: SessionAttachment, uploading: Bool, failure: String?) -> some View {
        if uploading {
            ProgressView().controlSize(.small)
        } else if failure != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if !attachment.uploaded {
            Text("Not copied")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let sent = attachment.sentAt {
            Text("Sent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Sent \(sent.formatted(.relative(presentation: .named)))")
        } else {
            Text("Not sent")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Files to copy to where claude runs."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { sessions.attachmentNotices[session.id] = await sessions.addAttachments(urls, to: session.id) }
    }
}

/// The attachments going with the next prompt, over the bar's text field:
/// each a thumbnail, put back with its ×.
struct StagedAttachmentsStrip: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession

    var body: some View {
        let staged = sessions.staged(in: session.id)
        if !staged.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(staged) { attachment in
                        VStack(spacing: 3) {
                            AttachmentThumbnail(url: SessionStore.localAttachment(attachment.name, in: session.id), side: 56)
                            Text(attachment.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 72)
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                sessions.toggleStaged(attachment.name, in: session.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.borderless)
                            .offset(x: 4, y: -4)
                            .help("Leave it out of the prompt")
                        }
                        .help(SessionStore.attachmentPath(attachment.name, in: session))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
        }
    }
}

/// A file's Quick Look thumbnail (an image, a PDF's first page), else its
/// icon.
struct AttachmentThumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
