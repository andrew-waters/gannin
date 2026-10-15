import Foundation
import Testing
@testable import Gannin

struct HookFileWatcherTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hooks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Waits up to two seconds for `count` to reach `target`.
    private func wait(until target: Int, _ count: @escaping () -> Int) async {
        for _ in 0..<40 where count() < target {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func readsTrimmedFilesAndLeavesMissingOnesNil() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "idle\n".write(to: directory.appending(path: "state"), atomically: true, encoding: .utf8)
        let files = HookFiles.read(in: directory)
        #expect(files.state == "idle")
        #expect(files.pullRequest == nil)
    }

    @Test func reportsAFileRewrittenInPlace() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appending(path: "state")
        try "working".write(to: state, atomically: false, encoding: .utf8)
        var changes = 0
        let watcher = HookFileWatcher(directory: directory) { changes += 1 }
        defer { watcher.cancel() }

        // What a hook's `printf idle > state` does: truncate and write the same file.
        let handle = try FileHandle(forWritingTo: state)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("idle".utf8))
        try handle.close()

        await wait(until: 1) { changes }
        #expect(changes >= 1)
        #expect(HookFiles.read(in: directory).state == "idle")
    }

    @Test func reportsAFileCreatedAfterwardsAndOneReplacedByRename() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var changes = 0
        let watcher = HookFileWatcher(directory: directory) { changes += 1 }
        defer { watcher.cancel() }

        try "starting".write(to: directory.appending(path: "state"), atomically: false, encoding: .utf8)
        await wait(until: 1) { changes }
        #expect(changes >= 1)

        // The new file is watched now, and so is the one that replaces it.
        let before = changes
        try "working".write(to: directory.appending(path: "state"), atomically: true, encoding: .utf8)
        await wait(until: before + 1) { changes }
        #expect(changes > before)

        let afterReplace = changes
        let handle = try FileHandle(forWritingTo: directory.appending(path: "state"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("idle".utf8))
        try handle.close()
        await wait(until: afterReplace + 1) { changes }
        #expect(changes > afterReplace)
    }

    @Test func burstOfWritesIsOneReport() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var changes = 0
        let watcher = HookFileWatcher(directory: directory) { changes += 1 }
        defer { watcher.cancel() }

        for name in ["state", "pr", "changed"] {
            try name.write(to: directory.appending(path: name), atomically: false, encoding: .utf8)
        }
        try await Task.sleep(for: .milliseconds(400))
        // The debounce joins a burst, though one slow write can split it.
        #expect(changes >= 1 && changes <= 2)
    }

    @Test func noReportsAfterCancel() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        var changes = 0
        let watcher = HookFileWatcher(directory: directory) { changes += 1 }
        watcher.cancel()
        try "idle".write(to: directory.appending(path: "state"), atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes == 0)
    }
}
