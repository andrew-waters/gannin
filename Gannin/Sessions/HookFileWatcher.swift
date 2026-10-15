import Foundation

/// What a local session's hooks last wrote in its folder, each trimmed.
nonisolated struct HookFiles: Sendable {
    static let names = ["state", "pr", "changed", "statusline", "review-request", "sandbox"]

    var state, pullRequest, changed, statusLine, reviewRequest, sandbox: String?

    static func read(in directory: URL) -> HookFiles {
        func read(_ name: String) -> String? {
            (try? String(contentsOf: directory.appending(path: name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return HookFiles(state: read("state"), pullRequest: read("pr"), changed: read("changed"), statusLine: read("statusline"),
                         reviewRequest: read("review-request"), sandbox: read("sandbox"))
    }
}

/// Calls `onChange` once, shortly after a session's hook files change.
/// Hooks write with `>`, which rewrites a file that exists in place, so the
/// folder's own events miss it: each file is watched too, and the folder's
/// events pick up files created later.
final class HookFileWatcher {
    private let directory: URL
    private let onChange: () -> Void
    private var folder: DispatchSourceFileSystemObject?
    private var files: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
        attach()
    }

    // A source that's resumed and never cancelled stays alive with its
    // descriptor open, whatever releases the watcher.
    isolated deinit {
        cancel()
    }

    /// Watches whatever isn't watched yet: the folder and files that didn't
    /// exist at the last attempt.
    func attach() {
        if folder == nil { folder = source(directory.path, mask: .write, name: nil) }
        for name in HookFiles.names where files[name] == nil {
            files[name] = source(directory.appending(path: name).path, mask: [.write, .extend, .delete, .rename], name: name)
        }
    }

    func cancel() {
        pending?.cancel()
        folder?.cancel()
        folder = nil
        for source in files.values { source.cancel() }
        files = [:]
    }

    private func source(_ path: String, mask: DispatchSource.FileSystemEvent, name: String?) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed(name) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func changed(_ name: String?) {
        // A deleted or replaced file's descriptor points at the old one.
        if let name, let source = files[name], !source.data.isDisjoint(with: [.delete, .rename]) {
            source.cancel()
            files[name] = nil
        }
        attach()
        // A hook can write several files in a burst.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }
}
