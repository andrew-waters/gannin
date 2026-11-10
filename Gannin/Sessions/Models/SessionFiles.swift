import AppKit
import Foundation
import Observation

/// A file an Ask session wrote: in its folder, or elsewhere as its
/// transcript says.
nonisolated struct SessionFile: Identifiable, Hashable, Sendable {
    let url: URL
    /// Its path within the session's folder (`files/users.csv`); nil for
    /// one outside it.
    let relativePath: String?
    let size: Int64
    let modified: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isElsewhere: Bool { relativePath == nil }

    /// Where it is, when that isn't plain `files/`: the folder within the
    /// session's, or the whole folder for one outside it.
    var location: String? {
        guard let relativePath else {
            let folder = url.deletingLastPathComponent().path, home = FileManager.default.homeDirectoryForCurrentUser.path
            return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
        }
        let folder = (relativePath as NSString).deletingLastPathComponent
        return folder == SessionFiles.filesFolder ? nil : (folder.isEmpty ? nil : folder + "/")
    }
}

/// The files an Ask session has written, for its Files pane: everything in
/// its folder but Gannin's own (`.gannin/`, the org data in `context/`),
/// and what its transcript says claude wrote outside it. Read by walking the
/// folder, since a file an MCP tool or a script writes fires no hook.
@Observable
final class SessionFiles {
    /// Where the brief tells claude to save what it makes.
    nonisolated static let filesFolder = "files"
    /// Gannin's, not the session's: its brief and hooks, and the org data.
    nonisolated static let skipped: Set<String> = [".gannin", "context"]
    /// Enough for anything a conversation makes; a script that unpacks
    /// thousands shouldn't stall the pane.
    nonisolated static let limit = 1000

    private(set) var files: [SessionFile] = []
    private(set) var loaded = false
    /// More than `limit` were in the folder, so some aren't listed.
    private(set) var truncated = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var again: (URL, [String])?

    var inFolder: [SessionFile] { files.filter { !$0.isElsewhere } }
    var elsewhere: [SessionFile] { files.filter(\.isElsewhere) }

    /// Reads the folder again, with `edited` (the transcript's paths) for
    /// files outside it. A call while one runs reads once more when done.
    func refresh(folder: URL, edited: [String]) async {
        guard !refreshing else {
            again = (folder, edited)
            return
        }
        refreshing = true
        defer { refreshing = false }
        var next: (URL, [String])? = (folder, edited)
        while let pending = next {
            let (folder, edited) = pending
            again = nil
            let (found, truncated) = await Task.detached { Self.scan(folder: folder, edited: edited) }.value
            // Left alone when nothing changed, so the list doesn't redraw
            // every two seconds.
            if found != files { files = found }
            if truncated != self.truncated { self.truncated = truncated }
            loaded = true
            next = again
        }
    }

    /// Every file in `folder` but Gannin's, and those of `edited` outside
    /// it that are still there, newest first.
    nonisolated static func scan(folder: URL, edited: [String]) -> ([SessionFile], Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var found: [SessionFile] = []
        var truncated = false

        func file(_ url: URL, relativePath: String?) -> SessionFile? {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return SessionFile(url: url, relativePath: relativePath, size: Int64(values.fileSize ?? 0),
                               modified: values.contentModificationDate ?? .distantPast)
        }

        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath) else { continue }
                let relative = String(path.dropFirst(rootPath.count))
                let name = url.lastPathComponent
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if (enumerator.level == 1 && skipped.contains(name)) || name == ".git" || name == "node_modules" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if name == ".DS_Store" { continue }
                guard found.count < limit else {
                    truncated = true
                    break
                }
                if let file = file(url, relativePath: relative) { found.append(file) }
            }
        }

        var seen = Set(found.map(\.url.path))
        for path in edited {
            let url = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            guard !url.path.hasPrefix(rootPath), seen.insert(url.path).inserted else { continue }
            if let file = file(url, relativePath: nil) { found.append(file) }
        }
        found.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.url.path < $1.url.path }
        return (found, truncated)
    }

    // MARK: Actions

    static func open(_ file: SessionFile) {
        NSWorkspace.shared.open(file.url)
    }

    /// The apps that can open it, its default first.
    static func applications(for file: SessionFile) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: file.url)
        guard let preferred = NSWorkspace.shared.urlForApplication(toOpen: file.url) else { return all }
        return [preferred] + all.filter { $0.standardizedFileURL != preferred.standardizedFileURL }
    }

    static func open(_ file: SessionFile, with application: URL) {
        NSWorkspace.shared.open([file.url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ file: SessionFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// The file itself on the pasteboard, as Finder's Copy puts it, so it
    /// pastes into Finder, Mail or Slack.
    static func copy(_ file: SessionFile) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([file.url as NSURL])
    }

    /// Asks where, then copies it there; the panel has already asked about
    /// replacing a file of that name. Returns why it failed.
    static func saveCopy(of file: SessionFile) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: copyToTemporary(file.url))
            } else {
                try FileManager.default.copyItem(at: file.url, to: destination)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// `replaceItemAt` moves its source, so the original is copied aside first.
    private static func copyToTemporary(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}
