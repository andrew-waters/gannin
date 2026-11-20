import Foundation
import Testing
@testable import Gannin

/// `AsyncFileWriter` keeps the newest save for a key, runs a removal after the
/// writes before it, and lets a clear drop what came before it without
/// dropping what came after, whether the consumer task or `flush()` gets there
/// first.
@MainActor
struct AsyncFileWriterTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "AsyncFileWriterTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func writer() -> AsyncFileWriter {
        let folder = folder
        return AsyncFileWriter(directory: folder, fileURL: { folder.appending(path: "\($0).txt") })
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    private func text(_ key: String) -> String? {
        try? String(contentsOf: folder.appending(path: "\(key).txt"), encoding: .utf8)
    }

    private func save(_ writer: AsyncFileWriter, _ key: String, _ value: String) {
        writer.save(key) { Data(value.utf8) }
    }

    private var exists: Bool { FileManager.default.fileExists(atPath: folder.path) }

    /// Waits up to five seconds for `condition`, for work that finishes on a
    /// task `settle()` doesn't cover.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func theNewestSaveForAKeyIsTheOneOnDisk() async {
        defer { clean() }
        let writer = writer()
        for number in 1...20 { save(writer, "a", "\(number)") }
        await writer.settle()
        #expect(text("a") == "20")
    }

    @Test func keysAreWrittenSeparately() async {
        defer { clean() }
        let writer = writer()
        save(writer, "a", "1")
        save(writer, "b", "2")
        await writer.settle()
        #expect(text("a") == "1")
        #expect(text("b") == "2")
    }

    @Test func aWriteMakesItsFolder() async {
        defer { clean() }
        let writer = writer()
        #expect(!exists)
        save(writer, "a", "1")
        await writer.settle()
        #expect(text("a") == "1")
    }

    @Test func flushWritesWhatTheTaskHasNotReached() {
        defer { clean() }
        let writer = writer()
        save(writer, "a", "1")
        writer.flush()
        #expect(text("a") == "1")
    }

    @Test func aFolderGoesAfterTheWritesBeforeIt() async {
        defer { clean() }
        let writer = writer()
        let session = folder.appending(path: "session", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try? Data("transcript".utf8).write(to: session.appending(path: "log"))
        // A write, then the removal of a folder: the write comes first.
        save(writer, "a", "1")
        writer.removeFolder(session)
        let gone = await eventually { !FileManager.default.fileExists(atPath: session.path) }
        #expect(gone)
        #expect(text("a") == "1")
    }

    @Test func aResetLeavesNoFolderWhateverWasQueuedBeforeIt() async {
        defer { clean() }
        let writer = writer()
        for _ in 0..<100 {
            save(writer, "a", "1")
            writer.reset()
            await writer.settle()
            #expect(!exists)
        }
    }

    /// The task can't be held back, so the sequence that lost a save (a write
    /// queued before the reset taking the save made after it) is repeated
    /// until it has had every chance to happen.
    @Test func aSaveMadeAfterAResetIsWritten() async {
        defer { clean() }
        let writer = writer()
        for round in 0..<300 {
            save(writer, "a", "0")
            writer.reset()
            save(writer, "a", "\(round)")
            await writer.settle()
            #expect(text("a") == "\(round)")
        }
    }

    @Test func aFlushAfterAResetDropsTheOldFilesAndKeepsTheNewSave() async {
        defer { clean() }
        let writer = writer()
        save(writer, "old", "1")
        writer.flush()
        #expect(text("old") == "1")

        writer.reset()
        save(writer, "new", "2")
        writer.flush()
        // As at quit: the old file is gone before the task has run.
        #expect(text("old") == nil)
        #expect(text("new") == "2")

        // The reset the task finds later has been done already, so it must not
        // remove what the flush wrote.
        await writer.settle()
        #expect(text("old") == nil)
        #expect(text("new") == "2")
    }

    @Test func settleReturnsOnceEarlierWorkHasRun() async {
        defer { clean() }
        let writer = writer()
        save(writer, "a", "1")
        await writer.settle()
        #expect(text("a") == "1")
    }
}
